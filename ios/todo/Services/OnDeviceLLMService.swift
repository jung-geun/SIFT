import Foundation
import Combine
import UIKit

// MARK: - On-Device LLM Service

/// 온디바이스 LLM(Qwen3.5/MLX) 모델 수명주기 관리 싱글턴.
///
/// ⚠️ 프라이버시 불변식: 모든 추론은 기기 내에서 완결됨. 네트워크 미전송.
///   (최초 실행 시에만 HuggingFace에서 모델 가중치 다운로드 — 사용자 동의 필요)
///
/// 기본 모델: mlx-community/Qwen3.5-4B-MLX-4bit (~2.3GB)
///   - mlx-swift-lm 3.x + mlx-swift 0.31.4 기준 qwen3_5 타입 지원
///   - UserDefaults "pieroot.todo.onDeviceModelID"로 커스텀 모델 ID 지정 가능
///   - `isCapable`: 실제 메모리 6GB 이상 기기 (iPhone 15/16 이상)
///   - OOM/로드 실패 → 각 엔진이 NSDataDetector/Heuristic으로 폴백
///
/// 패키지 설치 방법 (Xcode GUI):
///   File → Add Package Dependencies →
///   https://github.com/ml-explore/mlx-swift-examples
///   branch: main → MLXLLM, MLXLMCommon 추가
#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import MLX

@MainActor
final class OnDeviceLLMService: ObservableObject {

    static let shared = OnDeviceLLMService()

    @Published var isModelLoaded = false
    @Published var isLoading = false
    @Published var isDeleting = false
    @Published var loadError: String?
    @Published var downloadProgress: Double = 0
    @Published var downloadInterrupted = false

    /// 지원 모델 카탈로그 — 설정 화면 Picker와 모델 관리 UI에 사용.
    struct ModelOption: Identifiable {
        let id: String          // HuggingFace 모델 ID (UserDefaults 저장값)
        let displayName: String // 설정 화면 표시명
        let sizeMB: Int         // 예상 다운로드 크기(MB)
    }
    static let modelCatalog: [ModelOption] = [
        // ── 범용 Qwen 모델 (성능 비교용) ──────────────────────────
        ModelOption(
            id: "mlx-community/Qwen3.5-2B-MLX-4bit",
            displayName: "Qwen3.5-2B · 4bit (범용, ~1.4GB)",
            sizeMB: 1400
        ),
        ModelOption(
            id: "mlx-community/Qwen3.5-4B-MLX-4bit",
            displayName: "Qwen3.5-4B · 4bit (범용 고품질, ~2.4GB)",
            sizeMB: 2400
        ),
    ]
    /// 기본 모델: Qwen 2B 모델.
    /// UserDefaults "pieroot.todo.onDeviceModelID"로 기기당 재지정 가능.
    static let defaultModelID = "mlx-community/Qwen3.5-2B-MLX-4bit"
    /// 입력 컨텍스트 최대 토큰 수. 기본 4K로 메모리 절약 (Qwen3.5-2B는 32K 지원).
    static let defaultContextLength = 4096
    /// MLXLLM 패키지가 Xcode에 추가되어 있는지 여부. false면 모든 기능이 stub.
    static let isMLXAvailable = true

    /// UserDefaults에 저장된 커스텀 모델 ID. 없으면 defaultModelID 반환.
    var modelID: String {
        UserDefaults.standard.string(forKey: "pieroot.todo.onDeviceModelID") ?? Self.defaultModelID
    }

    private var container: ModelContainer?
    /// 실제 로드된 모델 ID — 삭제 시 정확한 캐시 경로 계산에 사용.
    private var loadedModelID: String?

    // MARK: - 수명주기 옵저버 상태
    /// 백그라운드 진입 알림 관찰 토큰 (앱 수명 동안 유지)
    private var backgroundToken: Any?
    /// 메모리 부족 알림 관찰 토큰
    private var memoryToken: Any?
    /// 마지막 generate() 후 유휴 자동 언로드 타이머 (120초)
    private var idleTimer: Task<Void, Never>?
    /// 현재 실행 중인 loadModelIfNeeded() 래핑 태스크 — 백그라운드 진입 시 즉시 취소에 사용.
    private var loadingTask: Task<Void, Never>?
    /// 현재 실행 중인 generate() 태스크 — 백그라운드 진입 시 즉시 취소에 사용.
    private var generationTask: Task<String, Error>?
    /// generate()가 CancellationError를 LLMError.cancelled로 변환할 때 첨부할 사유.
    private(set) var lastUnloadReason: UnloadReason?

    var isCapable: Bool {
        ProcessInfo.processInfo.physicalMemory >= 6 * 1_024 * 1_024 * 1_024
    }

    /// HuggingFace 캐시 디렉터리에 모델 파일이 있는지 확인.
    var isModelCachedOnDisk: Bool {
        let fm = FileManager.default
        let slug = modelID.replacingOccurrences(of: "/", with: "--")
        let dirs: [URL] = [
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ].compactMap { $0 }
        return dirs.contains { base in
            fm.fileExists(atPath: base.appendingPathComponent("huggingface/hub/models--\(slug)").path)
        }
    }

    private init() {
        setupLifecycleObservers()
    }

    func loadModelIfNeeded() async {
        guard isCapable, !isModelLoaded, !isLoading else { return }
        let task = Task<Void, Never> { [weak self] in await self?.performLoad() }
        loadingTask = task
        await task.value
    }

    private func performLoad() async {
        isLoading = true
        loadError = nil
        downloadInterrupted = false
        downloadProgress = 0
        defer {
            isLoading = false
            loadingTask = nil
            // 완료·오류 없이 로딩이 중단된 경우(백그라운드 진입, Task 취소 등)
            if !isModelLoaded && loadError == nil && downloadProgress > 0.01 {
                downloadInterrupted = true
            }
        }
        do {
            try Task.checkCancellation()
            let idToLoad = modelID
            let config = ModelConfiguration(id: idToLoad)
            container = try await LLMModelFactory.shared.loadContainer(
                from: HuggingFaceHubDownloader(),
                using: JSONBPETokenizerLoader(),
                configuration: config,
                progressHandler: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = progress.fractionCompleted
                    }
                }
            )
            loadedModelID = idToLoad
            isModelLoaded = true
            downloadInterrupted = false
            MLX.Memory.cacheLimit = 512 * 1_024 * 1_024
        } catch is CancellationError {
            // Task 취소 — 오류 메시지 없이 interrupted 상태로 처리
        } catch {
            loadError = error.localizedDescription
        }
    }

    func unloadModel(reason: UnloadReason = .manual) {
        lastUnloadReason = reason
        if generationTask != nil {
            print("[OnDeviceLLM] ⚠️ 진행 중인 generate 취소 — 사유: \(reason.rawValue)")
        }
        loadingTask?.cancel()
        loadingTask = nil
        generationTask?.cancel()
        generationTask = nil
        idleTimer?.cancel()
        idleTimer = nil
        container = nil
        isModelLoaded = false
        MLX.Memory.cacheLimit = 0
    }

    // MARK: - Lifecycle Observers

    /// 백그라운드 진입 / 메모리 경고 시 모델 자동 언로드 등록.
    ///
    /// willResignActive(didEnterBackground보다 먼저 발생)에서 in-flight 로딩·generate()를
    /// 즉시 취소한 뒤 언로드한다. didEnterBackground는 이미 GPU 접근이 차단된 후라
    /// Metal crash 방지에 충분하지 않다.
    private func setupLifecycleObservers() {
        // didEnterBackground: 앱이 실제로 백그라운드로 전환될 때만 취소+언로드.
        // willResignActive는 알림 배너·Dynamic Island 오버레이·FaceID 등 순간적
        // 포커스 이탈에도 발화해 inference를 오탐 취소하므로 사용하지 않는다.
        // todoApp.swift의 scenePhase(.background) 핸들러와 이중 보호 구조.
        backgroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.unloadModel(reason: .background)
            }
        }
        // 메모리 경고 시 언로드 (~1-2.4GB 상주 해제)
        // os_proc_available_memory() 로그로 실제 헤드룸 측정 (defer-unload 판단용 데이터)
        memoryToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isModelLoaded else { return }
                let avail = os_proc_available_memory()
                print("[OnDeviceLLM] ⚠️ 메모리 경고 — 가용 메모리: \(avail / 1_024 / 1_024)MB → 언로드")
                self.unloadModel(reason: .memoryWarning)
            }
        }
    }

    /// generate() 완료 후 호출. 120초 유휴 시 자동 언로드한다.
    /// 연속 호출 시 타이머가 리셋되어 마지막 추론 완료로부터 120초를 센다.
    private func resetIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(120)) }
            catch { return }  // 취소됨 (unloadModel 또는 새 generate 호출)
            // generate()가 진행 중이면 유휴 언로드를 건너뜀 (이중 안전)
            guard let self, self.generationTask == nil else { return }
            self.unloadModel(reason: .idleTimeout)
        }
    }

    func deleteDownloadedModel() async {
        isDeleting = true
        defer { isDeleting = false }
        let idToDelete = loadedModelID ?? modelID
        unloadModel(reason: .modelDelete)
        loadedModelID = nil
        downloadInterrupted = false
        downloadProgress = 0
        let fm = FileManager.default
        let slug = idToDelete.replacingOccurrences(of: "/", with: "--")
        let searchDirs: [URL] = [
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ].compactMap { $0 }
        for base in searchDirs {
            let candidate = base.appendingPathComponent("huggingface/hub/models--\(slug)")
            try? fm.removeItem(at: candidate)
        }
    }

    /// 시스템 프롬프트 + 사용자 프롬프트로 텍스트 생성 (JSON 출력 용도).
    /// Qwen3.5 ChatML + 빈 <think> 블록으로 thinking mode 비활성화 → JSON 직접 출력.
    /// contextLength: 입력 최대 토큰 수(기본 8192). Qwen3.5-4B는 32K까지 지원하나 메모리 절약.
    func generate(systemPrompt: String, userPrompt: String, maxTokens: Int = 512, contextLength: Int = 8192) async throws -> String {
        guard let container else { throw LLMError.modelNotLoaded }
        guard UIApplication.shared.applicationState == .active else { throw LLMError.appInBackground }
        // 직전 generate의 유휴 타이머가 이번 추론 중 발화하지 못하도록 선제 차단
        idleTimer?.cancel()
        idleTimer = nil
        // 실측 가용 메모리 로깅 — defer-unload 판단 기준 데이터 수집
        let availAtStart = os_proc_available_memory()
        print("[OnDeviceLLM] 🚀 generate 시작 — 가용 메모리: \(availAtStart / 1_024 / 1_024)MB, maxTokens: \(maxTokens)")

        let maxUserChars = max(200, contextLength * 3 - systemPrompt.count - 100)
        let trimmedUser = userPrompt.count > maxUserChars
            ? String(userPrompt.prefix(maxUserChars)) + "\n...[이하 생략]"
            : userPrompt
        let prompt = "<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\n\(trimmedUser)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n"

        let task = Task<String, Error> {
            try await container.perform { context in
                let input = try await context.processor.prepare(input: .init(prompt: prompt))
                let stream = try MLXLMCommon.generate(
                    input: input,
                    parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.1),
                    context: context
                )
                var output = ""
                var iterator = stream.makeAsyncIterator()
                while true {
                    // Metal GPU 명령 제출 전에 취소 확인 — for-await post-check 대비 race window 최소화
                    try Task.checkCancellation()
                    guard let generation = await iterator.next() else { break }
                    if let chunk = generation.chunk { output += chunk }
                }
                return output
            }
        }
        generationTask = task
        defer { generationTask = nil }

        let result: String
        do {
            result = try await task.value
        } catch is CancellationError {
            throw LLMError.cancelled(reason: lastUnloadReason)
        }
        resetIdleTimer()
        return result
    }

    // MARK: - 언로드 사유 계측

    /// 모델 언로드 사유 — generate() 취소 에러에 actionable 정보를 추가한다.
    enum UnloadReason: String {
        case background    = "백그라운드 전환"
        case memoryWarning = "메모리 부족 경고"
        case idleTimeout   = "유휴 타임아웃 120초"
        case modelDelete   = "모델 삭제"
        case manual        = "수동"
    }

    enum LLMError: LocalizedError {
        case modelNotLoaded
        case appInBackground
        case cancelled(reason: UnloadReason?)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "모델이 로드되지 않았습니다. 설정 > 온디바이스 모델 관리에서 상태를 확인하세요."
            case .appInBackground:
                return "앱이 백그라운드 상태입니다. 화면을 켠 상태에서 다시 시도해주세요."
            case .cancelled(let reason):
                let hint: String
                switch reason {
                case .memoryWarning:
                    hint = "실행 중인 영상·다른 앱을 닫고 다시 시도해주세요."
                default:
                    hint = "다시 시도해주세요."
                }
                return "온디바이스 분석이 중단되었습니다 (사유: \(reason?.rawValue ?? "알 수 없음")).\n\(hint)"
            }
        }
    }
}

// MARK: - HuggingFace Hub Downloader

/// Foundation-only downloader that fetches model snapshots from the HuggingFace Hub API.
private struct HuggingFaceHubDownloader: MLXLMCommon.Downloader, @unchecked Sendable {

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let rev = revision ?? "main"
        let slug = id.replacingOccurrences(of: "/", with: "--")
        let cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("huggingface/hub/models--\(slug)/snapshots/\(rev)")

        if !useLatest, isAdequatelyCached(cacheDir, patterns: patterns) {
            let p = Progress(totalUnitCount: 1)
            p.completedUnitCount = 1
            progressHandler(p)
            return cacheDir
        }

        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Fetch file listing from HuggingFace Hub API
        let apiURL = URL(string: "https://huggingface.co/api/models/\(id)/tree/\(rev)?recursive=true")!
        let (listData, listResponse) = try await URLSession.shared.data(from: apiURL)
        guard (listResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let allFiles = try JSONDecoder().decode([HFFileEntry].self, from: listData)

        // Filter to files (blobs) matching any of the requested glob patterns
        let toDownload = allFiles.filter { entry in
            (entry.type == "blob" || entry.type == "file") && patterns.contains { pat in
                if pat == "*" { return true }
                if pat.hasPrefix("*.") { return entry.path.hasSuffix(String(pat.dropFirst(1))) }
                return entry.path == pat || entry.path.hasSuffix("/\(pat)")
            }
        }

        let overallProgress = Progress(totalUnitCount: Int64(toDownload.count))

        for entry in toDownload {
            let dest = cacheDir.appendingPathComponent(entry.path)
            if FileManager.default.fileExists(atPath: dest.path) {
                overallProgress.completedUnitCount += 1
                progressHandler(overallProgress)
                continue
            }
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

            let fileURL = URL(string: "https://huggingface.co/\(id)/resolve/\(rev)/\(entry.path)")!
            let (tmpURL, _) = try await URLSession.shared.download(from: fileURL)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpURL, to: dest)

            overallProgress.completedUnitCount += 1
            progressHandler(overallProgress)
        }

        return cacheDir
    }

    private func isAdequatelyCached(_ dir: URL, patterns: [String]) -> Bool {
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        let needsSafetensors = patterns.contains { $0.contains("safetensors") }
        let needsJson = patterns.contains { $0.contains("json") }
        var hasSafetensors = false
        var hasConfigJson = false
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        for case let url as URL in enumerator ?? NSEnumerator() {
            if url.pathExtension == "safetensors" { hasSafetensors = true }
            if url.lastPathComponent == "config.json" { hasConfigJson = true }
            if hasSafetensors && hasConfigJson { break }
        }
        if needsSafetensors && !hasSafetensors { return false }
        if needsJson && !hasConfigJson { return false }
        return true
    }
}

private struct HFFileEntry: Decodable {
    let type: String
    let path: String
}

// MARK: - JSON BPE Tokenizer Loader

/// Loads a byte-level BPE tokenizer from a local `tokenizer.json` file.
private struct JSONBPETokenizerLoader: MLXLMCommon.TokenizerLoader, @unchecked Sendable {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        return try BPETokenizer(directory: directory)
    }
}

// MARK: - Byte-Level BPE Tokenizer

/// Minimal byte-level BPE tokenizer compatible with Qwen/GPT-2 style `tokenizer.json`.
///
/// `applyChatTemplate` always throws `missingChatTemplate` so that
/// `LLMUserInputProcessor` falls back to `encode(text:)`, which correctly
/// encodes the pre-formatted ChatML prompt produced by `OnDeviceLLMService.generate`.
private final class BPETokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {

    private let vocab: [String: Int]
    private let idToToken: [Int: String]
    private let mergeRanks: [String: Int]
    private let addedTokens: [String: Int]
    private let addedTokenIds: Set<Int>
    private let byteEncoder: [UInt8: Character]
    private let byteDecoder: [Character: UInt8]

    let bosToken: String?
    let eosToken: String?
    let unknownToken: String?

    init(directory: URL) throws {
        let tokenizerURL = directory.appendingPathComponent("tokenizer.json")
        let data = try Data(contentsOf: tokenizerURL)
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let model = json["model"] as? [String: Any],
            let rawVocab = model["vocab"] as? [String: Any]
        else {
            throw NSError(
                domain: "BPETokenizer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid tokenizer.json"])
        }
        // merges는 [String] 또는 [[String]] 두 형식 모두 지원
        let rawMerges: [String]
        if let nested = model["merges"] as? [[String]] {
            rawMerges = nested.map { $0.joined(separator: " ") }
        } else if let flat = model["merges"] as? [String] {
            rawMerges = flat
        } else {
            rawMerges = []
        }

        var v = [String: Int]()
        for (token, idAny) in rawVocab {
            if let id = idAny as? Int { v[token] = id }
        }

        var specials = [String: Int]()
        if let addedList = json["added_tokens"] as? [[String: Any]] {
            for t in addedList {
                guard let content = t["content"] as? String,
                      let id = t["id"] as? Int else { continue }
                specials[content] = id
                if v[content] == nil { v[content] = id }
            }
        }

        vocab = v
        idToToken = Dictionary(uniqueKeysWithValues: v.map { ($1, $0) })
        mergeRanks = Dictionary(
            uniqueKeysWithValues: rawMerges.enumerated().map { ($1, $0) })
        addedTokens = specials
        addedTokenIds = Set(specials.values)
        byteEncoder = BPETokenizer.buildByteEncoder()
        byteDecoder = Dictionary(uniqueKeysWithValues: byteEncoder.map { ($1, $0) })

        // Read special token names from tokenizer_config.json
        var bos: String? = nil
        var eos: String? = nil
        var unk: String? = nil
        let configURL = directory.appendingPathComponent("tokenizer_config.json")
        if let cfgData = try? Data(contentsOf: configURL),
           let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any] {
            bos = BPETokenizer.extractTokenString(cfg["bos_token"])
            eos = BPETokenizer.extractTokenString(cfg["eos_token"])
            unk = BPETokenizer.extractTokenString(cfg["unk_token"])
        }
        bosToken = bos
        eosToken = eos
        unknownToken = unk
    }

    // MARK: - Tokenizer Protocol

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        guard !text.isEmpty else { return [] }
        // Sort special tokens longest-first for greedy prefix matching
        let sortedSpecials = addedTokens.keys.sorted { $0.count > $1.count }
        var ids = [Int]()
        var remaining = text
        while !remaining.isEmpty {
            var foundSpecial = false
            for special in sortedSpecials {
                guard let range = remaining.range(of: special) else { continue }
                // Encode text before the special token using BPE
                let before = String(remaining[remaining.startIndex..<range.lowerBound])
                if !before.isEmpty { ids += bpeEncodeText(before) }
                if let sid = addedTokens[special] { ids.append(sid) }
                remaining = String(remaining[range.upperBound...])
                foundSpecial = true
                break
            }
            if !foundSpecial {
                ids += bpeEncodeText(remaining)
                break
            }
        }
        return ids
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        var result = ""
        for id in tokenIds {
            guard let token = idToToken[id] else { continue }
            if addedTokenIds.contains(id) {
                if !skipSpecialTokens { result += token }
                continue
            }
            // Reconstruct bytes from the unicode-encoded token chars
            var bytes = [UInt8]()
            for scalar in token.unicodeScalars {
                let ch = Character(scalar)
                if let b = byteDecoder[ch] { bytes.append(b) }
            }
            result += String(bytes: bytes, encoding: .utf8) ?? ""
        }
        return result
    }

    func convertTokenToId(_ token: String) -> Int? {
        vocab[token] ?? addedTokens[token]
    }

    func convertIdToToken(_ id: Int) -> String? {
        idToToken[id]
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        // Throw missingChatTemplate so LLMUserInputProcessor falls back to encode(text:),
        // which correctly encodes the pre-formatted ChatML prompt.
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }

    // MARK: - BPE Implementation

    private func bpeEncodeText(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        var ids = [Int]()
        for word in preTokenize(text) {
            let byteChars = Array(word.utf8).map { b -> String in
                String(byteEncoder[b] ?? Character(UnicodeScalar(b)))
            }
            let tokens = applyBPE(byteChars)
            ids += tokens.compactMap { vocab[$0] }
        }
        return ids
    }

    /// Splits text into pre-tokens using the GPT-2/tiktoken byte-level regex.
    private func preTokenize(_ text: String) -> [String] {
        let pattern =
            "(?i:'s|'t|'re|'ve|'m|'ll|'d)" +
            "|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+" +
            "|\\p{N}{1,3}" +
            "| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*" +
            "|\\s*[\\r\\n]+" +
            "|\\s+(?!\\S)" +
            "|\\s+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [text]
        }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { nsText.substring(with: $0.range) }
    }

    /// Applies BPE merges to a sequence of byte-level unicode characters.
    private func applyBPE(_ chars: [String]) -> [String] {
        var word = chars
        while word.count > 1 {
            var bestPriority = Int.max
            var bestIdx = -1
            for i in 0..<(word.count - 1) {
                let pair = word[i] + " " + word[i + 1]
                if let p = mergeRanks[pair], p < bestPriority {
                    bestPriority = p
                    bestIdx = i
                }
            }
            guard bestIdx >= 0 else { break }
            let merged = word[bestIdx] + word[bestIdx + 1]
            var next = Array(word[0..<bestIdx])
            next.append(merged)
            if bestIdx + 2 < word.count {
                next.append(contentsOf: word[(bestIdx + 2)...])
            }
            word = next
        }
        return word
    }

    // MARK: - Helpers

    /// GPT-2 byte-to-unicode mapping: maps every byte 0-255 to a printable unicode char.
    private static func buildByteEncoder() -> [UInt8: Character] {
        var bs = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0...255 {
            if !bs.contains(b) {
                bs.append(b)
                cs.append(256 + n)
                n += 1
            }
        }
        return Dictionary(uniqueKeysWithValues: zip(bs, cs).map {
            (UInt8($0), Character(UnicodeScalar($1)!))
        })
    }

    private static func extractTokenString(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let d = value as? [String: Any], let s = d["content"] as? String, !s.isEmpty { return s }
        return nil
    }
}

#else

// MARK: - Stub (MLXLLM 패키지 미설치 시 컴파일 유지용)
// Xcode에서 mlx-swift-examples 패키지를 추가하면 위 실 구현체로 교체됨.

@MainActor
final class OnDeviceLLMService: ObservableObject {
    static let shared = OnDeviceLLMService()
    @Published var isModelLoaded      = false
    @Published var isLoading          = false
    @Published var isDeleting         = false
    @Published var loadError: String?
    @Published var downloadProgress: Double = 0
    @Published var downloadInterrupted = false
    struct ModelOption: Identifiable {
        let id: String; let displayName: String; let sizeMB: Int
    }
    static let modelCatalog: [ModelOption] = [
        ModelOption(id: "mlx-community/Qwen3.5-2B-MLX-4bit", displayName: "Qwen3.5-2B · 4bit (범용, ~1.4GB)", sizeMB: 1400),
        ModelOption(id: "mlx-community/Qwen3.5-4B-MLX-4bit", displayName: "Qwen3.5-4B · 4bit (범용 고품질, ~2.4GB)", sizeMB: 2400),
    ]
    static let defaultModelID = "mlx-community/Qwen3.5-2B-MLX-4bit"
    static let defaultContextLength = 4096
    static let isMLXAvailable = false   // 패키지 미설치 — Xcode GUI로 추가 필요
    var modelID: String {
        UserDefaults.standard.string(forKey: "pieroot.todo.onDeviceModelID") ?? Self.defaultModelID
    }
    var isCapable: Bool { false }
    var isModelCachedOnDisk: Bool { false }
    private init() {}
    func loadModelIfNeeded() async {}
    func unloadModel() {}
    func deleteDownloadedModel() async {}
    func generate(systemPrompt: String, userPrompt: String, maxTokens: Int = 512, contextLength: Int = 8192) async throws -> String {
        throw LLMError.modelNotLoaded
    }
    enum LLMError: Error { case modelNotLoaded }
}

#endif
