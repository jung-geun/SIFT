import Foundation
import SwiftData
import Testing
@testable import todo

@MainActor
@Suite("Cloud identity conflict review and recovery", .serialized)
struct CloudSyncConflictTests {
    private enum Failure: Error { case save }

    @MainActor
    private final class Fixture {
        let root: URL
        let app: ModelContext
        let email: ModelContext
        let meeting: ModelContext
        let cloud: ModelContext
        let installation = UUID().uuidString
        let engine: FullCloudSyncEngine
        let service: FullCloudSyncService
        let date = Date(timeIntervalSinceReferenceDate: 810_000_000)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudConflict-\(UUID().uuidString)", isDirectory: true)
            func context(_ schema: Schema) throws -> ModelContext {
                let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
                context.autosaveEnabled = false
                return context
            }
            app = try context(AppDataContainer.appSchema)
            email = try context(AppDataContainer.emailSchema)
            meeting = try context(AppDataContainer.meetingSchema)
            cloud = try context(Schema([CloudDataRevision.self]))
            engine = try FullCloudSyncEngine(cloud: cloud, installationID: installation,
                journalURL: root.appendingPathComponent("journal.json"))
            service = FullCloudSyncService(conflictApp: app, conflictEmail: email, conflictMeeting: meeting,
                engine: engine, archiveURL: root.appendingPathComponent("history.json"))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func todo(_ title: String, id: UUID = UUID()) throws -> Todo {
            let row = Todo(title: title, notes: "Original notes: \(title)")
            row.id = id
            row.createdAt = date
            row.updatedAt = date
            app.insert(row)
            try app.save()
            return row
        }

        func snapshot() throws -> CloudModelCodec.Snapshot {
            try CloudModelCodec.capture(app: app, email: email, meeting: meeting)
        }

        func payload(_ row: Todo) throws -> Data {
            let key = "Todo/" + row.id.uuidString.lowercased()
            return try #require(snapshot().records[key])
        }

        @discardableResult
        func remote(_ key: String, _ payload: Data?, clock: Int64) throws -> CloudDataRevision {
            let row = CloudDataRevision(itemKey: key, clock: clock, installationID: UUID().uuidString, payload: payload)
            cloud.insert(row)
            try cloud.save()
            return row
        }

        func sync(_ replacement: FullCloudSyncEngine? = nil) async throws {
            let engine = replacement ?? self.engine
            let snapshot = try snapshot()
            let conflicts = try await engine.modelConflicts(local: snapshot)
            try await engine.reconcile(digests: snapshot.records.mapValues(CloudFileStore.digest),
                temporarilyUnavailable: snapshot.conflictingKeys.union(conflicts.map(\.itemKey)).union(engine.unavailableConflictKeys),
                load: { snapshot.records[$0] }, apply: { key, payload in
                    try CloudModelCodec.apply(key: key, payload: payload, app: self.app, email: self.email, meeting: self.meeting)
                    for context in [self.app, self.email, self.meeting] where context.hasChanges { try context.save() }
                })
        }
    }

    private struct WireEnvelope: Codable {
        let version: Int
        let entity: String
        let identity: String
        var fields: [String: Data]
    }

    private func changed<Value: Encodable>(_ payload: Data, field: String, value: Value) throws -> Data {
        var envelope = try JSONDecoder().decode(WireEnvelope.self, from: payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        envelope.fields[field] = try encoder.encode(value)
        return try encoder.encode(envelope)
    }

    @Test("Selected third version replaces every duplicate and remote envelope, retains originals and stays resolved")
    func selectedVersionArchiveAndResync() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let first = try f.todo("First")
        let todoID = first.id
        let audit = TaskAuditEvent(from: first)
        let behavior = TaskBehaviorEvent(todo: first, type: .created, actor: .system, occurredAt: f.date)
        f.app.insert(audit)
        f.app.insert(behavior)
        try f.app.save()
        let firstPayload = try f.payload(first)
        let key = "Todo/" + first.id.uuidString.lowercased()
        _ = try f.remote(key, try changed(firstPayload, field: "title", value: "Remote"), clock: 7)
        _ = try f.todo("Second", id: first.id)
        _ = try f.todo("Third", id: first.id)
        let unrelated = try f.todo("Independent task")
        try await f.sync()
        #expect(try f.cloud.fetch(FetchDescriptor<CloudDataRevision>()).contains { $0.itemKey == "Todo/" + unrelated.id.uuidString.lowercased() })
        try await f.service.refreshConflicts()
        let conflict = try #require(f.service.conflicts.first)
        #expect(conflict.id == key)
        #expect(conflict.versions.count == 4)
        #expect(conflict.versions.allSatisfy { $0.modifiedAt == f.date })
        let chosen = try #require(conflict.versions.first { $0.fields.contains { $0.name == "title" && $0.value == "Third" } })
        try await f.service.resolveConflict(conflict, selecting: chosen.id)
        #expect(f.service.conflicts.isEmpty)
        #expect(f.service.errorMessage == nil)
        let duplicates = try f.app.fetch(FetchDescriptor<Todo>()).filter { $0.id == todoID }
        #expect(duplicates.count == 1)
        #expect(duplicates.allSatisfy { $0.title == "Third" && $0.notes == "Original notes: Third" })
        #expect(try f.app.fetch(FetchDescriptor<TaskAuditEvent>()).map(\.id) == [audit.id])
        #expect(try f.app.fetch(FetchDescriptor<TaskBehaviorEvent>()).map(\.id) == [behavior.id])
        let saved = try f.cloud.fetch(FetchDescriptor<CloudDataRevision>()).filter { $0.itemKey == key }
        #expect(saved.count == 1)
        #expect(saved.first?.payload == chosen.payload)
        #expect((saved.first?.logicalClock ?? 0) > 7)
        let archive = try #require(f.service.retainedConflicts.first)
        #expect(Set(archive.versions.compactMap(\.payload)) == Set(conflict.versions.compactMap(\.payload)))
        #expect(try CloudSyncConflictArchive(url: f.root.appendingPathComponent("history.json")).load() == [archive])
        let restarted = try FullCloudSyncEngine(cloud: f.cloud, installationID: f.installation,
            journalURL: f.root.appendingPathComponent("journal.json"))
        try await f.sync(restarted)
        try await f.sync(restarted)
        #expect(try await restarted.modelConflicts(local: f.snapshot()).isEmpty)
        #expect(try f.cloud.fetch(FetchDescriptor<CloudDataRevision>()).filter { $0.itemKey == key }.count == 1)
    }

    @Test("Edited local data invalidates a reviewed selection without writing archive or changing rows")
    func staleLocalSelection() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let first = try f.todo("First")
        let second = try f.todo("Second", id: first.id)
        try await f.service.refreshConflicts()
        let reviewed = try #require(f.service.conflicts.first)
        first.title = "New unreviewed edit"
        try f.app.save()
        await #expect(throws: CloudSyncConflictError.staleSelection) {
            try await f.service.resolveConflict(reviewed, selecting: reviewed.versions[0].id)
        }
        #expect(first.title == "New unreviewed edit" && second.title == "Second")
        #expect(f.service.retainedConflicts.isEmpty)
        #expect(try f.cloud.fetch(FetchDescriptor<CloudDataRevision>()).isEmpty)
        try await f.service.refreshConflicts()
        #expect(f.service.conflicts.first?.id == reviewed.id)
        #expect(f.service.conflicts.first?.fingerprint != reviewed.fingerprint)
    }

    @Test("An arriving remote version invalidates selection and is not compacted away")
    func staleRemoteSelection() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let first = try f.todo("First")
        let payload = try f.payload(first)
        let key = "Todo/" + first.id.uuidString.lowercased()
        _ = try f.todo("Second", id: first.id)
        try await f.service.refreshConflicts()
        let conflict = try #require(f.service.conflicts.first)
        let arrival = try f.remote(key, try changed(payload, field: "title", value: "Arriving edit"), clock: 12)
        await #expect(throws: CloudSyncConflictError.staleSelection) {
            try await f.service.resolveConflict(conflict, selecting: conflict.versions[0].id)
        }
        #expect(try f.cloud.fetch(FetchDescriptor<CloudDataRevision>()).map(\.revisionID) == [arrival.revisionID])
        #expect(f.service.retainedConflicts.isEmpty)
    }

    @Test("Canonical save failure leaves originals, remote rows and checkpoint intact but retains recovery copies")
    func localSaveFailure() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let first = try f.todo("First")
        _ = try f.todo("Second", id: first.id)
        try await f.service.refreshConflicts()
        let conflict = try #require(f.service.conflicts.first)
        let before = try f.snapshot().versions
        await #expect(throws: Failure.self) {
            try await f.service.resolveConflict(conflict, selecting: conflict.versions[0].id, save: { _ in throw Failure.save })
        }
        #expect(try f.snapshot().versions.mapValues(Set.init) == before.mapValues(Set.init))
        #expect(try f.cloud.fetch(FetchDescriptor<CloudDataRevision>()).isEmpty)
        #expect(f.engine.journal.pendingPublications.isEmpty)
        #expect(f.service.retainedConflicts.count == 1)
        try await f.service.resolveConflict(conflict, selecting: conflict.versions[0].id)
        #expect(f.service.retainedConflicts.count == 1)
    }

    @Test("Unreadable history or an unavailable archive directory refuses resolution before saves", arguments: [false, true])
    func archiveFailure(corruptExistingHistory: Bool) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let first = try f.todo("First")
        _ = try f.todo("Second", id: first.id)
        try await f.service.refreshConflicts()
        let conflict = try #require(f.service.conflicts.first)
        let before = try f.snapshot().versions
        if corruptExistingHistory {
            try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
            try Data("not a recovery archive".utf8).write(to: f.root.appendingPathComponent("history.json"))
        } else {
            // A regular file in place of the protected archive directory makes
            // durable retention fail before the resolver touches either store.
            try Data("not a directory".utf8).write(to: f.root)
        }
        await #expect(throws: (any Error).self) {
            try await f.service.resolveConflict(conflict, selecting: conflict.versions[0].id)
        }
        #expect(try f.snapshot().versions.mapValues(Set.init) == before.mapValues(Set.init))
        #expect(try f.cloud.fetch(FetchDescriptor<CloudDataRevision>()).isEmpty)
    }

    @Test("A cloud-save failure retries the exact selected intent after restart rather than restoring a loser")
    func cloudSaveFailureReplay() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let row = try f.todo("Baseline")
        let key = "Todo/" + row.id.uuidString.lowercased()
        let original = try f.payload(row)
        _ = try f.remote(key, original, clock: 1)
        try await f.sync()
        row.title = "Selected local edit"
        try f.app.save()
        let selected = try f.payload(row)
        _ = try f.remote(key, try changed(original, field: "title", value: "Remote competitor"), clock: 2)
        try await f.service.refreshConflicts()
        let conflict = try #require(f.service.conflicts.first)
        let archive = CloudSyncConflictArchive(url: f.root.appendingPathComponent("history.json"))
        try archive.retain(conflict)
        #expect(throws: Failure.self) {
            try f.engine.resolve(key: key, payload: selected,
                expectedCloudVersions: conflict.versions.filter { $0.origin == .cloud },
                isValid: { true }, apply: {}, saveCloud: { _ in throw Failure.save })
        }
        let intended = try #require(f.engine.journal.pendingPublications[key])
        #expect(intended.digest == CloudFileStore.digest(selected))
        #expect(try f.cloud.fetch(FetchDescriptor<CloudDataRevision>()).filter { $0.itemKey == key }.count == 2)
        let restarted = try FullCloudSyncEngine(cloud: f.cloud, installationID: f.installation,
            journalURL: f.root.appendingPathComponent("journal.json"))
        #expect(try await restarted.modelConflicts(local: f.snapshot()).isEmpty)
        try await f.sync(restarted)
        let saved = try #require(f.cloud.fetch(FetchDescriptor<CloudDataRevision>()).first { $0.itemKey == key })
        #expect(saved.revisionID == intended.revisionID)
        #expect(saved.payload == selected)
        #expect(restarted.journal.pendingPublications.isEmpty)
        #expect(try archive.load().count == 1)
    }

    @Test("Retained versions are reviewable and restorable, with a fresh stale-edit guard")
    func retainedRecovery() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let row = try f.todo("Original")
        _ = try f.todo("Other", id: row.id)
        try await f.service.refreshConflicts()
        let conflict = try #require(f.service.conflicts.first)
        let other = try #require(conflict.versions.first { $0.fields.contains { $0.name == "title" && $0.value == "Other" } })
        try await f.service.resolveConflict(conflict, selecting: other.id)
        let retained = try #require(f.service.retainedConflicts.first)
        let recovery = try await f.service.reviewRetainedConflict(retained)
        let original = try #require(recovery.versions.first {
            $0.origin == .retained && $0.fields.contains { $0.name == "title" && $0.value == "Original" }
        })
        let current = try #require(f.app.fetch(FetchDescriptor<Todo>()).first)
        current.title = "Edited since recovery review"
        try f.app.save()
        await #expect(throws: CloudSyncConflictError.staleSelection) {
            try await f.service.resolveConflict(recovery, selecting: original.id)
        }
        let fresh = try await f.service.reviewRetainedConflict(retained)
        let selected = try #require(fresh.versions.first { $0.id == original.id })
        try await f.service.resolveConflict(fresh, selecting: selected.id)
        #expect(try f.app.fetch(FetchDescriptor<Todo>()).allSatisfy { $0.title == "Original" })
        #expect(f.service.retainedConflicts.count == 2)
        try await f.sync()
        try await f.service.refreshConflicts()
        #expect(f.service.conflicts.isEmpty)
    }

    @Test("Repeated recovery keeps retained review identities bounded and original archive provenance intact")
    func repeatedRecoveryNormalizesRetainedVersions() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let row = try f.todo("First")
        _ = try f.todo("Second", id: row.id)
        try await f.service.refreshConflicts()
        let conflict = try #require(f.service.conflicts.first)
        let second = try #require(conflict.versions.first {
            $0.fields.contains { $0.name == "title" && $0.value == "Second" }
        })
        try await f.service.resolveConflict(conflict, selecting: second.id)
        let originals = try #require(f.service.retainedConflicts.first)
        var stableIDs = Set<String>()
        for iteration in 0..<4 {
            let history = try #require(f.service.retainedConflicts.first)
            let review = try await f.service.reviewRetainedConflict(history)
            let retained = review.versions.filter { $0.origin == .retained }
            #expect(retained.count == 2)
            #expect(Set(retained.map { $0.payload.map(CloudFileStore.digest) ?? "deleted" }).count == 2)
            #expect(retained.allSatisfy { $0.source == conflict.itemKey && !$0.id.contains("#") })
            let observed = Set(retained.map(\.id))
            if stableIDs.isEmpty { stableIDs = observed }
            else { #expect(observed == stableIDs) }
            let title = iteration.isMultiple(of: 2) ? "First" : "Second"
            let selected = try #require(retained.first {
                $0.fields.contains { $0.name == "title" && $0.value == title }
            })
            try await f.service.resolveConflict(review, selecting: selected.id)
        }
        let saved = try CloudSyncConflictArchive(url: f.root.appendingPathComponent("history.json")).load()
        #expect(saved.contains(originals))
        #expect(originals.versions == conflict.versions)
    }

    @Test("Ordinary incoming changes and equivalent cloud peers do not manufacture review conflicts")
    func semanticEquivalenceAndNormalIncoming() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let row = try f.todo("Initial")
        let key = "Todo/" + row.id.uuidString.lowercased()
        let original = try f.payload(row)
        _ = try f.remote(key, original, clock: 1)
        try await f.sync()
        let incoming = try changed(original, field: "title", value: "Normal remote update")
        _ = try f.remote(key, incoming, clock: 2)
        try await f.service.refreshConflicts()
        #expect(f.service.conflicts.isEmpty)
        try await f.sync()
        #expect(row.title == "Normal remote update")
        let deviceLocalDifference = try changed(incoming, field: "calendarSourceID", value: "other-device-only-source")
        _ = try f.remote(key, deviceLocalDifference, clock: 2)
        #expect(incoming != deviceLocalDifference)
        #expect(try CloudModelCodec.semanticDigest(key: key, payload: incoming) == CloudModelCodec.semanticDigest(key: key, payload: deviceLocalDifference))
        try await f.service.refreshConflicts()
        #expect(f.service.conflicts.isEmpty)
        try await f.sync()
        #expect(try f.cloud.fetch(FetchDescriptor<CloudDataRevision>()).filter { $0.itemKey == key }.count == 1)
    }

    @Test("Concurrent equal-clock cloud branches require a choice and converge to the selected branch")
    func cloudPeerSelection() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let row = try f.todo("First cloud branch")
        let key = "Todo/" + row.id.uuidString.lowercased()
        let original = try f.payload(row)
        let alternative = try changed(original, field: "title", value: "Selected cloud branch")
        _ = try f.remote(key, original, clock: 4)
        _ = try f.remote(key, alternative, clock: 4)
        try await f.service.refreshConflicts()
        let review = try #require(f.service.conflicts.first)
        let chosen = try #require(review.versions.first { $0.origin == .cloud && $0.payload == alternative })
        try await f.service.resolveConflict(review, selecting: chosen.id)
        #expect(row.title == "Selected cloud branch")
        #expect(f.service.retainedConflicts.first?.versions.count == 3)
        try await f.sync()
        try await f.service.refreshConflicts()
        #expect(f.service.conflicts.isEmpty)
        #expect(try f.cloud.fetch(FetchDescriptor<CloudDataRevision>()).count == 1)
    }

    @Test("Remote clock metadata changes invalidate a selected envelope before apply")
    func remoteMetadataStaleGuard() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let row = try f.todo("Original")
        let key = "Todo/" + row.id.uuidString.lowercased()
        let payload = try f.payload(row)
        let remote = try f.remote(key, payload, clock: 1)
        let reviewed = try await f.engine.cloudVersions(key: key)
        remote.logicalClock = 8
        try f.cloud.save()
        var applied = false
        #expect(throws: CloudSyncConflictError.staleSelection) {
            try f.engine.resolve(key: key, payload: payload, expectedCloudVersions: reviewed,
                isValid: { true }, apply: { applied = true })
        }
        #expect(!applied)
        #expect(f.engine.journal.pendingPublications.isEmpty)
        #expect(remote.logicalClock == 8)
    }

    @Test("Old absent default fields and neutral physical duplicates are semantically equivalent")
    func schemaDefaultsAndLocalNeutralValues() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let row = try f.todo("Same")
        row.calendarSourceID = "device-calendar-one"
        let duplicate = try f.todo("Same", id: row.id)
        duplicate.calendarSourceID = "device-calendar-two"
        try f.app.save()
        #expect(try f.snapshot().conflictingKeys.isEmpty)
        let meeting = MeetingRecord()
        meeting.meetingID = UUID().uuidString.lowercased()
        f.meeting.insert(meeting)
        try f.meeting.save()
        let snapshot = try f.snapshot()
        let key = try #require(snapshot.records.keys.first { $0.hasPrefix("MeetingRecord/") })
        let original = try #require(snapshot.records[key])
        var legacy = try JSONDecoder().decode(WireEnvelope.self, from: original)
        legacy.fields.removeValue(forKey: "automaticLanguageDetection")
        let oldPayload = try JSONEncoder().encode(legacy)
        #expect(oldPayload != original)
        #expect(try CloudModelCodec.semanticDigest(key: key, payload: oldPayload) == CloudModelCodec.semanticDigest(key: key, payload: original))
        _ = try f.remote(key, oldPayload, clock: 2)
        _ = try f.remote(key, original, clock: 2)
        try await f.service.refreshConflicts()
        #expect(f.service.conflicts.isEmpty)
    }

    @Test("A competing newer-schema envelope stays held without starving an independent task")
    func newerSchemaDoesNotStarveIndependentSync() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let row = try f.todo("Reviewed schema")
        let key = "Todo/" + row.id.uuidString.lowercased()
        let original = try f.payload(row)
        let newerSchema = try changed(original, field: "futureSchemaField", value: "Retain these original bytes")
        _ = try f.remote(key, original, clock: 3)
        _ = try f.remote(key, newerSchema, clock: 3)
        let independent = try f.todo("Independent forward progress")
        let independentKey = "Todo/" + independent.id.uuidString.lowercased()
        try await f.sync()
        let cloudRows = try f.cloud.fetch(FetchDescriptor<CloudDataRevision>())
        #expect(cloudRows.contains { $0.itemKey == independentKey })
        #expect(cloudRows.filter { $0.itemKey == key }.count == 2)
        try await f.service.refreshConflicts()
        let review = try #require(f.service.conflicts.first { $0.itemKey == key })
        #expect(review.versions.contains { $0.payload == newerSchema })
        let selected = try #require(review.versions.first { $0.origin == .local })
        try await f.service.resolveConflict(review, selecting: selected.id)
        #expect(f.service.retainedConflicts.first?.versions.contains { $0.payload == newerSchema } == true)
    }

    @Test("Meeting tombstone review cannot destroy parent, child, original audio or deletion fences")
    func meetingDeletionRequiresMeetingFlow() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let parent = MeetingRecord()
        parent.meetingID = UUID().uuidString.lowercased()
        parent.summaryCustomInstructions = "Parent original"
        let child = MeetingRecord()
        child.meetingID = UUID().uuidString.lowercased()
        child.parentMeetingID = parent.meetingID
        f.meeting.insert(parent)
        f.meeting.insert(child)
        try f.meeting.save()
        let originalSnapshot = try f.snapshot()
        let key = try #require(originalSnapshot.records.keys.first { key in
            (try? CloudModelCodec.meetingID(for: key)) == parent.meetingID
        })
        let original = try #require(originalSnapshot.records[key])
        _ = try f.remote(key, original, clock: 1)
        try await f.sync()
        parent.summaryCustomInstructions = "Edited parent"
        try f.meeting.save()
        _ = try f.remote(key, nil, clock: 2)
        try await f.service.refreshConflicts()
        let conflict = try #require(f.service.conflicts.first { $0.itemKey == key })
        let deletion = try #require(conflict.versions.first { $0.payload == nil })
        // Use isolated marker/audio bytes. A rejected action must never reach
        // applyModelRecord or any filesystem mutation at all.
        let files = f.root.appendingPathComponent("Meetings", isDirectory: true)
        for id in [parent.meetingID, child.meetingID] {
            let directory = files.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("original audio \(id)".utf8).write(to: directory.appendingPathComponent("audio.wav"))
        }
        await #expect(throws: CloudSyncConflictError.dependentContentUnavailable) {
            try await f.service.resolveConflict(conflict, selecting: deletion.id)
        }
        #expect(parent.summaryCustomInstructions == "Edited parent")
        #expect(try f.meeting.fetch(FetchDescriptor<MeetingRecord>()).count == 2)
        #expect(f.service.retainedConflicts.isEmpty)
        for id in [parent.meetingID, child.meetingID] {
            #expect(try !MeetingDeletionFence.isDeleted(meetingID: id, rootURL: files))
            #expect(try Data(contentsOf: files.appendingPathComponent(id).appendingPathComponent("audio.wav")) == Data("original audio \(id)".utf8))
        }
        #expect(try f.cloud.fetch(FetchDescriptor<CloudDataRevision>()).filter { $0.itemKey == key }.count == 2)
    }
}
