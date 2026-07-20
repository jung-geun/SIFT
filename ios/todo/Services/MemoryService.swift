import Foundation
import SwiftData

/// Todo 상태와 typed transition event를 결정론적으로 분석합니다.
/// 결과는 모든 지원 기기에서 동일하며 사용자 적용 후 SwiftData에 저장됩니다.

/// 포그라운드 패턴 분석 결과를 사용자 확인 전까지 임시 보관하는 구조체.
struct MemoryAnalysisResult {
    let summary: String
    let insights: [String]
    let fastTags: Set<String>
    let overdueRate: Double
    let productiveHour: Int?
    let analyzedCompletedCount: Int
    let recordTitle: String
    let accessScopeSummary: String
    let processorDescription: String
    let behaviorProfile: BehaviorProfile
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
    var fastTags: Set<String> {
        guard latestAnalysis?.confidence.allowsPersonalization == true else { return [] }
        return Set(latestAnalysis?.fastTags ?? [])
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
        language: AppLanguage = .current
    ) -> MemoryAnalysisResult {
        let calendar = Calendar.current
        let windowStart = now.addingTimeInterval(-90 * 24 * 3600)
        let weekOut = now.addingTimeInterval(7 * 24 * 3600)
        let isInWindow: (Date) -> Bool = { $0 >= windowStart && $0 <= now }

        let scopedTodos = todos.filter { $0.triage == .todo }
        let scopedAuditSnapshots = auditEvents.filter {
            $0.triageType == TodoTriage.todo.rawValue && isInWindow($0.deletedAt)
        }
        let scopedBehaviorEvents = behaviorEvents.filter {
            $0.triageType == TodoTriage.todo.rawValue && isInWindow($0.occurredAt)
        }
        let completed = scopedTodos.filter {
            $0.isCompleted && $0.completedAt.map(isInWindow) == true
        }
        let completedAuditSnapshots = auditEvents.filter {
            $0.triageType == TodoTriage.todo.rawValue && $0.completedAt.map(isInWindow) == true
        }

        let liveCompletionRecords = completed.compactMap { todo -> (createdAt: Date, completedAt: Date)? in
            guard let completedAt = todo.completedAt else { return nil }
            return (todo.createdAt, completedAt)
        }
        let deletedCompletionRecords = completedAuditSnapshots.compactMap { event -> (createdAt: Date, completedAt: Date)? in
            guard let completedAt = event.completedAt else { return nil }
            return (event.createdAt, completedAt)
        }
        let completionRecords = liveCompletionRecords + deletedCompletionRecords
        let completedDates = completionRecords.map(\.completedAt)
        let completionWeights = completedDates.map {
            Self.decayWeight(for: $0, relativeTo: now, halfLifeDays: 21)
        }
        let completionEffectiveSampleSize = Self.effectiveSampleSize(weights: completionWeights)
        let completionConfidence = Self.behaviorConfidence(
            rawCount: completedDates.count,
            weights: completionWeights
        )

        let evidenceDates = completedDates
            + scopedAuditSnapshots.map(\.deletedAt)
            + scopedBehaviorEvents.map(\.occurredAt)
            + scopedTodos.filter { isInWindow($0.updatedAt) }.map(\.updatedAt)
        let evidenceWeights = evidenceDates.map {
            Self.decayWeight(for: $0, relativeTo: now, halfLifeDays: 21)
        }
        let overallEffectiveSampleSize = Self.effectiveSampleSize(weights: evidenceWeights)
        let overallConfidence = Self.behaviorConfidence(
            rawCount: evidenceDates.count,
            weights: evidenceWeights
        )

        var lines: [String] = []
        var textualInsights: [String] = []
        var structuredInsights: [BehaviorInsight] = []
        func copy(_ korean: String, _ english: String) -> String {
            language == .english ? english : korean
        }
        var detectedCompletionHour: Int?
        var computedOverdueRate = 0.0

        func appendRateInsight(
            metric: BehaviorMetric,
            successes: Int,
            total: Int,
            successDates: [Date] = [],
            totalDates: [Date] = [],
            evidence: String,
            includeInText: Bool = true
        ) {
            guard total > 0 else { return }
            let hasTemporalEvidence = successDates.count == successes && totalDates.count == total
            let totalWeights = hasTemporalEvidence
                ? totalDates.map { Self.decayWeight(for: $0, relativeTo: now, halfLifeDays: 21) }
                : Array(repeating: 1, count: total)
            let successWeight = hasTemporalEvidence
                ? successDates.reduce(0) {
                    $0 + Self.decayWeight(for: $1, relativeTo: now, halfLifeDays: 21)
                }
                : Double(successes)
            let totalWeight = totalWeights.reduce(0, +)
            let effectiveSupport = Self.effectiveSampleSize(weights: totalWeights)
            let confidence = Self.behaviorConfidence(
                rawCount: total,
                weights: totalWeights
            )
            structuredInsights.append(
                BehaviorInsight(
                    metric: metric,
                    value: Self.smoothedRate(
                        successes: min(successWeight, totalWeight),
                        total: totalWeight
                    ),
                    numerator: successes,
                    denominator: total,
                    effectiveSampleSize: effectiveSupport,
                    confidence: confidence,
                    windowStart: windowStart,
                    windowEnd: now,
                    previousValue: nil,
                    trend: .unavailable,
                    evidence: evidence
                )
            )
            if includeInText, total >= 5, confidence != .insufficient {
                textualInsights.append(evidence)
            }
        }

        // Completion records indicate check-off concentration, not actual work time.
        if !completedDates.isEmpty {
            var blockWeights: [Int: Double] = [:]
            var blockCounts: [Int: Int] = [:]
            for (date, weight) in zip(completedDates, completionWeights) {
                let blockStart = (calendar.component(.hour, from: date) / 3) * 3
                blockWeights[blockStart, default: 0] += weight
                blockCounts[blockStart, default: 0] += 1
            }
            if let top = blockWeights.sorted(by: {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }).first {
                let blockStart = top.key
                let rawCount = blockCounts[blockStart, default: 0]
                let evidence = completionConfidence == .insufficient
                    ? copy(
                        "최근 90일 완료 기록 \(completedDates.count)건으로 시간대 경향을 판단하기에는 데이터가 부족함",
                        "There is not enough data from \(completedDates.count) completions in the last 90 days to infer a time-of-day trend."
                    )
                    : copy(
                        "최근 90일 완료 기록은 \(blockStart)시~\(min(24, blockStart + 3))시에 가장 많이 집중됨 (\(rawCount)/\(completedDates.count)건)",
                        "Completions in the last 90 days were most concentrated from \(blockStart):00 to \(min(24, blockStart + 3)):00 (\(rawCount)/\(completedDates.count))."
                    )
                structuredInsights.append(
                    BehaviorInsight(
                        metric: .completionConcentrationHour,
                        value: Double(blockStart),
                        numerator: rawCount,
                        denominator: completedDates.count,
                        effectiveSampleSize: completionEffectiveSampleSize,
                        confidence: completionConfidence,
                        windowStart: windowStart,
                        windowEnd: now,
                        previousValue: nil,
                        trend: .unavailable,
                        evidence: evidence
                    )
                )
                if completionConfidence == .insufficient {
                    lines.append(evidence)
                } else {
                    detectedCompletionHour = blockStart
                    lines.append(
                        copy(
                            "완료 기록 집중 시간: \(blockStart)시~\(min(24, blockStart + 3))시 (\(rawCount)/\(completedDates.count)건, \(completionConfidence.label))",
                            "Completion concentration: \(blockStart):00–\(min(24, blockStart + 3)):00 (\(rawCount)/\(completedDates.count), \(completionConfidence.label(language: language))."
                        )
                    )
                    textualInsights.append(evidence)
                }
            }

            let weekdayCounts = Dictionary(
                grouping: completedDates,
                by: { calendar.component(.weekday, from: $0) }
            ).mapValues(\.count)
            if completionConfidence != .insufficient,
               let top = weekdayCounts.sorted(by: {
                   $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
               }).first {
                lines.append(
                    copy(
                        "완료 기록 집중 요일: \(Self.weekdayLabel(top.key, language: language))요일 (\(top.value)/\(completedDates.count)건)",
                        "Completion concentration by weekday: \(Self.weekdayLabel(top.key, language: language)) (\(top.value)/\(completedDates.count))."
                    )
                )
            }
        }

        // Current Todo state and user-deletion snapshots are separate observation sets.
        if !scopedTodos.isEmpty {
            let currentCompletedCount = scopedTodos.filter(\.isCompleted).count
            let evidence = copy(
                "현재 보유 TODO 완료 상태: \(currentCompletedCount)/\(scopedTodos.count)건",
                "Current to-do completion state: \(currentCompletedCount)/\(scopedTodos.count)."
            )
            lines.append(evidence)
            appendRateInsight(
                metric: .currentCompletionShare,
                successes: currentCompletedCount,
                total: scopedTodos.count,
                evidence: evidence,
                includeInText: false
            )
        }

        if !scopedAuditSnapshots.isEmpty {
            let completedBeforeDeletion = scopedAuditSnapshots.filter { $0.completedAt != nil }.count
            let evidence = copy(
                "최근 90일 사용자 삭제 스냅샷 중 완료 후 삭제: \(completedBeforeDeletion)/\(scopedAuditSnapshots.count)건",
                "Among user-deletion snapshots from the last 90 days, completed before deletion: \(completedBeforeDeletion)/\(scopedAuditSnapshots.count)."
            )
            lines.append(evidence)
            appendRateInsight(
                metric: .deletedCompletedShare,
                successes: completedBeforeDeletion,
                total: scopedAuditSnapshots.count,
                successDates: scopedAuditSnapshots
                    .filter { $0.completedAt != nil }
                    .map(\.deletedAt),
                totalDates: scopedAuditSnapshots.map(\.deletedAt),
                evidence: evidence,
                includeInText: false
            )
            structuredInsights.append(
                BehaviorInsight(
                    metric: .deletedSnapshotCount,
                    value: Double(scopedAuditSnapshots.count),
                    numerator: scopedAuditSnapshots.count,
                    denominator: scopedAuditSnapshots.count,
                    effectiveSampleSize: Double(scopedAuditSnapshots.count),
                    confidence: BehaviorConfidence.classify(
                        effectiveSampleSize: Double(scopedAuditSnapshots.count)
                    ),
                    windowStart: windowStart,
                    windowEnd: now,
                    previousValue: nil,
                    trend: .unavailable,
                    evidence: copy(
                        "최근 90일 사용자 주도 삭제 스냅샷 \(scopedAuditSnapshots.count)건",
                        "\(scopedAuditSnapshots.count) user-deletion snapshots in the last 90 days."
                    )
                )
            )
        }

        // Lifecycle elapsed time. This is not active work duration.
        if !completionRecords.isEmpty {
            let elapsedValues = zip(completionRecords, completionWeights).map {
                (
                    value: max(0, $0.0.completedAt.timeIntervalSince($0.0.createdAt) / 3600),
                    weight: $0.1
                )
            }
            let weightedElapsed = Self.weightedMean(elapsedValues)
            lines.append(
                copy(
                    "생성 후 완료까지 경과 시간 가중 평균: \(Self.formatHours(weightedElapsed, language: language))",
                    "Weighted elapsed time from creation to completion: \(Self.formatHours(weightedElapsed, language: language))."
                )
            )
        }

        // Tag elapsed-time medians require at least five recent records per tag.
        var tagElapsed: [String: [(value: Double, weight: Double)]] = [:]
        for todo in completed {
            guard let completedAt = todo.completedAt else { continue }
            let elapsed = max(0, completedAt.timeIntervalSince(todo.createdAt) / 3600)
            let weight = Self.decayWeight(for: completedAt, relativeTo: now, halfLifeDays: 21)
            for tag in todo.tags where !tag.isEmpty {
                tagElapsed[tag, default: []].append((elapsed, weight))
            }
        }
        let eligibleTagMedians = tagElapsed
            .filter { $0.value.count >= 5 }
            .mapValues(Self.weightedMedian)
        if eligibleTagMedians.count >= 2,
           let fastest = eligibleTagMedians.min(by: { $0.value < $1.value }),
           let slowest = eligibleTagMedians.max(by: { $0.value < $1.value }),
           fastest.key != slowest.key {
            lines.append(
                copy(
                    "생성→완료 경과가 짧은 태그: '\(fastest.key)' 중앙값 \(Self.formatHours(fastest.value, language: language)) / 긴 태그: '\(slowest.key)' 중앙값 \(Self.formatHours(slowest.value, language: language))",
                    "Shortest creation-to-completion tag: '\(fastest.key)' median \(Self.formatHours(fastest.value, language: language)); longest: '\(slowest.key)' median \(Self.formatHours(slowest.value, language: language))."
                )
            )
            textualInsights.append(
                copy(
                    "최근 기록에서 '\(fastest.key)' 태그의 생성 후 완료까지 경과 시간이 '\(slowest.key)' 태그보다 짧았음",
                    "Recent records show shorter creation-to-completion time for '\(fastest.key)' than '\(slowest.key)'."
                )
            )
        }
        let overallTagMedian = Self.median(Array(eligibleTagMedians.values))
        let fastTagSet = overallTagMedian > 0
            ? Set(eligibleTagMedians.filter { $0.value < overallTagMedian }.keys)
            : []

        // Due-date adherence uses only completed live Todos that actually have a due date.
        let dueDateCompleted = completed.compactMap { todo -> (due: Date, completedAt: Date)? in
            guard let due = todo.dueDate, let completedAt = todo.completedAt else { return nil }
            return (due, completedAt)
        }
        let earlyCount = dueDateCompleted.filter { $0.completedAt < $0.due }.count
        let onTimeCount = dueDateCompleted.filter {
            calendar.isDate($0.completedAt, equalTo: $0.due, toGranularity: .minute)
        }.count
        let lateCount = dueDateCompleted.count - earlyCount - onTimeCount
        if !dueDateCompleted.isEmpty {
            let evidence = copy(
                "마감이 있는 최근 완료 기록: 조기 \(earlyCount)건 / 정시 \(onTimeCount)건 / 지연 \(lateCount)건",
                "Recent due-dated completions: early \(earlyCount) / on time \(onTimeCount) / late \(lateCount)."
            )
            lines.append(evidence)
            let lateDates = dueDateCompleted
                .filter { $0.completedAt > $0.due }
                .map(\.completedAt)
            let dueCompletionDates = dueDateCompleted.map(\.completedAt)
            appendRateInsight(
                metric: .overdueCompletionRate,
                successes: lateCount,
                total: dueDateCompleted.count,
                successDates: lateDates,
                totalDates: dueCompletionDates,
                evidence: evidence
            )
            let dueWeights = dueCompletionDates.map {
                Self.decayWeight(for: $0, relativeTo: now, halfLifeDays: 21)
            }
            let confidence = Self.behaviorConfidence(
                rawCount: dueDateCompleted.count,
                weights: dueWeights
            )
            if confidence.allowsPersonalization {
                let lateWeight = lateDates.reduce(0) {
                    $0 + Self.decayWeight(for: $1, relativeTo: now, halfLifeDays: 21)
                }
                computedOverdueRate = Self.smoothedRate(
                    successes: lateWeight,
                    total: dueWeights.reduce(0, +)
                )
            }
        }

        let leadTimeValues = completed.compactMap { todo -> Double? in
            guard let due = todo.dueDate, due > todo.createdAt else { return nil }
            return due.timeIntervalSince(todo.createdAt) / 3600
        }
        if !leadTimeValues.isEmpty {
            lines.append(
                copy(
                    "생성→마감 리드타임 평균: \(Self.formatHours(leadTimeValues.reduce(0, +) / Double(leadTimeValues.count), language: .korean))",
                    "Average creation-to-deadline lead time: \(Self.formatHours(leadTimeValues.reduce(0, +) / Double(leadTimeValues.count), language: language))."
                )
            )
        }

        let nearTermBacklog = scopedTodos.filter { todo in
            guard !todo.isCompleted, let due = todo.dueDate else { return false }
            return due >= now && due <= weekOut
        }.count
        if nearTermBacklog > 0 {
            let activeCount = scopedTodos.filter { !$0.isCompleted }.count
            let evidence = copy(
                "향후 7일 내 마감 미완료 TODO \(nearTermBacklog)건",
                "\(nearTermBacklog) incomplete to-dos are due within the next 7 days."
            )
            lines.append(evidence)
            textualInsights.append(evidence)
            structuredInsights.append(
                BehaviorInsight(
                    metric: .nearTermBacklog,
                    value: Double(nearTermBacklog),
                    numerator: nearTermBacklog,
                    denominator: activeCount,
                    effectiveSampleSize: Double(activeCount),
                    confidence: BehaviorConfidence.classify(effectiveSampleSize: Double(activeCount)),
                    windowStart: windowStart,
                    windowEnd: now,
                    previousValue: nil,
                    trend: .unavailable,
                    evidence: evidence
                )
            )
        }

        // Typed transition metrics. Claims are withheld until the denominator reaches five.
        let observedTodoCount = Set(scopedBehaviorEvents.map(\.todoID)).count
        if observedTodoCount > 0 {
            func latestDatesByTodo(_ events: [TaskBehaviorEvent]) -> [Date] {
                Dictionary(grouping: events, by: \.todoID)
                    .values
                    .compactMap { group in group.map(\.occurredAt).max() }
            }

            let observedDates = latestDatesByTodo(scopedBehaviorEvents)
            let userCompletionEvents = scopedBehaviorEvents
                .filter { $0.eventType == .completionChanged && $0.actor == .user }
                .sorted { $0.occurredAt < $1.occurredAt }
            let completionEvents = userCompletionEvents.filter { $0.afterCompletion == true }
            var availableCompletions: [UUID: Int] = [:]
            var pairedUndoEvents: [TaskBehaviorEvent] = []
            for event in userCompletionEvents {
                if event.beforeCompletion == false, event.afterCompletion == true {
                    availableCompletions[event.todoID, default: 0] += 1
                } else if event.beforeCompletion == true,
                          event.afterCompletion == false,
                          availableCompletions[event.todoID, default: 0] > 0 {
                    availableCompletions[event.todoID, default: 0] -= 1
                    pairedUndoEvents.append(event)
                }
            }
            appendRateInsight(
                metric: .completionUndoRate,
                successes: pairedUndoEvents.count,
                total: completionEvents.count,
                successDates: pairedUndoEvents.map(\.occurredAt),
                totalDates: completionEvents.map(\.occurredAt),
                evidence: copy(
                    "사용자 완료 전환 \(completionEvents.count)건 중 같은 관찰 기간 내 완료 취소 \(pairedUndoEvents.count)건",
                    "\(pairedUndoEvents.count) completion undos among \(completionEvents.count) user completion changes in the same observation window."
                )
            )

            let userDueChangeEvents = scopedBehaviorEvents.filter {
                $0.eventType == .dueDateChanged && $0.actor == .user
            }
            let dueChangeDates = latestDatesByTodo(userDueChangeEvents)
            let dueChangedTodoCount = dueChangeDates.count
            appendRateInsight(
                metric: .dueDateChangeRate,
                successes: dueChangedTodoCount,
                total: observedTodoCount,
                successDates: dueChangeDates,
                totalDates: observedDates,
                evidence: copy(
                    "변경 이벤트가 관찰된 TODO \(observedTodoCount)건 중 사용자가 마감일을 변경한 TODO \(dueChangedTodoCount)건",
                    "\(dueChangedTodoCount) of \(observedTodoCount) observed to-dos had a user due-date change."
                )
            )

            let manualPriorityEvents = scopedBehaviorEvents.filter {
                $0.eventType == .priorityChanged
                    && $0.actor == .user
                    && ($0.beforeManualPriority != nil || $0.afterManualPriority != nil)
            }
            let manualPriorityDates = latestDatesByTodo(manualPriorityEvents)
            let manuallyPrioritizedTodoCount = manualPriorityDates.count
            appendRateInsight(
                metric: .manualPriorityChangeRate,
                successes: manuallyPrioritizedTodoCount,
                total: observedTodoCount,
                successDates: manualPriorityDates,
                totalDates: observedDates,
                evidence: copy(
                    "변경 이벤트가 관찰된 TODO \(observedTodoCount)건 중 사용자가 우선순위를 변경한 TODO \(manuallyPrioritizedTodoCount)건",
                    "\(manuallyPrioritizedTodoCount) of \(observedTodoCount) observed to-dos had a user priority change."
                )
            )

            let priorityEvents = scopedBehaviorEvents
                .filter { $0.eventType == .priorityChanged }
                .sorted { $0.occurredAt < $1.occurredAt }
            let aiPriorityEvents = priorityEvents.filter { $0.actor == .artificialIntelligence }
            let overriddenAIEvents = aiPriorityEvents.filter { aiEvent in
                priorityEvents.contains { laterEvent in
                    laterEvent.todoID == aiEvent.todoID
                        && laterEvent.actor == .user
                        && laterEvent.occurredAt > aiEvent.occurredAt
                        && laterEvent.occurredAt.timeIntervalSince(aiEvent.occurredAt) <= 24 * 3600
                }
            }
            appendRateInsight(
                metric: .aiOverrideRate,
                successes: overriddenAIEvents.count,
                total: aiPriorityEvents.count,
                successDates: overriddenAIEvents.map(\.occurredAt),
                totalDates: aiPriorityEvents.map(\.occurredAt),
                evidence: copy(
                    "AI 우선순위 변경 \(aiPriorityEvents.count)건 중 24시간 내 사용자 재변경 \(overriddenAIEvents.count)건",
                    "\(overriddenAIEvents.count) user overrides within 24 hours among \(aiPriorityEvents.count) AI priority changes."
                )
            )
        }

        let profile = BehaviorProfile(
            version: BehaviorProfile.currentVersion,
            windowStart: windowStart,
            windowEnd: now,
            sampleCount: evidenceDates.count,
            effectiveSampleSize: overallEffectiveSampleSize,
            confidence: overallConfidence,
            insights: structuredInsights
        )
        let accessScopeSummary = "분석 범위: 현재 TODO \(scopedTodos.count)개, 최근 사용자 삭제 스냅샷 \(scopedAuditSnapshots.count)개, typed 변경 이벤트 \(scopedBehaviorEvents.count)개, 최근 완료 기록 \(completionRecords.count)개"

        return MemoryAnalysisResult(
            summary: lines.joined(separator: "\n"),
            insights: Array(textualInsights.prefix(8)),
            fastTags: fastTagSet,
            overdueRate: computedOverdueRate,
            productiveHour: detectedCompletionHour,
            analyzedCompletedCount: completionRecords.count,
            recordTitle: copy("행동 패턴 분석", "Behavior Pattern Analysis"),
            accessScopeSummary: copy(
                "분석 범위: 현재 TODO \(scopedTodos.count)개, 최근 사용자 삭제 스냅샷 \(scopedAuditSnapshots.count)개, typed 변경 이벤트 \(scopedBehaviorEvents.count)개, 최근 완료 기록 \(completionRecords.count)개",
                "Scope: \(scopedTodos.count) current to-dos, \(scopedAuditSnapshots.count) recent user-deletion snapshots, \(scopedBehaviorEvents.count) typed change events, and \(completionRecords.count) recent completions."
            ),
            processorDescription: copy("통계 기반(결정론적)", "Statistical (deterministic)"),
            behaviorProfile: profile
        )
    }



    private static nonisolated func decayWeight(
        for date: Date,
        relativeTo now: Date,
        halfLifeDays: Double
    ) -> Double {
        let ageDays = max(0, now.timeIntervalSince(date) / (24 * 3600))
        return pow(2, -ageDays / halfLifeDays)
    }

    private static nonisolated func effectiveSampleSize(weights: [Double]) -> Double {
        let sum = weights.reduce(0, +)
        let squaredSum = weights.reduce(0) { $0 + $1 * $1 }
        guard squaredSum > 0 else { return 0 }
        return sum * sum / squaredSum
    }

    private static nonisolated func behaviorConfidence(
        rawCount: Int,
        weights: [Double]
    ) -> BehaviorConfidence {
        let kishSupport = effectiveSampleSize(weights: weights)
        let decayedMass = weights.reduce(0, +)
        let ageSensitiveSupport = min(kishSupport, decayedMass)
        let thresholdSupport = rawCount >= 5 && ageSensitiveSupport >= 4.5
            ? max(5, ageSensitiveSupport)
            : ageSensitiveSupport
        return BehaviorConfidence.classify(effectiveSampleSize: thresholdSupport)
    }

    private static nonisolated func smoothedRate(successes: Double, total: Double) -> Double {
        guard total >= 0 else { return 0.5 }
        return (successes + 2) / (total + 4)
    }

    private static nonisolated func weightedMean(
        _ values: [(value: Double, weight: Double)]
    ) -> Double {
        let totalWeight = values.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return 0 }
        return values.reduce(0) { $0 + $1.value * $1.weight } / totalWeight
    }

    private static nonisolated func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static nonisolated func weightedMedian(
        _ values: [(value: Double, weight: Double)]
    ) -> Double {
        let sorted = values.sorted { $0.value < $1.value }
        let threshold = sorted.reduce(0) { $0 + $1.weight } / 2
        var cumulative = 0.0
        for item in sorted {
            cumulative += item.weight
            if cumulative >= threshold {
                return item.value
            }
        }
        return sorted.last?.value ?? 0
    }

    private static func weekdayLabel(
        _ weekday: Int,
        language: AppLanguage = .current
    ) -> String {
        let korean = ["", "일", "월", "화", "수", "목", "금", "토"]
        let english = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        guard korean.indices.contains(weekday) else { return "\(weekday)" }
        return language == .english ? english[weekday] : korean[weekday]
    }

    private static func formatHours(
        _ hours: Double,
        language: AppLanguage = .current
    ) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = hours < 24
            ? [.hour]
            : hours.truncatingRemainder(dividingBy: 24) == 0
                ? [.day]
                : [.day, .hour]
        formatter.unitsStyle = .full
        formatter.collapsesLargestUnit = false
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.calendar?.locale = language.locale
        return formatter.string(from: max(0, hours) * 3600) ?? "\(max(0, Int(hours.rounded())))"
    }


    // MARK: - Foreground Preview (사용자 확인 후 적용)

    /// 포그라운드 전용 — 분석만 수행하고 UserDefaults에 저장하지 않는다.
    /// UI에서 미리보기를 보여주고 사용자가 확인하면 `applyAnalysisResult(_:)` 로 저장.
    func analyzeForegroundPreview(
        todos: [Todo],
        auditEvents: [TaskAuditEvent] = [],
        behaviorEvents: [TaskBehaviorEvent] = []
    ) async throws -> MemoryAnalysisResult {
        Self.computeAnalysis(
            todos: todos,
            auditEvents: auditEvents,
            behaviorEvents: behaviorEvents
        )
    }

    /// 미리보기로 생성된 분석 결과를 저장한다.
    /// 사용자가 "적용" 버튼을 누른 후에만 호출.
    func applyAnalysisResult(_ result: MemoryAnalysisResult) {
        save(result)
    }

    func deleteAnalysis(_ analysis: MemoryAnalysis, context: ModelContext) {
        do {
            context.delete(analysis)
            try context.save()
            invalidateCache()
        } catch {
            print("[MemoryService] SwiftData 삭제 실패: \(error)")
        }
    }

    // MARK: - Persistence

    private func save(_ result: MemoryAnalysisResult) {
        let analysis = MemoryAnalysis(
            summary: result.summary,
            insights: result.insights,
            fastTags: Array(result.fastTags),
            overdueRate: result.overdueRate,
            productiveHour: result.productiveHour,
            recordTitle: result.recordTitle,
            accessScopeSummary: result.accessScopeSummary,
            processorDescription: result.processorDescription,
            behaviorProfile: result.behaviorProfile
        )

        do {
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

            // 저장 성공 시 캐시 갱신
            cacheLock.lock()
            cachedAnalysis = analysis
            lastFetchTime = Date()
            cacheLock.unlock()

        } catch {
            print("[MemoryService] SwiftData 저장 실패: \(error)")
        }
    }
}
