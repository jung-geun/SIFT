import Foundation
import SwiftData
import Testing
@testable import todo

@MainActor
private struct StreamingPriorityService: IntelligenceService {
    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext,
        progress: IntelligenceProgressHandler?
    ) async throws -> [PriorityResult] {
        let result = PriorityResult(
            todoID: todos[0].id,
            score: 0.8,
            reason: "Act now",
            detail: "",
            needsNotification: false,
            recommendedTime: nil,
            personaFit: false,
            engine: .laya
        )
        progress?(.result(result, index: 1, total: 1, title: todos[0].title))
        return [result]
    }
}

@Suite("RoutedIntelligenceEngine", .serialized)
@MainActor
struct RoutedIntelligenceEngineTests {
    private func sampleTodo(_ title: String = "세금 신고") -> Todo {
        let todo = Todo(title: title)
        todo.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        return todo
    }

    @Test("no beta opt-in uses deterministic rules without consulting legacy selection")
    func noProviderOptInUsesRules() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let policy = BetaFeaturePolicy(
                accessReader: { .disabled },
                selectionReader: { .openAI }
            )
            let results = try await RoutedIntelligenceEngine(policy: policy).prioritize(
                todos: [sampleTodo()],
                events: [],
                persona: .empty
            )

            let first = try #require(results.first)
            #expect(first.engine == .heuristic)
            #expect(first.executionPath == .rules(.noProviderOptIn))
            #expect(first.fallbackReason == RuleFallbackReason.noProviderOptIn.rawValue)
        }
    }

    @Test("approved legacy calendar tasks remain sortable without a selected analysis source")
    func approvedCalendarTasksKeepAutomaticPriority() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let task = Todo(title: "Urgent tax filing", source: .calendar)
            task.dueDate = Date().addingTimeInterval(3_600)
            let review = Todo(title: "Pending suggestion", source: .calendar)
            review.triageStatus = TodoTriage.review.rawValue
            #expect(TodoPriorityScope.candidates(from: [task, review]).map(\.id) == [task.id])
            let policy = BetaFeaturePolicy(accessReader: { .disabled }, selectionReader: { .openAI })
            let results = try await RoutedIntelligenceEngine(policy: policy).prioritize(
                todos: [task, review], events: [], persona: .empty
            )
            #expect(results.map(\.todoID) == [task.id])
            let result = try #require(results.first)
            #expect(result.engine == .heuristic)
            #expect((result.axes?.urgency ?? 0) > 0)
            #expect(TodoPriorityScope.apply(result, in: [task, review])?.id == task.id)
            task.triageStatus = TodoTriage.review.rawValue
            #expect(TodoPriorityScope.apply(result, in: [task, review]) == nil)
        }
    }

    @Test("router exposes only the selected beta provider for standard analysis")
    func routerUsesSingleSelectedProvider() {
        let policy = BetaFeaturePolicy(
            accessReader: {
                BetaProviderAccess(
                    foundationModelsEnabled: true,
                    onDeviceEnabled: true,
                    openAIEnabled: true,
                    layaEnabled: false,
                    meetingVoiceProcessingEnabled: false
                )
            },
            selectionReader: { .onDevice }
        )

        #expect(IntelligenceProviderRouting.decision(policy: policy) == .providers([.onDevice]))
    }

    @Test("streamed Laya results persist selected provider before the final return")
    func streamedResultPreservesProviderAttribution() async throws {
        let policy = BetaFeaturePolicy(
            accessReader: {
                BetaProviderAccess(
                    foundationModelsEnabled: false,
                    onDeviceEnabled: false,
                    openAIEnabled: false,
                    layaEnabled: true,
                    meetingVoiceProcessingEnabled: false
                )
            },
            selectionReader: { .laya }
        )
        let todo = sampleTodo()
        var appliedResultIDs = Set<UUID>()
        let results = try await RoutedIntelligenceEngine(policy: policy, laya: StreamingPriorityService())
            .prioritize(todos: [todo], events: [], persona: .empty) { event in
                guard case .result(let result, _, _, _) = event else { return }
                if !appliedResultIDs.contains(result.todoID) {
                    TodoPriorityScope.apply(result, in: [todo])
                    appliedResultIDs.insert(result.todoID)
                }
            }
        for result in results where !appliedResultIDs.contains(result.todoID) {
            TodoPriorityScope.apply(result, in: [todo])
        }

        #expect(appliedResultIDs == [todo.id])
        #expect(todo.aiRequestedProvider == PersonaAIProvider.laya.rawValue)
        #expect(results.first?.executionPath == .beta(.laya))
    }

    @Test("laya provider without an installed model falls back to heuristic")
    func layaWithoutInstalledModelFallsBackToHeuristic() async throws {
        try await AIProviderTestIsolation.shared.withLock {

            // Isolated install root: guaranteed absent regardless of any previous manual
            // download on this machine's shared LayaDecisionService singleton.
            let emptyRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: emptyRoot) }
            let isolatedService = LayaDecisionService(installRoot: emptyRoot)
            #expect(isolatedService.isModelInstalled == false)

            let policy = BetaFeaturePolicy(
                accessReader: {
                    BetaProviderAccess(
                        foundationModelsEnabled: false,
                        onDeviceEnabled: false,
                        openAIEnabled: false,
                        layaEnabled: true,
                        meetingVoiceProcessingEnabled: false
                    )
                },
                selectionReader: { .laya }
            )
            let results = try await RoutedIntelligenceEngine(
                policy: policy,
                laya: LayaPriorityEngine(service: isolatedService, policy: policy)
            ).prioritize(todos: [sampleTodo()], events: [], persona: .empty)

            let first = try #require(results.first)
            #expect(first.engine == .heuristic)
            #expect(first.executionPath == .rules(.modelNotLoaded))
            #expect(first.fallbackReason == RuleFallbackReason.modelNotLoaded.rawValue)
        }
    }
}

@MainActor
private final class SuspendedCreationPriorityEngine: IntelligenceService {
    private(set) var requestedIDs: [UUID] = []
    private var continuations: [UUID: CheckedContinuation<[PriorityResult], Error>] = [:]

    func prioritize(todos: [Todo], events: [CalendarService.CalendarEventSummary],
                    persona: PersonaContext, progress: IntelligenceProgressHandler?) async throws -> [PriorityResult] {
        let id = todos[0].id
        requestedIDs.append(id)
        return try await withCheckedThrowingContinuation { continuations[id] = $0 }
    }

    func complete(_ id: UUID, resultID: UUID? = nil) {
        continuations.removeValue(forKey: id)?.resume(returning: [
            PriorityResult(todoID: resultID ?? id, score: 0.83, reason: "New task",
                           detail: "", needsNotification: false, recommendedTime: nil,
                           personaFit: false, engine: .laya)
        ])
    }

    func cancel(_ id: UUID) {
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

@Suite("Committed creation priority", .serialized)
@MainActor
struct CommittedCreationPriorityTests {
    private func fixture() throws -> (ModelContainer, UserDefaults, String) {
        let container = try ModelContainer(
            for: AppDataContainer.appSchema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        container.mainContext.autosaveEnabled = false
        let suite = "new-task-priority-tests-\(UUID().uuidString)"
        return (container, try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func settle(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func insert(_ todo: Todo, service: QuickSortService, context: ModelContext) {
        context.insert(todo)
        service.recordInsertion(todo, in: context)
    }

    @Test("Only committed insertions run; restored rows and later status changes never run")
    func creationIsNotCollectionOrStatusObservation() async throws {
        let (container, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = container.mainContext
        let engine = SuspendedCreationPriorityEngine()
        let service = QuickSortService(defaults: defaults, engine: { engine })
        service.start(context: context)
        defer { service.stop() }

        let restored = Todo(title: "Restored from another device")
        restored.createdAt = .distantPast
        context.insert(restored)
        try context.save()
        service.recordInsertion(restored, in: context) // Even a mistaken hook cannot bless an old row.
        restored.isCompleted = true
        try context.save()
        restored.isCompleted = false
        try context.save()
        let rolledBack = Todo(title: "Never saved")
        insert(rolledBack, service: service, context: context)
        context.rollback()
        let restoredReplacement = Todo(id: rolledBack.id, title: "Restored after rollback")
        restoredReplacement.createdAt = rolledBack.createdAt
        context.insert(restoredReplacement)
        try context.save()
        await Task.yield()
        #expect(engine.requestedIDs.isEmpty)

        let new = Todo(title: "A genuinely new task")
        insert(new, service: service, context: context)
        await Task.yield()
        #expect(engine.requestedIDs.isEmpty)
        try context.save()
        #expect(await settle { engine.requestedIDs == [new.id] })
        engine.complete(new.id)
        #expect(await settle { new.computedPriorityScore == 0.83 })
        let reopened = ModelContext(container)
        #expect(try reopened.fetch(FetchDescriptor<Todo>()).first { $0.id == new.id }?.computedPriorityScore == 0.83)
        #expect(restored.computedPriorityScore == 0)
    }

    @Test("Review, health, manual priority and completed insertions remain excluded after promotion")
    func exclusionsAreDecidedAtCreation() async throws {
        let (container, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = container.mainContext
        let engine = SuspendedCreationPriorityEngine()
        let service = QuickSortService(defaults: defaults, engine: { engine })
        service.start(context: context)
        defer { service.stop() }
        let review = Todo(title: "Review")
        review.triageStatus = TodoTriage.review.rawValue
        let health = Todo(title: "Health", sourceRef: "health:private")
        let manual = Todo(title: "Manual")
        manual.manualPriority = 5
        let completed = Todo(title: "Completed")
        completed.isCompleted = true
        for todo in [review, health, manual, completed] { insert(todo, service: service, context: context) }
        try context.save()
        review.triageStatus = TodoTriage.todo.rawValue
        manual.manualPriority = nil
        completed.isCompleted = false
        try context.save()
        for _ in 0..<20 { await Task.yield() }
        #expect(engine.requestedIDs.isEmpty)
    }

    @Test("One suspended provider never blocks another creation; stale edits and explicit sort results win")
    func concurrentCreationPreservesNewerUserWork() async throws {
        let (container, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = container.mainContext
        let engine = SuspendedCreationPriorityEngine()
        let service = QuickSortService(defaults: defaults, engine: { engine })
        service.start(context: context)
        defer { service.stop() }
        let first = Todo(title: "Slow")
        insert(first, service: service, context: context)
        try context.save()
        #expect(await settle { engine.requestedIDs.contains(first.id) })
        let second = Todo(title: "Independent")
        insert(second, service: service, context: context)
        try context.save()
        #expect(await settle { engine.requestedIDs.count == 2 })
        engine.complete(second.id)
        #expect(await settle { second.computedPriorityScore == 0.83 })
        #expect(first.computedPriorityScore == 0)
        first.priorityReason = "Explicit AI sort"
        first.computedPriorityScore = 0.4
        try context.save()
        engine.complete(first.id)
        for _ in 0..<20 { await Task.yield() }
        #expect(first.computedPriorityScore == 0.4)
        #expect(first.priorityReason == "Explicit AI sort")
        #expect(try context.fetch(FetchDescriptor<TaskBehaviorEvent>()).filter { $0.todoID == first.id }.isEmpty)
    }

    @Test("Editing, deleting or demoting a task during inference rejects the obsolete result", arguments: ["edit", "delete", "review", "manual", "complete"])
    func obsoleteResultIsDiscarded(_ mutation: String) async throws {
        let (container, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = container.mainContext
        let engine = SuspendedCreationPriorityEngine()
        let service = QuickSortService(defaults: defaults, engine: { engine })
        service.start(context: context)
        defer { service.stop() }
        let todo = Todo(title: "Original input")
        let id = todo.id
        insert(todo, service: service, context: context)
        try context.save()
        #expect(await settle { engine.requestedIDs == [id] })
        switch mutation {
        case "edit": todo.title = "Edited input"
        case "delete": context.delete(todo)
        case "review": todo.triageStatus = TodoTriage.review.rawValue
        case "manual": todo.manualPriority = 5
        default: todo.isCompleted = true
        }
        try context.save()
        engine.complete(id)
        for _ in 0..<20 { await Task.yield() }
        #expect(try context.fetch(FetchDescriptor<Todo>()).allSatisfy { $0.computedPriorityScore == 0 })
        #expect(try context.fetch(FetchDescriptor<TaskBehaviorEvent>()).isEmpty)
    }

    @Test("Restart resumes only device-local creation receipts, never restored audit history")
    func restartUsesLocalReceipts() async throws {
        let (container, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = container.mainContext
        let firstEngine = SuspendedCreationPriorityEngine()
        let firstService = QuickSortService(defaults: defaults, engine: { firstEngine })
        firstService.start(context: context)
        let new = Todo(title: "Locally committed")
        insert(new, service: firstService, context: context)
        let restored = Todo(title: "Restored with creation audit")
        context.insert(restored)
        context.insert(TaskBehaviorEvent(todo: restored, type: .created, actor: .user, occurredAt: Date()))
        try context.save()
        #expect(await settle { firstEngine.requestedIDs == [new.id] })
        firstService.stop()
        let secondEngine = SuspendedCreationPriorityEngine()
        let secondService = QuickSortService(defaults: defaults, engine: { secondEngine })
        secondService.start(context: context)
        defer { secondService.stop() }
        #expect(await settle { secondEngine.requestedIDs == [new.id] })
        firstEngine.complete(new.id) // Late completion from the cancelled lifecycle cannot apply.
        for _ in 0..<20 { await Task.yield() }
        #expect(new.computedPriorityScore == 0)
        secondEngine.complete(new.id)
        #expect(await settle { new.computedPriorityScore == 0.83 })
        #expect(restored.computedPriorityScore == 0)
    }

    @Test("A provider result for a different task cannot be applied")
    func resultIdentityMustMatch() async throws {
        let (container, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = container.mainContext
        let engine = SuspendedCreationPriorityEngine()
        let service = QuickSortService(defaults: defaults, engine: { engine })
        service.start(context: context)
        defer { service.stop() }
        let todo = Todo(title: "Exact identity")
        insert(todo, service: service, context: context)
        try context.save()
        #expect(await settle { engine.requestedIDs == [todo.id] })
        engine.complete(todo.id, resultID: UUID())
        for _ in 0..<20 { await Task.yield() }
        #expect(todo.computedPriorityScore == 0)
    }

    @Test("A failed insertion save cannot invoke the priority provider")
    func failedCommitDoesNotRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("priority-read-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        do {
            let seed = try ModelContainer(for: AppDataContainer.appSchema, configurations: [
                ModelConfiguration(schema: AppDataContainer.appSchema, url: url, cloudKitDatabase: .none)
            ])
            seed.mainContext.insert(Todo(title: "Existing"))
            try seed.mainContext.save()
        }
        let container = try ModelContainer(for: AppDataContainer.appSchema, configurations: [
            ModelConfiguration(schema: AppDataContainer.appSchema, url: url, allowsSave: false, cloudKitDatabase: .none)
        ])
        let suite = "new-task-priority-failure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = container.mainContext
        context.autosaveEnabled = false
        let engine = SuspendedCreationPriorityEngine()
        let service = QuickSortService(defaults: defaults, engine: { engine })
        service.start(context: context)
        defer { service.stop() }
        insert(Todo(title: "Unsavable"), service: service, context: context)
        do {
            try context.save()
            Issue.record("Expected the read-only store to reject insertion")
        } catch {}
        for _ in 0..<20 { await Task.yield() }
        #expect(engine.requestedIDs.isEmpty)
        let key = try #require(defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("sift.local.newTaskPriority.") })
        #expect(!CloudPreferenceStore.isUserPreference(key))
        service.stop()
        service.start(context: context)
        #expect(await settle {
            guard let data = defaults.data(forKey: key),
                  let rows = try? JSONDecoder().decode([QuickSortService.Receipt].self, from: data) else { return false }
            return rows.isEmpty
        })
        #expect(engine.requestedIDs.isEmpty)
    }

    @Test("Automatic creation scoring retains the real no-consent rules route")
    func creationDoesNotOptIntoAProvider() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let (container, defaults, suite) = try fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let policy = BetaFeaturePolicy(accessReader: { .disabled }, selectionReader: { .openAI })
            let service = QuickSortService(defaults: defaults, engine: { RoutedIntelligenceEngine(policy: policy) })
            let context = container.mainContext
            service.start(context: context)
            defer { service.stop() }
            let todo = Todo(title: "Urgent deadline", dueDate: Date().addingTimeInterval(3_600))
            insert(todo, service: service, context: context)
            try context.save()
            #expect(await settle { !todo.aiEngine.isEmpty })
            #expect(todo.aiEngine == PriorityEngine.heuristic.rawValue)
            #expect(todo.aiFallbackReason == RuleFallbackReason.noProviderOptIn.rawValue)
            #expect(todo.aiRequestedProvider.isEmpty)
        }
    }

    @Test("System calendar linkage after insertion does not invalidate priority; receipts never sync")
    func calendarLinkageAndLocalReceipts() async throws {
        let (container, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = container.mainContext
        let engine = SuspendedCreationPriorityEngine()
        let service = QuickSortService(defaults: defaults, engine: { engine })
        service.start(context: context)
        defer { service.stop() }
        let todo = Todo(title: "Register a new task to calendar")
        insert(todo, service: service, context: context)
        try context.save()
        todo.calendarEventID = "device-event-id"
        todo.calendarEventExternalID = "stable-event-id"
        todo.calendarSourceID = "calendar-id"
        todo.calendarSyncedTitle = todo.title
        todo.calendarEventOrigin = CalendarEventOrigin.siftManual.rawValue
        todo.updatedAt = Date().addingTimeInterval(1)
        try context.save()
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("sift.local.newTaskPriority.") }
        #expect(keys.count == 1)
        #expect(keys.allSatisfy { !CloudPreferenceStore.isUserPreference($0) })
        #expect(await settle { engine.requestedIDs == [todo.id] })
        engine.complete(todo.id)
        #expect(await settle { todo.computedPriorityScore == 0.83 })
    }

    @Test("Provider-originated cancellation falls back without requiring an app restart")
    func providerCancellationDoesNotStrandCreation() async throws {
        let (container, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = container.mainContext
        let engine = SuspendedCreationPriorityEngine()
        let service = QuickSortService(defaults: defaults, engine: { engine })
        service.start(context: context)
        defer { service.stop() }
        let todo = Todo(title: "Urgent deadline", dueDate: Date().addingTimeInterval(3_600))
        insert(todo, service: service, context: context)
        try context.save()
        #expect(await settle { engine.requestedIDs == [todo.id] })
        engine.cancel(todo.id)
        #expect(await settle { !todo.aiEngine.isEmpty })
        #expect(todo.aiEngine == PriorityEngine.heuristic.rawValue)
        #expect(todo.aiFallbackReason == RuleFallbackReason.providerExecutionFailed.rawValue)
    }

    @Test("Committing priority never saves or rolls back unrelated unsaved UI edits")
    func isolatedPriorityCommitPreservesUncommittedUserWork() async throws {
        let (container, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = container.mainContext
        let existing = Todo(title: "Existing user task", notes: "Persisted notes")
        context.insert(existing)
        try context.save()
        let engine = SuspendedCreationPriorityEngine()
        let service = QuickSortService(defaults: defaults, engine: { engine })
        service.start(context: context)
        defer { service.stop() }
        let new = Todo(title: "Independent creation")
        insert(new, service: service, context: context)
        try context.save()
        #expect(await settle { engine.requestedIDs == [new.id] })
        existing.notes = "Uncommitted user typing"
        new.calendarEventID = "Unsaved device calendar linkage"
        engine.complete(new.id)
        #expect(await settle { new.computedPriorityScore == 0.83 })
        let reader = ModelContext(container)
        let persisted = try reader.fetch(FetchDescriptor<Todo>())
        #expect(persisted.first { $0.id == existing.id }?.notes == "Persisted notes")
        #expect(persisted.first { $0.id == new.id }?.computedPriorityScore == 0.83)
        #expect(existing.notes == "Uncommitted user typing")
        #expect(context.hasChanges)
        #expect(try reader.fetch(FetchDescriptor<TaskBehaviorEvent>()).filter { $0.todoID == new.id }.count == 1)
        // Exercise the later real UI/autosave boundary too: the isolated write
        // must not make the UI's pending task/linkage changes unsavable.
        try context.save()
        let afterUISave = try ModelContext(container).fetch(FetchDescriptor<Todo>())
        #expect(afterUISave.first { $0.id == existing.id }?.notes == "Uncommitted user typing")
        #expect(afterUISave.first { $0.id == new.id }?.calendarEventID == "Unsaved device calendar linkage")
        #expect(afterUISave.first { $0.id == new.id }?.computedPriorityScore == 0.83)
    }

    @Test("A crash between creation commit and didSave receipt promotion does not lose scoring")
    func recoverPrecommitIntentAfterMissedSaveNotification() async throws {
        let (container, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = container.mainContext
        let engine = SuspendedCreationPriorityEngine()
        let service = QuickSortService(defaults: defaults, engine: { engine })
        service.start(context: context)
        defer { service.stop() }
        let todo = Todo(title: "Recover the local committed creation")
        insert(todo, service: service, context: context)
        let key = try #require(defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("sift.local.newTaskPriority.") })
        let beforeSave = try JSONDecoder().decode([QuickSortService.Receipt].self, from: #require(defaults.data(forKey: key)))
        #expect(beforeSave.map(\.id) == [todo.id])
        #expect(engine.requestedIDs.isEmpty)
        // Detaching before save simulates losing every didSave callback while
        // retaining the journal that had already been flushed before the commit.
        service.stop()
        try context.save()
        service.start(context: context)
        #expect(await settle { engine.requestedIDs == [todo.id] })
        engine.complete(todo.id)
        #expect(await settle { todo.computedPriorityScore == 0.83 })
    }

    @Test("An inserted duplicate UUID cannot journal a historical task as new")
    func historicalIdentityCannotBeReclassified() async throws {
        let (container, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = container.mainContext
        let old = Todo(title: "Already persisted", dueDate: Date().addingTimeInterval(3_600))
        context.insert(old)
        try context.save()
        let engine = SuspendedCreationPriorityEngine()
        let service = QuickSortService(defaults: defaults, engine: { engine })
        service.start(context: context)
        defer { service.stop() }
        let duplicate = Todo(id: old.id, title: old.title, dueDate: old.dueDate)
        duplicate.createdAt = old.createdAt
        insert(duplicate, service: service, context: context)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("sift.local.newTaskPriority.") })
        context.rollback()
        service.stop()
        service.start(context: context)
        for _ in 0..<20 { await Task.yield() }
        #expect(engine.requestedIDs.isEmpty)
        #expect(old.computedPriorityScore == 0)
    }
}
