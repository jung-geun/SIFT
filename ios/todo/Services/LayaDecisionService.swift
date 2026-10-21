import Foundation
import Combine
import CryptoKit

/// Downloads and tracks the pinned multilingual Laya e8 L256 options32 Core ML artifact.
/// Model bytes stay in Application Support; no user Todo text is ever sent anywhere
/// as part of installing or removing this model.
@MainActor
final class LayaDecisionService: ObservableObject {
    static let shared = LayaDecisionService()

    /// Multilingual Core ML artifact published by FluidInference.
    static let modelRepoID = "FluidInference/laya-coreml"
    nonisolated static let modelRevision = "7b8d7a2b7e28e746c6ecaad44bbcd5cf251a4fcc"
    /// Upstream weights checkpoint the artifact was converted from — distinct from
    /// `modelRepoID`, which is where the converted Core ML package is published.
    nonisolated static let sourceCheckpointRepo = "convaiinnovations/laya"
    nonisolated static let sourceCheckpointRevision = "1c5edc17a7acd8701df6fc341c0d179f1c62c982"
    nonisolated static let sourceCheckpointSubfolder = "multilingual"
    static let compiledModelFolder = "laya_multilingual_e8_L256_options32.mlmodelc"
    static let minCapableMemoryGiB = 3.0

    struct PinnedFile: Equatable, Sendable {
        let size: Int64
        let sha256: String
    }

    nonisolated static let pinnedFiles: [String: PinnedFile] = [
        "config.json": PinnedFile(
            size: 1811,
            sha256: "177d55ccbc774b14d893086bf2f07a53f720fe4d5d4e6798e96624d6b38a15af"
        ),
        "tokenizer.json": PinnedFile(
            size: 34363188,
            sha256: "609d8f4c067cd3950f88594c5a802616cea245823836ef5848ee4fc40aab5b6f"
        ),
        "laya_multilingual_e8_L256_options32.mlmodelc/model.mil": PinnedFile(
            size: 384859,
            sha256: "e0a127660b301a2e90a9a844ade624ef08c2e8e3d6bdf469cd2927344664e18a"
        ),
        "laya_multilingual_e8_L256_options32.mlmodelc/coremldata.bin": PinnedFile(
            size: 1115,
            sha256: "14b7b96379ca462ae78fa750f365ba07bb6fb7c252069e8edf437265d7f679ba"
        ),
        "laya_multilingual_e8_L256_options32.mlmodelc/analytics/coremldata.bin": PinnedFile(
            size: 243,
            sha256: "df3b97214eb80318c4afaae09da42a11739b1471d499e29611c5bfe2c29de862"
        ),
        "laya_multilingual_e8_L256_options32.mlmodelc/weights/weight.bin": PinnedFile(
            size: 448323072,
            sha256: "1cf24b8e0a545a1ee18a881ae1d9ff175eefc144d9da2e4674d2bd219be15a50"
        )
    ]

    nonisolated static let requiredFiles = [
        "config.json",
        "tokenizer.json",
        "laya_multilingual_e8_L256_options32.mlmodelc/model.mil",
        "laya_multilingual_e8_L256_options32.mlmodelc/coremldata.bin",
        "laya_multilingual_e8_L256_options32.mlmodelc/analytics/coremldata.bin",
        "laya_multilingual_e8_L256_options32.mlmodelc/weights/weight.bin"
    ]

    @Published private(set) var isModelInstalled = false
    @Published var isLoading = false
    @Published var isDeleting = false
    @Published var loadError: String?
    @Published var downloadProgress: Double = 0
    var progress: Double { downloadProgress }

    let installRoot: URL
    let expectedFiles: [String: PinnedFile]
    private var verifiedInstall = false

    var installDirectory: URL {
        installRoot.appendingPathComponent(Self.modelRevision)
    }

    var isCapable: Bool {
        OnDeviceLLMService.physicalMemoryGiB >= Self.minCapableMemoryGiB
    }

    var installedSizeBytes: Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        let enumerator = FileManager.default.enumerator(at: installDirectory, includingPropertiesForKeys: Array(keys))
        var total: Int64 = 0
        for case let url as URL in enumerator ?? NSEnumerator() {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    init(installRoot: URL? = nil, expectedFiles: [String: PinnedFile]? = nil) {
        self.installRoot = installRoot ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("laya")
        self.expectedFiles = expectedFiles ?? Self.pinnedFiles
        isModelInstalled = Self.filesPresent(in: installDirectory, expectedFiles: self.expectedFiles)
    }

    func loadModelIfNeeded(use: ProviderUse) async {
        guard use == .layaModelManagement,
              BetaFeaturePolicy().authorizes(.laya, for: use), isCapable, !isLoading, !isDeleting else { return }
        isLoading = true
        downloadProgress = 0
        loadError = nil
        defer { isLoading = false }
        do {
            if !verifiedInstall {
                verifiedInstall = (try? await Self.verifyDirectory(installDirectory, expectedFiles: expectedFiles)) != nil
            }
            if !verifiedInstall {
                try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
                let stagingDirectory = installRoot.appendingPathComponent(".staging-\(UUID().uuidString)")
                defer {
                    try? FileManager.default.removeItem(at: stagingDirectory)
                }
                try await LayaHubDownloader.download(
                    id: Self.modelRepoID,
                    revision: Self.modelRevision,
                    files: Array(expectedFiles.keys),
                    fileSizes: expectedFiles.mapValues { $0.size },
                    into: stagingDirectory,
                    progressHandler: { [weak self] progress in
                        Task { @MainActor in self?.downloadProgress = progress }
                    }
                )
                // Verify complete staging payload before touching installation directory
                try await Self.verifyDirectory(stagingDirectory, expectedFiles: expectedFiles)
                try Task.checkCancellation()

                let backupDirectory = installRoot.appendingPathComponent(".old-\(UUID().uuidString)")
                if FileManager.default.fileExists(atPath: installDirectory.path) {
                    try FileManager.default.moveItem(at: installDirectory, to: backupDirectory)
                }
                do {
                    try FileManager.default.moveItem(at: stagingDirectory, to: installDirectory)
                    try? FileManager.default.removeItem(at: backupDirectory)
                } catch {
                    if FileManager.default.fileExists(atPath: backupDirectory.path) {
                        try? FileManager.default.moveItem(at: backupDirectory, to: installDirectory)
                    }
                    throw error
                }
                verifiedInstall = true
            }
            try Task.checkCancellation()
            isModelInstalled = true
        } catch is CancellationError {
            isModelInstalled = false
        } catch {
            loadError = error.localizedDescription
            isModelInstalled = false
            verifiedInstall = false
        }
    }

    /// Never run an unverified installed payload. Verification is streamed off the UI actor once per launch.
    func verifiedModelDirectory() async throws -> URL {
        guard isModelInstalled, !isLoading, !isDeleting else { throw LayaError.artifactCorrupt }
        if !verifiedInstall {
            do {
                try await Self.verifyDirectory(installDirectory, expectedFiles: expectedFiles)
                verifiedInstall = true
            } catch {
                isModelInstalled = false
                throw error
            }
        }
        return installDirectory
    }

    private static func verifyDirectory(_ directory: URL, expectedFiles: [String: PinnedFile]) async throws {
        try await Task.detached(priority: .utility) {
            try Self.verifyFiles(in: directory, expectedFiles: expectedFiles)
        }.value
    }

    nonisolated static func verifyFiles(in directory: URL, expectedFiles: [String: PinnedFile] = LayaDecisionService.pinnedFiles) throws {
        let standardDir = directory.standardizedFileURL
        for path in expectedFiles.keys {
            guard !path.contains(".."), !path.hasPrefix("/") else {
                throw LayaError.artifactCorrupt
            }
            let fileURL = standardDir.appendingPathComponent(path).standardizedFileURL
            guard fileURL.path.hasPrefix(standardDir.path + "/") else {
                throw LayaError.artifactCorrupt
            }
        }
        guard let rootValues = try? standardDir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw LayaError.artifactCorrupt
        }
        var pendingDirectories = [(url: standardDir, prefix: "")]
        var observedFiles = Set<String>()
        while let directory = pendingDirectories.popLast() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            ) else { throw LayaError.artifactCorrupt }
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true else {
                    throw LayaError.artifactCorrupt
                }
                let relativePath = directory.prefix + entry.lastPathComponent
                if values.isDirectory == true {
                    pendingDirectories.append((url: entry, prefix: relativePath + "/"))
                } else {
                    guard values.isRegularFile == true, expectedFiles[relativePath] != nil else {
                        throw LayaError.artifactCorrupt
                    }
                    observedFiles.insert(relativePath)
                }
            }
        }
        guard observedFiles == Set(expectedFiles.keys) else { throw LayaError.artifactCorrupt }

        let configURL = standardDir.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configURL) else {
            throw LayaError.artifactCorrupt
        }
        struct ConfigPayload: Decodable {
            struct Source: Decodable {
                let repo: String
                let revision: String
                let subfolder: String?
            }
            let format: String
            let source: Source
            let inputs: [String: String]
            let outputs: [String: String]
            let max_options: Int?
            let head_max_len: Int?
        }
        guard let config = try? JSONDecoder().decode(ConfigPayload.self, from: configData) else {
            throw LayaError.artifactCorrupt
        }
        guard config.format == "coreml",
              config.source.repo == sourceCheckpointRepo,
              config.source.revision == sourceCheckpointRevision,
              config.source.subfolder == sourceCheckpointSubfolder,
              config.inputs["input_ids"] == "int32 [1, L]",
              config.inputs["attention_mask"] == "int32 [1, L]",
              config.inputs["marker_map"] == "float32 [1, 32, L]",
              config.inputs["question_type"] == "float32 [1, 3]",
              config.outputs["logits"] == "float32 [1, 32]",
              config.outputs["probabilities"] == "float32 [1, 32]",
              config.outputs["action_probabilities"] == "float32 [1, 2]",
              config.max_options == 32,
              config.head_max_len == 256 else {
            throw LayaError.artifactCorrupt
        }

        for (path, expected) in expectedFiles {
            let fileURL = standardDir.appendingPathComponent(path)
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  Int64(values.fileSize ?? -1) == expected.size else {
                throw LayaError.artifactCorrupt
            }

            let stream = try FileHandle(forReadingFrom: fileURL)
            defer { try? stream.close() }
            var hasher = SHA256()
            while let chunk = try stream.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            let digest = hasher.finalize().map({ String(format: "%02x", $0) }).joined()
            guard digest.lowercased() == expected.sha256.lowercased() else {
                throw LayaError.artifactCorrupt
            }
        }
    }

    func deleteDownloadedModel() async {
        guard !isDeleting, !isLoading else { return }
        isDeleting = true
        defer { isDeleting = false }
        await LayaCoreMLRunner.shared.unload()
        try? FileManager.default.removeItem(at: installDirectory)
        isModelInstalled = false
        verifiedInstall = false
    }

    private static func filesPresent(in directory: URL, expectedFiles: [String: PinnedFile]) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        for (path, expected) in expectedFiles {
            guard !path.contains(".."), !path.hasPrefix("/") else { return false }
            let fileURL = directory.appendingPathComponent(path)
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == expected.size else {
                return false
            }
        }
        return true
    }

    enum LayaError: LocalizedError {
        case artifactCorrupt

        var errorDescription: String? {
            AppLanguage.localized("error.laya.model.corrupt", defaultValue: "The downloaded Laya model is incomplete or corrupted.", language: AppLanguage.current)
        }
    }
}

/// Fetch only the explicitly pinned payload paths; never trust a remote tree
/// to choose local file destinations. Manifest integrity is verified before use.
enum LayaHubDownloader {
    static func download(
        id: String,
        revision: String,
        files: [String],
        fileSizes: [String: Int64] = [:],
        into directory: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let totalBytes = files.reduce(Int64(0)) { $0 + (fileSizes[$1] ?? 1) }
        var completedBytes: Int64 = 0

        for path in files {
            try Task.checkCancellation()
            guard !path.contains(".."), !path.hasPrefix("/") else {
                throw URLError(.badURL)
            }
            let dest = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            guard let fileURL = URL(string: "https://huggingface.co/\(id)/resolve/\(revision)/\(path)") else {
                throw URLError(.badURL)
            }
            let (tmpURL, response) = try await URLSession.shared.download(from: fileURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpURL, to: dest)

            completedBytes += (fileSizes[path] ?? 1)
            if totalBytes > 0 {
                progressHandler(Double(completedBytes) / Double(totalBytes))
            }
        }
    }
}
