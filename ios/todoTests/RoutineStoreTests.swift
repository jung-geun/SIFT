import Foundation
import Testing
@testable import todo

@Suite("Protected local routine decisions", .serialized)
@MainActor
struct RoutineStoreTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ day: Int, hour: Int = 10, minute: Int = 15) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute))!
    }
    private func rows(_ days: [Int] = [1, 2, 3]) -> [Todo] {
        days.map { day in
            let task = Todo(title: "Read")
            task.createdAt = date(day).addingTimeInterval(-3600)
            task.isCompleted = true
            task.completedAt = date(day)
            return task
        }
    }
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
    private func fixture() -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routine-tests-\(UUID())")
        let suite = "routine-tests-\(UUID())"
        return Fixture(directory: directory, file: directory.appendingPathComponent("routines.json"),
                       defaults: UserDefaults(suiteName: suite)!, suite: suite)
    }
    private func prepared(_ fixture: Fixture) throws -> RoutineStore {
        let store = RoutineStore(fileURL: fixture.file, defaults: fixture.defaults)
        store.setLearningEnabled(true)
        try store.refresh(todos: rows(), now: date(4, hour: 8), calendar: calendar)
        try store.confirm(try #require(store.routines.first))
        return store
    }

    @Test("Opt-in is off by default and disabling prevents learning and suggestions")
    func consentAndDeletion() throws {
        let f = fixture(); defer { f.clean() }
        let store = RoutineStore(fileURL: f.file, defaults: f.defaults)
        #expect(!store.isLearningEnabled)
        #expect(throws: Error.self) { try store.refresh(todos: rows(), now: date(4), calendar: calendar) }
        #expect(store.routines.isEmpty)
        store.setLearningEnabled(true)
        try store.refresh(todos: rows(), now: date(4, hour: 8), calendar: calendar)
        #expect(store.suggestions(now: date(4, hour: 8), todos: [], calendar: calendar).isEmpty)
        try store.confirm(try #require(store.routines.first))
        #expect(store.suggestions(now: date(4, hour: 8), todos: [], calendar: calendar).count == 1)
        store.setLearningEnabled(false)
        #expect(store.suggestions(now: date(4, hour: 8), todos: [], calendar: calendar).isEmpty)
        #expect(throws: Error.self) { try store.refresh(todos: rows([1, 2, 3, 4]), now: date(5), calendar: calendar) }
        try store.deleteAll()
        let reopened = RoutineStore(fileURL: f.file, defaults: f.defaults)
        #expect(reopened.routines.isEmpty && reopened.feedback.isEmpty && reopened.pendingAcceptances.isEmpty)
        reopened.setLearningEnabled(true)
        #expect(reopened.routines.isEmpty) // Enabling is not hidden analysis.
    }

    @Test("Explicit confirmation edits survive refresh and disk reopen without fabricating evidence")
    func manualEditsPersist() throws {
        let f = fixture(); defer { f.clean() }
        let store = try prepared(f)
        var edited = try #require(store.routines.first)
        let id = edited.id
        edited.title = "Read a book"
        edited.periodDays = 7
        edited.preferredHour = 19
        edited.preferredMinute = 45
        edited.estimatedDurationMinutes = 50
        edited.nextOccurrence = date(8, hour: 19, minute: 45)
        edited.sampleCount = 999 // Confirmation may edit scheduling, never learned evidence.
        try store.confirm(edited)
        #expect(store.routines.first?.sampleCount == 3)
        try store.refresh(todos: rows([1, 2, 3, 4]), now: date(5), calendar: calendar)
        let reopened = RoutineStore(fileURL: f.file, defaults: f.defaults)
        let saved = try #require(reopened.routines.first)
        #expect(saved.id == id && saved.isConfirmed)
        #expect(saved.title == "Read a book" && saved.periodDays == 7)
        #expect(saved.preferredHour == 19 && saved.preferredMinute == 45)
        #expect(saved.estimatedDurationMinutes == 50 && saved.nextOccurrence == date(8, hour: 19, minute: 45))
        #expect(saved.sampleCount == 4)
        let suggestion = try #require(reopened.suggestions(now: date(5), todos: [], calendar: calendar).first)
        #expect(suggestion.occurrence == calendar.startOfDay(for: date(8)))
        var traveling = calendar; traveling.timeZone = TimeZone(identifier: "Asia/Seoul")!
        #expect(reopened.suggestions(now: date(5), todos: [], calendar: traveling).first?.id == suggestion.id)
        try reopened.delete(id)
        #expect(RoutineStore(fileURL: f.file, defaults: f.defaults).routines.isEmpty)
    }

    @Test("Irregular evidence remains non-actionable until the user explicitly edits its schedule")
    func lowConfidenceGuard() throws {
        let f = fixture(); defer { f.clean() }
        let store = RoutineStore(fileURL: f.file, defaults: f.defaults)
        store.setLearningEnabled(true)
        try store.refresh(todos: rows([1, 2, 16]), now: date(17), calendar: calendar)
        var candidate = try #require(store.routines.first)
        #expect(throws: Error.self) { try store.confirm(candidate) }
        #expect(store.routines.first?.isConfirmed == false)
        #expect(store.suggestions(now: date(17), todos: [], calendar: calendar).isEmpty)
        candidate.periodDays = 7
        try store.confirm(candidate)
        #expect(store.suggestions(now: date(17), todos: [], calendar: calendar).count == 1)
    }

    @Test("Existing matching tasks, completed same occurrence and source refs suppress duplicate suggestions")
    func matchingTasks() throws {
        let f = fixture(); defer { f.clean() }
        let store = try prepared(f)
        let now = date(4, hour: 8)
        let suggestion = try #require(store.suggestions(now: now, todos: [], calendar: calendar).first)
        let unscheduled = Todo(title: " READ ")
        #expect(store.suggestions(now: now, todos: [unscheduled], calendar: calendar).isEmpty)
        let scheduled = Todo(title: "Read", startDate: date(4), dueDate: date(4, hour: 11))
        #expect(store.suggestions(now: now, todos: [scheduled], calendar: calendar).isEmpty)
        let otherDay = Todo(title: "Read", startDate: date(5), dueDate: date(5, hour: 11))
        #expect(store.suggestions(now: now, todos: [otherDay], calendar: calendar).count == 1)
        let renamed = Todo(title: "Renamed", sourceRef: suggestion.sourceRef)
        renamed.isCompleted = true
        #expect(store.suggestions(now: now, todos: [renamed], calendar: calendar).isEmpty)
        let done = Todo(title: "Read"); done.isCompleted = true; done.completedAt = date(4, hour: 7)
        #expect(store.suggestions(now: now, todos: [done], calendar: calendar).isEmpty)
    }

    @Test("Postponement retains occurrence identity, acceptance changes timing and cannot be repeated")
    func feedbackTimingAndIdentity() throws {
        let f = fixture(); defer { f.clean() }
        let store = try prepared(f)
        let now = date(4, hour: 8)
        let initial = try #require(store.suggestions(now: now, todos: [], calendar: calendar).first)
        try store.record(RoutineFeedback(routineID: initial.routineID, occurrence: initial.occurrence,
                                         action: .postponed, suggestedTime: initial.preferredStart,
                                         appliedTime: date(5, hour: 18), recordedAt: now))
        let postponed = try #require(store.suggestions(now: date(5, hour: 8), todos: [], calendar: calendar).first)
        #expect(postponed.id == initial.id && postponed.occurrence == initial.occurrence)
        #expect(postponed.preferredStart == date(5, hour: 18))
        let accepted = RoutineFeedback(routineID: initial.routineID, occurrence: initial.occurrence,
                                       action: .accepted, suggestedTime: postponed.preferredStart,
                                       appliedTime: date(5, hour: 19), todoID: UUID(), recordedAt: date(5, hour: 8))
        try store.record(accepted)
        #expect(throws: Error.self) { try store.record(accepted) }
        #expect(store.suggestions(now: now, todos: [], calendar: calendar).isEmpty)
        #expect(store.suggestions(now: date(6, hour: 8), todos: [], calendar: calendar).first?.preferredStart == date(6, hour: 19))
    }

    @Test("A manual checkoff on the postponed day prevents recreating that occurrence", arguments: [5, 6])
    func completedPostponement(queryDay: Int) throws {
        let f = fixture(); defer { f.clean() }
        let store = try prepared(f)
        let now = date(4, hour: 8)
        let suggestion = try #require(store.suggestions(now: now, todos: [], calendar: calendar).first)
        try store.record(RoutineFeedback(routineID: suggestion.routineID, occurrence: suggestion.occurrence,
                                         action: .postponed, suggestedTime: suggestion.preferredStart,
                                         appliedTime: date(5, hour: 18), recordedAt: now))
        let completed = Todo(title: "Read")
        completed.isCompleted = true
        completed.completedAt = date(5, hour: 18)
        #expect(store.suggestions(now: date(queryDay, hour: 19), todos: [completed], calendar: calendar).isEmpty)
    }

    @Test("Three distinct rejected occurrences conservatively suppress future predictions until reconfirmation")
    func rejectionLearning() throws {
        let f = fixture(); defer { f.clean() }
        let store = try prepared(f)
        for day in 4...6 {
            let now = date(day, hour: 8)
            let suggestion = try #require(store.suggestions(now: now, todos: [], calendar: calendar).first)
            try store.record(RoutineFeedback(routineID: suggestion.routineID, occurrence: suggestion.occurrence,
                                             action: .rejected, suggestedTime: suggestion.preferredStart, recordedAt: now))
            #expect(store.suggestions(now: now, todos: [], calendar: calendar).isEmpty)
        }
        #expect(store.suggestions(now: date(7, hour: 8), todos: [], calendar: calendar).isEmpty)
        #expect(store.routines.first?.isSuppressed == true)
        try store.confirm(try #require(store.routines.first))
        #expect(store.suggestions(now: date(7, hour: 8), todos: [], calendar: calendar).count == 1)
        try store.deleteAll()
        #expect(RoutineStore(fileURL: f.file, defaults: f.defaults).feedback.isEmpty)
    }

    @Test("Durable acceptance reservation repairs crashes before and after SwiftData save")
    func acceptanceCrashRecovery() throws {
        let f = fixture(); defer { f.clean() }
        let store = try prepared(f)
        let now = date(4, hour: 8)
        let suggestion = try #require(store.suggestions(now: now, todos: [], calendar: calendar).first)
        let id = UUID()
        let reservation = try store.beginAcceptance(suggestion, todos: [], appliedTime: date(4), todoID: id, now: now, calendar: calendar)
        #expect(reservation.sourceRef == suggestion.sourceRef)
        #expect(store.suggestions(now: now, todos: [], calendar: calendar).isEmpty)
        #expect(throws: Error.self) {
            try store.beginAcceptance(suggestion, todos: [], appliedTime: date(4), todoID: UUID(), now: now, calendar: calendar)
        }
        let beforeSave = RoutineStore(fileURL: f.file, defaults: f.defaults)
        #expect(beforeSave.pendingAcceptances.count == 1)
        try beforeSave.reconcileAcceptances(todos: [], now: now)
        #expect(beforeSave.pendingAcceptances.isEmpty && beforeSave.feedback.isEmpty)
        let retry = try #require(beforeSave.suggestions(now: now, todos: [], calendar: calendar).first)
        _ = try beforeSave.beginAcceptance(retry, todos: [], appliedTime: date(4), todoID: id, now: now, calendar: calendar)
        let task = Todo(id: id, title: retry.title, startDate: date(4), sourceRef: retry.sourceRef)
        let afterSave = RoutineStore(fileURL: f.file, defaults: f.defaults)
        try afterSave.reconcileAcceptances(todos: [task], now: now)
        #expect(afterSave.pendingAcceptances.isEmpty)
        #expect(afterSave.feedback.first?.action == .accepted && afterSave.feedback.first?.todoID == id)
        #expect(afterSave.suggestions(now: now, todos: [], calendar: calendar).isEmpty)
        #expect(RoutineStore(fileURL: f.file, defaults: f.defaults).feedback.count == 1)
    }

    @Test("Failed writes never publish successful learning, feedback or acceptance; failed commit keeps reservation")
    func failedWritesRollback() throws {
        let f = fixture(); defer { f.clean() }
        var fail = false
        let store = RoutineStore(fileURL: f.file, defaults: f.defaults, writer: { data, url in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        })
        store.setLearningEnabled(true)
        fail = true
        #expect(throws: Error.self) { try store.refresh(todos: rows(), now: date(4, hour: 8), calendar: calendar) }
        #expect(store.routines.isEmpty && store.errorMessage != nil)
        fail = false
        try store.refresh(todos: rows(), now: date(4, hour: 8), calendar: calendar)
        let candidate = try #require(store.routines.first)
        fail = true
        #expect(throws: Error.self) { try store.confirm(candidate) }
        #expect(store.routines.first?.isConfirmed == false)
        fail = false
        try store.confirm(candidate)
        let suggestion = try #require(store.suggestions(now: date(4, hour: 8), todos: [], calendar: calendar).first)
        fail = true
        #expect(throws: Error.self) {
            try store.beginAcceptance(suggestion, todos: [], appliedTime: date(4), todoID: UUID(), now: date(4, hour: 8), calendar: calendar)
        }
        #expect(store.pendingAcceptances.isEmpty)
        fail = false
        let pending = try store.beginAcceptance(suggestion, todos: [], appliedTime: date(4), todoID: UUID(), now: date(4, hour: 8), calendar: calendar)
        fail = true
        #expect(throws: Error.self) { try store.commitAcceptance(pending.id) }
        #expect(store.feedback.isEmpty && store.pendingAcceptances.count == 1)
        #expect(RoutineStore(fileURL: f.file, defaults: f.defaults).pendingAcceptances.count == 1)
        fail = false
        store.setLearningEnabled(false)
        try store.commitAcceptance(pending.id) // Finishes already-started transaction while disabled.
        #expect(store.pendingAcceptances.isEmpty && store.feedback.count == 1)
    }

    @Test("Save failure cancellation releases the occurrence; corrupted files fail closed until explicit deletion")
    func cancelAndCorruption() throws {
        let f = fixture(); defer { f.clean() }
        let store = try prepared(f)
        let now = date(4, hour: 8)
        let suggestion = try #require(store.suggestions(now: now, todos: [], calendar: calendar).first)
        let pending = try store.beginAcceptance(suggestion, todos: [], appliedTime: date(4), todoID: UUID(), now: now, calendar: calendar)
        try store.cancelAcceptance(pending.id)
        #expect(store.feedback.isEmpty && store.suggestions(now: now, todos: [], calendar: calendar).count == 1)
        try Data("not json".utf8).write(to: f.file, options: .atomic)
        let corrupted = RoutineStore(fileURL: f.file, defaults: f.defaults)
        #expect(corrupted.errorMessage != nil)
        #expect(throws: Error.self) { try corrupted.refresh(todos: rows(), now: now, calendar: calendar) }
        #expect(try Data(contentsOf: f.file) == Data("not json".utf8))
        try corrupted.deleteAll()
        #expect(RoutineStore(fileURL: f.file, defaults: f.defaults).errorMessage == nil)
    }

    @Test("Production persistence excludes backup and applies complete file protection")
    func protectedLocalFile() throws {
        let f = fixture(); defer { f.clean() }
        _ = try prepared(f)
        let values = try f.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #if !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        let attributes = try FileManager.default.attributesOfItem(atPath: f.file.path)
        #expect(attributes[.protectionKey] as? FileProtectionType == .complete)
        #endif
    }
}
