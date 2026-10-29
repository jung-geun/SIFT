import Foundation
import SwiftData

/// Todo 상태와 typed transition event를 결정론적으로 분석합니다.
/// 결과는 모든 지원 기기에서 동일하며 사용자 적용 후 SwiftData에 저장됩니다.

/// 포그라운드 패턴 분석 결과를 사용자 확인 전까지 임시 보관하는 구조체.
struct MemoryAnalysisResult {
    let summary: String
    let insights: [String]
    let fastTags: [String]
    let overdueRate: Double
    let productiveHour: Int?
    let analyzedCompletedCount: Int
    let recordTitle: String
    let accessScopeSummary: String
    let processorDescription: String
    let behaviorProfile: BehaviorProfile
}

/// AFM can improve only the prose accompanying deterministic behavior statistics.
struct BehaviorNarrative: Equatable, Sendable {
    let summary: String
    let insights: [String]
}

/// Keeps behavior statistics deterministic while optionally enriching their user-visible narrative.
struct BehaviorNarrationService {
    typealias NarrativeProvider = @Sendable (
        _ baseline: MemoryAnalysisResult,
        _ language: AppLanguage
    ) async throws -> BehaviorNarrative
    typealias RoutingDecisionProvider = @MainActor @Sendable () -> ProviderRoutingDecision
    typealias AvailabilityProvider = () -> Bool

    private let narrativeProvider: NarrativeProvider
    private let localNarrativeProvider: NarrativeProvider
    private let routingDecisionProvider: RoutingDecisionProvider
    private let availabilityProvider: AvailabilityProvider

    init(
        narrativeProvider: @escaping NarrativeProvider = Self.liveNarrative,
        routingDecisionProvider: @escaping RoutingDecisionProvider = {
            BetaFeaturePolicy().routingDecision(for: .personalNarrative)
        },
        availabilityProvider: @escaping AvailabilityProvider = {
            FoundationModelsAvailability.isAvailable
        },
        localNarrativeProvider: @escaping NarrativeProvider = { baseline, language in
            try await LocalNarrativeService.behavior(baseline: baseline, language: language)
        }
    ) {
        self.narrativeProvider = narrativeProvider
        self.localNarrativeProvider = localNarrativeProvider
        self.routingDecisionProvider = routingDecisionProvider
        self.availabilityProvider = availabilityProvider
    }

    func enrich(
        _ baseline: MemoryAnalysisResult,
        language: AppLanguage,
        tier: OpenAIAnalysisTier = .basic
    ) async throws -> MemoryAnalysisResult {
        if tier == .advanced {
            let narrative = try await OpenAIAnalysisService().behavior(baseline, tier: tier, language: language)
            return enriched(baseline, narrative: narrative, processor: "OpenAI · \(tier.modelID) · deterministic metrics")
        }
        let route = routingDecisionProvider()
        let usesLocalModel = route == .providers([.onDevice])
        guard usesLocalModel || (route == .providers([.foundationModels]) && availabilityProvider()) else {
            return baseline
        }
        do {
            let narrative = try await (usesLocalModel ? localNarrativeProvider : narrativeProvider)(baseline, language)
            return enriched(baseline, narrative: narrative,
                processor: usesLocalModel ? "On-device model · deterministic metrics" : "Apple Intelligence · deterministic metrics")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return baseline
        }
    }

    private func enriched(_ baseline: MemoryAnalysisResult, narrative: BehaviorNarrative, processor: String) -> MemoryAnalysisResult {
        let summary = narrative.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return baseline }
        let insights = narrative.insights.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return MemoryAnalysisResult(
            summary: summary,
            insights: insights.isEmpty ? baseline.insights : Array(insights.prefix(4)),
            fastTags: baseline.fastTags,
            overdueRate: baseline.overdueRate,
            productiveHour: baseline.productiveHour,
            analyzedCompletedCount: baseline.analyzedCompletedCount,
            recordTitle: baseline.recordTitle,
            accessScopeSummary: baseline.accessScopeSummary,
            processorDescription: processor,
            behaviorProfile: baseline.behaviorProfile
        )
    }

    private static func liveNarrative(
        baseline: MemoryAnalysisResult,
        language: AppLanguage
    ) async throws -> BehaviorNarrative {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), FoundationModelsAvailability.isAvailable else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .foundationModels,
                reason: RuleFallbackReason.unavailable.rawValue
            )
        }
        return try await FoundationModelsService().narrateBehavior(
            baseline: baseline,
            language: language
        )
        #else
        throw IntelligenceRoutingError.backendUnavailable(
            provider: .foundationModels,
            reason: RuleFallbackReason.unavailable.rawValue
        )
        #endif
    }
}


enum BehaviorAnalysisContextBuilder {
    static func make(
        todos: [Todo],
        auditEvents: [TaskAuditEvent],
        behaviorEvents: [TaskBehaviorEvent],
        now: Date,
        calendar: Calendar,
        behaviorProfile: BehaviorProfile = .empty(),
        personaTypes: [PersonaType] = []
    ) -> BehaviorAnalysisContext {
        // Apply the source boundary before snapshots discard provenance. Health
        // transitions/deletions are never recorded, so deleted tasks need no flag.
        let excludedTodoIDs = Set(todos.lazy.filter(\.isHealthRelated).map(\.id))
        let liveSnapshots = todos.compactMap { todo -> BehaviorTodoSnapshot? in
            guard !excludedTodoIDs.contains(todo.id) else { return nil }
            return BehaviorTodoSnapshot(
                id: todo.id,
                createdAt: todo.createdAt,
                completedAt: todo.completedAt,
                dueDate: todo.dueDate,
                isCompleted: todo.isCompleted,
                triage: TodoTriage(rawValue: todo.triageStatus) ?? .todo,
                tags: todo.tags.map(UserVocabularyService.normalizedKey).filter { !$0.isEmpty },
                observationDate: todo.updatedAt,
                isDeleted: false
            )
        }
        let deletedSnapshots = auditEvents.compactMap { event -> BehaviorTodoSnapshot? in
            guard !excludedTodoIDs.contains(event.todoID) else { return nil }
            return BehaviorTodoSnapshot(
                id: event.todoID,
                createdAt: event.createdAt,
                completedAt: event.completedAt,
                dueDate: event.dueDate,
                isCompleted: event.completedAt != nil,
                triage: TodoTriage(rawValue: event.triageType) ?? .todo,
                tags: event.tags.map(UserVocabularyService.normalizedKey).filter { !$0.isEmpty },
                observationDate: event.deletedAt,
                isDeleted: true
            )
        }
        let eventSnapshots = behaviorEvents.compactMap { event -> BehaviorEventSnapshot? in
            guard !excludedTodoIDs.contains(event.todoID) else { return nil }
            return BehaviorEventSnapshot(
                todoID: event.todoID,
                kind: event.eventType,
                timestamp: event.occurredAt,
                actorRawValue: event.actorRaw,
                triageRawValue: event.triageType,
                todoCreatedAt: event.todoCreatedAt,
                beforeCompletion: event.beforeCompletion,
                afterCompletion: event.afterCompletion,
                beforeDueDate: event.beforeDueDate,
                afterDueDate: event.afterDueDate,
                beforeManualPriority: event.beforeManualPriority,
                afterManualPriority: event.afterManualPriority
            )
        }
        return BehaviorAnalysisContext(
            now: now,
            calendar: calendar,
            events: eventSnapshots,
            todos: liveSnapshots + deletedSnapshots,
            behaviorProfile: behaviorProfile,
            personaTypes: personaTypes
        )
    }
}

final class MemoryService {

    static let shared = MemoryService()
    private init() {}

    // MARK: - SwiftData Cache

    private let cacheLock = NSLock()
    private var cachedAnalysis: MemoryAnalysis?
    private var lastFetchTime: Date = .distantPast

    func invalidateCache() {
        cacheLock.lock()
        cachedAnalysis = nil
        lastFetchTime = .distantPast
        cacheLock.unlock()
    }

    private var latestAnalysis: MemoryAnalysis? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let now = Date()
        if now.timeIntervalSince(lastFetchTime) < 5 {
            return cachedAnalysis
        }

        do {
            let context = ModelContext(AppDataContainer.shared.container)
            var descriptor = FetchDescriptor<MemoryAnalysis>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            descriptor.fetchLimit = 1
            cachedAnalysis = try context.fetch(descriptor).first
            lastFetchTime = now
        } catch {
            print("[MemoryService] SwiftData fetch 실패: \(error)")
        }
        return cachedAnalysis
    }

    // MARK: - Stored State

    var summary: String {
        latestAnalysis?.summary ?? ""
    }

    var insights: [String] {
        latestAnalysis?.insights ?? []
    }

    var lastAnalysisDate: Date? {
        latestAnalysis?.createdAt
    }

    /// 충분한 근거가 있는 생성→완료 경과 시간 기준의 빠른 태그.
    var fastTags: [String] {
        guard latestAnalysis?.confidence.allowsPersonalization == true else { return [] }
        return latestAnalysis?.fastTags ?? []
    }

    /// 마감일이 있는 완료 항목 중 지연된 비율. 중간 이상 신뢰도에서만 일정 보정에 사용합니다.
    var overdueRate: Double {
        guard latestAnalysis?.behaviorProfile
            .insight(for: .overdueCompletionRate)?
            .confidence.allowsPersonalization == true else { return 0 }
        return latestAnalysis?.overdueRate ?? 0
    }

    /// 완료 기록이 집중된 3시간 구간의 시작 시각. 실제 작업 시간으로 해석하지 않습니다.
    var productiveHour: Int? {
        guard latestAnalysis?.behaviorProfile
            .insight(for: .completionConcentrationHour)?
            .confidence.allowsPersonalization == true else { return nil }
        return latestAnalysis?.productiveHour
    }

    var behaviorProfile: BehaviorProfile {
        latestAnalysis?.behaviorProfile ?? .empty()
    }

    // MARK: - Analysis

    static func computeAnalysis(
        todos: [Todo],
        auditEvents: [TaskAuditEvent] = [],
        behaviorEvents: [TaskBehaviorEvent] = [],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        language: AppLanguage = .current
    ) -> MemoryAnalysisResult {
        let context = BehaviorAnalysisContextBuilder.make(
            todos: todos,
            auditEvents: auditEvents,
            behaviorEvents: behaviorEvents,
            now: now,
            calendar: calendar
        )
        return computeAnalysis(context: context, language: language)
    }

    static func computeAnalysis(
        context: BehaviorAnalysisContext,
        language: AppLanguage = .current
    ) -> MemoryAnalysisResult {
        BehaviorAnalysisEngine.compute(context: context, language: language)
    }





    // MARK: - Foreground Preview (사용자 확인 후 적용)

    /// 포그라운드 전용 — 분석만 수행하고 UserDefaults에 저장하지 않는다.
    /// UI에서 미리보기를 보여주고 사용자가 확인하면 `applyAnalysisResult(_:)` 로 저장.
    func analyzeForegroundPreview(
        todos: [Todo],
        auditEvents: [TaskAuditEvent] = [],
        behaviorEvents: [TaskBehaviorEvent] = [],
        tier: OpenAIAnalysisTier = .basic
    ) async throws -> MemoryAnalysisResult {
        let baseline = Self.computeAnalysis(
            todos: todos,
            auditEvents: auditEvents,
            behaviorEvents: behaviorEvents
        )
        return try await BehaviorNarrationService().enrich(
            baseline,
            language: .current,
            tier: tier
        )
    }

    /// 미리보기로 생성된 분석 결과를 저장한다.
    /// 사용자가 "적용" 버튼을 누른 후에만 호출.
    func applyAnalysisResult(_ result: MemoryAnalysisResult) async throws {
        try save(result)
    }

    func deleteAnalysis(_ analysis: MemoryAnalysis, context: ModelContext) {
        do {
            context.delete(analysis)
            try context.save()
            invalidateCache()
        } catch {
            DiagnosticRecorder.shared.record(
                error: error,
                component: "storage.swiftdata",
                operation: "memoryDelete"
            )
            print("[MemoryService] SwiftData 삭제 실패: \(error)")
        }
    }

    // MARK: - Persistence

    private func save(_ result: MemoryAnalysisResult) throws {
        let analysis = MemoryAnalysis(
            summary: result.summary,
            insights: result.insights,
            fastTags: result.fastTags,
            overdueRate: result.overdueRate,
            productiveHour: result.productiveHour,
            recordTitle: result.recordTitle,
            accessScopeSummary: result.accessScopeSummary,
            processorDescription: result.processorDescription,
            behaviorProfile: result.behaviorProfile
        )
        let context = ModelContext(AppDataContainer.shared.container)
        context.insert(analysis)

        // 기존 데이터가 너무 많이 쌓이지 않도록 오래된 분석 결과 정리 (최근 5개만 유지)
        let descriptor = FetchDescriptor<MemoryAnalysis>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let allAnalyses = try context.fetch(descriptor)
        if allAnalyses.count > 5 {
            for old in allAnalyses.dropFirst(5) {
                context.delete(old)
            }
        }
        try context.save()

        cacheLock.lock()
        cachedAnalysis = analysis
        lastFetchTime = Date()
        cacheLock.unlock()
    }
}
