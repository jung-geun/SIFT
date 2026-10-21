import Foundation
import Testing
@testable import todo

@Suite("Cloud file authorization and source boundaries")
struct CloudFileStoreTests {
    @Test("Opt-out during the first file hash read prevents replacement and deletion")
    func invalidationAfterHashRead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data(repeating: 0x31, count: 768 * 1_024)
        try original.write(to: fixture.audio)
        let digest = CloudFileStore.digest(original)
        for replacement in [Data([0x32]), nil] as [Data?] {
            // apply checks entry, decoded identity, meeting/marker authorization,
            // then before opening, before reading, and immediately after reading.
            // Revoke on that first post-read checkpoint, not at method entry.
            let authorization = Authorization(revokeOnCheck: 8)
            let store = CloudFileStore(root: fixture.root)
            await #expect(throws: CancellationError.self) {
                try await store.apply(key: fixture.key, payload: replacement, expectedDigest: digest,
                    isAuthorized: { authorization.check() })
            }
            #expect(try Data(contentsOf: fixture.audio) == original)
        }
    }

    @Test("Opt-out immediately after load reads bytes never returns a payload")
    func invalidationAfterLoadRead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(repeating: 0x33, count: 768 * 1_024).write(to: fixture.audio)
        let store = CloudFileStore(root: fixture.root)
        let snapshot = try #require(try await store.capture()[fixture.key])
        let authorization = Authorization(revokeOnCheck: 5)
        await #expect(throws: CancellationError.self) {
            _ = try await store.load(snapshot, isAuthorized: { authorization.check() })
        }
    }

    @Test("A cancelled task cannot capture, load, write, or delete files")
    func cancellationRejectsAllOperations() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data([1, 2, 3])
        try original.write(to: fixture.audio)
        let store = CloudFileStore(root: fixture.root)
        let snapshot = try #require(try await store.capture()[fixture.key])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { _ = try await store.capture() }
            await #expect(throws: CancellationError.self) { _ = try await store.load(snapshot) }
            await #expect(throws: CancellationError.self) {
                try await store.apply(key: fixture.key, payload: Data([4]), expectedDigest: snapshot.digest)
            }
            await #expect(throws: CancellationError.self) {
                try await store.apply(key: fixture.key, payload: nil, expectedDigest: snapshot.digest)
            }
        }
        await task.value
        #expect(try Data(contentsOf: fixture.audio) == original)
    }

    @Test("Revocation during capture is observed before hashing the entire file")
    func invalidationDuringCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(repeating: 0x34, count: 768 * 1_024).write(to: fixture.audio)
        let store = CloudFileStore(root: fixture.root)
        let authorization = Authorization(revokeOnCheck: 14)
        await #expect(throws: CancellationError.self) {
            _ = try await store.capture(isAuthorized: { authorization.check() })
        }
    }

    @Test("Capture rejects symlinked source metadata and audio directories")
    func sourceSymlinksCannotEscapeRoot() async throws {
        for component in ["Meetings", "audio", "capture-recovery.json"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: outside) }
            let source: URL
            if component == "Meetings" {
                source = fixture.root.appendingPathComponent("Meetings")
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            } else if component == "audio" {
                source = fixture.audio.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            } else {
                source = fixture.audio.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(component)
                try Data("private source metadata".utf8).write(to: outside)
            }
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
            let store = CloudFileStore(root: fixture.root)
            await #expect(throws: CloudFileError.self) { _ = try await store.capture() }
        }
    }

    @Test("Load revalidates captured URLs rather than trusting old source metadata")
    func loadRejectsReplacedSourceAndForgedURL() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data([5, 6, 7])
        try original.write(to: fixture.audio)
        let store = CloudFileStore(root: fixture.root)
        let snapshot = try #require(try await store.capture()[fixture.key])
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try original.write(to: outside)
        let forged = CloudFileSnapshot(key: snapshot.key, url: outside, digest: snapshot.digest, byteCount: snapshot.byteCount)
        await #expect(throws: CloudFileError.self) { _ = try await store.load(forged) }
        try FileManager.default.removeItem(at: fixture.audio)
        try FileManager.default.createSymbolicLink(at: fixture.audio, withDestinationURL: outside)
        await #expect(throws: CloudFileError.self) { _ = try await store.load(snapshot) }
        #expect(try Data(contentsOf: outside) == original)
    }

    @Test("LocalRoutines is neither portable nor captured when meeting transfer is disabled")
    func routinesAreNotPortableFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("LocalRoutines")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("local routines".utf8).write(to: directory.appendingPathComponent("routines.json"))
        let store = CloudFileStore(root: fixture.root)
        #expect(!CloudFileStore.isPortablePath("LocalRoutines/routines.json"))
        #expect(try await store.capture(includeMeetings: false).isEmpty)
        await #expect(throws: CloudFileError.self) {
            try await store.apply(key: "file/LocalRoutines/routines.json", payload: Data(), expectedDigest: nil)
        }
    }

    private struct Fixture {
        let root: URL
        let audio: URL
        let key: String

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let path = "Meetings/\(UUID().uuidString.lowercased())/audio/part-00.flac"
            audio = root.appendingPathComponent(path)
            key = "file/" + path
            try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private final class Authorization: @unchecked Sendable {
        private let lock = NSLock()
        private let revokeOnCheck: Int
        private var count = 0

        init(revokeOnCheck: Int) { self.revokeOnCheck = revokeOnCheck }

        func check() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count < revokeOnCheck
        }
    }
}
