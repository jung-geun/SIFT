import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Todo mutation durability and health telemetry privacy", .serialized)
@MainActor
struct TodoMutationsTests {
    private func makeStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("todo-deletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeContainer(at directory: URL, allowsSave: Bool = true) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            url: directory.appendingPathComponent("store.sqlite"),
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: AppDataContainer.appSchema, configurations: [configuration])
    }

    // Separate scopes release each writer before the next container reopens the disk store.
    private func seedStore(at directory: URL, review: Bool = false, email: Bool = false) throws -> UUID {
        let container = try makeContainer(at: directory)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let todo = Todo(
            title: "Durable deletion",
            source: email ? .email : .manual,
            sourceRef: email ? "deletion-test-\(UUID().uuidString)" : ""
        )
        todo.triageStatus = review ? TodoTriage.review.rawValue : TodoTriage.todo.rawValue
        context.insert(todo)
        try context.save()
        return todo.id
    }

    private func deletePersistedTodo(at directory: URL, id: UUID) throws {
        let container = try makeContainer(at: directory)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let todo = try #require(context.fetch(FetchDescriptor<Todo>()).first { $0.id == id })
        try TodoMutations.delete(todo, in: context)
        // Deliberately no caller save, background transition, wait, or autosave.
        #expect(!context.hasChanges)
    }

    private func persistedAnalysis(in context: ModelContext) throws -> MemoryAnalysisResult {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return MemoryService.computeAnalysis(
            todos: try context.fetch(FetchDescriptor<Todo>()),
            auditEvents: try context.fetch(FetchDescriptor<TaskAuditEvent>()),
            behaviorEvents: try context.fetch(FetchDescriptor<TaskBehaviorEvent>()),
            now: Date(timeIntervalSince1970: 1_700_172_800),
            calendar: calendar,
            language: .english
        )
    }

    private func expectAnalysis(_ actual: MemoryAnalysisResult, matches baseline: MemoryAnalysisResult) {
        #expect(actual.behaviorProfile == baseline.behaviorProfile)
        #expect(actual.summary == baseline.summary)
        #expect(actual.insights == baseline.insights)
        #expect(actual.fastTags == baseline.fastTags)
        #expect(actual.overdueRate == baseline.overdueRate)
        #expect(actual.productiveHour == baseline.productiveHour)
        #expect(actual.analyzedCompletedCount == baseline.analyzedCompletedCount)
        #expect(actual.accessScopeSummary == baseline.accessScopeSummary)
    }

    /// Fixed times make recorder payload assertions independent of the wall clock.
    private func recordCreationAndEdits(of todo: Todo, in context: ModelContext) {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        todo.createdAt = instant
        TaskBehaviorRecorder.recordCreation(of: todo, actor: .user, in: context, at: instant)

        let oldDueDate = todo.dueDate
        todo.dueDate = instant.addingTimeInterval(86_400)
        TaskBehaviorRecorder.recordDueDateChange(
            of: todo, from: oldDueDate, to: todo.dueDate,
            actor: .user, in: context, at: instant.addingTimeInterval(1)
        )

        let oldManualPriority = todo.manualPriority
        todo.manualPriority = TodoPriority.critical.rawValue
        TaskBehaviorRecorder.recordManualPriorityChange(
            of: todo, from: oldManualPriority, to: todo.manualPriority,
            actor: .user, in: context, at: instant.addingTimeInterval(2)
        )

        let oldComputedPriority = todo.computedPriorityScore
        todo.computedPriorityScore = 0.75
        TaskBehaviorRecorder.recordComputedPriorityChange(
            of: todo, from: oldComputedPriority, to: todo.computedPriorityScore,
            actor: .artificialIntelligence, in: context, at: instant.addingTimeInterval(3)
        )
    }

    @Test("All six recorder paths exclude health provenance but preserve ordinary payloads", arguments: [
        ("health:workout:occurrence", ""),
        ("HEALTH:sleep:occurrence", ""),
        ("HeAlTh:medication:occurrence", ""),
        ("restored-calendar", CalendarEventOrigin.siftHealth.rawValue),
        ("", CalendarEventOrigin.siftHealth.rawValue)
    ])
    func behaviorRecorderExcludesHealth(sourceRef: String, calendarOrigin: String) throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer(at: directory)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let health = Todo(title: "Private health task", sourceRef: sourceRef)
        health.calendarEventOrigin = calendarOrigin
        // A non-prefix occurrence of health: must not suppress an ordinary task.
        let ordinary = Todo(title: "Ordinary task", sourceRef: "message-health:workout")
        #expect(health.isHealthRelated)
        #expect(!ordinary.isHealthRelated)
        context.insert(health)
        context.insert(ordinary)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)

        for task in [health, ordinary] {
            recordCreationAndEdits(of: task, in: context)
            task.isCompleted = true
            TaskBehaviorRecorder.recordCompletionChange(
                of: task, from: false, to: true,
                actor: .user, in: context, at: instant.addingTimeInterval(4)
            )
            task.isCompleted = false
            TaskBehaviorRecorder.recordCompletionChange(
                of: task, from: true, to: false,
                actor: .user, in: context, at: instant.addingTimeInterval(5)
            )
            TaskBehaviorRecorder.recordDeletion(
                of: task, actor: .user, in: context, at: instant.addingTimeInterval(6)
            )
        }
        try context.save()

        let events = try context.fetch(FetchDescriptor<TaskBehaviorEvent>(
            sortBy: [SortDescriptor(\.occurredAt)]
        ))
        #expect(!events.contains { $0.todoID == health.id })
        try #require(events.count == 7)
        #expect(events.allSatisfy { $0.todoID == ordinary.id })
        #expect(events.allSatisfy { $0.todoCreatedAt == instant && $0.sourceType == TodoSource.manual.rawValue })
        #expect(events.map(\.eventType) == [
            .created, .dueDateChanged, .priorityChanged, .priorityChanged,
            .completionChanged, .completionChanged, .deleted
        ])
        #expect(events.map(\.actor) == [
            .user, .user, .user, .artificialIntelligence, .user, .user, .user
        ])
        #expect(events.map(\.occurredAt) == (0...6).map { instant.addingTimeInterval(Double($0)) })
        #expect(events[0].afterCompletion == false)
        #expect(events[0].afterDueDate == nil)
        #expect(events[0].afterManualPriority == nil)
        #expect(events[0].afterComputedPriority == 0)
        #expect(events[1].beforeDueDate == nil)
        #expect(events[1].afterDueDate == ordinary.dueDate)
        #expect(events[2].beforeManualPriority == nil)
        #expect(events[2].afterManualPriority == TodoPriority.critical.rawValue)
        #expect(events[2].afterComputedPriority == nil)
        #expect(events[3].beforeComputedPriority == 0)
        #expect(events[3].afterComputedPriority == 0.75)
        #expect(events[3].afterManualPriority == nil)
        #expect(events[4].beforeCompletion == false && events[4].afterCompletion == true)
        #expect(events[5].beforeCompletion == true && events[5].afterCompletion == false)
        #expect(events[6].beforeCompletion == false)
        #expect(events[6].beforeDueDate == ordinary.dueDate)
        #expect(events[6].beforeManualPriority == ordinary.manualPriority)
        #expect(events[6].beforeComputedPriority == ordinary.computedPriorityScore)
        #expect(try context.fetch(FetchDescriptor<TaskAuditEvent>()).isEmpty)
    }

    @Test("Real health completion, undo and durable deletion leave no telemetry", arguments: [
        ("health:workout:occurrence", ""),
        ("HEALTH:sleep:occurrence", ""),
        ("HeAlTh:medication:occurrence", ""),
        ("restored-calendar", CalendarEventOrigin.siftHealth.rawValue),
        ("", CalendarEventOrigin.siftHealth.rawValue)
    ])
    func healthMutationLifecycleExcludesTelemetry(sourceRef: String, calendarOrigin: String) throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let healthID: UUID
        let ordinaryID: UUID
        let baseline: MemoryAnalysisResult
        // Match the durability fixtures: release the writer before reopening the store.
        do {
            let container = try makeContainer(at: directory)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            // Manual tasks without calendar links or email provenance avoid provider work.
            let health = Todo(title: "Private health task", sourceRef: sourceRef)
            health.calendarEventOrigin = calendarOrigin
            let ordinary = Todo(title: "Ordinary task")
            healthID = health.id
            ordinaryID = ordinary.id
            context.insert(ordinary)

            recordCreationAndEdits(of: ordinary, in: context)
            TodoMutations.setCompleted(ordinary, completed: true, in: context)
            #expect(ordinary.isCompleted && ordinary.completedAt != nil)
            TodoMutations.setCompleted(ordinary, completed: false, in: context)
            #expect(!ordinary.isCompleted && ordinary.completedAt == nil)
            try TodoMutations.delete(ordinary, in: context)
            #expect(!context.hasChanges)
            baseline = try persistedAnalysis(in: context)

            context.insert(health)
            recordCreationAndEdits(of: health, in: context)
            for completed in [true, false] {
                TodoMutations.setCompleted(health, completed: completed, in: context)
                #expect(health.isCompleted == completed)
                #expect((health.completedAt != nil) == completed)
                #expect(health.sourceRef == sourceRef)
                #expect(health.calendarEventOrigin == calendarOrigin)
                try context.save()
                expectAnalysis(try persistedAnalysis(in: context), matches: baseline)
            }
            let beforeDeletion = try context.fetch(FetchDescriptor<TaskBehaviorEvent>())
            #expect(!beforeDeletion.contains { $0.todoID == healthID })
            #expect(beforeDeletion.filter { $0.todoID == ordinaryID }.count == 7)

            try TodoMutations.delete(health, in: context)
            #expect(!context.hasChanges)
            #expect(try context.fetch(FetchDescriptor<Todo>()).isEmpty)
            expectAnalysis(try persistedAnalysis(in: context), matches: baseline)
            // No caller save, autosave, wait or application lifecycle transition after deletion.
        }

        let reopened = try makeContainer(at: directory)
        let context = ModelContext(reopened)
        context.autosaveEnabled = false
        #expect(try context.fetch(FetchDescriptor<Todo>()).isEmpty)
        let events = try context.fetch(FetchDescriptor<TaskBehaviorEvent>())
        #expect(events.count == 7)
        #expect(!events.contains { $0.todoID == healthID })
        #expect(events.allSatisfy { $0.todoID == ordinaryID })
        let completionEvents = events.filter { $0.eventType == .completionChanged }
        #expect(completionEvents.count == 2)
        #expect(completionEvents.contains { $0.beforeCompletion == false && $0.afterCompletion == true })
        #expect(completionEvents.contains { $0.beforeCompletion == true && $0.afterCompletion == false })
        #expect(events.filter { $0.eventType == .deleted }.count == 1)
        let audits = try context.fetch(FetchDescriptor<TaskAuditEvent>())
        #expect(audits.count == 1)
        #expect(!audits.contains { $0.todoID == healthID })
        #expect(audits.first?.todoID == ordinaryID)
        #expect(audits.first?.completedAt == nil)
        #expect(audits.first?.dueDate == Date(timeIntervalSince1970: 1_700_086_400))
        expectAnalysis(try persistedAnalysis(in: context), matches: baseline)
    }

    @Test("Ordinary unchanged completion, deadline and priorities still emit nothing")
    func unchangedOrdinaryValuesDoNotRecordBehavior() throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer(at: directory)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let task = Todo(title: "Unchanged task")
        context.insert(task)
        try context.save()
        TaskBehaviorRecorder.recordCompletionChange(of: task, from: false, to: false, actor: .user, in: context)
        TaskBehaviorRecorder.recordDueDateChange(of: task, from: nil, to: nil, actor: .user, in: context)
        TaskBehaviorRecorder.recordManualPriorityChange(of: task, from: nil, to: nil, actor: .user, in: context)
        TaskBehaviorRecorder.recordComputedPriorityChange(of: task, from: 0, to: 0, actor: .artificialIntelligence, in: context)
        #expect(!context.hasChanges)
        #expect(try context.fetch(FetchDescriptor<TaskBehaviorEvent>()).isEmpty)
    }

    @Test("Successful delete survives immediate disk reopen with both audit records", arguments: [false, true])
    func deletionPersistsWithoutAutosave(review: Bool) throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try seedStore(at: directory, review: review)
        try deletePersistedTodo(at: directory, id: id)

        let reopened = try makeContainer(at: directory)
        let context = ModelContext(reopened)
        context.autosaveEnabled = false
        #expect(try context.fetch(FetchDescriptor<Todo>()).isEmpty)
        let audits = try context.fetch(FetchDescriptor<TaskAuditEvent>())
        #expect(audits.count == 1)
        #expect(audits.first?.todoID == id)
        #expect(audits.first?.triageType == (review ? TodoTriage.review.rawValue : TodoTriage.todo.rawValue))
        let behaviors = try context.fetch(FetchDescriptor<TaskBehaviorEvent>())
        #expect(behaviors.count == 1)
        #expect(behaviors.first?.todoID == id)
        #expect(behaviors.first?.eventType == .deleted)
        #expect(behaviors.first?.actor == .user)
    }

    @Test("Real read-only store save failure throws and restores deletion without audit or email learning")
    func failedDeletionIsNotSuccess() throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try seedStore(at: directory, email: true)
        let container = try makeContainer(at: directory, allowsSave: false)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let todo = try #require(context.fetch(FetchDescriptor<Todo>()).first { $0.id == id })
        let sourceRef = todo.sourceRef
        #expect(!EmailLearningStore.shared.isDismissed(sourceRef))

        #expect(throws: Error.self) {
            try TodoMutations.delete(todo, in: context)
        }

        #expect(!context.hasChanges)
        #expect(try context.fetch(FetchDescriptor<Todo>()).map(\.id) == [id])
        #expect(try context.fetch(FetchDescriptor<TaskAuditEvent>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TaskBehaviorEvent>()).isEmpty)
        #expect(!EmailLearningStore.shared.isDismissed(sourceRef))
        let reopened = try makeContainer(at: directory, allowsSave: false)
        let freshContext = ModelContext(reopened)
        freshContext.autosaveEnabled = false
        #expect(try freshContext.fetch(FetchDescriptor<Todo>()).map(\.id) == [id])
        #expect(try freshContext.fetch(FetchDescriptor<TaskAuditEvent>()).isEmpty)
        #expect(try freshContext.fetch(FetchDescriptor<TaskBehaviorEvent>()).isEmpty)
    }

    @Test("Failed pending-change checkpoint leaves unrelated edits intact and does not start deletion")
    func failedCheckpointPreservesPendingChanges() throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try seedStore(at: directory)
        let container = try makeContainer(at: directory, allowsSave: false)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let todo = try #require(context.fetch(FetchDescriptor<Todo>()).first { $0.id == id })
        let unrelatedTodo = Todo(title: "Unrelated pending edit")
        context.insert(unrelatedTodo)

        #expect(throws: Error.self) {
            try TodoMutations.delete(todo, in: context)
        }

        #expect(context.hasChanges)
        let rows = try context.fetch(FetchDescriptor<Todo>())
        #expect(Set(rows.map(\.id)) == Set([id, unrelatedTodo.id]))
        #expect(try context.fetch(FetchDescriptor<TaskAuditEvent>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TaskBehaviorEvent>()).isEmpty)
    }
}
