import Foundation
import Testing
import SwiftData
@testable import todo

@Suite("MemoryService deterministic behavior analysis")
@MainActor
struct MemoryServiceTests {
    private func makeDate(
        year: Int = 2026,
        month: Int = 7,
        day: Int,
        hour: Int,
        minute: Int = 0
    ) -> Date {
        Calendar.current.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    private func completedTodo(
        title: String,
        createdAt: Date,
        completedAt: Date,
        dueDate: Date? = nil,
        tags: [String] = []
    ) -> Todo {
        let todo = Todo(title: title, dueDate: dueDate, tags: tags)
        todo.createdAt = createdAt
        todo.updatedAt = completedAt
        todo.isCompleted = true
        todo.completedAt = completedAt
        return todo
    }

    private func deletionSnapshot(
        completed: Bool,
        createdAt: Date,
        completedAt: Date?,
        deletedAt: Date
    ) -> TaskAuditEvent {
        let todo = Todo(title: completed ? "완료 후 삭제" : "미완료 삭제")
        todo.createdAt = createdAt
        todo.isCompleted = completed
        todo.completedAt = completedAt
        todo.triageStatus = TodoTriage.todo.rawValue
        let event = TaskAuditEvent(from: todo)
        event.deletedAt = deletedAt
        return event
    }

    @Test("health provenance is excluded before live, audit, and event snapshots lose it")
    func healthEvidenceDoesNotChangeOrdinaryAnalysis() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_783_684_800)
        let createdAt = now.addingTimeInterval(-2 * 24 * 3600)
        let completedAt = now.addingTimeInterval(-24 * 3600)
        let ordinary = (0..<5).map { index in
            completedTodo(
                title: "Ordinary \(index)",
                createdAt: createdAt,
                completedAt: completedAt,
                dueDate: completedAt.addingTimeInterval(3600),
                tags: ["ordinary"]
            )
        }
        // A health-like substring must not exclude ordinary task learning.
        ordinary[0].sourceRef = "message-health:ordinary"
        let ordinaryAudit = TaskAuditEvent(from: Todo(title: "Ordinary deleted"))
        ordinaryAudit.createdAt = createdAt
        ordinaryAudit.deletedAt = completedAt
        let ordinaryEvent = TaskBehaviorEvent(
            todo: ordinary[0], type: .created, actor: .user, occurredAt: createdAt
        )
        ordinaryEvent.afterDueDate = ordinary[0].dueDate
        let health = (0..<8).map { index in
            let todo = completedTodo(
                title: "Private health title \(index)",
                createdAt: now.addingTimeInterval(-30 * 24 * 3600),
                completedAt: now.addingTimeInterval(-3600),
                dueDate: createdAt,
                tags: ["private-health-tag"]
            )
            if index.isMultiple(of: 2) {
                todo.sourceRef = "HeAlTh:workout:\(index)"
            } else {
                // Restored/calendar-linked health provenance must also survive
                // an absent or stale sourceRef.
                todo.calendarEventOrigin = "siftHealth"
            }
            if index >= 5 {
                todo.isCompleted = false
                todo.completedAt = nil
            }
            return todo
        }
        // Synthetic inputs exercise the collection guard too; production must
        // never persist these rows in the first place.
        let healthAudits = health.map { todo in
            let audit = TaskAuditEvent(from: todo)
            audit.deletedAt = now.addingTimeInterval(-1800)
            return audit
        }
        let healthEvents = health.flatMap { todo in
            [TaskBehaviorEventType.created, .completionChanged, .dueDateChanged, .priorityChanged, .deleted].map { kind in
                let event = TaskBehaviorEvent(
                    todo: todo, type: kind, actor: .user,
                    occurredAt: now.addingTimeInterval(-1800)
                )
                event.beforeCompletion = false
                event.afterCompletion = true
                event.beforeDueDate = createdAt
                event.afterDueDate = now
                event.beforeManualPriority = nil
                event.afterManualPriority = TodoPriority.critical.rawValue
                return event
            }
        }
        let baselineContext = BehaviorAnalysisContextBuilder.make(
            todos: ordinary, auditEvents: [ordinaryAudit], behaviorEvents: [ordinaryEvent],
            now: now, calendar: calendar
        )
        let mixedContext = BehaviorAnalysisContextBuilder.make(
            todos: ordinary + health,
            auditEvents: [ordinaryAudit] + healthAudits,
            behaviorEvents: [ordinaryEvent] + healthEvents,
            now: now, calendar: calendar
        )

        #expect(mixedContext.todos == baselineContext.todos)
        #expect(mixedContext.events == baselineContext.events)
        #expect(mixedContext.todos.count == ordinary.count + 1)
        #expect(mixedContext.events.count == 1)
        let baseline = MemoryService.computeAnalysis(context: baselineContext, language: .english)
        let mixed = MemoryService.computeAnalysis(context: mixedContext, language: .english)
        #expect(mixed.behaviorProfile == baseline.behaviorProfile)
        #expect(mixed.summary == baseline.summary)
        #expect(mixed.insights == baseline.insights)
        #expect(mixed.fastTags == baseline.fastTags)
        #expect(mixed.fastTags.contains("ordinary"))
        #expect(mixed.overdueRate == baseline.overdueRate)
        #expect(mixed.productiveHour == baseline.productiveHour)
        #expect(mixed.analyzedCompletedCount == baseline.analyzedCompletedCount)
        #expect(mixed.accessScopeSummary == baseline.accessScopeSummary)

        let healthOnlyContext = BehaviorAnalysisContextBuilder.make(
            todos: health, auditEvents: healthAudits, behaviorEvents: healthEvents,
            now: now, calendar: calendar
        )
        #expect(healthOnlyContext.todos.isEmpty)
        #expect(healthOnlyContext.events.isEmpty)
        let healthOnly = MemoryService.computeAnalysis(context: healthOnlyContext, language: .english)
        let empty = MemoryService.computeAnalysis(todos: [], now: now, calendar: calendar, language: .english)
        #expect(healthOnly.behaviorProfile == empty.behaviorProfile)
        #expect(healthOnly.summary == empty.summary)
        #expect(healthOnly.insights == empty.insights)
        #expect(healthOnly.fastTags.isEmpty)
        #expect(healthOnly.productiveHour == nil)
        #expect(healthOnly.analyzedCompletedCount == 0)
        #expect(healthOnly.accessScopeSummary == empty.accessScopeSummary)
    }

    @Test("current state and every user deletion snapshot use separate denominators")
    func separatesCurrentAndDeletionSnapshotDenominators() {
        let now = makeDate(day: 10, hour: 12)
        let completed = completedTodo(
            title: "현재 완료",
            createdAt: makeDate(day: 1, hour: 8),
            completedAt: makeDate(day: 2, hour: 10)
        )
        let active = Todo(title: "현재 미완료")
        active.createdAt = makeDate(day: 3, hour: 8)
        active.updatedAt = makeDate(day: 3, hour: 8)

        let completedDeletion = deletionSnapshot(
            completed: true,
            createdAt: makeDate(day: 1, hour: 8),
            completedAt: makeDate(day: 2, hour: 10),
            deletedAt: makeDate(day: 4, hour: 10)
        )
        let incompleteDeletion = deletionSnapshot(
            completed: false,
            createdAt: makeDate(day: 2, hour: 8),
            completedAt: nil,
            deletedAt: makeDate(day: 5, hour: 10)
        )

        let result = MemoryService.computeAnalysis(
            todos: [completed, active],
            auditEvents: [completedDeletion, incompleteDeletion],
            now: now,
            language: .korean
        )

        #expect(result.summary.contains("현재 보유 TODO 완료 상태: 1/2건"))
        #expect(result.summary.contains("완료 후 삭제: 1/2건"))
        #expect(!result.summary.contains("전체 완료율"))
        #expect(result.analyzedCompletedCount == 2)
        #expect(result.behaviorProfile.insight(for: .currentCompletionShare)?.denominator == 2)
        #expect(result.behaviorProfile.insight(for: .deletedCompletedShare)?.denominator == 2)
    }

    @Test("AFM behavior narration preserves deterministic metrics and profile")
    func AFMNarrationPreservesDeterministicMetrics() async throws {
        let now = makeDate(day: 10, hour: 12)
        let completed = completedTodo(
            title: "confidential",
            createdAt: makeDate(day: 1, hour: 8),
            completedAt: makeDate(day: 2, hour: 10)
        )
        let baseline = MemoryService.computeAnalysis(todos: [completed], now: now, language: .english)
        let service = BehaviorNarrationService(
            narrativeProvider: { _, _ in
                BehaviorNarrative(
                    summary: "  Completion records are concentrated in the observed window.  ",
                    insights: ["  One deterministic observation. ", ""]
                )
            },
            routingDecisionProvider: { .providers([.foundationModels]) },
            availabilityProvider: { true }
        )

        let result = try await service.enrich(baseline, language: .english)

        #expect(result.summary == "Completion records are concentrated in the observed window.")
        #expect(result.insights == ["One deterministic observation."])
        #expect(result.fastTags == baseline.fastTags)
        #expect(result.overdueRate == baseline.overdueRate)
        #expect(result.productiveHour == baseline.productiveHour)
        #expect(result.analyzedCompletedCount == baseline.analyzedCompletedCount)
        #expect(result.recordTitle == baseline.recordTitle)
        #expect(result.accessScopeSummary == baseline.accessScopeSummary)
        #expect(result.behaviorProfile == baseline.behaviorProfile)
        #expect(result.processorDescription == "Apple Foundation Models · deterministic metrics")
    }

    @Test("explicit local selection retains the deterministic behavior result")
    func explicitLocalSelectionDoesNotInvokeAFMNarration() async throws {
        let now = makeDate(day: 10, hour: 12)
        let baseline = MemoryService.computeAnalysis(todos: [], now: now, language: .english)
        let service = BehaviorNarrationService(
            narrativeProvider: { _, _ in throw CancellationError() },
            routingDecisionProvider: { .providers([.onDevice]) },
            availabilityProvider: { true }
        )

        let result = try await service.enrich(baseline, language: .english)

        #expect(result.summary == baseline.summary)
        #expect(result.insights == baseline.insights)
        #expect(result.processorDescription == baseline.processorDescription)
        #expect(result.behaviorProfile == baseline.behaviorProfile)
    }

    @Test("overdue rate denominator contains only completed Todos with due dates")
    func overdueRateUsesDueDatedCompletionDenominator() {
        let now = makeDate(day: 10, hour: 12)
        let due = makeDate(day: 5, hour: 12)
        var todos = [
            completedTodo(
                title: "조기",
                createdAt: makeDate(day: 1, hour: 8),
                completedAt: makeDate(day: 5, hour: 10),
                dueDate: due
            ),
            completedTodo(
                title: "지연",
                createdAt: makeDate(day: 1, hour: 8),
                completedAt: makeDate(day: 5, hour: 14),
                dueDate: due
            )
        ]
        for index in 0..<3 {
            todos.append(
                completedTodo(
                    title: "마감 없음 \(index)",
                    createdAt: makeDate(day: 1, hour: 8),
                    completedAt: makeDate(day: 6, hour: 9)
                )
            )
        }

        let result = MemoryService.computeAnalysis(todos: todos, now: now, language: .korean)
        let overdue = result.behaviorProfile.insight(for: .overdueCompletionRate)

        #expect(overdue?.numerator == 1)
        #expect(overdue?.denominator == 2)
        #expect((overdue?.value ?? 0) > 0.5)
        #expect(abs((overdue?.value ?? 0) - 0.5) < 0.001)
    }

    @Test("five equal-weight completion records produce a low-confidence time block")
    func completionConcentrationUsesConfidenceAndThreeHourBlocks() {
        let now = makeDate(day: 10, hour: 12)
        let completion = makeDate(day: 9, hour: 10)
        let todos = (0..<5).map { index in
            completedTodo(
                title: "완료 \(index)",
                createdAt: makeDate(day: 8, hour: 8),
                completedAt: completion
            )
        }

        let result = MemoryService.computeAnalysis(todos: todos, now: now, language: .korean)
        let concentration = result.behaviorProfile.insight(for: .completionConcentrationHour)

        #expect(result.productiveHour == 9)
        #expect(concentration?.confidence == .low)
        #expect(concentration?.numerator == 5)
        #expect(concentration?.denominator == 5)
        #expect(result.summary.contains("완료 기록 집중 시간: 9시~12시"))
    }

    @Test("typed transitions expose rates only after five denominator events")
    func transitionMetricsAreConfidenceGated() {
        let now = makeDate(day: 10, hour: 12)
        var events: [TaskBehaviorEvent] = []
        var todos: [Todo] = []

        for index in 0..<5 {
            let todo = Todo(title: "이벤트 \(index)")
            todos.append(todo)
            let completed = TaskBehaviorEvent(
                todo: todo,
                type: .completionChanged,
                actor: .user,
                occurredAt: makeDate(day: 9, hour: 6 + index)
            )
            completed.beforeCompletion = false
            completed.afterCompletion = true
            events.append(completed)

            let aiPriority = TaskBehaviorEvent(
                todo: todo,
                type: .priorityChanged,
                actor: .artificialIntelligence,
                occurredAt: makeDate(day: 9, hour: 12 + index)
            )
            aiPriority.beforeComputedPriority = 0.2
            aiPriority.afterComputedPriority = 0.8
            events.append(aiPriority)
        }

        let undone = TaskBehaviorEvent(
            todo: todos[0],
            type: .completionChanged,
            actor: .user,
            occurredAt: makeDate(day: 10, hour: 9)
        )
        undone.beforeCompletion = true
        undone.afterCompletion = false
        events.append(undone)

        for index in 0..<2 {
            let userPriority = TaskBehaviorEvent(
                todo: todos[index],
                type: .priorityChanged,
                actor: .user,
                occurredAt: makeDate(day: 9, hour: 18 + index)
            )
            userPriority.beforeManualPriority = nil
            userPriority.afterManualPriority = TodoPriority.high.rawValue
            events.append(userPriority)
        }

        let result = MemoryService.computeAnalysis(
            todos: todos,
            behaviorEvents: events,
            now: now,
            language: .korean
        )
        let undo = result.behaviorProfile.insight(for: .completionUndoRate)
        let override = result.behaviorProfile.insight(for: .aiOverrideRate)

        #expect(undo?.numerator == 1)
        #expect(undo?.denominator == 5)
        #expect(undo?.confidence == .low)
        #expect(override?.numerator == 2)
        #expect(override?.denominator == 5)
        #expect(result.insights.contains { $0.contains("완료 취소 1건") })
        #expect(result.insights.contains { $0.contains("사용자 재변경 2건") })
    }

    @Test("one completion can pair with at most one undo")
    func undoPairingIsOneToOne() {
        let now = makeDate(day: 10, hour: 12)
        let todo = Todo(title: "중복 완료 취소")
        let completed = TaskBehaviorEvent(
            todo: todo,
            type: .completionChanged,
            actor: .user,
            occurredAt: makeDate(day: 9, hour: 9)
        )
        completed.beforeCompletion = false
        completed.afterCompletion = true
        let firstUndo = TaskBehaviorEvent(
            todo: todo,
            type: .completionChanged,
            actor: .user,
            occurredAt: makeDate(day: 9, hour: 10)
        )
        firstUndo.beforeCompletion = true
        firstUndo.afterCompletion = false
        let duplicateUndo = TaskBehaviorEvent(
            todo: todo,
            type: .completionChanged,
            actor: .user,
            occurredAt: makeDate(day: 9, hour: 11)
        )
        duplicateUndo.beforeCompletion = true
        duplicateUndo.afterCompletion = false

        let result = MemoryService.computeAnalysis(
            todos: [todo],
            behaviorEvents: [completed, firstUndo, duplicateUndo],
            now: now,
            language: .korean
        )
        let insight = result.behaviorProfile.insight(for: .completionUndoRate)

        #expect(insight?.numerator == 1)
        #expect(insight?.denominator == 1)
        #expect((insight?.value ?? 0) <= 1)
    }

    @Test("four-event transition cohorts remain structured but produce no behavior claims")
    func sparseTransitionMetricsRemainHidden() {
        let now = makeDate(day: 10, hour: 12)
        var events: [TaskBehaviorEvent] = []
        var todos: [Todo] = []

        for index in 0..<4 {
            let todo = Todo(title: "희소 이벤트 \(index)")
            todos.append(todo)

            let completed = TaskBehaviorEvent(
                todo: todo,
                type: .completionChanged,
                actor: .user,
                occurredAt: makeDate(day: 5, hour: 8 + index)
            )
            completed.beforeCompletion = false
            completed.afterCompletion = true
            events.append(completed)

            let dueChanged = TaskBehaviorEvent(
                todo: todo,
                type: .dueDateChanged,
                actor: .user,
                occurredAt: makeDate(day: 6, hour: 8 + index)
            )
            dueChanged.beforeDueDate = makeDate(day: 12, hour: 9)
            dueChanged.afterDueDate = makeDate(day: 13, hour: 9)
            events.append(dueChanged)

            let aiPriority = TaskBehaviorEvent(
                todo: todo,
                type: .priorityChanged,
                actor: .artificialIntelligence,
                occurredAt: makeDate(day: 7, hour: 8 + index)
            )
            aiPriority.beforeComputedPriority = 0.2
            aiPriority.afterComputedPriority = 0.8
            events.append(aiPriority)

            let userPriority = TaskBehaviorEvent(
                todo: todo,
                type: .priorityChanged,
                actor: .user,
                occurredAt: makeDate(day: 7, hour: 12 + index)
            )
            userPriority.beforeManualPriority = nil
            userPriority.afterManualPriority = TodoPriority.high.rawValue
            events.append(userPriority)
        }

        let undone = TaskBehaviorEvent(
            todo: todos[0],
            type: .completionChanged,
            actor: .user,
            occurredAt: makeDate(day: 8, hour: 9)
        )
        undone.beforeCompletion = true
        undone.afterCompletion = false
        events.append(undone)

        let result = MemoryService.computeAnalysis(
            todos: todos,
            behaviorEvents: events,
            now: now,
            language: .korean
        )

        for metric in [
            BehaviorMetric.completionUndoRate,
            .dueDateChangeRate,
            .aiOverrideRate
        ] {
            #expect(result.behaviorProfile.insight(for: metric)?.confidence == .insufficient)
        }
        #expect(result.behaviorProfile.insight(for: .manualPriorityChangeRate) == nil)
        #expect(!result.insights.contains { $0.contains("완료 취소") })
        #expect(!result.insights.contains { $0.contains("마감일을 변경") })
        #expect(!result.insights.contains { $0.contains("우선순위를 변경") })
        #expect(!result.insights.contains { $0.contains("사용자 재변경") })
    }

    @Test("behavior recorder persists typed before and after values")
    @MainActor
    func behaviorRecorderPersistsTransitions() throws {
        let config = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AppDataContainer.appSchema,
            configurations: [config]
        )
        let context = ModelContext(container)
        let todo = Todo(title: "민감한 제목", dueDate: makeDate(day: 12, hour: 9))
        context.insert(todo)

        TaskBehaviorRecorder.recordCreation(
            of: todo,
            actor: .user,
            in: context,
            at: makeDate(day: 10, hour: 8)
        )
        let previousDueDate = todo.dueDate
        todo.dueDate = makeDate(day: 13, hour: 9)
        TaskBehaviorRecorder.recordDueDateChange(
            of: todo,
            from: previousDueDate,
            to: todo.dueDate,
            actor: .user,
            in: context,
            at: makeDate(day: 10, hour: 9)
        )
        TaskBehaviorRecorder.recordDeletion(
            of: todo,
            actor: .system,
            in: context,
            at: makeDate(day: 10, hour: 10)
        )
        context.delete(todo)
        try context.save()

        let events = try context.fetch(
            FetchDescriptor<TaskBehaviorEvent>(
                sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
            )
        )
        #expect(events.count == 3)
        #expect(events[0].eventType == .created)
        #expect(events[0].actor == .user)
        #expect(events[0].todoID == todo.id)
        #expect(events[1].eventType == .dueDateChanged)
        #expect(events[1].beforeDueDate == previousDueDate)
        #expect(events[1].afterDueDate == todo.dueDate)
        #expect(events[2].eventType == .deleted)
        #expect(events[2].actor == .system)
        #expect(events[2].beforeDueDate == makeDate(day: 13, hour: 9))
        #expect(try context.fetch(FetchDescriptor<TaskAuditEvent>()).isEmpty)
    }

    @Test("Firebase snapshot preserves future behavior event raw values")
    @MainActor
    func firebaseSnapshotPreservesUnknownBehaviorRawValues() throws {
        let sourceConfig = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let sourceContainer = try ModelContainer(
            for: AppDataContainer.appSchema,
            configurations: [sourceConfig]
        )
        let sourceContext = ModelContext(sourceContainer)
        let todo = Todo(title: "snapshot")
        let event = TaskBehaviorEvent(
            todo: todo,
            type: .created,
            actor: .system,
            occurredAt: makeDate(day: 10, hour: 9)
        )
        event.eventTypeRaw = "futureEvent"
        event.actorRaw = "futureActor"
        sourceContext.insert(event)
        let json = try FirebaseSnapshotStore.exportJSON(context: sourceContext)

        let targetConfig = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let targetContainer = try ModelContainer(
            for: AppDataContainer.appSchema,
            configurations: [targetConfig]
        )
        let targetContext = ModelContext(targetContainer)
        try FirebaseSnapshotStore.importJSON(json, context: targetContext)

        let imported = try #require(
            targetContext.fetch(FetchDescriptor<TaskBehaviorEvent>()).first
        )
        #expect(imported.eventTypeRaw == "futureEvent")
        #expect(imported.actorRaw == "futureActor")
    }

    @Test("behavior profile persists and corrupt payload falls back to scalar metadata")
    @MainActor
    func behaviorProfilePersistsAndFallsBack() throws {
        let now = makeDate(day: 10, hour: 12)
        let profile = BehaviorProfile(
            version: BehaviorProfile.currentVersion,
            windowStart: makeDate(day: 1, hour: 0),
            windowEnd: now,
            sampleCount: 12,
            effectiveSampleSize: 9,
            confidence: .low,
            insights: []
        )
        let config = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AppDataContainer.appSchema,
            configurations: [config]
        )
        let context = ModelContext(container)
        let analysis = MemoryAnalysis(
            summary: "요약",
            insights: [],
            fastTags: [],
            overdueRate: 0,
            behaviorProfile: profile
        )
        context.insert(analysis)
        try context.save()

        let reloaded = try #require(
            ModelContext(container).fetch(FetchDescriptor<MemoryAnalysis>()).first
        )
        #expect(reloaded.behaviorProfile == profile)
        #expect(reloaded.sampleCount == 12)
        #expect(reloaded.confidence == .low)

        reloaded.behaviorProfileData = Data([0xFF])
        let fallback = reloaded.behaviorProfile
        #expect(fallback.version == BehaviorProfile.currentVersion)
        #expect(fallback.sampleCount == 12)
        #expect(fallback.confidence == .low)
        #expect(fallback.insights.isEmpty)
    }
    @Test("legacy profile payloads default classifications and skip unknown elements")
    func behaviorProfileLossyDecode() throws {
        let date = makeDate(day: 10, hour: 12)
        let known = BehaviorClassification(
            dimension: .completionTime,
            label: .morning,
            confidence: .medium,
            evidence: [
                BehaviorEvidence(
                    metricRawValue: BehaviorMetric.completionTimeBucketConcentration.rawValue,
                    value: 0.5,
                    rawCount: 5,
                    effectiveCount: 5
                )
            ]
        )
        let profile = BehaviorProfile(
            version: BehaviorProfile.currentVersion,
            windowStart: date,
            windowEnd: date,
            sampleCount: 5,
            effectiveSampleSize: 5,
            confidence: .medium,
            insights: [],
            classifications: [known]
        )
        let encoded = try JSONEncoder().encode(profile)
        var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var classifications = try #require(payload["classifications"] as? [[String: Any]])
        classifications.append([
            "dimension": "futureDimension",
            "label": "futureLabel",
            "confidence": BehaviorConfidence.high.rawValue,
            "evidence": []
        ])
        payload["classifications"] = classifications
        let decoded = try JSONDecoder().decode(
            BehaviorProfile.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
        #expect(decoded.classifications == [known])

        payload.removeValue(forKey: "classifications")
        let legacy = try JSONDecoder().decode(
            BehaviorProfile.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
        #expect(legacy.classifications.isEmpty)
    }
}
