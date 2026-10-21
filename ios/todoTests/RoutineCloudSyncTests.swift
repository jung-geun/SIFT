import Foundation
import Testing
@testable import todo

@Suite("Fine-grained routine cloud records", .serialized)
@MainActor
struct RoutineCloudSyncTests {
    private struct Fixture {
        let directory: URL
        let file: URL
        let defaults: UserDefaults
        let suite: String

        func clean() {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    // Deliberately the original format, with no cloud metadata.
    private struct LegacySnapshot: Encodable {
        var version = 1
        var routines: [LearnedRoutine]
        var feedback: [RoutineFeedback] = []
        var pendingAcceptances: [RoutineAcceptance] = []
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute))!
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routine-cloud-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "routine-cloud-\(UUID())"
        return Fixture(directory: directory, file: directory.appendingPathComponent("routines.json"),
                       defaults: UserDefaults(suiteName: suite)!, suite: suite)
    }

    private func routine(_ id: String, activity: String = "read", updated: Date? = nil) -> LearnedRoutine {
        LearnedRoutine(id: UUID(uuidString: id)!, activityKey: activity, title: activity.capitalized,
                       periodDays: 1, preferredHour: 10, preferredMinute: 15, estimatedDurationMinutes: 35,
                       sampleCount: 5, confidence: 0.91, evidenceStart: date(1), evidenceEnd: date(3),
                       nextOccurrence: date(4, hour: 10, minute: 15), isConfirmed: true,
                       uncertainty: "Local checkoffs only", updatedAt: updated ?? date(3),
                       distinctCompletionDays: 5, recordedCompletionHours: [9, 10, 11, 10, 9],
                       timeZoneIdentifier: "GMT", hasManualOverrides: true, isSuppressed: false,
                       isScheduleManuallySpecified: true)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func seed(_ fixture: Fixture, routines: [LearnedRoutine], feedback: [RoutineFeedback] = [],
                      pending: [RoutineAcceptance] = []) throws -> RoutineStore {
        try encode(LegacySnapshot(routines: routines, feedback: feedback, pendingAcceptances: pending))
            .write(to: fixture.file, options: .atomic)
        return RoutineStore(fileURL: fixture.file, defaults: fixture.defaults)
    }

    private func key(_ kind: String, _ id: UUID) -> String {
        "routine/\(kind)/\(id.uuidString.lowercased())"
    }

    private func apply(_ records: [String: Data], to store: RoutineStore, reversed: Bool = false) throws {
        let keys = records.keys.sorted()
        for key in reversed ? Array(keys.reversed()) : keys {
            try store.applyCloudRecord(key: key, payload: records[key])
        }
    }

    private func author(_ fixture: Fixture, title: String) throws -> RoutineStore {
        let store = RoutineStore(fileURL: fixture.file, defaults: fixture.defaults)
        store.setLearningEnabled(true)
        let todos = [1, 2, 3].map { day in
            let todo = Todo(title: title)
            todo.createdAt = date(day, hour: 9)
            todo.completedAt = date(day, hour: 10, minute: 15)
            todo.isCompleted = true
            return todo
        }
        try store.refresh(todos: todos, now: date(4, hour: 8), calendar: calendar)
        var learned = try #require(store.routines.first)
        learned.estimatedDurationMinutes = 45
        try store.confirm(learned)
        return store
    }

    @Test("Independently authored activities union without restoring tasks or consent")
    func independentPeerUnion() throws {
        let a = try fixture(), b = try fixture(), destination = try fixture()
        defer { a.clean(); b.clean(); destination.clean() }
        let first = try author(a, title: "Read")
        let second = try author(b, title: "Walk")
        let suggestion = try #require(first.suggestions(now: date(4, hour: 8), todos: [], calendar: calendar).first)
        let reservation = try first.beginAcceptance(suggestion, todos: [], appliedTime: date(4, hour: 11),
                                                    todoID: UUID(), now: date(4, hour: 8), calendar: calendar)
        let walk = try #require(second.routines.first)
        let rejection = RoutineFeedback(routineID: walk.id, occurrence: date(4), action: .rejected,
                                        suggestedTime: date(4, hour: 10, minute: 15), recordedAt: date(4, hour: 9))
        try second.record(rejection)
        let aRecords = try first.captureCloudRecords(), bRecords = try second.captureCloudRecords()
        #expect(Set(aRecords.keys).isDisjoint(with: Set(bRecords.keys)))
        let expected = aRecords.merging(bRecords) { _, new in new }

        // Capture before download, just as a joining installation does. Applying only
        // the other peer's identities must not overwrite the nonempty local store.
        try apply(bRecords, to: first)
        try apply(aRecords, to: second)
        #expect(try first.captureCloudRecords() == expected)
        #expect(try second.captureCloudRecords() == expected)
        #expect(Set(first.routines.map(\.activityKey)) == ["read", "walk"])
        #expect(first.feedback == [rejection])
        #expect(first.pendingAcceptances == [reservation])

        let restored = RoutineStore(fileURL: destination.file, defaults: destination.defaults)
        try apply(expected, to: restored)
        #expect(!restored.isLearningEnabled)
        #expect(restored.routines.count == 2 && restored.pendingAcceptances == [reservation])
        #expect(restored.suggestions(now: date(4), todos: [], calendar: calendar).isEmpty)
        #expect(try restored.captureCloudRecords() == expected)
        let reopened = RoutineStore(fileURL: destination.file, defaults: destination.defaults)
        #expect(reopened.routines == restored.routines)
        #expect(reopened.feedback == restored.feedback)
        #expect(reopened.pendingAcceptances == restored.pendingAcceptances)
    }

    @Test("Same-activity UUID collisions retain every decision, reservation and original reference")
    func sameActivityCollision() throws {
        let a = try fixture(), b = try fixture(), c = try fixture(), x = try fixture(), y = try fixture()
        defer { a.clean(); b.clean(); c.clean(); x.clean(); y.clean() }
        let parents = [
            routine("00000000-0000-0000-0000-000000000001"),
            routine("00000000-0000-0000-0000-000000000002"),
            routine("00000000-0000-0000-0000-000000000003")
        ]
        let peers = try [seed(a, routines: [parents[0]]), seed(b, routines: [parents[1]]), seed(c, routines: [parents[2]])]
        for peer in peers { peer.setLearningEnabled(true) }
        let accepted = RoutineFeedback(routineID: parents[0].id, occurrence: date(4), action: .accepted,
                                       suggestedTime: date(4, hour: 10, minute: 15), appliedTime: date(4, hour: 11),
                                       todoID: UUID(), recordedAt: date(4, hour: 8))
        let rejected = RoutineFeedback(routineID: parents[1].id, occurrence: date(4), action: .rejected,
                                       suggestedTime: date(4, hour: 10, minute: 15), recordedAt: date(4, hour: 9))
        let postponed = RoutineFeedback(routineID: parents[2].id, occurrence: date(4), action: .postponed,
                                        suggestedTime: date(4, hour: 10, minute: 15), appliedTime: date(5, hour: 18),
                                        recordedAt: date(4, hour: 10))
        try peers[0].record(accepted)
        try peers[1].record(rejected)
        try peers[2].record(postponed)
        let suggestion = try #require(peers[2].suggestions(now: date(4, hour: 11), todos: [], calendar: calendar).first)
        let pending = try peers[2].beginAcceptance(suggestion, todos: [], appliedTime: date(5, hour: 18),
                                                  todoID: UUID(), now: date(4, hour: 11), calendar: calendar)
        var union: [String: Data] = [:]
        for peer in peers { union.merge(try peer.captureCloudRecords()) { _, new in new } }
        let first = RoutineStore(fileURL: x.file, defaults: x.defaults)
        let second = RoutineStore(fileURL: y.file, defaults: y.defaults)
        try apply(union, to: first)
        try apply(union, to: second, reversed: true)
        #expect(first.routines == second.routines)
        #expect(first.routines.count == 1 && first.routines.first?.id == parents[0].id)
        #expect(Set(first.feedback.map(\.id)) == Set([accepted.id, rejected.id, postponed.id]))
        #expect(first.feedback.contains(accepted) && first.feedback.contains(rejected) && first.feedback.contains(postponed))
        #expect(first.pendingAcceptances == [pending])
        #expect(try first.captureCloudRecords() == union)
        #expect(try second.captureCloudRecords() == union)
        first.setLearningEnabled(true)
        #expect(first.suggestions(now: date(4, hour: 11), todos: [], calendar: calendar).isEmpty)
        #expect(throws: Error.self) { try first.delete(parents[0].id) }
        #expect(throws: Error.self) { try first.confirm(try #require(first.routines.first)) }

        // A saved transaction completes despite the other peer's terminal decisions.
        try first.commitAcceptance(pending.id)
        #expect(first.pendingAcceptances.isEmpty)
        #expect(first.feedback.count == 4)
        let completed = try #require(first.feedback.first { $0.id == pending.id })
        #expect(completed.routineID == parents[2].id && completed.todoID == pending.todoID)
        #expect(completed.occurrence == pending.occurrence && completed.appliedTime == pending.appliedTime)
        let reopened = RoutineStore(fileURL: x.file, defaults: x.defaults)
        #expect(reopened.feedback == first.feedback && reopened.pendingAcceptances.isEmpty)
        #expect(reopened.routines == first.routines)
    }

    @Test("Children stage across reopening, and task UUID resolves an old alias before sourceRef")
    func outOfOrderChildrenAndTaskIdentity() throws {
        let f = try fixture(); defer { f.clean() }
        let parent = routine("00000000-0000-0000-0000-000000000002")
        let alias = routine("00000000-0000-0000-0000-000000000001", updated: date(5))
        let postponed = RoutineFeedback(routineID: parent.id, occurrence: date(4), action: .postponed,
                                        suggestedTime: date(4, hour: 10), appliedTime: date(5, hour: 18), recordedAt: date(4, hour: 8))
        let pending = RoutineAcceptance(routineID: parent.id, occurrence: date(4), suggestedTime: date(5, hour: 18),
                                        appliedTime: date(5, hour: 18), todoID: UUID(), recordedAt: date(4, hour: 9))
        let store = RoutineStore(fileURL: f.file, defaults: f.defaults)
        try store.applyCloudRecord(key: key("2-acceptance", pending.id), payload: encode(pending))
        try store.applyCloudRecord(key: key("1-feedback", postponed.id), payload: encode(postponed))
        #expect(store.routines.isEmpty && store.feedback.isEmpty && store.pendingAcceptances == [pending])
        #expect(try store.captureCloudRecords().count == 2)
        let reopened = RoutineStore(fileURL: f.file, defaults: f.defaults)
        try reopened.reconcileAcceptances(todos: [], now: date(5))
        #expect(reopened.pendingAcceptances == [pending])
        let saved = Todo(id: pending.todoID, title: "Renamed after sync", startDate: date(5, hour: 19), sourceRef: "edited-reference")
        let wrongReferenceMatch = Todo(title: "Older duplicate", sourceRef: pending.sourceRef)
        try reopened.reconcileAcceptances(todos: [wrongReferenceMatch, saved], now: date(5))
        #expect(reopened.pendingAcceptances == [pending]) // Parent is still staged.
        try reopened.applyCloudRecord(key: key("0-routine", parent.id), payload: encode(parent))
        try reopened.applyCloudRecord(key: key("0-routine", alias.id), payload: encode(alias))
        #expect(reopened.routines.count == 1 && reopened.routines.first?.id == alias.id)
        #expect(reopened.feedback == [postponed])
        try reopened.reconcileAcceptances(todos: [wrongReferenceMatch, saved], now: date(5))
        #expect(reopened.pendingAcceptances.isEmpty && reopened.feedback.count == 2)
        let accepted = try #require(reopened.feedback.first { $0.id == pending.id })
        #expect(accepted.todoID == saved.id && accepted.routineID == parent.id)
        #expect(accepted.appliedTime == saved.startDate)
        #expect(!reopened.isLearningEnabled)
        #expect(saved.title == "Renamed after sync" && saved.sourceRef == "edited-reference")
        // Replaying the retired reservation cannot reopen the transaction.
        try reopened.applyCloudRecord(key: key("2-acceptance", pending.id), payload: encode(pending))
        #expect(reopened.pendingAcceptances.isEmpty)
    }

    @Test("Local crash-before-save cancels, but restored reservations wait for task sync")
    func reservationOwnership() throws {
        let a = try fixture(), b = try fixture(); defer { a.clean(); b.clean() }
        let owner = try author(a, title: "Read")
        let suggestion = try #require(owner.suggestions(now: date(4, hour: 8), todos: [], calendar: calendar).first)
        let pending = try owner.beginAcceptance(suggestion, todos: [], appliedTime: date(4, hour: 11),
                                                todoID: UUID(), now: date(4, hour: 8), calendar: calendar)
        let foreign = RoutineStore(fileURL: b.file, defaults: b.defaults)
        try apply(owner.captureCloudRecords(), to: foreign)
        try foreign.reconcileAcceptances(todos: [], now: date(4, hour: 9))
        #expect(foreign.pendingAcceptances == [pending])
        let reopenedOwner = RoutineStore(fileURL: a.file, defaults: a.defaults)
        try reopenedOwner.reconcileAcceptances(todos: [], now: date(4, hour: 9))
        #expect(reopenedOwner.pendingAcceptances.isEmpty && reopenedOwner.feedback.isEmpty)
        try reopenedOwner.applyCloudRecord(key: key("2-acceptance", pending.id), payload: encode(pending))
        #expect(reopenedOwner.pendingAcceptances.isEmpty)
        // A cloud deletion releases the waiting peer as well.
        try foreign.applyCloudRecord(key: key("2-acceptance", pending.id), payload: nil)
        #expect(foreign.pendingAcceptances.isEmpty)
    }

    @Test("Known aliases and children stay deleted after reopen, replay and a fresh join")
    func deletionAndRejoin() throws {
        let a = try fixture(), b = try fixture(); defer { a.clean(); b.clean() }
        let first = routine("00000000-0000-0000-0000-000000000001")
        let second = routine("00000000-0000-0000-0000-000000000002")
        let feedback = RoutineFeedback(routineID: second.id, occurrence: date(4), action: .rejected,
                                       suggestedTime: date(4, hour: 10), recordedAt: date(4, hour: 8))
        let store = try seed(a, routines: [first])
        try store.applyCloudRecord(key: key("0-routine", second.id), payload: encode(second))
        try store.applyCloudRecord(key: key("1-feedback", feedback.id), payload: encode(feedback))
        let stale = try store.captureCloudRecords()
        try store.delete(first.id)
        #expect(store.routines.isEmpty && store.feedback.isEmpty)
        #expect(try store.captureCloudRecords().isEmpty)
        let reopened = RoutineStore(fileURL: a.file, defaults: a.defaults)
        try apply(stale, to: reopened, reversed: true)
        #expect(reopened.routines.isEmpty && reopened.feedback.isEmpty)
        #expect(try reopened.captureCloudRecords().isEmpty)

        let joining = RoutineStore(fileURL: b.file, defaults: b.defaults)
        // Engine tombstones can arrive before any local identity is known.
        for key in stale.keys.sorted() { try joining.applyCloudRecord(key: key, payload: nil) }
        try apply(stale, to: joining)
        #expect(joining.routines.isEmpty && joining.feedback.isEmpty)
        let late = RoutineFeedback(routineID: second.id, occurrence: date(5), action: .rejected,
                                   suggestedTime: date(5, hour: 10), recordedAt: date(5, hour: 8))
        try joining.applyCloudRecord(key: key("1-feedback", late.id), payload: encode(late))
        #expect(try joining.captureCloudRecords().isEmpty)
        // Explicit relearning is a fresh identity, not resurrection of a retired UUID.
        let fresh = routine("00000000-0000-0000-0000-000000000003")
        try joining.applyCloudRecord(key: key("0-routine", fresh.id), payload: encode(fresh))
        #expect(joining.routines == [fresh])
    }

    @Test("Remote routine deletion retains an in-flight journal without resurrecting the parent")
    func deletionDuringAcceptance() throws {
        let f = try fixture(); defer { f.clean() }
        let store = try author(f, title: "Read")
        let suggestion = try #require(store.suggestions(now: date(4, hour: 8), todos: [], calendar: calendar).first)
        let pending = try store.beginAcceptance(suggestion, todos: [], appliedTime: date(4, hour: 11),
                                                todoID: UUID(), now: date(4, hour: 8), calendar: calendar)
        try store.applyCloudRecord(key: key("0-routine", suggestion.routineID), payload: nil)
        #expect(store.routines.isEmpty && store.pendingAcceptances == [pending])
        let reopened = RoutineStore(fileURL: f.file, defaults: f.defaults)
        let saved = Todo(id: pending.todoID, title: "Saved task", startDate: pending.appliedTime)
        try reopened.reconcileAcceptances(todos: [saved], now: date(4, hour: 12))
        #expect(reopened.routines.isEmpty && reopened.feedback.isEmpty && reopened.pendingAcceptances.isEmpty)
        #expect(saved.id == pending.todoID && saved.title == "Saved task")
        #expect(try reopened.captureCloudRecords().isEmpty)
    }

    @Test("Record order, stable IDs and all model fields survive a legacy migration")
    func originalFormatMigrationAndRoundTrip() throws {
        let f = try fixture(), destination = try fixture(); defer { f.clean(); destination.clean() }
        let parent = routine("00000000-0000-0000-0000-000000000010")
        let accepted = RoutineFeedback(routineID: parent.id, occurrence: date(2), action: .accepted,
                                       suggestedTime: date(2, hour: 10), appliedTime: date(2, hour: 11),
                                       todoID: UUID(), recordedAt: date(2, hour: 8))
        let pending = RoutineAcceptance(routineID: parent.id, occurrence: date(4), suggestedTime: date(4, hour: 10),
                                        appliedTime: date(4, hour: 11), todoID: UUID(), recordedAt: date(4, hour: 8))
        let store = try seed(f, routines: [parent], feedback: [accepted], pending: [pending])
        let original = try Data(contentsOf: f.file)
        let records = try store.captureCloudRecords()
        #expect(try Data(contentsOf: f.file) == original) // Capture never mutates or rewrites migration input.
        let sorted = records.keys.sorted()
        #expect(sorted == [key("0-routine", parent.id), key("1-feedback", accepted.id), key("2-acceptance", pending.id)])
        #expect(try JSONDecoder().decode(LearnedRoutine.self, from: #require(records[sorted[0]])) == parent)
        #expect(try JSONDecoder().decode(RoutineFeedback.self, from: #require(records[sorted[1]])) == accepted)
        #expect(try JSONDecoder().decode(RoutineAcceptance.self, from: #require(records[sorted[2]])) == pending)
        let restored = RoutineStore(fileURL: destination.file, defaults: destination.defaults)
        try apply(records, to: restored, reversed: true)
        #expect(try restored.captureCloudRecords() == records)
        try store.cancelAcceptance(pending.id) // First write adds metadata inside the same protected snapshot.
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        #expect(json["version"] as? Int == 1 && json["cloud"] != nil)
        #expect(json["routines"] != nil && json["feedback"] != nil && json["pendingAcceptances"] != nil)
        let reopened = RoutineStore(fileURL: f.file, defaults: f.defaults)
        #expect(reopened.routines == store.routines && reopened.feedback == store.feedback)
        #expect(reopened.pendingAcceptances.isEmpty)
    }

    @Test("Failed writes leave both the live cache and the protected snapshot unchanged")
    func atomicWriteFailure() throws {
        let f = try fixture(); defer { f.clean() }
        let initial = routine("00000000-0000-0000-0000-000000000001")
        _ = try seed(f, routines: [initial])
        var fail = false
        let store = RoutineStore(fileURL: f.file, defaults: f.defaults) { data, url in
            if fail { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        }
        let before = try Data(contentsOf: f.file)
        let beforeRecords = try store.captureCloudRecords()
        let incoming = routine("00000000-0000-0000-0000-000000000002", activity: "walk")
        fail = true
        #expect(throws: Error.self) { try store.applyCloudRecord(key: key("0-routine", incoming.id), payload: encode(incoming)) }
        #expect(store.routines == [initial] && store.feedback.isEmpty && store.pendingAcceptances.isEmpty)
        #expect(try store.captureCloudRecords() == beforeRecords)
        #expect(try Data(contentsOf: f.file) == before)
        #expect(throws: Error.self) { try store.applyCloudRecord(key: key("0-routine", initial.id), payload: nil) }
        #expect(store.routines == [initial])
        fail = false
        try store.applyCloudRecord(key: key("0-routine", incoming.id), payload: encode(incoming))
        #expect(store.routines.count == 2 && store.errorMessage == nil)
        let reopened = RoutineStore(fileURL: f.file, defaults: f.defaults)
        #expect(reopened.routines == store.routines)
    }

    @Test("Unreadable stores and malformed records fail closed without an empty upload")
    func failClosedAndValidation() throws {
        let f = try fixture(), healthy = try fixture(); defer { f.clean(); healthy.clean() }
        let broken = Data("unreadable routine journal".utf8)
        try broken.write(to: f.file, options: .atomic)
        let corrupt = RoutineStore(fileURL: f.file, defaults: f.defaults)
        let parent = routine("00000000-0000-0000-0000-000000000001")
        #expect(throws: Error.self) { try corrupt.captureCloudRecords() }
        #expect(throws: Error.self) { try corrupt.applyCloudRecord(key: key("0-routine", parent.id), payload: encode(parent)) }
        #expect(throws: Error.self) { try corrupt.applyCloudRecord(key: key("0-routine", parent.id), payload: nil) }
        #expect(try Data(contentsOf: f.file) == broken)
        #expect(corrupt.errorMessage != nil && !corrupt.isLearningEnabled)
        try corrupt.deleteAll() // Explicit privacy deletion is the existing recovery operation.
        #expect(try corrupt.captureCloudRecords().isEmpty)

        let store = RoutineStore(fileURL: healthy.file, defaults: healthy.defaults)
        #expect(RoutineStore.isCloudRecordKey(key("0-routine", parent.id)))
        #expect(RoutineStore.isCloudRecordKey("routine/unknown/invalid")) // Route malformed namespace members to validation.
        #expect(!RoutineStore.isCloudRecordKey("file/LocalRoutines/routines.json"))
        for invalid in ["routine/unknown/invalid", "routine/0-routine/invalid", "routine/0-routine/\(parent.id)/extra", "model/routine/id"] {
            #expect(throws: Error.self) { try store.applyCloudRecord(key: invalid, payload: encode(parent)) }
        }
        #expect(throws: Error.self) { try store.applyCloudRecord(key: key("0-routine", UUID()), payload: encode(parent)) }
        var invalidParent = parent
        invalidParent.periodDays = 0
        #expect(throws: Error.self) { try store.applyCloudRecord(key: key("0-routine", parent.id), payload: encode(invalidParent)) }
        let invalidFeedback = RoutineFeedback(routineID: parent.id, occurrence: date(4), action: .accepted,
                                              suggestedTime: date(4, hour: 10))
        #expect(throws: Error.self) { try store.applyCloudRecord(key: key("1-feedback", invalidFeedback.id), payload: encode(invalidFeedback)) }
        #expect(store.routines.isEmpty && store.feedback.isEmpty && store.pendingAcceptances.isEmpty)
        #expect(try store.captureCloudRecords().isEmpty)
    }

    @Test("Alias decisions affect the canonical suggestion without rewriting their payloads",
          arguments: [RoutineFeedback.Action.accepted, .rejected, .postponed])
    func aliasDecision(action: RoutineFeedback.Action) throws {
        let f = try fixture(); defer { f.clean() }
        let canonical = routine("00000000-0000-0000-0000-000000000001")
        var original = routine("00000000-0000-0000-0000-000000000002")
        original.title = "Peer wording"
        original.preferredMinute = 17
        let store = RoutineStore(fileURL: f.file, defaults: f.defaults)
        try store.applyCloudRecord(key: key("0-routine", original.id), payload: encode(original))
        try store.applyCloudRecord(key: key("0-routine", canonical.id), payload: encode(canonical))
        var expected = original // Same timestamp: canonical JSON bytes break the field-selection tie.
        expected.id = canonical.id
        #expect(store.routines == [expected])
        let entry = RoutineFeedback(routineID: original.id, occurrence: date(4), action: action,
                                    suggestedTime: date(4, hour: 10),
                                    appliedTime: action == .rejected ? nil : date(5, hour: 18),
                                    todoID: action == .accepted ? UUID() : nil, recordedAt: date(4, hour: 8))
        try store.applyCloudRecord(key: key("1-feedback", entry.id), payload: encode(entry))
        store.setLearningEnabled(true)
        let suggestions = store.suggestions(now: date(4, hour: 9), todos: [], calendar: calendar)
        if action == .postponed {
            let suggestion = try #require(suggestions.first)
            #expect(suggestion.routineID == canonical.id && suggestion.occurrence == entry.occurrence)
            #expect(suggestion.preferredStart == entry.appliedTime)
        } else {
            #expect(suggestions.isEmpty)
        }
        let records = try store.captureCloudRecords()
        #expect(records[key("0-routine", original.id)] == (try encode(original)))
        #expect(records[key("0-routine", canonical.id)] == (try encode(canonical)))
        #expect(records[key("1-feedback", entry.id)] == (try encode(entry)))
    }

    @Test("Accepted proof retires reservations in either arrival order, including legacy feedback IDs",
          arguments: [true, false])
    func acceptedProofBeforeReservation(shareReservationID: Bool) throws {
        let a = try fixture(), b = try fixture(); defer { a.clean(); b.clean() }
        let parent = routine("00000000-0000-0000-0000-000000000001")
        let pending = RoutineAcceptance(routineID: parent.id, occurrence: date(4), suggestedTime: date(4, hour: 10),
                                        appliedTime: date(4, hour: 11), todoID: UUID(), recordedAt: date(4, hour: 8))
        let accepted = RoutineFeedback(id: shareReservationID ? pending.id : UUID(), routineID: parent.id,
                                       occurrence: pending.occurrence, action: .accepted,
                                       suggestedTime: pending.suggestedTime, appliedTime: pending.appliedTime,
                                       todoID: pending.todoID, recordedAt: pending.recordedAt)
        for (fixture, feedbackFirst) in [(a, true), (b, false)] {
            let store = RoutineStore(fileURL: fixture.file, defaults: fixture.defaults)
            if feedbackFirst {
                try store.applyCloudRecord(key: key("1-feedback", accepted.id), payload: encode(accepted))
                try store.applyCloudRecord(key: key("2-acceptance", pending.id), payload: encode(pending))
            } else {
                try store.applyCloudRecord(key: key("2-acceptance", pending.id), payload: encode(pending))
                try store.applyCloudRecord(key: key("1-feedback", accepted.id), payload: encode(accepted))
            }
            try store.applyCloudRecord(key: key("0-routine", parent.id), payload: encode(parent))
            #expect(store.feedback == [accepted] && store.pendingAcceptances.isEmpty)
            let reopened = RoutineStore(fileURL: fixture.file, defaults: fixture.defaults)
            try reopened.applyCloudRecord(key: key("2-acceptance", pending.id), payload: encode(pending))
            #expect(reopened.pendingAcceptances.isEmpty && reopened.feedback == [accepted])
        }
    }

    @Test("Imported candidates are not pruned by an incomplete local evidence set")
    func importedCandidateRetention() throws {
        let f = try fixture(); defer { f.clean() }
        var candidate = routine("00000000-0000-0000-0000-000000000001")
        candidate.isConfirmed = false
        candidate.hasManualOverrides = false
        candidate.isScheduleManuallySpecified = false
        let store = RoutineStore(fileURL: f.file, defaults: f.defaults)
        try store.applyCloudRecord(key: key("0-routine", candidate.id), payload: encode(candidate))
        #expect(!store.isLearningEnabled && store.routines == [candidate])
        store.setLearningEnabled(true)
        try store.refresh(todos: [], now: date(5), calendar: calendar)
        #expect(store.routines == [candidate] && store.suggestions(now: date(5), todos: [], calendar: calendar).isEmpty)
        let reopened = RoutineStore(fileURL: f.file, defaults: f.defaults)
        try reopened.refresh(todos: [], now: date(6), calendar: calendar)
        #expect(reopened.routines == [candidate])
    }

    @Test("A cloud timezone edit cannot invalidate an already-reserved task save")
    func timezoneChangeDuringAcceptance() throws {
        let f = try fixture(); defer { f.clean() }
        let original = routine("00000000-0000-0000-0000-000000000001")
        let store = try seed(f, routines: [original])
        store.setLearningEnabled(true)
        let suggestion = try #require(store.suggestions(now: date(4, hour: 8), todos: [], calendar: calendar).first)
        let pending = try store.beginAcceptance(suggestion, todos: [], appliedTime: date(4, hour: 11),
                                                todoID: UUID(), now: date(4, hour: 8), calendar: calendar)
        var edited = original
        edited.timeZoneIdentifier = "America/Los_Angeles"
        edited.updatedAt = date(4, hour: 9)
        try store.applyCloudRecord(key: key("0-routine", edited.id), payload: encode(edited))
        try store.commitAcceptance(pending.id)
        #expect(store.pendingAcceptances.isEmpty)
        let accepted = try #require(store.feedback.first)
        #expect(accepted.id == pending.id && accepted.occurrence == pending.occurrence)
        #expect(accepted.todoID == pending.todoID && accepted.appliedTime == pending.appliedTime)
        #expect(store.routines.first?.timeZoneIdentifier == edited.timeZoneIdentifier)
    }

    @Test("New canonical decisions use the winning alias schedule's timezone",
          arguments: [RoutineFeedback.Action.rejected, .postponed])
    func canonicalDecisionUsesProjectedTimezone(action: RoutineFeedback.Action) throws {
        let f = try fixture(); defer { f.clean() }
        let canonical = routine("00000000-0000-0000-0000-000000000001")
        var newerAlias = routine("00000000-0000-0000-0000-000000000002", updated: date(3, hour: 1))
        newerAlias.timeZoneIdentifier = "America/Los_Angeles"
        let store = try seed(f, routines: [canonical])
        try store.applyCloudRecord(key: key("0-routine", newerAlias.id), payload: encode(newerAlias))
        store.setLearningEnabled(true)
        let now = date(4, hour: 9)
        let suggestion = try #require(store.suggestions(now: now, todos: [], calendar: calendar).first)
        #expect(suggestion.routineID == canonical.id && suggestion.occurrence == date(4, hour: 8))
        let applied = suggestion.preferredStart.addingTimeInterval(24 * 3600)
        let entry = RoutineFeedback(routineID: suggestion.routineID, occurrence: suggestion.occurrence,
                                    action: action, suggestedTime: suggestion.preferredStart,
                                    appliedTime: action == .postponed ? applied : nil, recordedAt: now)
        try store.record(entry)
        #expect(store.feedback == [entry])
        if action == .postponed {
            let next = try #require(store.suggestions(now: now, todos: [], calendar: calendar).first)
            #expect(next.occurrence == suggestion.occurrence && next.preferredStart == applied)
        } else {
            #expect(store.suggestions(now: now, todos: [], calendar: calendar).isEmpty)
        }
    }

    @Test("A postponed occurrence keeps its anchor after a winning alias changes timezone",
          arguments: [RoutineFeedback.Action.rejected, .postponed])
    func postponedAnchorSurvivesProjectedTimezoneChange(action: RoutineFeedback.Action) throws {
        let f = try fixture(); defer { f.clean() }
        let canonical = routine("00000000-0000-0000-0000-000000000001")
        let store = try seed(f, routines: [canonical])
        store.setLearningEnabled(true)
        let original = try #require(store.suggestions(now: date(4, hour: 8), todos: [], calendar: calendar).first)
        let postponed = RoutineFeedback(routineID: canonical.id, occurrence: original.occurrence,
                                        action: .postponed, suggestedTime: original.preferredStart,
                                        appliedTime: date(5, hour: 18), recordedAt: date(4, hour: 8))
        try store.record(postponed)
        var alias = routine("00000000-0000-0000-0000-000000000002", updated: date(4, hour: 9))
        alias.timeZoneIdentifier = "America/Los_Angeles"
        try store.applyCloudRecord(key: key("0-routine", alias.id), payload: encode(alias))
        #expect(store.routines.first?.timeZoneIdentifier == alias.timeZoneIdentifier)
        let suggestion = try #require(store.suggestions(now: date(4, hour: 10), todos: [], calendar: calendar).first)
        #expect(suggestion.occurrence == original.occurrence && suggestion.id == original.id)
        let entry = RoutineFeedback(routineID: suggestion.routineID, occurrence: suggestion.occurrence,
                                    action: action, suggestedTime: suggestion.preferredStart,
                                    appliedTime: action == .postponed ? date(6, hour: 18) : nil,
                                    recordedAt: date(4, hour: 10))
        try store.record(entry)
        #expect(store.feedback.contains(postponed) && store.feedback.contains(entry))
        if action == .postponed {
            let next = try #require(store.suggestions(now: date(4, hour: 11), todos: [], calendar: calendar).first)
            #expect(next.id == original.id && next.preferredStart == entry.appliedTime)
        }
    }
}
