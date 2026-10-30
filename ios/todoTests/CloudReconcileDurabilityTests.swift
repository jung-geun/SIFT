import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Cloud reconcile write-ahead durability", .serialized)
@MainActor
struct CloudReconcileDurabilityTests {
    @Test("Applied R2 survives a lost tail checkpoint and cannot echo over arriving R3")
    func remoteApplyCrashR1R2R3() async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        let engine = try fixture.engine()
        let r1 = try fixture.remote("R1", clock: 1)
        var local = Data("R1".utf8)
        try await engine.reconcile(digests: [fixture.key: fixture.digest(local)], load: { _ in local }, apply: { _, data in
            local = try #require(data)
        })
        #expect(engine.journal.items[fixture.key] == r1)
        let r2 = try fixture.remote("R2", clock: 2)
        await #expect(throws: DurabilityFailure.self) {
            try await engine.reconcile(digests: [fixture.key: fixture.digest(local)], load: { _ in local }, apply: { _, data in
                // The application's local save committed, but the engine never
                // reached its checkpoint. This is the process-crash disk image.
                local = try #require(data)
                throw DurabilityFailure.crash
            })
        }
        let disk = try fixture.readJournal()
        #expect(disk.items[fixture.key] == r1)
        #expect(disk.pendingApplies[fixture.key]?.sourceDigest == r1.digest)
        #expect(disk.pendingApplies[fixture.key]?.target == r2)
        let r3 = try fixture.remote("R3", clock: 3)
        let restarted = try fixture.engine()
        var loads = 0
        try await restarted.reconcile(digests: [fixture.key: fixture.digest(local)], load: { _ in
            loads += 1
            return local
        }, apply: { _, data in local = try #require(data) })
        #expect(local == Data("R3".utf8))
        #expect(loads == 0)
        #expect(restarted.journal.items[fixture.key] == r3)
        #expect(try fixture.records().map(\.revisionID) == [r3.revisionID])
        #expect(try fixture.readJournal().pendingApplies.isEmpty)
    }

    @Test("Recovery distinguishes an unchanged source from a genuine newer local edit", arguments: [false, true])
    func interruptedApplySourceOrNewEdit(newEdit: Bool) async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        let engine = try fixture.engine()
        _ = try fixture.remote("R1", clock: 1)
        var local = Data("R1".utf8)
        try await engine.reconcile(digests: [fixture.key: fixture.digest(local)], load: { _ in local }, apply: { _, _ in })
        _ = try fixture.remote("R2", clock: 2)
        await #expect(throws: DurabilityFailure.self) {
            try await engine.reconcile(digests: [fixture.key: fixture.digest(local)], load: { _ in local }, apply: { _, _ in
                // No local save committed: the source remains R1.
                throw DurabilityFailure.crash
            })
        }
        let r3 = try fixture.remote("R3", clock: 3)
        if newEdit { local = Data("genuine local edit".utf8) }
        let restarted = try fixture.engine()
        try await restarted.reconcile(digests: [fixture.key: fixture.digest(local)], load: { _ in local }, apply: { _, data in
            local = try #require(data)
        })
        let saved = try #require(fixture.records().first)
        if newEdit {
            #expect(saved.payload == Data("genuine local edit".utf8))
            #expect(saved.installationID == fixture.installation)
            #expect(saved.logicalClock == 4)
        } else {
            #expect(local == Data("R3".utf8))
            #expect(saved.revisionID == r3.revisionID)
        }
    }

    @Test("A joining device also preserves edits made after an interrupted first apply")
    func joiningDeviceNewEdit() async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        _ = try fixture.remote("remote", clock: 1)
        let engine = try fixture.engine()
        let source = Data("old cache".utf8)
        await #expect(throws: DurabilityFailure.self) {
            try await engine.reconcile(digests: [fixture.key: fixture.digest(source)], load: { _ in source }, apply: { _, _ in
                throw DurabilityFailure.crash
            })
        }
        let edited = Data("edited after interruption".utf8)
        let restarted = try fixture.engine()
        try await restarted.reconcile(digests: [fixture.key: fixture.digest(edited)], load: { _ in edited }, apply: { _, _ in
            Issue.record("A genuine local edit must not be replaced")
        })
        #expect(try fixture.records().first?.payload == edited)
    }

    @Test("Publication recovery reuses its intended identity, or honors a newer remote", arguments: [false, true], [false, true])
    func publicationCrash(afterSave: Bool, newerRemote: Bool) async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        _ = try fixture.remote("R1", clock: 1)
        let engine = try fixture.engine()
        let r1 = Data("R1".utf8)
        try await engine.reconcile(digests: [fixture.key: fixture.digest(r1)], load: { _ in r1 }, apply: { _, _ in })
        let local = Data("intended publication".utf8)
        var valid = true
        var enqueues = 0
        do {
            try await engine.reconcile(digests: [fixture.key: fixture.digest(local)], isValid: { valid }, didEnqueue: {
                enqueues += 1
                // Stop immediately after save, before the checkpoint mutation.
                valid = false
            }, load: { _ in
                if !afterSave { throw DurabilityFailure.crash }
                return local
            }, apply: { _, _ in Issue.record("Unexpected apply") })
            Issue.record("Expected an interrupted publication")
        } catch is CancellationError {
            #expect(afterSave)
        } catch is DurabilityFailure {
            #expect(!afterSave)
        }
        #expect(enqueues == (afterSave ? 1 : 0))
        #expect(engine.didEnqueueChanges == afterSave)
        let disk = try fixture.readJournal()
        let intended = try #require(disk.pendingPublications[fixture.key])
        #expect(disk.items[fixture.key]?.logicalClock == 1)
        #expect(try fixture.records().contains { $0.revisionID == intended.revisionID } == afterSave)
        var winner: CloudSyncCheckpoint?
        if newerRemote { winner = try fixture.remote("newer remote", clock: intended.logicalClock + 1) }
        let restarted = try fixture.engine()
        var loads = 0
        var restored: Data?
        try await restarted.reconcile(digests: [fixture.key: fixture.digest(local)], load: { _ in
            loads += 1
            return local
        }, apply: { _, data in restored = data })
        let records = try fixture.records()
        #expect(records.count == 1)
        let saved = try #require(records.first)
        if let winner {
            #expect(saved.revisionID == winner.revisionID)
            #expect(restored == Data("newer remote".utf8))
            #expect(loads == 0)
        } else {
            #expect(saved.revisionID == intended.revisionID)
            #expect(saved.logicalClock == intended.logicalClock)
            #expect(saved.installationID == intended.installationID)
            #expect(loads == (afterSave ? 0 : 1))
            #expect(restored == nil)
        }
        #expect(try fixture.readJournal().pendingPublications.isEmpty)
    }

    @Test("A never-committed first publication is not discarded just because a remote appeared")
    func firstPublicationRetriesSameRevision() async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        // Another key raises our intended clock above an arriving older winner.
        _ = try fixture.remote("other", clock: 10, key: "Todo/other")
        let local = Data("not yet saved".utf8)
        let engine = try fixture.engine()
        await #expect(throws: DurabilityFailure.self) {
            try await engine.reconcile(digests: [fixture.key: fixture.digest(local)], load: { _ in
                throw DurabilityFailure.crash
            }, apply: { _, _ in })
        }
        let intended = try #require(fixture.readJournal().pendingPublications[fixture.key])
        _ = try fixture.remote("older remote", clock: 1)
        let restarted = try fixture.engine()
        try await restarted.reconcile(digests: [fixture.key: fixture.digest(local)], load: { _ in local }, apply: { _, _ in })
        let saved = try #require(fixture.records().first { $0.itemKey == fixture.key })
        #expect(saved.revisionID == intended.revisionID)
        #expect(saved.logicalClock == 11)
        #expect(saved.payload == local)
    }

    @Test("Cancellation or invalidation during a suspended load queues no cloud mutation", arguments: [false, true])
    func suspendedLoadGuard(cancel: Bool) async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        let engine = try fixture.engine()
        let gate = DurabilityLoadGate()
        let data = Data("suspended source".utf8)
        var valid = true
        var enqueues = 0
        let task = Task { @MainActor in
            try await engine.reconcile(digests: [fixture.key: fixture.digest(data)], isValid: { valid }, didEnqueue: {
                enqueues += 1
            }, load: { _ in
                await gate.suspend()
                return data
            }, apply: { _, _ in Issue.record("Unexpected apply") })
        }
        await gate.waitUntilSuspended()
        if cancel { task.cancel() } else { valid = false }
        gate.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(enqueues == 0)
        #expect(!engine.didEnqueueChanges)
        #expect(try fixture.records().isEmpty)
        #expect(engine.journal.items.isEmpty)
        let pending = try #require(fixture.readJournal().pendingPublications[fixture.key])
        let restarted = try fixture.engine()
        try await restarted.reconcile(digests: [fixture.key: fixture.digest(data)], load: { _ in data }, apply: { _, _ in })
        #expect(try fixture.records().first?.revisionID == pending.revisionID)
    }

    @Test("Invalidation after apply preserves recovery intent and prevents compaction")
    func invalidatedApply() async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        let engine = try fixture.engine()
        let r1 = try fixture.remote("R1", clock: 1)
        let source = Data("R1".utf8)
        try await engine.reconcile(digests: [fixture.key: fixture.digest(source)], load: { _ in source }, apply: { _, _ in })
        let r2 = try fixture.remote("R2", clock: 2)
        var valid = true
        var local = source
        await #expect(throws: CancellationError.self) {
            try await engine.reconcile(digests: [fixture.key: fixture.digest(local)], isValid: { valid }, didEnqueue: {
                Issue.record("Invalidated apply must not enqueue compaction")
            }, load: { _ in local }, apply: { _, data in
                local = try #require(data)
                await Task.yield()
                valid = false
            })
        }
        #expect(try fixture.records().count == 2)
        #expect(try fixture.readJournal().items[fixture.key] == r1)
        #expect(try fixture.readJournal().pendingApplies[fixture.key]?.target == r2)
        #expect(!engine.didEnqueueChanges)
    }

    @Test("Corrupt latest payloads are rejected even when the local digest matches", arguments: [false, true])
    func corruptionRejection(matchingLocal: Bool) async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        let expected = Data("expected bytes".utf8)
        let context = ModelContext(fixture.cloud)
        let bad = CloudDataRevision(itemKey: fixture.key, clock: 1, installationID: UUID().uuidString, payload: expected)
        bad.payload = Data("corrupt external bytes".utf8)
        context.insert(bad)
        try context.save()
        let engine = try fixture.engine()
        let digests = matchingLocal ? [fixture.key: fixture.digest(expected)] : [:]
        await #expect(throws: FullCloudSyncError.self) {
            try await engine.reconcile(digests: digests, didEnqueue: { Issue.record("Corruption must not enqueue") },
                load: { _ in expected }, apply: { _, _ in Issue.record("Corruption must not apply") })
        }
        #expect(engine.journal.items[fixture.key] == nil)
        #expect(!engine.didEnqueueChanges)
        #expect(try fixture.records().count == 1)
    }

    @Test("A later load error cannot hide a successful earlier enqueue")
    func partialEnqueueReporting() async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        let engine = try fixture.engine()
        let values = ["Todo/a": Data("a".utf8), "Todo/b": Data("b".utf8)]
        var callbacks = 0
        var reportedImmediately = false
        await #expect(throws: DurabilityFailure.self) {
            try await engine.reconcile(digests: values.mapValues(CloudFileStore.digest), didEnqueue: {
                callbacks += 1
                reportedImmediately = engine.didEnqueueChanges
            }, load: { key in
                if key == "Todo/b" { throw DurabilityFailure.crash }
                return values[key]
            }, apply: { _, _ in Issue.record("Unexpected apply") })
        }
        #expect(callbacks == 1)
        #expect(reportedImmediately)
        #expect(engine.didEnqueueChanges)
        #expect(try fixture.records().map(\.itemKey) == ["Todo/a"])
        let disk = try fixture.readJournal()
        #expect(disk.pendingPublications.count == 2)
        let a = try #require(disk.pendingPublications["Todo/a"])
        let b = try #require(disk.pendingPublications["Todo/b"])
        let restarted = try fixture.engine()
        try await restarted.reconcile(digests: values.mapValues(CloudFileStore.digest), load: { key in
            #expect(key == "Todo/b")
            return values[key]
        }, apply: { _, _ in })
        #expect(Set(try fixture.records().map(\.revisionID)) == Set([a.revisionID, b.revisionID]))
    }

    @Test("Cancellation or invalidation rolls back a staged group without deleting its prior revisions", arguments: [false, true])
    func interruptedPublicationGroup(cancel: Bool) async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        let oldA = try fixture.remote("old a", clock: 1, key: "Todo/a")
        let oldB = try fixture.remote("old b", clock: 1, key: "Todo/b")
        let engine = try fixture.engine()
        let original = ["Todo/a": Data("old a".utf8), "Todo/b": Data("old b".utf8)]
        try await engine.reconcile(digests: original.mapValues(CloudFileStore.digest), load: { original[$0] },
            apply: { _, _ in Issue.record("Matching originals must not be restored") })
        let values = ["Todo/a": Data("edited a".utf8), "Todo/b": Data("edited b".utf8), "Todo/z": Data("new task".utf8)]
        let gate = DurabilityLoadGate()
        var valid = true
        let task = Task { @MainActor in
            try await engine.reconcile(digests: values.mapValues(CloudFileStore.digest), isValid: { valid },
                didEnqueue: { Issue.record("A revoked uncommitted group cannot report success") }, load: { key in
                    if key == "Todo/z" { await gate.suspend() }
                    return values[key]
                }, apply: { _, _ in Issue.record("Local edits must not be replaced") })
        }
        await gate.waitUntilSuspended()
        if cancel { task.cancel() } else { valid = false }
        gate.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!engine.didEnqueueChanges)
        #expect(Set(try fixture.records().map(\.revisionID)) == Set([oldA.revisionID, oldB.revisionID]))
        #expect(engine.journal.items["Todo/a"] == oldA)
        #expect(engine.journal.items["Todo/b"] == oldB)
        let pending = try fixture.readJournal().pendingPublications
        #expect(Set(pending.keys) == Set(values.keys))
        let restarted = try fixture.engine()
        try await restarted.reconcile(digests: values.mapValues(CloudFileStore.digest), load: { values[$0] },
            apply: { _, _ in Issue.record("Recovery must preserve local edits") })
        let recovered = try fixture.records()
        #expect(Dictionary(uniqueKeysWithValues: recovered.map { ($0.itemKey, $0.payload) }) == values.mapValues(Optional.some))
        #expect(Set(recovered.map(\.revisionID)) == Set(pending.values.map(\.revisionID)))
        #expect(try fixture.readJournal().pendingPublications.isEmpty)
    }

    @Test("Compaction reports its successful save at the enqueue boundary")
    func compactionEnqueue() async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        _ = try fixture.remote("old", clock: 1)
        let winner = try fixture.remote("winner", clock: 2)
        let engine = try fixture.engine()
        let data = Data("winner".utf8)
        var callbacks = 0
        try await engine.reconcile(digests: [fixture.key: fixture.digest(data)], didEnqueue: {
            callbacks += 1
            #expect(engine.didEnqueueChanges)
        }, load: { _ in Issue.record("Compaction should not publish"); return data }, apply: { _, _ in
            Issue.record("Matching local data should not be reapplied")
        })
        #expect(callbacks == 1)
        #expect(try fixture.records().map(\.revisionID) == [winner.revisionID])
    }

    @Test("A same-target restart completes protected-file side effects after local bytes were saved")
    func sameTargetApplyCompletesRecoveryFence() async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        let target = try fixture.remote("durable target", clock: 1)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let localURL = fixture.root.appendingPathComponent("local-target.bin")
        let fenceURL = fixture.root.appendingPathComponent("recovery-pending")
        let completionDirectory = fixture.root.appendingPathComponent("completion")
        let completionURL = completionDirectory.appendingPathComponent("state.json")
        try Data("pending".utf8).write(to: fenceURL, options: .completeFileProtectionUntilFirstUserAuthentication)
        // A regular file obstructs the completion directory. This produces a
        // real filesystem failure after the canonical protected file saves,
        // rather than injecting an engine-only throw or a production hook.
        try Data("obstruction".utf8).write(to: completionDirectory)
        let engine = try fixture.engine()
        await #expect(throws: CocoaError.self) {
            try await engine.reconcile(digests: [:], load: { _ in nil }, apply: { _, payload in
                let data = try #require(payload)
                try data.write(to: localURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try Data("completed".utf8).write(to: completionURL,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try FileManager.default.removeItem(at: fenceURL)
            })
        }
        let saved = try Data(contentsOf: localURL)
        #expect(fixture.digest(saved) == target.digest)
        #expect(FileManager.default.fileExists(atPath: fenceURL.path))
        #expect(try fixture.readJournal().items[fixture.key] == nil)
        #expect(try fixture.readJournal().pendingApplies[fixture.key]?.target == target)
        try FileManager.default.removeItem(at: completionDirectory)
        try FileManager.default.createDirectory(at: completionDirectory, withIntermediateDirectories: true)
        let restarted = try fixture.engine()
        var applies = 0
        try await restarted.reconcile(digests: [fixture.key: fixture.digest(saved)], load: { _ in
            Issue.record("An interrupted remote apply must not publish its target")
            return saved
        }, apply: { _, payload in
            applies += 1
            let data = try #require(payload)
            try data.write(to: localURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try Data("completed".utf8).write(to: completionURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.removeItem(at: fenceURL)
        })
        #expect(applies == 1)
        #expect(!FileManager.default.fileExists(atPath: fenceURL.path))
        #expect(try Data(contentsOf: completionURL) == Data("completed".utf8))
        #expect(try fixture.readJournal().items[fixture.key] == target)
        #expect(try fixture.readJournal().pendingApplies.isEmpty)
        #expect(try fixture.records().map(\.revisionID) == [target.revisionID])
    }

    @Test("An applied tombstone cannot be republished over a later recreation")
    func remoteTombstoneCrash() async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        _ = try fixture.remote("R1", clock: 1)
        let engine = try fixture.engine()
        var local: Data? = Data("R1".utf8)
        try await engine.reconcile(digests: [fixture.key: fixture.digest(try #require(local))],
            load: { _ in local }, apply: { _, data in local = data })
        let context = ModelContext(fixture.cloud)
        let tombstone = CloudDataRevision(itemKey: fixture.key, clock: 2,
            installationID: UUID().uuidString, payload: nil)
        context.insert(tombstone)
        try context.save()
        await #expect(throws: DurabilityFailure.self) {
            try await engine.reconcile(digests: [fixture.key: fixture.digest(try #require(local))],
                load: { _ in local }, apply: { _, data in
                    #expect(data == nil)
                    local = data
                    throw DurabilityFailure.crash
                })
        }
        #expect(local == nil)
        #expect(try fixture.readJournal().pendingApplies[fixture.key]?.target.revisionID == tombstone.revisionID)
        let r3 = try fixture.remote("recreated R3", clock: 3)
        let restarted = try fixture.engine()
        try await restarted.reconcile(digests: [:], load: { _ in
            Issue.record("The applied deletion must not become a new publication")
            return nil
        }, apply: { _, data in local = data })
        #expect(local == Data("recreated R3".utf8))
        #expect(try fixture.records().map(\.revisionID) == [r3.revisionID])
    }

    @Test("Unavailable local sources keep their pending publication until the same revision can be saved")
    func unavailablePendingPublication() async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        let engine = try fixture.engine()
        let data = Data("offline asset".utf8)
        await #expect(throws: DurabilityFailure.self) {
            try await engine.reconcile(digests: [fixture.key: fixture.digest(data)], load: { _ in
                throw DurabilityFailure.crash
            }, apply: { _, _ in })
        }
        let pending = try #require(fixture.readJournal().pendingPublications[fixture.key])
        let restarted = try fixture.engine()
        try await restarted.reconcile(digests: [:], temporarilyUnavailable: [fixture.key], load: { _ in
            Issue.record("An unavailable source must not be read")
            return nil
        }, apply: { _, _ in Issue.record("An unavailable source must not be replaced") })
        #expect(try fixture.records().isEmpty)
        #expect(try fixture.readJournal().pendingPublications[fixture.key] == pending)
        try await restarted.reconcile(digests: [fixture.key: fixture.digest(data)], load: { _ in data }, apply: { _, _ in })
        #expect(try fixture.records().first?.revisionID == pending.revisionID)
    }

    @Test("Write-ahead metadata contains no asset bytes and legacy v1 journals still decode")
    func metadataOnlyAndLegacyJournal() async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        let legacy = Data("{\"version\":1,\"items\":{}}".utf8)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try legacy.write(to: fixture.journalURL)
        let engine = try fixture.engine()
        #expect(engine.journal.pendingApplies.isEmpty)
        #expect(engine.journal.pendingPublications.isEmpty)
        let asset = Data(repeating: 0xab, count: 256 * 1024)
        await #expect(throws: DurabilityFailure.self) {
            try await engine.reconcile(digests: [fixture.key: fixture.digest(asset)], load: { _ in
                throw DurabilityFailure.crash
            }, apply: { _, _ in })
        }
        let bytes = try Data(contentsOf: fixture.journalURL)
        #expect(bytes.count < 2048)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let pending = try #require(object["pendingPublications"] as? [String: [String: Any]])
        let metadata = try #require(pending[fixture.key])
        #expect(Set(metadata.keys) == Set(["digest", "revisionID", "logicalClock", "installationID"]))
    }
}

private enum DurabilityFailure: Error { case crash }

@MainActor
private final class DurabilityLoadGate {
    private var suspended = false
    private var onSuspended: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            release = continuation
            suspended = true
            onSuspended?.resume()
            onSuspended = nil
        }
    }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { onSuspended = $0 }
    }

    func resume() {
        release?.resume()
        release = nil
    }
}

@MainActor
private struct DurabilityFixture {
    let cloud: ModelContainer
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudDurability-\(UUID())")
    let key = "Todo/durability"
    let installation = UUID().uuidString
    var journalURL: URL { root.appendingPathComponent("journal.json") }

    init() throws {
        let schema = Schema([CloudDataRevision.self])
        cloud = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    func engine() throws -> FullCloudSyncEngine {
        try FullCloudSyncEngine(cloud: ModelContext(cloud), installationID: installation, journalURL: journalURL)
    }

    func digest(_ data: Data) -> String { CloudFileStore.digest(data) }

    @discardableResult
    func remote(_ text: String, clock: Int64, key: String? = nil) throws -> CloudSyncCheckpoint {
        let context = ModelContext(cloud)
        let data = Data(text.utf8)
        let revision = CloudDataRevision(itemKey: key ?? self.key, clock: clock,
            installationID: "00000000-0000-0000-0000-000000000001", payload: data)
        context.insert(revision)
        try context.save()
        return CloudSyncCheckpoint(digest: digest(data), revisionID: revision.revisionID,
            logicalClock: clock, installationID: revision.installationID)
    }

    func records() throws -> [CloudDataRevision] {
        try ModelContext(cloud).fetch(FetchDescriptor<CloudDataRevision>())
    }

    func readJournal() throws -> CloudSyncJournal {
        try JSONDecoder().decode(CloudSyncJournal.self, from: Data(contentsOf: journalURL))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
