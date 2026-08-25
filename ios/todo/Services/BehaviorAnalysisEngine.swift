import Foundation

/// Pure behavior analyzer. It consumes only immutable snapshots and injected time/calendar values.
nonisolated enum BehaviorAnalysisEngine {
    private struct CompletionRecord {
        let id: UUID
        let createdAt: Date
        let completedAt: Date
        let dueDate: Date?
        let tags: [String]
        let isDeleted: Bool
    }

    static func compute(
        context: BehaviorAnalysisContext,
        language: AppLanguage
    ) -> MemoryAnalysisResult {
        let now = context.now
        let calendar = context.calendar
        let windowStart = now.addingTimeInterval(-90 * 24 * 3600)
        let weekOut = now.addingTimeInterval(7 * 24 * 3600)
        let isInWindow: (Date) -> Bool = { $0 >= windowStart && $0 <= now }
        let scopedTodos = context.todos.filter { !$0.isDeleted && $0.triage == .todo }
        let scopedAuditSnapshots = context.todos.filter {
            $0.isDeleted && $0.triage == .todo && isInWindow($0.observationDate)
        }
        let scopedEvents = context.events.filter {
            $0.triageRawValue == TodoTriage.todo.rawValue && isInWindow($0.timestamp)
        }
        func completionRecord(_ snapshot: BehaviorTodoSnapshot) -> CompletionRecord? {
            guard snapshot.triage == .todo,
                  let completedAt = snapshot.completedAt,
                  completedAt >= snapshot.createdAt,
                  completedAt <= now,
                  isInWindow(completedAt) else { return nil }
            return CompletionRecord(
                id: snapshot.id,
                createdAt: snapshot.createdAt,
                completedAt: completedAt,
                dueDate: snapshot.dueDate,
                tags: snapshot.tags,
                isDeleted: snapshot.isDeleted
            )
        }
        let allCompletionRecords = Dictionary(
            grouping: context.todos.compactMap(completionRecord),
            by: \.id
        ).compactMapValues { records in
            records.sorted { !$0.isDeleted && $1.isDeleted }.first
        }.map(\.value)
        let liveCompletionRecords = allCompletionRecords.filter { !$0.isDeleted }
        let completionRecords = liveCompletionRecords
        let liveCompleted = scopedTodos.filter {
            $0.isCompleted && $0.completedAt.map(isInWindow) == true
        }
        let completedDates = completionRecords.map(\.completedAt)
        let completionWeights = completedDates.map {
            decayWeight(for: $0, relativeTo: now, halfLifeDays: 21)
        }
        let completionEffectiveSampleSize = effectiveSampleSize(weights: completionWeights)
        let completionConfidence = behaviorConfidence(rawCount: completedDates.count, weights: completionWeights)
        let evidenceDates = completedDates
            + scopedAuditSnapshots.map(\.observationDate)
            + scopedEvents.map(\.timestamp)
            + scopedTodos.filter { isInWindow($0.observationDate) }.map(\.observationDate)
        let evidenceWeights = evidenceDates.map {
            decayWeight(for: $0, relativeTo: now, halfLifeDays: 21)
        }
        let overallEffectiveSampleSize = effectiveSampleSize(weights: evidenceWeights)
        let overallConfidence = behaviorConfidence(rawCount: evidenceDates.count, weights: evidenceWeights)

        var lines: [String] = []
        var textualInsights: [String] = []
        var structuredInsights: [BehaviorInsight] = []
        var detectedCompletionHour: Int?
        var computedOverdueRate = 0.0
        func copy(_ korean: String, _ english: String) -> String {
            language == .english ? english : korean
        }

        func rateTrend(successDates: [Date], totalDates: [Date]) -> (previous: Double, trend: BehaviorTrend)? {
            let recentStart = now.addingTimeInterval(-30 * 24 * 3600)
            let previousStart = now.addingTimeInterval(-60 * 24 * 3600)
            let recentTotal = totalDates.filter { $0 >= recentStart && $0 <= now }
            let previousTotal = totalDates.filter { $0 >= previousStart && $0 < recentStart }
            let recentSuccess = successDates.filter { $0 >= recentStart && $0 <= now }
            let previousSuccess = successDates.filter { $0 >= previousStart && $0 < recentStart }
            let recentWeights = recentTotal.map { decayWeight(for: $0, relativeTo: now, halfLifeDays: 21) }
            let previousWeights = previousTotal.map { decayWeight(for: $0, relativeTo: now, halfLifeDays: 21) }
            guard recentTotal.count >= 5, previousTotal.count >= 5,
                  effectiveSampleSize(weights: recentWeights) >= 4.5,
                  effectiveSampleSize(weights: previousWeights) >= 4.5 else { return nil }
            let recentRate = Double(recentSuccess.count) / Double(recentTotal.count)
            let previousRate = Double(previousSuccess.count) / Double(previousTotal.count)
            let delta = recentRate - previousRate
            let trend: BehaviorTrend = delta >= 0.15
                ? .increasing
                : delta <= -0.15 ? .decreasing : .stable
            return (previousRate, trend)
        }

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
            let weights = hasTemporalEvidence
                ? totalDates.map { decayWeight(for: $0, relativeTo: now, halfLifeDays: 21) }
                : Array(repeating: 1.0, count: total)
            let successWeight = hasTemporalEvidence
                ? successDates.reduce(0) { $0 + decayWeight(for: $1, relativeTo: now, halfLifeDays: 21) }
                : Double(successes)
            let totalWeight = weights.reduce(0, +)
            let effectiveSupport = effectiveSampleSize(weights: weights)
            let confidence = behaviorConfidence(rawCount: total, weights: weights)
            let trendData = hasTemporalEvidence
                ? rateTrend(successDates: successDates, totalDates: totalDates)
                : nil
            structuredInsights.append(
                BehaviorInsight(
                    metric: metric,
                    value: smoothedRate(successes: min(successWeight, totalWeight), total: totalWeight),
                    numerator: successes,
                    denominator: total,
                    effectiveSampleSize: effectiveSupport,
                    confidence: confidence,
                    windowStart: windowStart,
                    windowEnd: now,
                    previousValue: trendData?.previous,
                    trend: trendData?.trend ?? .unavailable,
                    evidence: evidence
                )
            )
            if includeInText, total >= 5, confidence != .insufficient {
                textualInsights.append(evidence)
            }
        }

        let eventLatencyByTask: [UUID: (value: Double, date: Date)] = Dictionary(
            grouping: scopedEvents.filter { event in
                event.kind == .completionChanged
                    && event.actorRawValue == TaskBehaviorActor.user.rawValue
                    && event.afterCompletion == true
                    && isInWindow(event.timestamp)
                    && event.todoCreatedAt.map { createdAt in createdAt <= event.timestamp } == true
            },
            by: \.todoID
        ).compactMapValues { events in
            guard let event = events.min(by: { $0.timestamp < $1.timestamp }),
                  let createdAt = event.todoCreatedAt,
                  event.timestamp <= now else { return nil }
            return (
                value: event.timestamp.timeIntervalSince(createdAt) / 3600,
                date: event.timestamp
            )
        }
        if !completedDates.isEmpty {
            var blockCounts: [Int: Int] = [:]
            for date in completedDates {
                blockCounts[(calendar.component(.hour, from: date) / 3) * 3, default: 0] += 1
            }
            if let top = blockCounts.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).first {
                let evidence = completionConfidence == .insufficient
                    ? copy(
                        "최근 90일 완료 기록 \(completedDates.count)건으로 시간대 경향을 판단하기에는 데이터가 부족함",
                        "There is not enough data from \(completedDates.count) completions in the last 90 days to infer a time-of-day trend."
                    )
                    : copy(
                        "최근 90일 완료 기록은 \(top.key)시~\(min(24, top.key + 3))시에 가장 많이 집중됨 (\(top.value)/\(completedDates.count)건)",
                        "Completions in the last 90 days were most concentrated from \(top.key):00 to \(min(24, top.key + 3)):00 (\(top.value)/\(completedDates.count))."
                    )
                structuredInsights.append(BehaviorInsight(
                    metric: .completionConcentrationHour,
                    value: Double(top.key),
                    numerator: top.value,
                    denominator: completedDates.count,
                    effectiveSampleSize: completionEffectiveSampleSize,
                    confidence: completionConfidence,
                    windowStart: windowStart,
                    windowEnd: now,
                    previousValue: nil,
                    trend: .unavailable,
                    evidence: evidence
                ))
                if completionConfidence == .insufficient {
                    lines.append(evidence)
                } else {
                    detectedCompletionHour = top.key
                    lines.append(copy(
                        "완료 기록 집중 시간: \(top.key)시~\(min(24, top.key + 3))시 (\(top.value)/\(completedDates.count)건, \(completionConfidence.label))",
                        "Completion concentration: \(top.key):00–\(min(24, top.key + 3)):00 (\(top.value)/\(completedDates.count), \(completionConfidence.label(language: language))."
                    ))
                    textualInsights.append(evidence)
                }
            }
            let timeCounts = Dictionary(grouping: completedDates) {
                (calendar.component(.hour, from: $0) / 3) * 3
            }.mapValues(\.count)
            if let top = timeCounts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) {
                structuredInsights.append(BehaviorInsight(
                    metric: .completionTimeBucketConcentration,
                    value: Double(top.value) / Double(completedDates.count),
                    numerator: top.value,
                    denominator: completedDates.count,
                    effectiveSampleSize: completionEffectiveSampleSize,
                    confidence: completionConfidence,
                    windowStart: windowStart,
                    windowEnd: now,
                    previousValue: nil,
                    trend: .unavailable,
                    evidence: copy(
                        "완료 시간대 최빈 구간 비율 \(top.value)/\(completedDates.count)",
                        "Top completion time bucket share: \(top.value)/\(completedDates.count)."
                    )
                ))
            }
            let weekdayCounts = Dictionary(grouping: completedDates) {
                calendar.component(.weekday, from: $0)
            }.mapValues(\.count)
            if let top = weekdayCounts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) {
                let second = weekdayCounts.values.sorted(by: >).dropFirst().first ?? 0
                structuredInsights.append(BehaviorInsight(
                    metric: .completionWeekdayConcentration,
                    value: Double(top.value) / Double(completedDates.count),
                    numerator: top.value,
                    denominator: completedDates.count,
                    effectiveSampleSize: completionEffectiveSampleSize,
                    confidence: completionConfidence,
                    windowStart: windowStart,
                    windowEnd: now,
                    previousValue: nil,
                    trend: .unavailable,
                    evidence: copy(
                        "완료 최빈 요일 비율 \(top.value)/\(completedDates.count), 2위 \(second)건",
                        "Top completion weekday share: \(top.value)/\(completedDates.count); runner-up \(second)."
                    )
                ))
            }
        }
        if !eventLatencyByTask.isEmpty {
            let samples = Array(eventLatencyByTask.values)
            let weights = samples.map { decayWeight(for: $0.date, relativeTo: now, halfLifeDays: 21) }
            let latency = samples.map(\.value)
            let confidence = behaviorConfidence(rawCount: latency.count, weights: weights)
            structuredInsights.append(BehaviorInsight(
                metric: .completionLatencyHours,
                value: weightedMean(zip(latency, weights).map { (value: $0.0, weight: $0.1) }),
                numerator: latency.count,
                denominator: latency.count,
                effectiveSampleSize: effectiveSampleSize(weights: weights),
                confidence: confidence,
                windowStart: windowStart,
                windowEnd: now,
                previousValue: nil,
                trend: .unavailable,
                evidence: copy(
                    "사용자 완료 이벤트에서 생성 후 완료까지 유효한 경과 시간 \(latency.count)건",
                    "\(latency.count) valid creation-to-completion latency observations from user completion events."
                )
            ))
        }

        if !scopedTodos.isEmpty {
            let currentCompleted = scopedTodos.filter(\.isCompleted).count
            let evidence = copy(
                "현재 보유 TODO 완료 상태: \(currentCompleted)/\(scopedTodos.count)건",
                "Current to-do completion state: \(currentCompleted)/\(scopedTodos.count)."
            )
            lines.append(evidence)
            appendRateInsight(metric: .currentCompletionShare, successes: currentCompleted, total: scopedTodos.count, evidence: evidence, includeInText: false)
        }
        if !scopedAuditSnapshots.isEmpty {
            let completedBeforeDeletion = scopedAuditSnapshots.filter { $0.completedAt != nil }.count
            let evidence = copy(
                "최근 90일 사용자 삭제 스냅샷 중 완료 후 삭제: \(completedBeforeDeletion)/\(scopedAuditSnapshots.count)건",
                "Among user-deletion snapshots from the last 90 days, completed before deletion: \(completedBeforeDeletion)/\(scopedAuditSnapshots.count)."
            )
            lines.append(evidence)
            let successDates = scopedAuditSnapshots.filter { $0.completedAt != nil }.map(\.observationDate)
            let totalDates = scopedAuditSnapshots.map(\.observationDate)
            appendRateInsight(metric: .deletedCompletedShare, successes: completedBeforeDeletion, total: scopedAuditSnapshots.count, successDates: successDates, totalDates: totalDates, evidence: evidence, includeInText: false)
            structuredInsights.append(BehaviorInsight(
                metric: .deletedSnapshotCount,
                value: Double(scopedAuditSnapshots.count),
                numerator: scopedAuditSnapshots.count,
                denominator: scopedAuditSnapshots.count,
                effectiveSampleSize: Double(scopedAuditSnapshots.count),
                confidence: BehaviorConfidence.classify(effectiveSampleSize: Double(scopedAuditSnapshots.count)),
                windowStart: windowStart,
                windowEnd: now,
                previousValue: nil,
                trend: .unavailable,
                evidence: copy(
                    "최근 90일 사용자 주도 삭제 스냅샷 \(scopedAuditSnapshots.count)건",
                    "\(scopedAuditSnapshots.count) user-deletion snapshots in the last 90 days."
                )
            ))
        }

        if !completionRecords.isEmpty {
            let elapsed = weightedMean(completionRecords.enumerated().map { index, record in
                (value: max(0, record.completedAt.timeIntervalSince(record.createdAt) / 3600), weight: completionWeights[index])
            })
            lines.append(copy(
                "생성 후 완료까지 경과 시간 가중 평균: \(formatHours(elapsed, language: language))",
                "Weighted elapsed time from creation to completion: \(formatHours(elapsed, language: language))."
            ))
        }

        var tagSamples: [String: [(value: Double, weight: Double)]] = [:]
        let tagRecords = allCompletionRecords
        let tagWeights = tagRecords.map {
            decayWeight(for: $0.completedAt, relativeTo: now, halfLifeDays: 21)
        }
        for (record, weight) in zip(tagRecords, tagWeights) {
            let elapsed = max(0, record.completedAt.timeIntervalSince(record.createdAt) / 3600)
            for tag in record.tags { tagSamples[tag, default: []].append((elapsed, weight)) }
        }
        let eligibleTags = tagSamples.compactMap { tag, samples -> (tag: String, sampleCount: Int, weightedLatencyHours: Double)? in
            guard samples.count >= 5 else { return nil }
            let latency = weightedMean(samples)
            guard latency < 48 else { return nil }
            return (tag, samples.count, latency)
        }.sorted { $0.sampleCount == $1.sampleCount ? $0.tag < $1.tag : $0.sampleCount > $1.sampleCount }
        let fastTags = Array(eligibleTags.prefix(3)).map(\.tag)
        if let fastest = eligibleTags.min(by: { $0.weightedLatencyHours < $1.weightedLatencyHours }),
           let slowest = eligibleTags.max(by: { $0.weightedLatencyHours < $1.weightedLatencyHours }), fastest.tag != slowest.tag {
            let evidence = copy(
                "생성→완료 경과가 짧은 태그: '\(fastest.tag)' 평균 \(formatHours(fastest.weightedLatencyHours, language: language)) / 긴 태그: '\(slowest.tag)' 평균 \(formatHours(slowest.weightedLatencyHours, language: language))",
                "Shortest creation-to-completion tag: '\(fastest.tag)' average \(formatHours(fastest.weightedLatencyHours, language: language)); longest: '\(slowest.tag)' average \(formatHours(slowest.weightedLatencyHours, language: language))."
            )
            lines.append(evidence)
            textualInsights.append(copy(
                "최근 기록에서 '\(fastest.tag)' 태그의 생성 후 완료까지 경과 시간이 '\(slowest.tag)' 태그보다 짧았음",
                "Recent records show shorter creation-to-completion time for '\(fastest.tag)' than '\(slowest.tag)'."
            ))
        }

        let dueDateCompleted = liveCompleted.compactMap { snapshot -> (due: Date, completedAt: Date)? in
            guard let due = snapshot.dueDate, let completedAt = snapshot.completedAt else { return nil }
            return (due, completedAt)
        }
        let early = dueDateCompleted.filter { $0.completedAt < $0.due }.count
        let onTime = dueDateCompleted.filter { calendar.isDate($0.completedAt, equalTo: $0.due, toGranularity: .minute) }.count
        let late = dueDateCompleted.count - early - onTime
        if !dueDateCompleted.isEmpty {
            let evidence = copy(
                "마감이 있는 최근 완료 기록: 조기 \(early)건 / 정시 \(onTime)건 / 지연 \(late)건",
                "Recent due-dated completions: early \(early) / on time \(onTime) / late \(late)."
            )
            lines.append(evidence)
            let lateDates = dueDateCompleted.filter { $0.completedAt > $0.due }.map(\.completedAt)
            let totalDates = dueDateCompleted.map(\.completedAt)
            appendRateInsight(metric: .overdueCompletionRate, successes: late, total: dueDateCompleted.count, successDates: lateDates, totalDates: totalDates, evidence: evidence)
            let weights = totalDates.map { decayWeight(for: $0, relativeTo: now, halfLifeDays: 21) }
            let confidence = behaviorConfidence(rawCount: totalDates.count, weights: weights)
            if confidence.allowsPersonalization {
                let lateWeight = lateDates.reduce(0) { $0 + decayWeight(for: $1, relativeTo: now, halfLifeDays: 21) }
                computedOverdueRate = smoothedRate(successes: lateWeight, total: weights.reduce(0, +))
            }
        }
        let leadTimes = liveCompleted.compactMap { snapshot -> Double? in
            guard let due = snapshot.dueDate, due > snapshot.createdAt else { return nil }
            return due.timeIntervalSince(snapshot.createdAt) / 3600
        }
        if !leadTimes.isEmpty {
            lines.append(copy(
                "생성→마감 리드타임 평균: \(formatHours(leadTimes.reduce(0, +) / Double(leadTimes.count), language: language))",
                "Average creation-to-deadline lead time: \(formatHours(leadTimes.reduce(0, +) / Double(leadTimes.count), language: language))."
            ))
        }

        let activeTodos = scopedTodos.filter { !$0.isCompleted }
        let nearTerm = activeTodos.filter { snapshot in
            guard let due = snapshot.dueDate else { return false }
            return due <= weekOut
        }.count
        if nearTerm > 0 {
            let evidence = copy(
                "마감 경과 또는 향후 7일 내 마감 미완료 TODO \(nearTerm)건",
                "\(nearTerm) incomplete to-dos are overdue or due within the next 7 days."
            )
            lines.append(evidence)
            textualInsights.append(evidence)
            structuredInsights.append(BehaviorInsight(
                metric: .nearTermBacklog,
                value: Double(nearTerm),
                numerator: nearTerm,
                denominator: activeTodos.count,
                effectiveSampleSize: Double(activeTodos.count),
                confidence: BehaviorConfidence.classify(effectiveSampleSize: Double(activeTodos.count)),
                windowStart: windowStart,
                windowEnd: now,
                previousValue: nil,
                trend: .unavailable,
                evidence: evidence
            ))
        }
        if !activeTodos.isEmpty {
            let withoutDue = activeTodos.filter { $0.dueDate == nil }.count
            appendRateInsight(
                metric: .activeWithoutDueDateShare,
                successes: withoutDue,
                total: activeTodos.count,
                evidence: copy(
                    "활성 TODO \(activeTodos.count)건 중 마감일 없는 TODO \(withoutDue)건",
                    "\(withoutDue) of \(activeTodos.count) active to-dos have no due date."
                ),
                includeInText: false
            )
        }

        let observedTodoIDs = Set(scopedEvents.map(\.todoID))
        func latestDatesByTodo(_ events: [BehaviorEventSnapshot]) -> [Date] {
            Dictionary(grouping: events, by: \.todoID).values.compactMap { $0.map(\.timestamp).max() }
        }
        if !observedTodoIDs.isEmpty {
            let userCompletionEvents = scopedEvents.filter { $0.kind == .completionChanged && $0.actorRawValue == TaskBehaviorActor.user.rawValue }.sorted { $0.timestamp < $1.timestamp }
            let completionEvents = userCompletionEvents.filter { $0.afterCompletion == true }
            var available: [UUID: Int] = [:]
            var undoEvents: [BehaviorEventSnapshot] = []
            for event in userCompletionEvents {
                if event.beforeCompletion == false && event.afterCompletion == true {
                    available[event.todoID, default: 0] += 1
                } else if event.beforeCompletion == true && event.afterCompletion == false && available[event.todoID, default: 0] > 0 {
                    available[event.todoID, default: 0] -= 1
                    undoEvents.append(event)
                }
            }
            let completionDateByTask = Dictionary(grouping: completionEvents, by: \.todoID).compactMapValues { $0.map(\.timestamp).min() }
            let undoDateByTask = Dictionary(grouping: undoEvents, by: \.todoID).compactMapValues { $0.map(\.timestamp).min() }
            appendRateInsight(metric: .completionUndoRate, successes: undoDateByTask.count, total: completionDateByTask.count, successDates: Array(undoDateByTask.values), totalDates: Array(completionDateByTask.values), evidence: copy(
                "사용자 완료 TODO \(completionDateByTask.count)건 중 완료 취소 \(undoDateByTask.count)건",
                "\(undoDateByTask.count) completion undos among \(completionDateByTask.count) user-completed to-dos."
            ))

            let dueChanges = scopedEvents.filter { $0.kind == .dueDateChanged && $0.actorRawValue == TaskBehaviorActor.user.rawValue && $0.beforeDueDate != $0.afterDueDate }
            let dueChangeDates = latestDatesByTodo(dueChanges)
            appendRateInsight(metric: .dueDateChangeRate, successes: dueChangeDates.count, total: observedTodoIDs.count, successDates: dueChangeDates, totalDates: latestDatesByTodo(scopedEvents), evidence: copy(
                "관찰된 TODO \(observedTodoIDs.count)건 중 사용자가 마감일을 변경한 TODO \(dueChangeDates.count)건",
                "\(dueChangeDates.count) of \(observedTodoIDs.count) observed to-dos had a user due-date change."
            ))
            let validDueChanges = dueChanges.filter { $0.beforeDueDate != nil && $0.afterDueDate != nil }
            let validDueDates = latestDatesByTodo(validDueChanges)
            let postponed = latestDatesByTodo(validDueChanges.filter { $0.afterDueDate! > $0.beforeDueDate! })
            appendRateInsight(metric: .dueDatePostponeRate, successes: postponed.count, total: validDueDates.count, successDates: postponed, totalDates: validDueDates, evidence: copy(
                "유효한 사용자 마감일 변경 TODO \(validDueDates.count)건 중 연기한 TODO \(postponed.count)건",
                "\(postponed.count) of \(validDueDates.count) to-dos with valid user due-date changes were postponed."
            ))

            let createdEvents = scopedEvents.filter { $0.kind == .created && $0.actorRawValue == TaskBehaviorActor.user.rawValue && $0.timestamp <= now }
            let createdDates = Dictionary(grouping: createdEvents, by: \.todoID).compactMapValues { $0.map(\.timestamp).min() }
            let dueAtCreation = Set(createdEvents.filter { $0.afterDueDate != nil }.map(\.todoID))
            appendRateInsight(metric: .dueDateAtCreationRate, successes: dueAtCreation.count, total: createdDates.count, successDates: Array(dueAtCreation.compactMap { createdDates[$0] }), totalDates: Array(createdDates.values), evidence: copy(
                "사용자 생성 이벤트가 있는 TODO \(createdDates.count)건 중 생성 시 마감일이 있던 TODO \(dueAtCreation.count)건",
                "\(dueAtCreation.count) of \(createdDates.count) user-created to-dos with valid creation events had a due date at creation."
            ))
            let manualEvents = scopedEvents.filter {
                $0.kind == .priorityChanged
                    && $0.actorRawValue == TaskBehaviorActor.user.rawValue
                    && ($0.beforeManualPriority != nil || $0.afterManualPriority != nil)
            }
            let manualDatesByCreatedTask: [UUID: Date] = Dictionary(
                grouping: manualEvents.filter { createdDates[$0.todoID] != nil },
                by: \.todoID
            ).compactMapValues { $0.map(\.timestamp).max() }
            appendRateInsight(metric: .manualPriorityChangeRate, successes: manualDatesByCreatedTask.count, total: createdDates.count, successDates: Array(manualDatesByCreatedTask.values), totalDates: Array(createdDates.values), evidence: copy(
                "사용자 생성 이벤트가 있는 TODO \(createdDates.count)건 중 수동 우선순위를 변경한 TODO \(manualDatesByCreatedTask.count)건",
                "\(manualDatesByCreatedTask.count) of \(createdDates.count) user-created to-dos with valid creation events had a manual priority change."
            ))
            let priorityEvents = scopedEvents.filter { $0.kind == .priorityChanged }.sorted { $0.timestamp < $1.timestamp }
            let aiEvents = priorityEvents.filter { $0.actorRawValue == TaskBehaviorActor.artificialIntelligence.rawValue }
            let overrides = aiEvents.filter { ai in
                priorityEvents.contains { later in
                    later.todoID == ai.todoID && later.actorRawValue == TaskBehaviorActor.user.rawValue && later.timestamp > ai.timestamp && later.timestamp.timeIntervalSince(ai.timestamp) <= 24 * 3600
                }
            }
            appendRateInsight(metric: .aiOverrideRate, successes: overrides.count, total: aiEvents.count, successDates: overrides.map(\.timestamp), totalDates: aiEvents.map(\.timestamp), evidence: copy(
                "AI 우선순위 변경 \(aiEvents.count)건 중 24시간 내 사용자 재변경 \(overrides.count)건",
                "\(overrides.count) user overrides within 24 hours among \(aiEvents.count) AI priority changes."
            ))
        }

        var classifications: [BehaviorClassification] = []
        if let insight = structuredInsights.first(where: { $0.metric == .completionConcentrationHour }), insight.confidence.allowsPersonalization, insight.denominator > 0 {
            let counts = Dictionary(grouping: completedDates, by: { calendar.component(.hour, from: $0) / 3 }).mapValues(\.count)
            let ranking = counts.values.sorted(by: >)
            let top = ranking.first ?? 0
            let second = ranking.dropFirst().first ?? 0
            let share = Double(top) / Double(insight.denominator)
            let qualifies = share >= 0.35 && share - Double(second) / Double(insight.denominator) >= 0.10
            let hour = Int(insight.value.rounded())
            classifications.append(BehaviorClassification(
                dimension: .completionTime,
                label: qualifies ? (hour < 12 ? .morning : hour < 18 ? .afternoon : hour < 21 ? .evening : .night) : .distributed,
                confidence: insight.confidence,
                evidence: [BehaviorEvidence(metricRawValue: insight.metric.rawValue, value: share, rawCount: top, effectiveCount: insight.effectiveSampleSize)]
            ))
        }
        if let insight = structuredInsights.first(where: { $0.metric == .completionWeekdayConcentration }), insight.confidence.allowsPersonalization, insight.denominator > 0 {
            let counts = Dictionary(grouping: completedDates, by: { calendar.component(.weekday, from: $0) }).mapValues(\.count)
            let ranking = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let top = ranking.first
            let topCount = top?.value ?? 0
            let second = ranking.dropFirst().first?.value ?? 0
            let share = Double(topCount) / Double(insight.denominator)
            let qualifies = top != nil && share >= 0.35 && share - Double(second) / Double(insight.denominator) >= 0.10
            let label: BehaviorLabel = {
                guard qualifies, let weekday = top?.key else { return .distributed }
                switch weekday { case 1: return .sunday; case 2: return .monday; case 3: return .tuesday; case 4: return .wednesday; case 5: return .thursday; case 6: return .friday; default: return .saturday }
            }()
            classifications.append(BehaviorClassification(dimension: .completionWeekday, label: label, confidence: insight.confidence, evidence: [BehaviorEvidence(metricRawValue: insight.metric.rawValue, value: share, rawCount: topCount, effectiveCount: insight.effectiveSampleSize)]))
        }
        if let insight = structuredInsights.first(where: { $0.metric == .dueDateAtCreationRate }), insight.confidence.allowsPersonalization, insight.denominator > 0 {
            let rate = Double(insight.numerator) / Double(insight.denominator)
            if rate >= 0.70 || rate <= 0.30 {
                classifications.append(BehaviorClassification(dimension: .schedulingStyle, label: rate >= 0.70 ? .scheduleFirst : .flexibleScheduling, confidence: insight.confidence, evidence: [BehaviorEvidence(metricRawValue: insight.metric.rawValue, value: rate, rawCount: insight.numerator, effectiveCount: insight.effectiveSampleSize)]))
            }
        }
        if let insight = structuredInsights.first(where: { $0.metric == .dueDatePostponeRate }), insight.confidence.allowsPersonalization, insight.denominator > 0, Double(insight.numerator) / Double(insight.denominator) >= 0.60 {
            let rate = Double(insight.numerator) / Double(insight.denominator)
            classifications.append(BehaviorClassification(dimension: .schedulingStyle, label: .frequentPostponement, confidence: insight.confidence, evidence: [BehaviorEvidence(metricRawValue: insight.metric.rawValue, value: rate, rawCount: insight.numerator, effectiveCount: insight.effectiveSampleSize)]))
        }
        if let insight = structuredInsights.first(where: { $0.metric == .manualPriorityChangeRate }), insight.confidence.allowsPersonalization, insight.denominator > 0, Double(insight.numerator) / Double(insight.denominator) >= 0.50 {
            let rate = Double(insight.numerator) / Double(insight.denominator)
            classifications.append(BehaviorClassification(dimension: .priorityControl, label: .manualPriorityPreference, confidence: insight.confidence, evidence: [BehaviorEvidence(metricRawValue: insight.metric.rawValue, value: rate, rawCount: insight.numerator, effectiveCount: insight.effectiveSampleSize)]))
        }
        if let insight = structuredInsights.first(where: { $0.metric == .completionUndoRate }), insight.confidence.allowsPersonalization, insight.denominator > 0, Double(insight.numerator) / Double(insight.denominator) >= 0.30 {
            let rate = Double(insight.numerator) / Double(insight.denominator)
            classifications.append(BehaviorClassification(dimension: .completionStability, label: .completionRevisit, confidence: insight.confidence, evidence: [BehaviorEvidence(metricRawValue: insight.metric.rawValue, value: rate, rawCount: insight.numerator, effectiveCount: insight.effectiveSampleSize)]))
        }
        if let insight = structuredInsights.first(where: { $0.metric == .overdueCompletionRate }), insight.confidence.allowsPersonalization, insight.denominator > 0 {
            let rate = Double(insight.numerator) / Double(insight.denominator)
            let label: BehaviorLabel = rate <= 0.25 ? .deadlineConsistent : rate >= 0.50 ? .deadlinePressure : .mixedDeadline
            classifications.append(BehaviorClassification(dimension: .deadlineAdherence, label: label, confidence: insight.confidence, evidence: [BehaviorEvidence(metricRawValue: insight.metric.rawValue, value: rate, rawCount: insight.numerator, effectiveCount: insight.effectiveSampleSize)]))
        }
        if let insight = structuredInsights.first(where: { $0.metric == .nearTermBacklog }), insight.confidence.allowsPersonalization, insight.numerator >= 5, insight.denominator > 0, Double(insight.numerator) / Double(insight.denominator) >= 0.50 {
            classifications.append(BehaviorClassification(dimension: .backlog, label: .nearTermBacklogPressure, confidence: insight.confidence, evidence: [BehaviorEvidence(metricRawValue: insight.metric.rawValue, value: insight.value, rawCount: insight.numerator, effectiveCount: insight.effectiveSampleSize)]))
        }

        let profile = BehaviorProfile(
            version: BehaviorProfile.currentVersion,
            windowStart: windowStart,
            windowEnd: now,
            sampleCount: evidenceDates.count,
            effectiveSampleSize: overallEffectiveSampleSize,
            confidence: overallConfidence,
            insights: structuredInsights,
            classifications: classifications
        )
        let scope = copy(
            "분석 범위: 현재 TODO \(scopedTodos.count)개, 최근 사용자 삭제 스냅샷 \(scopedAuditSnapshots.count)개, typed 변경 이벤트 \(scopedEvents.count)개, 최근 완료 기록 \(allCompletionRecords.count)개",
            "Scope: \(scopedTodos.count) current to-dos, \(scopedAuditSnapshots.count) recent user-deletion snapshots, \(scopedEvents.count) typed change events, and \(allCompletionRecords.count) recent completions."
        )
        return MemoryAnalysisResult(
            summary: lines.joined(separator: "\n"),
            insights: Array(textualInsights.prefix(8)),
            fastTags: fastTags,
            overdueRate: computedOverdueRate,
            productiveHour: detectedCompletionHour,
            analyzedCompletedCount: allCompletionRecords.count,
            recordTitle: copy("행동 패턴 분석", "Behavior Pattern Analysis"),
            accessScopeSummary: scope,
            processorDescription: copy("통계 기반(결정론적)", "Statistical (deterministic)"),
            behaviorProfile: profile
        )
    }

    private static func decayWeight(for date: Date, relativeTo now: Date, halfLifeDays: Double) -> Double {
        pow(2, -max(0, now.timeIntervalSince(date) / (24 * 3600)) / halfLifeDays)
    }

    private static func effectiveSampleSize(weights: [Double]) -> Double {
        let sum = weights.reduce(0, +)
        let squared = weights.reduce(0) { $0 + $1 * $1 }
        guard squared > 0 else { return 0 }
        return sum * sum / squared
    }

    private static func behaviorConfidence(rawCount: Int, weights: [Double]) -> BehaviorConfidence {
        let kish = effectiveSampleSize(weights: weights)
        let mass = weights.reduce(0, +)
        let support = min(kish, mass)
        return BehaviorConfidence.classify(effectiveSampleSize: rawCount >= 5 && support >= 4.5 ? max(5, support) : support)
    }

    private static func smoothedRate(successes: Double, total: Double) -> Double {
        guard total >= 0 else { return 0.5 }
        return (successes + 2) / (total + 4)
    }

    private static func weightedMean(_ values: [(value: Double, weight: Double)]) -> Double {
        let total = values.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        return values.reduce(0) { $0 + $1.value * $1.weight } / total
    }

    private static func formatHours(_ hours: Double, language: AppLanguage) -> String {
        let rounded = hours.rounded()
        if language == .english { return "\(rounded)h" }
        return "\(rounded)시간"
    }
}
