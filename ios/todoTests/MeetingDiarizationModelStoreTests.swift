import CryptoKit
import Foundation
import Testing
@testable import todo

@Suite("Meeting speaker model pack installation", .serialized)
struct MeetingDiarizationModelStoreTests {
    private typealias Store = MeetingDiarizationModelStore

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = [
            "learnable_sil_emb.bin",
            "split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc/model.mil",
            "split/Nemotron3Diarizer_c128_split_w8a8.mlmodelc/model.mil",
            "FBank.mlmodelc/model.mil",
            "Embedding.mlmodelc/model.mil"
        ]
        var legacy: URL { root.appendingPathComponent(Store.revision) }
        var installed: URL { root.appendingPathComponent(Store.modelDirectoryName) }
        var files: [Store.PinnedFile] {
            paths.enumerated().map { index, path in
                let data = bytes(index)
                return Store.PinnedFile(
                    path: path, size: Int64(data.count),
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    source: index < 3 ? .nemotron : .community1
                )
            }
        }
        func bytes(_ index: Int) -> Data { Data(repeating: UInt8(index + 1), count: (index + 1) * 16) }
        func write(_ indices: Range<Int>, to directory: URL) throws {
            for index in indices {
                let url = directory.appendingPathComponent(files[index].localPath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes(index).write(to: url)
            }
        }
        func session(corruptDownload: Bool = false) -> URLSession {
            var responses: [URL: Data] = [:]
            for (index, file) in files.enumerated() {
                if let url = file.downloadURL {
                    responses[url] = corruptDownload ? Data(repeating: 0, count: bytes(index).count) : bytes(index)
                }
            }
            PackURLProtocol.requests.configure(responses)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PackURLProtocol.self]
            return URLSession(configuration: configuration)
        }
        func stagingIsEmpty() throws -> Bool {
            guard FileManager.default.fileExists(atPath: root.path) else { return true }
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .allSatisfy { !$0.lastPathComponent.hasPrefix(".staging-") }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    enum ModelPresence: CaseIterable, Sendable {
        case legacy, incomplete, staging, complete, mixed
    }

    @Test("owned legacy, partial and staged models are removable offline without making them ready", arguments: ModelPresence.allCases)
    @MainActor
    func removableModelsWithoutInstallation(presence: ModelPresence) async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let fileManager = FileManager.default
        let unrelatedFile = fixture.root.appendingPathComponent("unrelated.bin")
        let unrelatedDirectories = [
            fixture.root.appendingPathComponent("\(Store.revision)-unrelated"),
            fixture.root.appendingPathComponent(".staging")
        ]
        for directory in unrelatedDirectories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([42]).write(to: directory.appendingPathComponent("keep.bin"))
        }
        try Data([43]).write(to: unrelatedFile)
        let store = Store(root: fixture.root, session: fixture.session(), expectedFiles: fixture.files, validateModels: { _, _ in })
        let controller = MeetingDiarizationModelController(store: store)
        await controller.refresh()
        #expect(!controller.isInstalled)
        #expect(!controller.hasRemovableModels)
        #expect(await store.hasRemovableModels() == false)

        let staging = fixture.root.appendingPathComponent(".staging-interrupted")
        switch presence {
        case .legacy:
            try fixture.write(0..<3, to: fixture.legacy)
        case .incomplete:
            try fixture.write(0..<3, to: fixture.installed)
        case .staging:
            try fixture.write(0..<1, to: staging)
        case .complete:
            try fixture.write(0..<5, to: fixture.installed)
        case .mixed:
            try fixture.write(0..<3, to: fixture.legacy)
            try fixture.write(0..<4, to: fixture.installed)
            try fixture.write(0..<1, to: staging)
        }
        await controller.refresh()
        #expect(controller.hasRemovableModels)
        #expect(await store.hasRemovableModels())
        #expect(controller.isInstalled == (presence == .complete))
        #expect(!controller.isInstalling)
        #expect(!controller.isDeleting)

        if presence == .complete {
            _ = try await store.acquire()
            await controller.delete()
            #expect(controller.errorMessage != nil)
            #expect(controller.isInstalled)
            #expect(controller.hasRemovableModels)
            #expect(!controller.isDeleting)
            #expect(fileManager.fileExists(atPath: fixture.installed.path))
            await store.release()
        } else {
            await #expect(throws: MeetingDiarizationFailure.modelUnavailable) { _ = try await store.acquire() }
        }

        await controller.delete()
        #expect(controller.errorMessage == nil)
        #expect(!controller.isInstalled)
        #expect(!controller.hasRemovableModels)
        #expect(!controller.isDeleting)
        #expect(await store.isInstalled() == false)
        #expect(await store.hasRemovableModels() == false)
        #expect(!fileManager.fileExists(atPath: fixture.legacy.path))
        #expect(!fileManager.fileExists(atPath: fixture.installed.path))
        #expect(try fixture.stagingIsEmpty())
        #expect(try Data(contentsOf: unrelatedFile) == Data([43]))
        for directory in unrelatedDirectories {
            #expect(try Data(contentsOf: directory.appendingPathComponent("keep.bin")) == Data([42]))
        }
        #expect(PackURLProtocol.requests.urls.isEmpty)
    }

    @Test("fresh installs publish only a complete verified pack; acquisitions never network")
    func freshInstallAndLease() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = Store(root: fixture.root, session: fixture.session(), expectedFiles: fixture.files, validateModels: { _, _ in })
        #expect(await store.isInstalled() == false)
        await #expect(throws: MeetingDiarizationFailure.modelUnavailable) { _ = try await store.acquire() }
        #expect(PackURLProtocol.requests.urls.isEmpty)
        try await store.install()
        #expect(await store.isInstalled())
        #expect(PackURLProtocol.requests.urls.count == fixture.files.count)
        let requestsAfterInstall = PackURLProtocol.requests.urls
        let directory = try await store.acquire()
        #expect(directory == fixture.installed)
        _ = try await store.acquire()
        await #expect(throws: MeetingDiarizationModelError.inUse) { try await store.delete() }
        await #expect(throws: MeetingDiarizationModelError.inUse) { try await store.install() }
        await store.release()
        await #expect(throws: MeetingDiarizationModelError.inUse) { try await store.delete() }
        await store.release()
        try await store.delete()
        #expect(await store.isInstalled() == false)
        #expect(PackURLProtocol.requests.urls == requestsAfterInstall)
    }

    @Test("explicit old-install upgrade reuses exact Nemotron bytes and counts them in progress")
    func upgradeReusesNemotron() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.write(0..<3, to: fixture.legacy)
        let unrelated = fixture.root.appendingPathComponent("unrelated")
        try Data([42]).write(to: unrelated)
        let progress = PackProgressLog()
        let store = Store(root: fixture.root, session: fixture.session(), expectedFiles: fixture.files, validateModels: { _, _ in })
        #expect(await store.isInstalled() == false)
        await #expect(throws: MeetingDiarizationFailure.modelUnavailable) { _ = try await store.acquire() }
        #expect(PackURLProtocol.requests.urls.isEmpty)
        try await store.install { progress.append($0) }
        #expect(Set(PackURLProtocol.requests.urls) == Set(fixture.files.suffix(2).compactMap(\.downloadURL)))
        let total = Double(fixture.files.reduce(Int64(0)) { $0 + $1.size })
        #expect(progress.values.prefix(4) == [0, 0.9 * 16 / total, 0.9 * 48 / total, 0.9 * 96 / total])
        #expect(progress.values.last == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.legacy.path))
        #expect(try Data(contentsOf: unrelated) == Data([42]))
        let installed = try await store.acquire()
        for index in 0..<3 {
            #expect(try Data(contentsOf: installed.appendingPathComponent(fixture.files[index].localPath)) == fixture.bytes(index))
        }
        await store.release()
        #expect(try fixture.stagingIsEmpty())
    }

    @Test("same-size local corruption cannot be acquired or reused")
    func corruptLocalBytesFailClosed() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.write(0..<5, to: fixture.installed)
        let corrupt = fixture.installed.appendingPathComponent(fixture.files[0].localPath)
        try Data(repeating: 0, count: 16).write(to: corrupt)
        let store = Store(root: fixture.root, session: fixture.session(corruptDownload: true), expectedFiles: fixture.files, validateModels: { _, _ in })
        await #expect(throws: MeetingDiarizationFailure.artifactCorrupt) { _ = try await store.acquire() }
        #expect(PackURLProtocol.requests.urls.isEmpty)
        await #expect(throws: MeetingDiarizationModelError.downloadFailed) { try await store.install() }
        await #expect(throws: MeetingDiarizationFailure.artifactCorrupt) { _ = try await store.acquire() }
        #expect(PackURLProtocol.requests.urls == fixture.files.prefix(1).compactMap(\.downloadURL))
        #expect(try fixture.stagingIsEmpty())
    }

    @Test("canceling model validation removes staging and keeps the old pack unavailable")
    func cancelBeforePublication() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.write(0..<3, to: fixture.legacy)
        let gate = PackValidationGate()
        let store = Store(root: fixture.root, session: fixture.session(), expectedFiles: fixture.files, validateModels: { _, _ in
            await gate.pause()
            try Task.checkCancellation()
        })
        let installation = Task { try await store.install() }
        await gate.waitUntilEntered()
        #expect(await store.isInstalled() == false)
        #expect(await store.hasRemovableModels())
        await #expect(throws: MeetingDiarizationFailure.modelUnavailable) { _ = try await store.acquire() }
        await #expect(throws: MeetingDiarizationModelError.operationInProgress) { try await store.delete() }
        installation.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await installation.value }
        #expect(await store.isInstalled() == false)
        #expect(await store.hasRemovableModels())
        #expect(try fixture.stagingIsEmpty())
        #expect(FileManager.default.fileExists(atPath: fixture.legacy.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.installed.path))
    }

    @Test("load failure publishes nothing; delete also removes an obsolete Nemotron install")
    func validationFailureAndOldDelete() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.write(0..<3, to: fixture.legacy)
        let store = Store(root: fixture.root, session: fixture.session(), expectedFiles: fixture.files, validateModels: { _, _ in
            throw MeetingDiarizationModelError.loadFailed
        })
        await #expect(throws: MeetingDiarizationModelError.loadFailed) { try await store.install() }
        #expect(await store.isInstalled() == false)
        #expect(try fixture.stagingIsEmpty())
        #expect(!FileManager.default.fileExists(atPath: fixture.installed.path))
        try await store.delete()
        #expect(!FileManager.default.fileExists(atPath: fixture.legacy.path))
    }
}

private final class PackURLProtocol: URLProtocol {
    static let requests = PackRequestLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let bytes = Self.requests.response(for: url),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "\(bytes.count)"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class PackRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: Data] = [:]
    private var recorded: [URL] = []
    var urls: [URL] { lock.withLock { recorded } }
    func configure(_ responses: [URL: Data]) {
        lock.withLock { self.responses = responses; recorded = [] }
    }
    func response(for url: URL) -> Data? {
        lock.withLock { recorded.append(url); return responses[url] }
    }
}

private final class PackProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    var values: [Double] { lock.withLock { recorded } }
    func append(_ value: Double) { lock.withLock { recorded.append(value) } }
}

private actor PackValidationGate {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var pending: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            pending = continuation
            entered = true
            for observer in observers { observer.resume() }
            observers.removeAll()
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func open() { pending?.resume(); pending = nil }
}
