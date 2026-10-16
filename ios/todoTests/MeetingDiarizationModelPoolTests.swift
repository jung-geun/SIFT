import CryptoKit
import Foundation
import Testing
@testable import todo

@Suite("Meeting shared diarization model ownership")
struct MeetingDiarizationModelPoolTests {
    private typealias Pool = MeetingDiarizationModelPool<String, URL>

    @Test("concurrent loading is single-flight and cancellation cannot revoke a sibling's lease")
    func cancelledLoaderKeepsSiblingAndDeletionBlocked() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pool = Pool()
        let loading = LoadingBarrier()
        let load: @Sendable () async throws -> URL = {
            let url = try await fixture.store.acquire()
            await loading.pause()
            return url
        }
        let first = Task { try await pool.acquire(key: "live", load: load, release: { await fixture.store.release() }) }
        await loading.waitUntilEntered()
        let sibling = Task { try await pool.acquire(key: "live", load: load, release: { await fixture.store.release() }) }
        while await pool.borrowerCount(for: "live") != 2 { await Task.yield() }
        first.cancel()
        await #expect(throws: MeetingDiarizationModelError.inUse) { try await fixture.store.delete() }
        #expect(await loading.calls == 1)
        await loading.open()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        let lease = try await sibling.value
        #expect(await loading.calls == 1)
        #expect(await pool.borrowerCount(for: "live") == 1)
        await #expect(throws: MeetingDiarizationModelError.inUse) { try await fixture.store.delete() }
        await pool.release(key: lease.key, id: lease.id)
        await pool.release(key: lease.key, id: lease.id) // Duplicate cancellation cannot release another owner.
        #expect(await pool.borrowerCount(for: "live") == 0)
        try await fixture.store.delete()
        #expect(await fixture.store.isInstalled() == false)
    }

    @Test("last cancellation during loading holds deletion until loading actually settles")
    func cancelOnlyBorrowerDuringLoad() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pool = Pool()
        let loading = LoadingBarrier()
        let prepare = Task {
            try await pool.acquire(key: "live", load: {
                let directory = try await fixture.store.acquire()
                await loading.pause()
                return directory
            }, release: { await fixture.store.release() })
        }
        await loading.waitUntilEntered()
        prepare.cancel()
        #expect(await pool.borrowerCount(for: "live") == 1)
        await #expect(throws: MeetingDiarizationModelError.inUse) { try await fixture.store.delete() }
        await loading.open()
        await #expect(throws: CancellationError.self) { _ = try await prepare.value }
        #expect(await pool.borrowerCount(for: "live") == 0)
        try await fixture.store.delete()
    }

    @Test("failed shared loading unwinds its lease once and allows a fresh attempt")
    func failureCleanupAndRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pool = Pool()
        let loading = LoadingBarrier()
        let load: @Sendable () async throws -> URL = {
            _ = try await fixture.store.acquire()
            await loading.pause()
            await fixture.store.release()
            throw MeetingDiarizationFailure.modelUnavailable
        }
        let first = Task { try await pool.acquire(key: "live", load: load, release: { Issue.record("Failed load released twice") }) }
        await loading.waitUntilEntered()
        let sibling = Task { try await pool.acquire(key: "live", load: load, release: { Issue.record("Failed load released twice") }) }
        while await pool.borrowerCount(for: "live") != 2 { await Task.yield() }
        await #expect(throws: MeetingDiarizationModelError.inUse) { try await fixture.store.delete() }
        await loading.open()
        await #expect(throws: MeetingDiarizationFailure.modelUnavailable) { _ = try await first.value }
        await #expect(throws: MeetingDiarizationFailure.modelUnavailable) { _ = try await sibling.value }
        #expect(await loading.calls == 1)
        #expect(await pool.borrowerCount(for: "live") == 0)
        let retry = try await pool.acquire(key: "live", load: { try await fixture.store.acquire() }, release: { await fixture.store.release() })
        await #expect(throws: MeetingDiarizationModelError.inUse) { try await fixture.store.delete() }
        await pool.release(key: retry.key, id: retry.id)
        try await fixture.store.delete()
    }

    @Test("cancellation after prepare is idempotent and cannot release a prepared sibling")
    func preparedBorrowersReleaseIndependently() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pool = Pool()
        let first = try await pool.acquire(key: "live", load: { try await fixture.store.acquire() }, release: { await fixture.store.release() })
        let sibling = try await pool.acquire(key: "live", load: {
            Issue.record("Prepared sibling redundantly loaded the model")
            return try await fixture.store.acquire()
        }, release: { await fixture.store.release() })
        #expect(first.value == sibling.value)
        #expect(first.id != sibling.id)
        await pool.release(key: first.key, id: first.id)
        await pool.release(key: first.key, id: first.id)
        #expect(await pool.borrowerCount(for: "live") == 1)
        await #expect(throws: MeetingDiarizationModelError.inUse) { try await fixture.store.delete() }
        await pool.release(key: sibling.key, id: sibling.id)
        try await fixture.store.delete()
    }

    @Test("separate presets hold independent leases; releasing one cannot unpin the other")
    func differentPresetsRemainIndependent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pool = Pool()
        let live = try await pool.acquire(key: "live", load: { try await fixture.store.acquire() }, release: { await fixture.store.release() })
        let finalLease = try await pool.acquire(key: "final", load: { try await fixture.store.acquire() }, release: { await fixture.store.release() })
        await pool.release(key: live.key, id: live.id)
        await #expect(throws: MeetingDiarizationModelError.inUse) { try await fixture.store.delete() }
        await pool.release(key: finalLease.key, id: finalLease.id)
        try await fixture.store.delete()
    }

    @Test("already cancelled prepare does not acquire or start loading")
    func cancelBeforePrepare() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pool = Pool()
        let admission = LoadingBarrier()
        let loading = LoadingBarrier()
        let task = Task {
            await admission.pause()
            return try await pool.acquire(key: "live", load: {
                await loading.pause()
                return try await fixture.store.acquire()
            }, release: { await fixture.store.release() })
        }
        await admission.waitUntilEntered()
        task.cancel()
        await admission.open()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await loading.calls == 0)
        #expect(await pool.borrowerCount(for: "live") == 0)
        try await fixture.store.delete()
    }

    @Test("real worker cancel-before-prepare and failed Core ML prepare leave no model lease")
    func workerTerminalPreparationCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cancelled = MeetingDiarizationWorker(preset: .live, sessionID: UUID(), store: fixture.store)
        await cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.prepare() }
        let failed = MeetingDiarizationWorker(preset: .live, sessionID: UUID(), store: fixture.store)
        await #expect(throws: MeetingDiarizationFailure.modelUnavailable) { try await failed.prepare() }
        await failed.cancel()
        await failed.cancel()
        try await fixture.store.delete()
    }

    @Test("failed real prewarm preparation releases both the gate and verified artifact lease")
    @MainActor
    func failedPrewarmUnpinsGateAndModels() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = MeetingDiarizationExecutionGate()
        let prewarmer = MeetingLiveSpeakerPrewarmer(
            gate: gate, enabled: { true }, installed: { await fixture.store.isInstalled() },
            createWorker: { MeetingDiarizationWorker(preset: .live, sessionID: $0, store: fixture.store) }
        )
        await prewarmer.prepareIfAvailable()
        #expect(prewarmer.phase == .preparing)
        while prewarmer.phase != .inactive { await Task.yield() }
        await prewarmer.releaseUnused()
        #expect(prewarmer.take(groupID: "recording") == nil)
        #expect(await gate.beginFinal())
        gate.endFinal()
        try await fixture.store.delete()
    }

    /// A real store and verified local bytes; no Core ML prediction mock. The pool
    /// tests exercise resource ownership, not fabricated speaker probabilities.
    private struct Fixture: Sendable {
        let root: URL
        let directory: URL
        let store: MeetingDiarizationModelStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            directory = root.appendingPathComponent(MeetingDiarizationModelStore.modelDirectoryName)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bytes = Data([1, 2, 3, 4])
            let file = MeetingDiarizationModelStore.PinnedFile(
                path: "lease-fixture.bin", size: Int64(bytes.count),
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            )
            try bytes.write(to: directory.appendingPathComponent(file.localPath))
            store = MeetingDiarizationModelStore(root: root, expectedFiles: [file])
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor LoadingBarrier {
    private var opened = false
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0

    func waitUntilEntered() async {
        if calls > 0 { return }
        await withCheckedContinuation { entered.append($0) }
    }

    func pause() async {
        calls += 1
        let observers = entered
        entered.removeAll()
        for observer in observers { observer.resume() }
        if opened { return }
        await withCheckedContinuation { blocked.append($0) }
    }

    func open() {
        opened = true
        let waiters = blocked
        blocked.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
