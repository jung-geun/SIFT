import Combine
import CoreML
import CryptoKit
@preconcurrency import FluidAudio
import Foundation

/// Explicit installation of pinned Nemotron and Community-1 Core ML assets.
/// Only `install` uses the network; sessions read locally verified bytes.
actor MeetingDiarizationModelStore {
    static let shared = MeetingDiarizationModelStore()

    nonisolated static let repository = "FluidInference/nemotron-3-diarization-coreml"
    nonisolated static let revision = "25a90f97f254428d4b30374b76af9c74fdee8327"
    nonisolated static let embeddingRepository = "FluidInference/speaker-diarization-coreml"
    nonisolated static let embeddingRevision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    nonisolated static let installationRevision = "nemotron-\(revision)_community1-\(embeddingRevision)"
    nonisolated static let modelDirectoryName = installationRevision

    nonisolated struct PinnedFile: Sendable {
        let path: String
        let size: Int64
        let sha256: String
        enum Source: Sendable { case nemotron, community1 }
        let source: Source

        init(path: String, size: Int64, sha256: String, source: Source = .nemotron) {
            self.path = path
            self.size = size
            self.sha256 = sha256
            self.source = source
        }

        var downloadURL: URL? {
            let repository = source == .nemotron ? MeetingDiarizationModelStore.repository : MeetingDiarizationModelStore.embeddingRepository
            let revision = source == .nemotron ? MeetingDiarizationModelStore.revision : MeetingDiarizationModelStore.embeddingRevision
            return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")
        }

        /// FluidAudio's local loader expects the bundles and root assets side by side.
        var localPath: String { path.hasPrefix("split/") ? String(path.dropFirst(6)) : path }
    }

    /// Sizes and SHA-256 digests of the pinned Hugging Face tree (LFS oids; the
    /// two non-LFS `model.mil` files were hashed from the same revision).
    nonisolated static let nemotronFiles: [PinnedFile] = [
        PinnedFile(path: "learnable_sil_emb.bin", size: 2_048,
                   sha256: "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7"),
        PinnedFile(path: "pre_encode_proj_t.bin", size: 2_097_152,
                   sha256: "eb15b89e7af9813331a7d8db02e83e30bf97463d272c748e72086bafd4e81c60"),
        PinnedFile(path: "split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc/analytics/coremldata.bin", size: 243,
                   sha256: "3241bd5be194abbf0f625be8bd639b5c2035359594a6a513d70e9159e294ce39"),
        PinnedFile(path: "split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc/coremldata.bin", size: 603,
                   sha256: "b349771fbdb19443fb0af32b6c061fdb183d58e54c0b6376c2fbdca0a9941b70"),
        PinnedFile(path: "split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc/model.mil", size: 759_102,
                   sha256: "560f87a4a5124712d51ac7aecfee9a97278cac9087919719b031917a0160b508"),
        PinnedFile(path: "split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc/weights/weight.bin", size: 99_237_504,
                   sha256: "99e2ae43ac6a513abf99951b35a75fb6bc51d2287c3c1af48a9657d917e57aed"),
        PinnedFile(path: "split/Nemotron3Diarizer_c128_split_w8a8.mlmodelc/analytics/coremldata.bin", size: 243,
                   sha256: "9522ac23edf90deb9bc4d3ef97ca435a90df499d346c4806351784b5a8decb60"),
        PinnedFile(path: "split/Nemotron3Diarizer_c128_split_w8a8.mlmodelc/coremldata.bin", size: 605,
                   sha256: "777c6c6240baef5973b99b6984e9bb3a1f6a4812de28d3c65317be8911491421"),
        PinnedFile(path: "split/Nemotron3Diarizer_c128_split_w8a8.mlmodelc/model.mil", size: 759_134,
                   sha256: "fdc429dae043fd0e10c9c91408a6002df6b90c71ef5c30877c56f7796abb6c53"),
        PinnedFile(path: "split/Nemotron3Diarizer_c128_split_w8a8.mlmodelc/weights/weight.bin", size: 99_249_792,
                   sha256: "9a4c5de6ba011560713206b76c357d99ee596d1f1a58c66368b82834f9e12f95")
    ]

    /// Supported Community-1 pair, not the separately licensed legacy WeSpeaker bundle.
    nonisolated static let embeddingFiles: [PinnedFile] = [
        PinnedFile(path: "FBank.mlmodelc/analytics/coremldata.bin", size: 243,
                   sha256: "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a", source: .community1),
        PinnedFile(path: "FBank.mlmodelc/coremldata.bin", size: 853,
                   sha256: "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759", source: .community1),
        PinnedFile(path: "FBank.mlmodelc/metadata.json", size: 3_409,
                   sha256: "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a", source: .community1),
        PinnedFile(path: "FBank.mlmodelc/model.mil", size: 15_667,
                   sha256: "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed", source: .community1),
        PinnedFile(path: "FBank.mlmodelc/weights/weight.bin", size: 1_776_896,
                   sha256: "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36", source: .community1),
        PinnedFile(path: "Embedding.mlmodelc/analytics/coremldata.bin", size: 243,
                   sha256: "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682", source: .community1),
        PinnedFile(path: "Embedding.mlmodelc/coremldata.bin", size: 704,
                   sha256: "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004", source: .community1),
        PinnedFile(path: "Embedding.mlmodelc/metadata.json", size: 2_818,
                   sha256: "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5", source: .community1),
        PinnedFile(path: "Embedding.mlmodelc/model.mil", size: 78_432,
                   sha256: "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3", source: .community1),
        PinnedFile(path: "Embedding.mlmodelc/weights/weight.bin", size: 13_412_288,
                   sha256: "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b", source: .community1)
    ]
    nonisolated static let files = nemotronFiles + embeddingFiles
    nonisolated static let totalBytes: Int64 = files.reduce(0) { $0 + $1.size }

    private let root: URL
    private let session: URLSession
    private let expectedFiles: [PinnedFile]
    private let validateModels: @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> Void
    private var installing = false
    private var verified = false
    private var leases = 0

    init(
        root: URL? = nil,
        session: URLSession = .shared,
        expectedFiles: [PinnedFile] = MeetingDiarizationModelStore.files,
        validateModels: (@Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> Void)? = nil
    ) {
        self.root = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingDiarization", isDirectory: true)
        self.session = session
        self.expectedFiles = expectedFiles
        self.validateModels = validateModels ?? Self.validateModelLoads
    }

    private var installDirectory: URL {
        root.appendingPathComponent(Self.modelDirectoryName, isDirectory: true)
    }

    private var legacyDirectory: URL {
        root.appendingPathComponent(Self.revision, isDirectory: true)
    }

    /// Cheap presentation check: every pinned file exists with its exact size.
    func isInstalled() -> Bool {
        !installing && expectedFiles.allSatisfy { file in
            Self.regularFileSize(installDirectory.appendingPathComponent(file.localPath)) == file.size
        }
    }

    /// Owned artifacts can be removed even when the complete pack is not ready.
    func hasRemovableModels() -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: installDirectory.path)
            || fileManager.fileExists(atPath: legacyDirectory.path) {
            return true
        }
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return false
        }
        return entries.contains { $0.lastPathComponent.hasPrefix(".staging-") }
    }

    /// Hash-verifies the install once per process and pins it against deletion
    /// until `release()`. Never downloads.
    func acquire() throws -> URL {
        try Task.checkCancellation()
        guard !installing else { throw MeetingDiarizationFailure.modelUnavailable }
        guard isInstalled() else { throw MeetingDiarizationFailure.modelUnavailable }
        if !verified {
            do {
                try verify(directory: installDirectory)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MeetingDiarizationFailure.artifactCorrupt
            }
            verified = true
        }
        leases += 1
        return installDirectory
    }

    func release() {
        leases = max(0, leases - 1)
    }

    func install(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard !installing else { throw MeetingDiarizationModelError.operationInProgress }
        guard leases == 0 else { throw MeetingDiarizationModelError.inUse }
        try Task.checkCancellation()
        if isInstalled() {
            do {
                try verify(directory: installDirectory)
                verified = true
                progress(1)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Explicit repair may reuse only individually verified files.
            }
        }
        installing = true
        verified = false
        defer { installing = false }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var rootValues = URLResourceValues()
        rootValues.isExcludedFromBackup = true
        var excludedRoot = root
        try? excludedRoot.setResourceValues(rootValues)
        try removeStagingDirectories()
        let totalBytes = expectedFiles.reduce(Int64(0)) { $0 + $1.size }
        if let capacity = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
            capacity < totalBytes + 32 * 1_024 * 1_024 {
            throw MeetingDiarizationModelError.insufficientStorage
        }

        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString.lowercased())", isDirectory: true)
        // Never publish staged bytes until all hashes and model loads succeed.
        defer { try? fileManager.removeItem(at: staging) }
        do {
            var completedBytes: Int64 = 0
            progress(0)
            for file in expectedFiles {
                try Task.checkCancellation()
                let destination = staging.appendingPathComponent(file.localPath)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let local = try verifiedLocalFile(file) {
                    try fileManager.copyItem(at: local, to: destination)
                } else {
                    guard let url = file.downloadURL else { throw MeetingDiarizationModelError.downloadFailed }
                    let (temporary, response) = try await session.download(from: url)
                    defer { try? fileManager.removeItem(at: temporary) }
                    try Task.checkCancellation()
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw MeetingDiarizationModelError.downloadFailed
                    }
                    try Self.verify(file: temporary, expected: file)
                    try fileManager.moveItem(at: temporary, to: destination)
                }
                completedBytes += file.size
                progress(0.9 * Double(completedBytes) / Double(totalBytes))
            }
            try Task.checkCancellation()
            try verify(directory: staging)
            do {
                try await validateModels(staging, progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MeetingDiarizationModelError.loadFailed
            }
            try Task.checkCancellation()
            if fileManager.fileExists(atPath: installDirectory.path) {
                try fileManager.removeItem(at: installDirectory)
            }
            // Same-volume rename is the only publication point.
            try fileManager.moveItem(at: staging, to: installDirectory)
        } catch {
            if error is CancellationError || error is MeetingDiarizationModelError { throw error }
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw MeetingDiarizationModelError.downloadFailed
        }
        // Only this exact obsolete pin is owned by this store; preserve unrelated entries.
        if fileManager.fileExists(atPath: legacyDirectory.path) {
            try fileManager.removeItem(at: legacyDirectory)
        }
        verified = true
        progress(1)
    }

    func delete() throws {
        guard !installing else { throw MeetingDiarizationModelError.operationInProgress }
        guard leases == 0 else { throw MeetingDiarizationModelError.inUse }
        verified = false
        for directory in [installDirectory, legacyDirectory] where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try removeStagingDirectories()
    }

    private func verify(directory: URL) throws {
        for file in expectedFiles {
            try Self.verify(file: directory.appendingPathComponent(file.localPath), expected: file)
        }
    }

    private func removeStagingDirectories() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where entry.lastPathComponent.hasPrefix(".staging-") {
            try FileManager.default.removeItem(at: entry)
        }
    }

    private func verifiedLocalFile(_ file: PinnedFile) throws -> URL? {
        let candidates = file.source == .nemotron ? [installDirectory, legacyDirectory] : [installDirectory]
        for directory in candidates {
            let url = directory.appendingPathComponent(file.localPath)
            do {
                try Self.verify(file: url, expected: file)
                return url
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Missing or corrupt local bytes are not reused.
            }
        }
        return nil
    }

    nonisolated private static func validateModelLoads(
        directory: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Each helper's scope releases its model before the next large graph loads.
        try Task.checkCancellation()
        try await validateNemotronLoad(preset: .live, directory: directory)
        try Task.checkCancellation()
        progress(0.925)
        try await validateNemotronLoad(preset: .finalPass, directory: directory)
        try Task.checkCancellation()
        progress(0.95)
        try validateEmbeddingLoad(name: "FBank", directory: directory, computeUnits: .cpuOnly)
        try Task.checkCancellation()
        progress(0.975)
        try validateEmbeddingLoad(name: "Embedding", directory: directory, computeUnits: .cpuAndNeuralEngine)
        try Task.checkCancellation()
        progress(0.99)
    }

    nonisolated private static func validateNemotronLoad(preset: MeetingDiarizationPreset, directory: URL) async throws {
        guard let config = Nemotron3Config.preset(named: preset.sdkPresetName) else {
            throw MeetingDiarizationModelError.loadFailed
        }
        _ = try await Nemotron3Models.load(config: config, directory: directory, computeUnits: .cpuAndNeuralEngine)
    }

    nonisolated private static func validateEmbeddingLoad(name: String, directory: URL, computeUnits: MLComputeUnits) throws {
        try autoreleasepool {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            _ = try MLModel(contentsOf: directory.appendingPathComponent("\(name).mlmodelc"), configuration: configuration)
        }
    }

    nonisolated private static func verify(file url: URL, expected: PinnedFile) throws {
        guard regularFileSize(url) == expected.size else { throw MeetingDiarizationFailure.artifactCorrupt }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == expected.sha256 else {
            throw MeetingDiarizationFailure.artifactCorrupt
        }
    }

    nonisolated private static func regularFileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize else { return nil }
        return Int64(size)
    }
}

nonisolated enum MeetingDiarizationModelError: LocalizedError, Equatable {
    case operationInProgress
    case inUse
    case insufficientStorage
    case downloadFailed
    case loadFailed

    var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .operationInProgress:
            return AppLanguage.localized(
                "meeting.diarization.model.busy",
                defaultValue: english ? "Another speaker model operation is in progress." : "다른 화자 모델 작업이 진행 중입니다.",
                language: .current, comment: "Speaker model install/delete conflict."
            )
        case .inUse:
            return AppLanguage.localized(
                "meeting.diarization.model.inUse",
                defaultValue: english
                    ? "The speaker model is in use. Stop recording or speaker analysis first."
                    : "화자 모델을 사용 중입니다. 녹음이나 화자 분석을 먼저 끝내세요.",
                language: .current, comment: "Speaker model cannot change while a session uses it."
            )
        case .insufficientStorage:
            return AppLanguage.localized(
                "meeting.diarization.model.storage",
                defaultValue: english
                    ? "Not enough storage to install the speaker model pack (about 218 MB)."
                    : "화자 모델 팩(약 218 MB)을 설치할 저장 공간이 부족합니다.",
                language: .current, comment: "Speaker model install storage failure."
            )
        case .downloadFailed:
            return AppLanguage.localized(
                "meeting.diarization.model.downloadFailed",
                defaultValue: english
                    ? "The speaker model could not be downloaded or verified. Try again."
                    : "화자 모델을 내려받거나 검증하지 못했습니다. 다시 시도하세요.",
                language: .current, comment: "Speaker model download or integrity failure."
            )
        case .loadFailed:
            return AppLanguage.localized(
                "meeting.diarization.model.loadFailed",
                defaultValue: english
                    ? "The speaker model pack could not be loaded on this device, so installation was canceled."
                    : "이 기기에서 화자 모델을 불러오지 못해 설치를 취소했습니다.",
                language: .current, comment: "Downloaded speaker model failed to compile or load on this device."
            )
        }
    }
}

/// Presentation state for AI settings; capture and replay consult the actor.
@MainActor
final class MeetingDiarizationModelController: ObservableObject {
    static let shared = MeetingDiarizationModelController()

    @Published private(set) var isInstalled = false
    @Published private(set) var hasRemovableModels = false
    @Published private(set) var isInstalling = false
    @Published private(set) var isDeleting = false
    @Published private(set) var progress = 0.0
    @Published private(set) var errorMessage: String?

    private let store: MeetingDiarizationModelStore
    private var installTask: Task<Void, Never>?

    init(store: MeetingDiarizationModelStore = .shared) {
        self.store = store
    }

    func refresh() async {
        isInstalled = await store.isInstalled()
        hasRemovableModels = await store.hasRemovableModels()
    }

    func install() {
        guard installTask == nil, !isDeleting else { return }
        isInstalling = true
        progress = 0
        errorMessage = nil
        installTask = Task { [store] in
            do {
                try await store.install { value in
                    Task { @MainActor in self.progress = value }
                }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
            isInstalling = false
            installTask = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    func delete() async {
        guard !isInstalling, !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            try await store.delete()
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }
}
