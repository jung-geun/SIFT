import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Protected health workflow", .serialized)
@MainActor
struct HealthRoutineStoreTests {
    @MainActor private final class Reader: HealthHistoryReading {
        var rows: [HealthHistoryRecord] = []
        var requestCount = 0
        var queryCount = 0
        var permissionGate: CheckedContinuation<Void, Never>?
        var holdPermission = false
        var queryGate: CheckedContinuation<Void, Never>?
        var holdQuery = false
        var failure: Error?
        func unavailableReason(for category: HealthHistoryCategory) -> String? { nil }
        func requestRead(for category: HealthHistoryCategory) async throws {
            requestCount += 1
            if holdPermission { await withCheckedContinuation { permissionGate = $0 } }
            if let failure { throw failure }
        }
        func history(for category: HealthHistoryCategory, from: Date, through: Date) async throws -> [HealthHistoryRecord] {
            queryCount += 1
            if holdQuery { await withCheckedContinuation { queryGate = $0 } }
            if let failure { throw failure }
            return rows.filter { $0.category == category }
        }
    }
    private struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        var file: URL { directory.appendingPathComponent("health.json") }
        func clean() {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
    }
    private func fixture() -> Fixture {
        let suite = "HealthTests-\(UUID())"
        return Fixture(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite), defaults: UserDefaults(suiteName: suite)!, suite: suite)
    }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func day(_ day: Int, hour: Int = 8) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    private func rows() -> [HealthHistoryRecord] {
        (1...4).map { HealthHistoryRecord(id: "record-\($0)", category: .workout, kindKey: "running", title: "Running",
            startDate: day($0, hour: 9), sourceID: "test.source", sourceName: "Test Source") }
    }
    private func container() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: AppDataContainer.appSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: AppDataContainer.appSchema, configurations: [configuration])
    }
    private func prepared(_ fixture: Fixture, reader: Reader, context: ModelContext,
                          writer: ((Data, URL) throws -> Void)? = nil,
                          saveTasks: ((ModelContext) throws -> Void)? = nil,
                          clock: @escaping () -> Date = Date.init) async throws -> HealthRoutineStore {
        reader.rows = rows()
        let store = HealthRoutineStore(reader: reader, fileURL: fixture.file, defaults: fixture.defaults, writer: writer, saveTasks: saveTasks, clock: clock)
        await store.connect(.workout, context: context, now: day(5), calendar: calendar)
        #expect(store.candidates.isEmpty) // Sources are independently approved.
        try store.approveSource("test.source", category: .workout, approved: true, now: day(5), calendar: calendar)
        var candidate = try #require(store.candidates.first)
        candidate.title = "My approved run"
        try store.confirm(candidate)
        return store
    }

    @Test("No launch permission and no task creation before both explicit consents")
    func consent() async throws {
        let f = fixture(); defer { f.clean() }
        let db = try container(); let context = db.mainContext
        let reader = Reader()
        let store = HealthRoutineStore(reader: reader, fileURL: f.file, defaults: f.defaults)
        await store.refresh(context: context, now: day(5), calendar: calendar)
        #expect(reader.requestCount == 0 && reader.queryCount == 0)
        reader.rows = rows()
        await store.connect(.workout, context: context, now: day(5), calendar: calendar)
        try store.approveSource("test.source", category: .workout, approved: true, now: day(5), calendar: calendar)
        try store.setAutoCreateEnabled(true)
        #expect(try store.generate(context: context, now: day(5)) == 0)
        try store.setAutoCreateEnabled(false)
        try store.confirm(try #require(store.candidates.first))
        #expect(try store.generate(context: context, now: day(5)) == 0)
        #expect(try context.fetch(FetchDescriptor<Todo>()).isEmpty)
        #expect(reader.requestCount == 1)
    }

    @Test("Repeated refresh, completed task, deletion and disk reopen never duplicate an occurrence")
    func deduplication() async throws {
        let f = fixture(); defer { f.clean() }
        let db = try container(); let context = db.mainContext
        let reader = Reader()
        let store = try await prepared(f, reader: reader, context: context)
        try store.setAutoCreateEnabled(true)
        #expect(try store.generate(context: context, now: day(5)) == 1)
        let storageResources = try f.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(storageResources.isExcludedFromBackup == true)
        #if !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        let attributes = try FileManager.default.attributesOfItem(atPath: f.file.path)
        #expect(attributes[.protectionKey] as? String == FileProtectionType.complete.rawValue)
        #endif
        let task = try #require(context.fetch(FetchDescriptor<Todo>()).first)
        #expect(task.title == "My approved run" && task.todoSource == .manual && task.sourceRef.hasPrefix("health:"))
        #expect(task.reminderOffsets.isEmpty && !task.aiNeedsNotification && task.calendarEventID == nil)
        #expect(task.startDate == day(5, hour: 9) && task.dueDate == day(5, hour: 9))
        #expect(task.hasLocalOnlySourceContent)
        task.isCompleted = true; try context.save()
        await store.refresh(context: context, now: day(5), calendar: calendar)
        #expect(try context.fetchCount(FetchDescriptor<Todo>()) == 1)
        context.delete(task); try context.save()
        let reopened = HealthRoutineStore(reader: reader, fileURL: f.file, defaults: f.defaults)
        #expect(try reopened.generate(context: context, now: day(5)) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Todo>()) == 0)
        #expect(try reopened.generate(context: context, now: day(6)) == 1)
    }

    @Test("Medication sample UUID overlap preserves confirmation and dedup across archive byte changes")
    func medicationIdentity() async throws {
        let f = fixture(); defer { f.clean() }
        let db = try container(); let context = db.mainContext
        let reader = Reader()
        reader.rows = rows().map { row in
            var row = row; row.category = .medication; row.kindKey = "opaque-archive-first"; return row
        }
        let store = HealthRoutineStore(reader: reader, fileURL: f.file, defaults: f.defaults)
        await store.connect(.medication, context: context, now: day(5), calendar: calendar)
        try store.approveSource("test.source", category: .medication, approved: true, now: day(5), calendar: calendar)
        let original = try #require(store.candidates.first)
        try store.confirm(original); try store.setAutoCreateEnabled(true)
        #expect(try store.generate(context: context, now: day(5)) == 1)
        let task = try #require(context.fetch(FetchDescriptor<Todo>()).first)
        context.delete(task); try context.save()
        reader.rows = reader.rows.map { row in
            var row = row; row.kindKey = "opaque-archive-reencoded"; return row
        }
        let reopened = HealthRoutineStore(reader: reader, fileURL: f.file, defaults: f.defaults)
        await reopened.refresh(context: context, now: day(5), calendar: calendar)
        #expect(reopened.candidates.first?.id == original.id)
        #expect(reopened.candidates.first?.isConfirmed == true)
        #expect(try context.fetchCount(FetchDescriptor<Todo>()) == 0)
    }

    @Test("Disable and unapprove source immediately stop generation")
    func controls() async throws {
        let f = fixture(); defer { f.clean() }
        let db = try container(); let context = db.mainContext
        let reader = Reader(); let store = try await prepared(f, reader: reader, context: context)
        try store.setAutoCreateEnabled(true)
        let candidate = try #require(store.candidates.first)
        try store.setRoutineEnabled(candidate.id, enabled: false)
        #expect(try store.generate(context: context, now: day(5)) == 0)
        try store.setRoutineEnabled(candidate.id, enabled: true)
        try store.approveSource("test.source", category: .workout, approved: false, now: day(5), calendar: calendar)
        #expect(store.candidates.isEmpty)
        #expect(try store.generate(context: context, now: day(5)) == 0)
    }

    @Test("Empty or denied history is not claimed as authorized or kept actionable")
    func emptyAndDenied() async throws {
        let f = fixture(); defer { f.clean() }
        let db = try container(); let context = db.mainContext
        let reader = Reader(); let store = try await prepared(f, reader: reader, context: context)
        try store.setAutoCreateEnabled(true)
        reader.rows = []
        await store.refresh(context: context, now: day(5), calendar: calendar)
        #expect(store.records.isEmpty && store.candidates.isEmpty)
        #expect(store.states[.workout]?.readRecordCount == 0)
        reader.failure = NSError(domain: "Denied", code: 1)
        await store.refresh(context: context, now: day(5), calendar: calendar)
        #expect(store.errorMessage != nil)
        #expect(try context.fetchCount(FetchDescriptor<Todo>()) == 0)
    }

    @Test("Disconnect during read blocks late records and generated tasks")
    func disconnectDuringQuery() async throws {
        let f = fixture(); defer { f.clean() }
        let db = try container(); let context = db.mainContext
        let reader = Reader(); let store = try await prepared(f, reader: reader, context: context)
        try store.setAutoCreateEnabled(true)
        reader.holdQuery = true
        let refresh = Task { await store.refresh(context: context, now: day(5), calendar: calendar) }
        while reader.queryGate == nil { await Task.yield() }
        store.disconnect(.workout)
        reader.queryGate?.resume(); reader.queryGate = nil
        // Reader intentionally ignores cancellation; joining proves the epoch blocks late publication.
        await refresh.value
        #expect(store.records.isEmpty && store.candidates.isEmpty)
        #expect(store.states[.workout]?.isConnected == false)
        #expect(try context.fetchCount(FetchDescriptor<Todo>()) == 0)
    }

    @Test("Disconnect while the OS prompt is pending cannot connect on late completion")
    func disconnectDuringPermission() async throws {
        let f = fixture(); defer { f.clean() }
        let db = try container(); let context = db.mainContext
        let reader = Reader(); reader.rows = rows(); reader.holdPermission = true
        let store = HealthRoutineStore(reader: reader, fileURL: f.file, defaults: f.defaults)
        let connection = Task { await store.connect(.workout, context: context, now: day(5), calendar: calendar) }
        while reader.permissionGate == nil { await Task.yield() }
        store.disconnect(.workout)
        reader.permissionGate?.resume(); reader.permissionGate = nil
        await connection.value
        #expect(reader.queryCount == 0 && store.records.isEmpty)
        #expect(store.states[.workout]?.isConnected == false)
    }

    @Test("Cancellation without disconnect cannot publish or generate from a late read")
    func cancellation() async throws {
        let f = fixture(); defer { f.clean() }
        let db = try container(); let context = db.mainContext
        let reader = Reader(); let store = try await prepared(f, reader: reader, context: context)
        try store.setAutoCreateEnabled(true)
        reader.holdQuery = true
        let refresh = Task { await store.refresh(context: context, now: day(5), calendar: calendar) }
        while reader.queryGate == nil { await Task.yield() }
        store.cancelRefresh()
        reader.rows = []
        reader.queryGate?.resume(); reader.queryGate = nil
        await refresh.value
        #expect(store.records.count == 4)
        #expect(try context.fetchCount(FetchDescriptor<Todo>()) == 0)
    }

    @Test("A read crossing a scheduled minute creates only the next future occurrence")
    func slowReadDoesNotBackfill() async throws {
        let f = fixture(); defer { f.clean() }
        let db = try container(); let context = db.mainContext
        var currentTime = day(5, hour: 9).addingTimeInterval(-1)
        let reader = Reader()
        let store = try await prepared(f, reader: reader, context: context, clock: { currentTime })
        try store.setAutoCreateEnabled(true)
        reader.holdQuery = true
        let queryDate = currentTime
        let refresh = Task { await store.refresh(context: context, now: queryDate, calendar: calendar) }
        while reader.queryGate == nil { await Task.yield() }
        currentTime = day(5, hour: 9).addingTimeInterval(2)
        reader.queryGate?.resume(); reader.queryGate = nil
        await refresh.value
        let generated = try context.fetch(FetchDescriptor<Todo>())
        #expect(generated.map(\.dueDate) == [day(6, hour: 9)])
    }

    @Test("A slow reservation write cannot insert an occurrence whose time has passed")
    func slowReservationDoesNotBackfill() async throws {
        let f = fixture(); defer { f.clean() }
        let db = try container(); let context = db.mainContext
        var currentTime = day(5, hour: 9).addingTimeInterval(-1)
        var advanceDuringWrite = false
        let reader = Reader()
        let store = try await prepared(f, reader: reader, context: context, writer: { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            if advanceDuringWrite { currentTime = self.day(5, hour: 9).addingTimeInterval(2) }
        }, clock: { currentTime })
        try store.setAutoCreateEnabled(true)
        advanceDuringWrite = true
        #expect(try store.generate(context: context, now: currentTime) == 0)
        #expect(try context.fetch(FetchDescriptor<Todo>()).isEmpty)
        advanceDuringWrite = false
        #expect(try store.generate(context: context, now: currentTime) == 1)
        #expect(try context.fetch(FetchDescriptor<Todo>()).map(\.dueDate) == [day(6, hour: 9)])
    }

    @Test("Write failures fail closed across reopen; task save failures retain dedup reservations")
    func persistenceFailures() async throws {
        let f = fixture(); defer { f.clean() }
        let db = try container(); let context = db.mainContext
        let reader = Reader(); let healthy = try await prepared(f, reader: reader, context: context)
        try healthy.setAutoCreateEnabled(true)
        let failing = HealthRoutineStore(reader: reader, fileURL: f.file, defaults: f.defaults,
            writer: { _, _ in throw NSError(domain: "Write", code: 1) })
        #expect(throws: Error.self) { try failing.generate(context: context, now: day(5)) }
        #expect(!failing.autoCreateEnabled && failing.errorMessage != nil)
        let reopened = HealthRoutineStore(reader: reader, fileURL: f.file, defaults: f.defaults)
        #expect(!reopened.autoCreateEnabled)
        #expect(try reopened.generate(context: context, now: day(5)) == 0)
        // Reconnect and explicitly enable after failure; fail task commit, not the protected journal.
        let saveFail = HealthRoutineStore(reader: reader, fileURL: f.file, defaults: f.defaults,
            saveTasks: { _ in throw NSError(domain: "TaskSave", code: 1) })
        await saveFail.connect(.workout, context: context, now: day(5), calendar: calendar)
        try saveFail.setAutoCreateEnabled(true)
        #expect(throws: Error.self) { try saveFail.generate(context: context, now: day(5)) }
        #expect(try context.fetchCount(FetchDescriptor<Todo>()) == 0)
        let after = HealthRoutineStore(reader: reader, fileURL: f.file, defaults: f.defaults)
        #expect(try after.generate(context: context, now: day(5)) == 0)
    }

    @Test("History erase stops consent and preserves dedup; full reset explicitly forgets it")
    func erasure() async throws {
        let f = fixture(); defer { f.clean() }
        let db = try container(); let context = db.mainContext
        let reader = Reader(); let store = try await prepared(f, reader: reader, context: context)
        try store.setAutoCreateEnabled(true)
        #expect(try store.generate(context: context, now: day(5)) == 1)
        let task = try #require(context.fetch(FetchDescriptor<Todo>()).first)
        context.delete(task); try context.save()
        try store.eraseHistory()
        #expect(!store.autoCreateEnabled && store.records.isEmpty && store.candidates.isEmpty)
        #expect(store.hasLocalData, "Consumed occurrences must keep local erase/reset management reachable")
        await store.connect(.workout, context: context, now: day(5), calendar: calendar)
        try store.approveSource("test.source", category: .workout, approved: true, now: day(5), calendar: calendar)
        try store.confirm(try #require(store.candidates.first)); try store.setAutoCreateEnabled(true)
        #expect(try store.generate(context: context, now: day(5)) == 0)
        try store.resetAll()
        #expect(!store.hasLocalData)
        await store.connect(.workout, context: context, now: day(5), calendar: calendar)
        try store.approveSource("test.source", category: .workout, approved: true, now: day(5), calendar: calendar)
        try store.confirm(try #require(store.candidates.first)); try store.setAutoCreateEnabled(true)
        #expect(try store.generate(context: context, now: day(5)) == 1)
    }

    @Test("Unreadable protected store never overwrites dedup or creates tasks")
    func corruptStore() async throws {
        let f = fixture(); defer { f.clean() }
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: f.file)
        let db = try container(); let reader = Reader()
        let store = HealthRoutineStore(reader: reader, fileURL: f.file, defaults: f.defaults)
        #expect(store.errorMessage != nil && !store.autoCreateEnabled)
        #expect(store.hasLocalData, "An unreadable protected store still needs an explicit reset path")
        await store.connect(.workout, context: db.mainContext, now: day(5), calendar: calendar)
        #expect(reader.requestCount == 0)
        #expect(throws: Error.self) { try store.setAutoCreateEnabled(true) }
        #expect(try store.generate(context: db.mainContext, now: day(5)) == 0)
        try store.resetAll()
        #expect(store.errorMessage == nil && !store.autoCreateEnabled)
        #expect(!store.hasLocalData)
    }
}
