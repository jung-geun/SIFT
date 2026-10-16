import CryptoKit
import Foundation
import WhisperKit

/// Network access is restricted to the explicit install action. Inference must
/// use `withVerifiedModel`/`withLoadedModel` so deletion waits for the session.
actor MeetingWhisperModelStore {
    static let shared = MeetingWhisperModelStore()

    private let root: URL
    private let session: URLSession
    private var installing = false
    private var leases = 0

    init(root: URL? = nil, session: URLSession = .shared) {
        self.root = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingWhisper", isDirectory: true)
        self.session = session
    }

    private var installed: URL {
        root.appendingPathComponent(MeetingWhisperManifest.modelRevision, isDirectory: true)
    }

    /// Presentation hint only; this is not an authorization to load. The load
    /// entrypoint hashes *every* file (including tokenizer and alignment data).
    func isInstalled() -> Bool {
        !installing && MeetingWhisperManifest.files.allSatisfy { file in
            Self.sizeOfRegularFile(installed.appendingPathComponent(file.localPath)) == file.size
        }
    }

    /// Runs the consumer under a deletion lease. The closure gets no network
    /// client: paths refer solely to the SHA-verified local install.
    func withVerifiedModel<T: Sendable>(
        _ body: @Sendable (URL, URL) async throws -> T
    ) async throws -> T {
        guard !installing else { throw MeetingWhisperModelError.operationInProgress }
        guard FileManager.default.fileExists(atPath: installed.path) else {
            throw MeetingWhisperModelError.notInstalled
        }
        do {
            try Self.verify(installed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MeetingWhisperModelError.corruptArtifact
        }
        leases += 1
        defer { leases -= 1 }
        return try await body(installed.appendingPathComponent("model", isDirectory: true),
                              installed.appendingPathComponent("tokenizer", isDirectory: true))
    }

    /// Safe inference entrypoint: the tokenizer is parsed from pinned local
    /// bytes, and WhisperKit is initialized with both download and its own
    /// tokenizer fallback disabled by supplying the tokenizer up front.
    func withLoadedModel<T: Sendable>(
        _ body: @Sendable (WhisperKit) async throws -> T
    ) async throws -> T {
        try await withVerifiedModel { modelDirectory, tokenizerDirectory in
            let model = try await MeetingWhisperOfflineLoader.load(
                modelDirectory: modelDirectory, tokenizerDirectory: tokenizerDirectory
            )
            do {
                let result = try await body(model)
                await model.unloadModels()
                return result
            } catch {
                await model.unloadModels()
                throw error
            }
        }
    }

    /// Only this call downloads. Staging is on the destination volume and is
    /// renamed into place only after complete size + SHA-256 verification.
    func install(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard !installing else { throw MeetingWhisperModelError.operationInProgress }
        guard leases == 0 else { throw MeetingWhisperModelError.inUse }
        installing = true
        defer { installing = false }

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)

        // Interrupted installs have never been published; clean their leftovers.
        for entry in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where entry.lastPathComponent.hasPrefix(".staging-") {
            try fm.removeItem(at: entry)
        }
        try Task.checkCancellation()
        if fm.fileExists(atPath: installed.path) {
            do {
                try Self.verify(installed)
                progress(1)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try fm.removeItem(at: installed)
            }
        }
        try Task.checkCancellation()
        if let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           available < MeetingWhisperManifest.totalBytes + 32 * 1_024 * 1_024 {
            throw MeetingWhisperModelError.insufficientStorage
        }

        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            progress(0)
            var completed: Int64 = 0
            for file in MeetingWhisperManifest.files {
                try Task.checkCancellation()
                let (temporary, response) = try await session.download(from: file.remoteURL)
                defer { try? fm.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw MeetingWhisperModelError.downloadFailed
                }
                try Self.verify(temporary, against: file)
                let destination = staging.appendingPathComponent(file.localPath)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: temporary, to: destination)
                completed += file.size
                progress(Double(completed) / Double(MeetingWhisperManifest.totalBytes))
            }
            try Self.verify(staging)
            try Task.checkCancellation()
            try fm.moveItem(at: staging, to: installed)
        } catch {
            try? fm.removeItem(at: staging)
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if error is MeetingWhisperModelError { throw error }
            throw MeetingWhisperModelError.downloadFailed
        }
    }

    func delete() throws {
        guard !installing else { throw MeetingWhisperModelError.operationInProgress }
        guard leases == 0 else { throw MeetingWhisperModelError.inUse }
        if FileManager.default.fileExists(atPath: installed.path) {
            try FileManager.default.removeItem(at: installed)
        }
        if FileManager.default.fileExists(atPath: root.path) {
            for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where entry.lastPathComponent.hasPrefix(".staging-") {
                try FileManager.default.removeItem(at: entry)
            }
        }
    }

    nonisolated private static func verify(_ directory: URL) throws {
        for file in MeetingWhisperManifest.files {
            try verify(directory.appendingPathComponent(file.localPath), against: file)
        }
    }

    nonisolated private static func verify(_ url: URL, against file: MeetingWhisperManifest.File) throws {
        guard sizeOfRegularFile(url) == file.size else { throw MeetingWhisperModelError.corruptArtifact }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else { throw MeetingWhisperModelError.corruptArtifact }
    }

    nonisolated private static func sizeOfRegularFile(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize else { return nil }
        return Int64(size)
    }
}

enum MeetingWhisperModelError: LocalizedError {
    case notInstalled, corruptArtifact, operationInProgress, inUse, insufficientStorage, downloadFailed

    var errorDescription: String? {
        let english = AppLanguage.current == .english
        let key: String
        let fallback: String
        switch self {
        case .notInstalled:
            key = "meeting.whisper.error.notInstalled"
            fallback = english ? "The transcription model has not been installed." : "고급 전사 모델이 설치되지 않았습니다."
        case .corruptArtifact:
            key = "meeting.whisper.error.corrupt"
            fallback = english ? "The installed transcription model failed integrity verification." : "설치된 전사 모델의 무결성 검증에 실패했습니다. 다시 설치하세요."
        case .operationInProgress:
            key = "meeting.whisper.error.busy"
            fallback = english ? "The transcription model is being installed." : "전사 모델을 설치하는 중입니다."
        case .inUse:
            key = "meeting.whisper.error.inUse"
            fallback = english ? "The transcription model is in use. Try again after processing ends." : "전사 모델을 사용 중입니다. 처리가 끝난 뒤 다시 시도하세요."
        case .insufficientStorage:
            key = "meeting.whisper.error.storage"
            fallback = english ? "Not enough storage to install the 631 MB transcription model." : "전사 모델(약 631 MB)을 설치할 저장 공간이 부족합니다."
        case .downloadFailed:
            key = "meeting.whisper.error.download"
            fallback = english ? "The transcription model download or verification failed." : "전사 모델 다운로드 또는 검증에 실패했습니다."
        }
        return AppLanguage.localized(key, defaultValue: fallback, language: .current,
                                     comment: "On-device transcription model install and integrity error.")
    }
}
