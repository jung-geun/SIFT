import Foundation
import Combine
import UIKit

// MARK: - On-Device LLM Service

/// 온디바이스 LLM(Qwen3.5/MLX) 모델 수명주기 관리 싱글턴.
///
/// ⚠️ 프라이버시 불변식: 모든 추론은 기기 내에서 완결됨. 네트워크 미전송.
///   (최초 실행 시에만 HuggingFace에서 모델 가중치 다운로드 — 사용자 동의 필요)
///
/// 기본 모델: mlx-community/MiniCPM5-1B-4bit (~0.62GB)
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
#if canImport(MLXHuggingFace)
import MLXHuggingFace
#endif

@MainActor
final class OnDeviceLLMService: ObservableObject {

    static let shared = OnDeviceLLMService()

    @Published var isModelLoaded = false
    @Published var isLoading = false {
        didSet { if !isLoading { cachedModelSnapshot = nil } }
    }
    @Published var isDeleting = false {
        didSet { cachedModelSnapshot = nil }
    }
    @Published var loadError: String?
    @Published var downloadProgress: Double = 0
    @Published var downloadInterrupted = false

    /// 지원 모델 카탈로그 — 설정 화면 Picker와 모델 관리 UI에 사용.
    struct ModelOption: Identifiable {
        let id: String          // HuggingFace 모델 ID (UserDefaults 저장값)
        let displayName: String // 설정 화면 표시명
        let sizeMB: Int         // 예상 다운로드 크기(MB)
        /// 이 모델을 실행하기 위한 최소 물리 메모리(GiB, physicalMemory 보고값 기준).
        /// 6GB 기기(보고값 ~5.6–5.9 GiB)는 2B까지만, 4B는 8GB(보고값 ~7.3–7.9 GiB) 이상에서만.
        let minMemoryGiB: Double
        /// 프롬프트 맨 앞에 붙일 접두(BOS 등). 현재 지원 모델은 기본값을 사용한다.
        var promptPrefix: String = ""
        /// JSON을 직접 출력하도록 assistant 턴 뒤에 붙일 프라이머.
        /// 추론형 모델이 `<think>`를 먼저 열고 JSON 없이 토큰을 소진하는 것을 막는다.
        var assistantPrimer: String = "<think>\n\n</think>\n"
    }
    struct InstalledModel: Identifiable, Hashable {
        let id: String
        let displayName: String
        let sizeBytes: Int64
        let cachePaths: [String]
        let isSelected: Bool
        let isLoaded: Bool

        var sizeMB: Int {
            Int((sizeBytes + 1_024 * 1_024 - 1) / (1_024 * 1_024))
        }
    }

    static let modelCatalog: [ModelOption] = [
        // ── MiniCPM5 1B (MLX Community 4bit, HuggingFace chat template 사용) ─────────
        ModelOption(
            id: "mlx-community/MiniCPM5-1B-4bit",
            displayName: "MiniCPM5-1B · 4bit (~0.62 GB)",
            sizeMB: 620,
            minMemoryGiB: 5.0,
            promptPrefix: "<s>",
            assistantPrimer: "<think>\n\n</think>\n\n"
        ),
        // ── 범용 Qwen 모델 (성능 비교용) ──────────────────────────
        ModelOption(
            id: "mlx-community/Qwen3.5-2B-MLX-4bit",
            displayName: "Qwen3.5-2B · 4bit (~1.4 GB)",
            sizeMB: 1400,
            minMemoryGiB: 5.0
        ),
        ModelOption(
            id: "mlx-community/Qwen3.5-4B-MLX-4bit",
            displayName: "Qwen3.5-4B · 4bit (~2.4 GB)",
            sizeMB: 2400,
            minMemoryGiB: 7.0
        ),
    ]

    /// 현재 기기의 실측 물리 메모리(GiB). physicalMemory는 마케팅 용량보다 약간 낮게 보고됨
    /// (예: "6GB" 기기 → ~5.6–5.9 GiB, "8GB" → ~7.3–7.9 GiB, "4GB" → ~3.7 GiB).
    static var physicalMemoryGiB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / (1_024 * 1_024 * 1_024)
    }

    /// 최소 실행 요건(가장 작은 MiniCPM5 1B 모델) 충족을 판정하는 임계값.
    /// 6GB 기기는 통과(iPhone 13 Pro/14/15/15 Plus 등), 4GB 기기(~3.7 GiB)는 제외.
    static let minCapableMemoryGiB: Double = 5.0

    /// 현재 기기에서 실행 가능한 모델.
    static var availableModels: [ModelOption] {
        let mem = physicalMemoryGiB
        return modelCatalog.filter { option in
            mem >= option.minMemoryGiB
        }
    }
    /// 기본 모델: MiniCPM5 1B 모델.
    /// UserDefaults "pieroot.todo.onDeviceModelID"로 기기당 재지정 가능.
    static let defaultModelID = "mlx-community/MiniCPM5-1B-4bit"
    static let qwenFallbackModelID = "mlx-community/Qwen3.5-2B-MLX-4bit"
    static let retiredLFMModelID = "mlx-community/LFM2.5-1.2B-Instruct-4bit"
    static let legacyOpenBMBMiniCPMModelID = "openbmb/MiniCPM5-1B-MLX"
    static let miniCPMModelID = "mlx-community/MiniCPM5-1B-4bit"

    static func normalizedModelID(_ storedModelID: String?) -> String {
        let modelID = storedModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let modelID, !modelID.isEmpty else { return defaultModelID }
        if modelID == retiredLFMModelID || modelID == legacyOpenBMBMiniCPMModelID { return miniCPMModelID }
        return modelID
    }
    /// 입력 컨텍스트 최대 토큰 수. 기본 4K로 메모리 절약 (Qwen3.5-2B는 32K 지원).
    static let defaultContextLength = 4096
    /// 메모리 경고가 와도 이 정도 헤드룸이 남아 있으면 진행 중인 생성은 취소하지 않는다.
    private static let generationMemoryWarningFloorBytes = 768 * 1_024 * 1_024
    private static let idleMemoryWarningFloorBytes = 1_024 * 1_024 * 1_024
    private static let normalMLXCacheLimit = 256 * 1_024 * 1_024
    private static let pressureMLXCacheLimit = 64 * 1_024 * 1_024
    /// MLXLLM 패키지가 Xcode에 추가되어 있는지 여부. false면 모든 기능이 stub.
    static let isMLXAvailable = true

    /// UserDefaults에 저장된 사용자 모델 ID. 퇴역한 LFM 선택값은 MiniCPM5로 영구 마이그레이션한다.
    var modelID: String {
        let storedModelID = UserDefaults.standard.string(forKey: "pieroot.todo.onDeviceModelID")
        let normalizedModelID = Self.normalizedModelID(storedModelID)
        if storedModelID == Self.retiredLFMModelID || storedModelID == Self.legacyOpenBMBMiniCPMModelID || storedModelID != normalizedModelID {
            UserDefaults.standard.set(normalizedModelID, forKey: "pieroot.todo.onDeviceModelID")
        }
        return normalizedModelID
    }

    private let runtime: (any OnDeviceModelRuntime)?
    private let policy: BetaFeaturePolicy
    private var cachedModelSnapshot: (modelID: String, snapshot: OnDeviceModelCacheSnapshot)?
    private var container: ModelContainer?
    /// 실제 로드된 모델 ID — 삭제 시 정확한 캐시 경로 계산에 사용.
    private var loadedModelID: String?
    var loadedModelIdentifier: String? { isModelLoaded ? loadedModelID : nil }

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
    private var generationSequence: UInt64 = 0
    /// generate()가 CancellationError를 LLMError.cancelled로 변환할 때 첨부할 사유.
    private(set) var lastUnloadReason: UnloadReason?

    var isCapable: Bool {
        Self.physicalMemoryGiB >= Self.minCapableMemoryGiB
    }

    /// Only a complete snapshot is eligible for local loading, not an interrupted cache directory.
    var isModelCachedOnDisk: Bool { isModelCachedOnDisk(for: modelID) }

    func isModelCachedOnDisk(for selectedID: String) -> Bool {
        guard !isDeleting else { return false }
        if let cachedModelSnapshot, cachedModelSnapshot.modelID == selectedID,
           cachedModelSnapshot.snapshot.isUsable {
            return true
        }
        cachedModelSnapshot = nil
        guard !isLoading else { return false }
        for root in cacheDirectories(for: selectedID) {
            // The downloader below resolves the service's default revision to snapshots/main.
            let directory = root.appendingPathComponent("snapshots/main")
            if let snapshot = OnDeviceModelCacheSnapshot(
                directory: directory,
                requiresTokenizerConfiguration: usesNativeChatTemplate(selectedID)
            ) {
                cachedModelSnapshot = (selectedID, snapshot)
                return true
            }
        }
        return false
    }

    /// 현재 선택값과 무관하게 기기에 설치된 HuggingFace 모델 캐시를 모두 찾는다.
    var installedModels: [InstalledModel] {
        let selectedID = modelID
        let loadedID = loadedModelID
        let grouped = installedModelCacheDirectories()
        return grouped.map { modelID, urls in
            let catalogOption = Self.modelCatalog.first { $0.id == modelID }
            return InstalledModel(
                id: modelID,
                displayName: catalogOption?.displayName ?? modelID,
                sizeBytes: urls.reduce(Int64(0)) { $0 + directorySize(at: $1) },
                cachePaths: urls.map(\.path).sorted(),
                isSelected: modelID == selectedID,
                isLoaded: modelID == loadedID
            )
        }
        .sorted { lhs, rhs in
            if lhs.isSelected != rhs.isSelected { return lhs.isSelected && !rhs.isSelected }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var huggingFaceHubRoots: [URL] {
        let fm = FileManager.default
        return [
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ]
        .compactMap { $0?.appendingPathComponent("huggingface/hub") }
    }

    private func cacheDirectories(for id: String) -> [URL] {
        let slug = id.replacingOccurrences(of: "/", with: "--")
        let fm = FileManager.default
        return huggingFaceHubRoots
            .map { $0.appendingPathComponent("models--\(slug)") }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    private func installedModelCacheDirectories() -> [String: [URL]] {
        let fm = FileManager.default
        var grouped = [String: [URL]]()
        for root in huggingFaceHubRoots {
            guard let contents = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in contents where url.lastPathComponent.hasPrefix("models--") {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                let slug = String(url.lastPathComponent.dropFirst("models--".count))
                let id = slug.replacingOccurrences(of: "--", with: "/")
                grouped[id, default: []].append(url)
            }
        }
        return grouped
    }

    private func directorySize(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        var total: Int64 = 0
        for case let fileURL as URL in enumerator ?? NSEnumerator() {
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private func tokenizerLoader(for id: String) -> any MLXLMCommon.TokenizerLoader {
        #if canImport(MLXHuggingFace)
        if id == Self.miniCPMModelID {
            return #huggingFaceTokenizerLoader()
        }
        #endif
        return JSONBPETokenizerLoader()
    }

    private func usesNativeChatTemplate(_ id: String) -> Bool {
        #if canImport(MLXHuggingFace)
        return id == Self.miniCPMModelID
        #else
        return false
        #endif
    }
    init(runtime: (any OnDeviceModelRuntime)? = nil, policy: BetaFeaturePolicy = BetaFeaturePolicy()) {
        self.runtime = runtime
        self.policy = policy
        // 임계값 실측 검증용 진단 로그 — physicalMemory 보고값으로 6GB/4GB 판정 확인.
        print(String(format: "[OnDeviceLLM] 물리 메모리 %.2f GiB · isCapable=%@ · availableModels=%d",
                     Self.physicalMemoryGiB, isCapable ? "true" : "false", Self.availableModels.count))
        setupLifecycleObservers()
    }

    func loadModelIfNeeded(use: ProviderUse) async {
        await loadModel(id: modelID, use: use)
    }

    /// Choosing a download target is not choosing an inference model. Commit the
    /// active model preference only after installation and loading have succeeded.
    func installModel(id: String) async {
        guard Self.availableModels.contains(where: { $0.id == id }) else { return }
        await loadModel(id: id, use: .modelManagement)
        if loadedModelIdentifier == id {
            UserDefaults.standard.set(id, forKey: "pieroot.todo.onDeviceModelID")
            objectWillChange.send()
        }
    }

    private func loadModel(id selectedID: String, use: ProviderUse) async {
        guard policy.authorizes(.onDevice, for: use), isCapable, !isLoading else { return }
        if let runtime {
            isLoading = true
            loadError = nil
            downloadInterrupted = false
            downloadProgress = 0
            defer { isLoading = false }
            do {
                try await runtime.load()
                try Task.checkCancellation()
                loadedModelID = selectedID
                isModelLoaded = true
                downloadProgress = 1
            } catch is CancellationError {
                downloadInterrupted = true
            } catch {
                loadError = error.localizedDescription
            }
            return
        }
        if isModelLoaded {
            guard loadedModelID != selectedID else { return }
            unloadModel(reason: .manual)
        }
        let task = Task<Void, Never> { [weak self] in await self?.performLoad(idToLoad: selectedID) }
        loadingTask = task
        isLoading = true
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performLoad(idToLoad: String) async {
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
            // 로드 직전 실측 가용 메모리 확인 — 경계 기기에서 OOM 크래시 대신 명확한 에러로 폴백.
            // 모델 가중치(sizeMB)를 램에 올릴 여유 + 안전 마진(512MB)이 없으면 로드하지 않는다.
            let modelSizeMB = Self.modelCatalog.first { $0.id == idToLoad }?.sizeMB ?? 1400
            let requiredBytes = (modelSizeMB + 512) * 1_024 * 1_024
            let availableBytes = os_proc_available_memory()
            print("[OnDeviceLLM] 로드 전 가용 메모리 \(availableBytes / 1_024 / 1_024)MB, 필요 추정 \(requiredBytes / 1_024 / 1_024)MB")
            if availableBytes > 0 && availableBytes < requiredBytes {
                loadError = AppLanguage.localized(
                    "error.onDeviceLLM.insufficientMemory",
                    defaultValue: AppLanguage.current == .english
                        ? "There is not enough memory to load the on-device model. Close other apps and try again."
                        : "메모리가 부족해 온디바이스 모델을 로드할 수 없습니다. 다른 앱을 종료한 뒤 다시 시도해 주세요.",
                    language: .current,
                    comment: "On-device model error shown when available memory is insufficient to load the model."
                )
                return
            }
            let config = ModelConfiguration(id: idToLoad)
            let loadedContainer = try await LLMModelFactory.shared.loadContainer(
                from: HuggingFaceHubDownloader(),
                using: tokenizerLoader(for: idToLoad),
                configuration: config,
                progressHandler: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = progress.fractionCompleted
                    }
                }
            )
            try Task.checkCancellation()
            container = loadedContainer
            loadedModelID = idToLoad
            isModelLoaded = true
            downloadInterrupted = false
            MLX.Memory.cacheLimit = Self.normalMLXCacheLimit
        } catch is CancellationError {
            // Task 취소 — 오류 메시지 없이 interrupted 상태로 처리
        } catch {
            loadError = error.localizedDescription
        }
    }

    func unloadModel(reason: UnloadReason = .manual) {
        let hadNativeModel = container != nil
        lastUnloadReason = reason
        if generationTask != nil {
            print("[OnDeviceLLM] ⚠️ 진행 중인 generate 취소 — 사유: \(reason.rawValue)")
        }
        runtime?.unload()
        loadingTask?.cancel()
        loadingTask = nil
        generationTask?.cancel()
        generationTask = nil
        idleTimer?.cancel()
        idleTimer = nil
        container = nil
        isModelLoaded = false
        if hadNativeModel { MLX.Memory.cacheLimit = 0 }
    }

    // MARK: - Lifecycle Observers

    /// 백그라운드 진입 / 메모리 경고 시 모델 자동 언로드 등록.
    ///
    /// 실제 백그라운드 전환에서 로딩·추론을 취소하고 소유한 모델을 해제한다.
    /// 로드한 네이티브 모델이 없으면 MLX 캐시에 접근해 Metal을 새로 초기화하지 않는다.
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
        // 메모리 경고가 와도 os_proc_available_memory() 기준 헤드룸이 충분하면
        // 진행 중인 generate를 취소하지 않는다. MLX/Metal 컴파일 직후 경고가 올라와도
        // 실제 여유 메모리가 큰 경우가 있어, 무조건 언로드하면 정상 추론이 실패한다.
        memoryToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMemoryWarning()
            }
        }
    }

    private func handleMemoryWarning() {
        guard isModelLoaded else { return }
        let availableBytes = os_proc_available_memory()
        let isGenerating = generationTask != nil
        let floor = isGenerating
            ? Self.generationMemoryWarningFloorBytes
            : Self.idleMemoryWarningFloorBytes
        let availableMB = availableBytes / 1_024 / 1_024
        let floorMB = floor / 1_024 / 1_024

        if availableBytes > floor {
            MLX.Memory.cacheLimit = Self.pressureMLXCacheLimit
            print("[OnDeviceLLM] ⚠️ 메모리 경고 — 가용 메모리: \(availableMB)MB, 기준 \(floorMB)MB 초과 → MLX 캐시 축소 후 유지")
            return
        }

        print("[OnDeviceLLM] ⚠️ 메모리 경고 — 가용 메모리: \(availableMB)MB, 기준 \(floorMB)MB 이하 → 언로드")
        unloadModel(reason: .memoryWarning)
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
        await deleteDownloadedModel(id: loadedModelID ?? modelID)
    }

    func deleteDownloadedModel(id idToDelete: String) async {
        isDeleting = true
        defer { isDeleting = false }
        if loadedModelID == idToDelete || modelID == idToDelete {
            unloadModel(reason: .modelDelete)
            if loadedModelID == idToDelete { loadedModelID = nil }
            downloadInterrupted = false
            downloadProgress = 0
        }
        let fm = FileManager.default
        for candidate in cacheDirectories(for: idToDelete) {
            try? fm.removeItem(at: candidate)
        }
        objectWillChange.send()
    }

    nonisolated private static func trace(_ requestID: String, _ message: String) {
        print("[OnDeviceLLM][\(requestID)] \(message)")
    }

    nonisolated private static func elapsedMS(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1_000)
    }

    /// 시스템 프롬프트 + 사용자 프롬프트로 텍스트 생성 (JSON 출력 용도).
    /// MiniCPM5는 HuggingFace chat template을 그대로 쓰고, Qwen 계열은 수동 ChatML 프롬프트를 쓴다.
    func generate(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int = 512,
        contextLength: Int = 8192,
        use: ProviderUse
    ) async throws -> String {
        guard policy.authorizes(.onDevice, for: use) else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .onDevice,
                reason: RuleFallbackReason.providerDisabled.rawValue
            )
        }
        if let runtime {
            let result = try await runtime.generate(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: maxTokens,
                contextLength: contextLength
            )
            try Task.checkCancellation()
            guard policy.authorizes(.onDevice, for: use) else { throw CancellationError() }
            return result
        }
        guard let container else { throw LLMError.modelNotLoaded }
        guard UIApplication.shared.applicationState == .active else { throw LLMError.appInBackground }
        // 직전 generate의 유휴 타이머가 이번 추론 중 발화하지 못하도록 선제 차단
        idleTimer?.cancel()
        idleTimer = nil
        // 실측 가용 메모리 로깅 — defer-unload 판단 기준 데이터 수집
        let requestID = String(UUID().uuidString.prefix(8))
        let startedAt = Date()
        let selectedModelID = modelID
        let availAtStart = os_proc_available_memory()
        print("[OnDeviceLLM] 🚀 generate 시작 — 가용 메모리: \(availAtStart / 1_024 / 1_024)MB, maxTokens: \(maxTokens)")
        Self.trace(
            requestID,
            "stage=start model=\(selectedModelID) systemChars=\(systemPrompt.count) userChars=\(userPrompt.count) contextLength=\(contextLength) maxTokens=\(maxTokens) availableMB=\(availAtStart / 1_024 / 1_024)"
        )

        let maxUserChars = max(200, contextLength * 3 - systemPrompt.count - 100)
        let trimmedUser = userPrompt.count > maxUserChars
            ? String(userPrompt.prefix(maxUserChars)) + "\n...[이하 생략]"
            : userPrompt
        // 모델별 프롬프트 포맷 — MiniCPM5는 모델의 tokenizer_config chat_template을 쓰고,
        // Qwen 계열은 수동 ChatML과 빈 <think> 프라이머로 JSON 출력을 유도한다.
        let opt = Self.modelCatalog.first { $0.id == selectedModelID }
        let prefix = opt?.promptPrefix ?? ""
        let primer = opt?.assistantPrimer ?? "<think>\n\n</think>\n"
        let useNativeChatTemplate = usesNativeChatTemplate(selectedModelID)
        let prompt = useNativeChatTemplate
            ? "\(systemPrompt)\n\n\(trimmedUser)"
            : "\(prefix)<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\n\(trimmedUser)<|im_end|>\n<|im_start|>assistant\n\(primer)"
        if trimmedUser.count != userPrompt.count {
            Self.trace(requestID, "stage=prompt-trim originalUserChars=\(userPrompt.count) trimmedUserChars=\(trimmedUser.count) maxUserChars=\(maxUserChars)")
        }
        Self.trace(requestID, "stage=prompt-ready promptChars=\(prompt.count) primerChars=\(useNativeChatTemplate ? 0 : primer.count) nativeChatTemplate=\(useNativeChatTemplate) elapsedMS=\(Self.elapsedMS(since: startedAt))")

        let task = Task<String, Error> {
            Self.trace(requestID, "stage=container-perform-enter elapsedMS=\(Self.elapsedMS(since: startedAt))")
            return try await container.perform { context in
                Self.trace(requestID, "stage=prepare-input-start nativeChatTemplate=\(useNativeChatTemplate) elapsedMS=\(Self.elapsedMS(since: startedAt))")
                let userInput: UserInput
                if useNativeChatTemplate {
                    userInput = UserInput(
                        chat: [
                            .system(systemPrompt),
                            .user(trimmedUser)
                        ],
                        additionalContext: ["enable_thinking": false]
                    )
                } else {
                    userInput = UserInput(prompt: .text(prompt))
                }
                let input = try await context.processor.prepare(input: userInput)
                Self.trace(requestID, "stage=prepare-input-done elapsedMS=\(Self.elapsedMS(since: startedAt))")
                let stream = try MLXLMCommon.generate(
                    input: input,
                    parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.1),
                    context: context
                )
                Self.trace(requestID, "stage=stream-created elapsedMS=\(Self.elapsedMS(since: startedAt))")
                var output = ""
                var chunkCount = 0
                var lastProgressLog = Date()
                var iterator = stream.makeAsyncIterator()
                while true {
                    // Metal GPU 명령 제출 전에 취소 확인 — for-await post-check 대비 race window 최소화
                    try Task.checkCancellation()
                    guard let generation = await iterator.next() else {
                        Self.trace(requestID, "stage=stream-ended chunks=\(chunkCount) outputChars=\(output.count) elapsedMS=\(Self.elapsedMS(since: startedAt))")
                        break
                    }
                    if let chunk = generation.chunk {
                        output += chunk
                        chunkCount += 1
                        let shouldLogProgress = chunkCount == 1
                            || chunkCount % 32 == 0
                            || Date().timeIntervalSince(lastProgressLog) >= 3
                        if shouldLogProgress {
                            let availableMB = os_proc_available_memory() / 1_024 / 1_024
                            Self.trace(requestID, "stage=stream-progress chunks=\(chunkCount) outputChars=\(output.count) lastChunkChars=\(chunk.count) availableMB=\(availableMB) elapsedMS=\(Self.elapsedMS(since: startedAt))")
                            lastProgressLog = Date()
                        }
                        if let completedJSON = Self.completedTopLevelJSONObject(in: output) {
                            output = completedJSON
                            Self.trace(requestID, "stage=json-complete chunks=\(chunkCount) jsonChars=\(output.count) elapsedMS=\(Self.elapsedMS(since: startedAt))")
                            break
                        }
                    } else if chunkCount == 0 || Date().timeIntervalSince(lastProgressLog) >= 3 {
                        Self.trace(requestID, "stage=stream-heartbeat chunks=\(chunkCount) outputChars=\(output.count) elapsedMS=\(Self.elapsedMS(since: startedAt))")
                        lastProgressLog = Date()
                    }
                }
                try Task.checkCancellation()
                return output
            }
        }
        generationTask = task
        generationSequence &+= 1
        let sequence = generationSequence
        defer {
            if generationSequence == sequence { generationTask = nil }
        }

        let result: String
        do {
            result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard policy.authorizes(.onDevice, for: use) else { throw CancellationError() }
        } catch is CancellationError {
            Self.trace(requestID, "stage=cancelled reason=\(lastUnloadReason?.rawValue ?? "unknown") elapsedMS=\(Self.elapsedMS(since: startedAt))")
            throw CancellationError()
        } catch {
            DiagnosticRecorder.shared.record(
                error: error,
                component: "ai.onDeviceLLM",
                operation: "generate"
            )
            Self.trace(requestID, "stage=failed errorType=\(String(describing: type(of: error))) message=\(error.localizedDescription) elapsedMS=\(Self.elapsedMS(since: startedAt))")
            throw error
        }
        MLX.Memory.cacheLimit = Self.normalMLXCacheLimit
        resetIdleTimer()
        // 추론형 모델이 출력 앞에 <think>…</think>를 붙이면 JSON 파싱이 깨지므로 제거.
        let stripped = Self.stripLeadingThinkBlock(result)
        Self.trace(
            requestID,
            "stage=done rawChars=\(result.count) strippedChars=\(stripped.count) hadJSON=\(Self.completedTopLevelJSONObject(in: stripped) != nil) elapsedMS=\(Self.elapsedMS(since: startedAt))"
        )
        return stripped
    }

    /// 출력 맨 앞의 <think>…</think> 추론 블록을 제거해 후속 JSON 파싱을 보호한다.
    /// think 블록이 없으면 원본을 그대로 반환.
    static func stripLeadingThinkBlock(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<think>"),
              let end = trimmed.range(of: "</think>") else { return text }
        return String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// MLX 모델이 EOS를 바로 내지 못하고 maxTokens까지 이어 쓰는 경우를 막기 위해,
    /// 최상위 JSON 객체가 완성되는 순간 스트리밍 생성을 중단한다.
    nonisolated static func completedTopLevelJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var isEscaped = false
        var index = start

        while index < text.endIndex {
            let char = text[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }

        return nil
    }

    // MARK: - 언로드 사유 계측

    /// 모델 언로드 사유 — generate() 취소 에러에 actionable 정보를 추가한다.
    enum UnloadReason: String {
        case background    = "백그라운드 전환"
        case memoryWarning = "메모리 부족 경고"
        case idleTimeout   = "유휴 타임아웃 120초"
        case modelDelete   = "모델 삭제"
        case manual        = "수동"

        nonisolated func displayName(language: AppLanguage) -> String {
            switch self {
            case .background:
                return AppLanguage.localized(
                    "error.onDeviceLLM.reason.background",
                    defaultValue: language == .english ? "App moved to the background" : "백그라운드 전환",
                    language: language,
                    comment: "On-device LLM cancellation reason: the app moved to the background."
                )
            case .memoryWarning:
                return AppLanguage.localized(
                    "error.onDeviceLLM.reason.memoryWarning",
                    defaultValue: language == .english ? "Memory warning" : "메모리 부족 경고",
                    language: language,
                    comment: "On-device LLM cancellation reason: a memory warning."
                )
            case .idleTimeout:
                return AppLanguage.localized(
                    "error.onDeviceLLM.reason.idleTimeout",
                    defaultValue: language == .english ? "Idle timeout (120 seconds)" : "유휴 타임아웃 120초",
                    language: language,
                    comment: "On-device LLM cancellation reason: the 120-second idle timeout."
                )
            case .modelDelete:
                return AppLanguage.localized(
                    "error.onDeviceLLM.reason.modelDelete",
                    defaultValue: language == .english ? "Model deleted" : "모델 삭제",
                    language: language,
                    comment: "On-device LLM cancellation reason: the model was deleted."
                )
            case .manual:
                return AppLanguage.localized(
                    "error.onDeviceLLM.reason.manual",
                    defaultValue: language == .english ? "Manual unload" : "수동",
                    language: language,
                    comment: "On-device LLM cancellation reason: manually unloaded."
                )
            }
        }
    }

    enum LLMError: LocalizedError {
        case modelNotLoaded
        case appInBackground
        case cancelled(reason: UnloadReason?)

        var errorDescription: String? {
            errorDescription(language: .current)
        }

        func errorDescription(language: AppLanguage) -> String {
            switch self {
            case .modelNotLoaded:
                return AppLanguage.localized(
                    "error.onDeviceLLM.modelNotLoaded",
                    defaultValue: language == .english
                        ? "The model is not loaded. Check its status under Settings > On-Device Model Management."
                        : "모델이 로드되지 않았습니다. 설정 > 온디바이스 모델 관리에서 상태를 확인하세요.",
                    language: language,
                    comment: "On-device LLM error shown when inference is requested before a model is loaded."
                )
            case .appInBackground:
                return AppLanguage.localized(
                    "error.onDeviceLLM.appInBackground",
                    defaultValue: language == .english
                        ? "The app is in the background. Open it and try again."
                        : "앱이 백그라운드 상태입니다. 화면을 켠 상태에서 다시 시도해주세요.",
                    language: language,
                    comment: "On-device LLM error shown when inference is requested while the app is in the background."
                )
            case .cancelled(let reason):
                let hint: String
                switch reason {
                case .memoryWarning:
                    hint = AppLanguage.localized(
                        "error.onDeviceLLM.cancelled.memoryWarning",
                        defaultValue: language == .english
                            ? "Close video playback and other apps, then try again."
                            : "실행 중인 영상·다른 앱을 닫고 다시 시도해주세요.",
                        language: language,
                        comment: "On-device LLM cancellation guidance after a memory warning."
                    )
                default:
                    hint = AppLanguage.localized(
                        "error.onDeviceLLM.cancelled.retry",
                        defaultValue: language == .english
                            ? "Please try again."
                            : "다시 시도해주세요.",
                        language: language,
                        comment: "On-device LLM cancellation guidance for retryable cancellation."
                    )
                }
                let format = AppLanguage.localized(
                    "error.onDeviceLLM.cancelled",
                    defaultValue: language == .english
                        ? "On-device analysis stopped (reason: %@).\n%@"
                        : "온디바이스 분석이 중단되었습니다 (사유: %@).\n%@",
                    language: language,
                    comment: "On-device LLM error shown when inference stops; the reason remains diagnostic text."
                )
                let diagnostic: String
                if let reason {
                    diagnostic = reason.displayName(language: language)
                } else {
                    diagnostic = AppLanguage.localized(
                        "error.onDeviceLLM.reason.unknown",
                        defaultValue: language == .english ? "Unknown" : "알 수 없음",
                        language: language,
                        comment: "On-device LLM cancellation reason shown when no reason is available."
                    )
                }
                return String(format: format, locale: language.locale, diagnostic, hint)
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
final class BPETokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {

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
        var ids = [Int]()
        var remaining = text
        while !remaining.isEmpty {
            guard let match = Self.nextSpecialToken(in: remaining, tokens: addedTokens) else {
                ids += bpeEncodeText(remaining)
                break
            }
            let before = String(remaining[remaining.startIndex..<match.range.lowerBound])
            if !before.isEmpty { ids += bpeEncodeText(before) }
            ids.append(match.id)
            remaining = String(remaining[match.range.upperBound...])
        }
        return ids
    }

    private static func nextSpecialToken(
        in text: String,
        tokens: [String: Int]
    ) -> (range: Range<String.Index>, id: Int, token: String)? {
        var nearest: (range: Range<String.Index>, id: Int, token: String)?
        for (token, id) in tokens {
            guard let range = text.range(of: token) else { continue }
            guard let current = nearest else {
                nearest = (range, id, token)
                continue
            }
            if range.lowerBound < current.range.lowerBound
                || (range.lowerBound == current.range.lowerBound && token.count > current.token.count) {
                nearest = (range, id, token)
            }
        }
        return nearest
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
        let id: String; let displayName: String; let sizeMB: Int; let minMemoryGiB: Double
        var promptPrefix: String = ""; var assistantPrimer: String = "<think>\n\n</think>\n"
    }
    struct InstalledModel: Identifiable, Hashable {
        let id: String
        let displayName: String
        let sizeBytes: Int64
        let cachePaths: [String]
        let isSelected: Bool
        let isLoaded: Bool
        var sizeMB: Int { 0 }
    }
    static let modelCatalog: [ModelOption] = [
        ModelOption(id: "mlx-community/MiniCPM5-1B-4bit", displayName: "MiniCPM5-1B · 4bit (~0.62 GB)", sizeMB: 620, minMemoryGiB: 5.0),
        ModelOption(id: "mlx-community/Qwen3.5-2B-MLX-4bit", displayName: "Qwen3.5-2B · 4bit (~1.4 GB)", sizeMB: 1400, minMemoryGiB: 5.0),
        ModelOption(id: "mlx-community/Qwen3.5-4B-MLX-4bit", displayName: "Qwen3.5-4B · 4bit (~2.4 GB)", sizeMB: 2400, minMemoryGiB: 7.0),
    ]
    static var physicalMemoryGiB: Double { Double(ProcessInfo.processInfo.physicalMemory) / (1_024 * 1_024 * 1_024) }
    static let minCapableMemoryGiB: Double = 5.0
    static var availableModels: [ModelOption] { modelCatalog.filter { physicalMemoryGiB >= $0.minMemoryGiB } }
    static let defaultModelID = "mlx-community/MiniCPM5-1B-4bit"
    static let qwenFallbackModelID = "mlx-community/Qwen3.5-2B-MLX-4bit"
    static let retiredLFMModelID = "mlx-community/LFM2.5-1.2B-Instruct-4bit"
    static let legacyOpenBMBMiniCPMModelID = "openbmb/MiniCPM5-1B-MLX"
    static let miniCPMModelID = "mlx-community/MiniCPM5-1B-4bit"
    static func normalizedModelID(_ storedModelID: String?) -> String {
        let modelID = storedModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let modelID, !modelID.isEmpty else { return qwenFallbackModelID }
        return modelID == retiredLFMModelID || modelID == legacyOpenBMBMiniCPMModelID || modelID == miniCPMModelID ? qwenFallbackModelID : modelID
    }
    static let defaultContextLength = 4096
    static let isMLXAvailable = false   // 패키지 미설치 — Xcode GUI로 추가 필요
    var modelID: String {
        let storedModelID = UserDefaults.standard.string(forKey: "pieroot.todo.onDeviceModelID")
        let normalizedModelID = Self.normalizedModelID(storedModelID)
        if storedModelID == Self.retiredLFMModelID {
            UserDefaults.standard.set(normalizedModelID, forKey: "pieroot.todo.onDeviceModelID")
        }
        return normalizedModelID
    }
    var isCapable: Bool { false }
    var isModelCachedOnDisk: Bool { false }
    var installedModels: [InstalledModel] { [] }
    private let runtime: (any OnDeviceModelRuntime)?
    private let policy: BetaFeaturePolicy
    private var loadedModelID: String?
    var loadedModelIdentifier: String? { isModelLoaded ? loadedModelID : nil }
    init(runtime: (any OnDeviceModelRuntime)? = nil, policy: BetaFeaturePolicy = BetaFeaturePolicy()) {
        self.runtime = runtime
        self.policy = policy
    }
    func loadModelIfNeeded(use: ProviderUse) async {
        guard policy.authorizes(.onDevice, for: use), let runtime else { return }
        let selectedID = modelID
        do {
            try await runtime.load()
            loadedModelID = selectedID
            isModelLoaded = true
        } catch {
            loadError = error.localizedDescription
        }
    }
    func unloadModel() {
        runtime?.unload()
        isModelLoaded = false
    }
    func deleteDownloadedModel() async {}
    func deleteDownloadedModel(id: String) async {}
    func generate(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int = 512,
        contextLength: Int = 8192,
        use: ProviderUse
    ) async throws -> String {
        guard policy.authorizes(.onDevice, for: use) else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .onDevice,
                reason: RuleFallbackReason.providerDisabled.rawValue
            )
        }
        guard let runtime else { throw LLMError.modelNotLoaded }
        return try await runtime.generate(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: maxTokens,
            contextLength: contextLength
        )
    }
    enum LLMError: LocalizedError {
        case modelNotLoaded

        var errorDescription: String? {
            errorDescription(language: .current)
        }

        func errorDescription(language: AppLanguage) -> String {
            AppLanguage.localized(
                "error.onDeviceLLM.modelNotLoaded",
                defaultValue: language == .english
                    ? "The model is not loaded. Check its status under Settings > On-Device Model Management."
                    : "모델이 로드되지 않았습니다. 설정 > 온디바이스 모델 관리에서 상태를 확인하세요.",
                language: language,
                comment: "On-device LLM error shown when inference is requested before a model is loaded."
            )
        }
    }
}

#endif

/// A cheap file-stat check after reading the small shard index once. Never reads weight or tokenizer payloads.
nonisolated struct OnDeviceModelCacheSnapshot {
    private let requiredFiles: [URL]
    private let indexURL: URL
    private let indexSize: Int?
    private let indexModificationDate: Date?

    init?(directory: URL, requiresTokenizerConfiguration: Bool) {
        var files = ["config.json", "tokenizer.json"].map { directory.appendingPathComponent($0) }
        if requiresTokenizerConfiguration {
            files.append(directory.appendingPathComponent("tokenizer_config.json"))
        }
        let index = directory.appendingPathComponent("model.safetensors.index.json")
        let indexValues = Self.values(of: index)
        if FileManager.default.fileExists(atPath: index.path) {
            guard let data = try? Data(contentsOf: index),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let weights = json["weight_map"] as? [String: String], !weights.isEmpty else { return nil }
            for name in Set(weights.values) {
                guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
                      name.hasSuffix(".safetensors") else { return nil }
                files.append(directory.appendingPathComponent(name))
            }
            files.append(index)
        } else {
            // The MLX loader accepts standalone safetensors filenames, not only model.safetensors.
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { return nil }
            let weights = entries.filter { $0.pathExtension == "safetensors" }
            // A lone shard from an interrupted multi-file export is not a standalone model.
            guard weights.count == 1, !weights[0].lastPathComponent.contains("-of-") else { return nil }
            files.append(weights[0])
        }
        self.requiredFiles = files
        self.indexURL = index
        self.indexSize = indexValues?.fileSize
        self.indexModificationDate = indexValues?.contentModificationDate
        guard isUsable else { return nil }
    }

    var isUsable: Bool {
        let currentIndex = Self.values(of: indexURL)
        guard currentIndex?.fileSize == indexSize,
              currentIndex?.contentModificationDate == indexModificationDate else { return false }
        return requiredFiles.allSatisfy { file in
            guard let values = Self.values(of: file) else { return false }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
    }

    private static func values(of url: URL) -> URLResourceValues? {
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        return try? freshURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
    }
}
