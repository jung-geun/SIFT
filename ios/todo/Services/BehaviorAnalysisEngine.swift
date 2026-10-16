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
                    ? String(format: AppLanguage.localized("behavior.analysis.insufficientTimeSamples", defaultValue: "There is not enough data from %@ completions in the last 90 days to infer a time-of-day trend.", language: language), locale: language.locale, completedDates.count.formatted(.number.locale(language.locale)))
                    : String(format: AppLanguage.localized("behavior.analysis.completionTimeEvidence", defaultValue: "Completions in the last 90 days were most concentrated from %@:00 to %@:00 (%@/%@).", language: language), locale: language.locale, top.key.formatted(.number.locale(language.locale)), min(24, top.key + 3).formatted(.number.locale(language.locale)), top.value.formatted(.number.locale(language.locale)), completedDates.count.formatted(.number.locale(language.locale)))
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
                    lines.append(String(format: AppLanguage.localized("behavior.analysis.completionTimeSummary", defaultValue: "Completion concentration: %@:00–%@:00 (%@/%@, %@).", language: language), locale: language.locale, top.key.formatted(.number.locale(language.locale)), min(24, top.key + 3).formatted(.number.locale(language.locale)), top.value.formatted(.number.locale(language.locale)), completedDates.count.formatted(.number.locale(language.locale)), String(completionConfidence.label(language: language))))
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
                    evidence: String(format: AppLanguage.localized("behavior.analysis.timeBucketShare", defaultValue: "Top completion time bucket share: %@/%@.", language: language), locale: language.locale, top.value.formatted(.number.locale(language.locale)), completedDates.count.formatted(.number.locale(language.locale)))
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
                    evidence: String(format: AppLanguage.localized("behavior.analysis.weekdayShare", defaultValue: "Top completion weekday share: %@/%@; runner-up %@.", language: language), locale: language.locale, top.value.formatted(.number.locale(language.locale)), completedDates.count.formatted(.number.locale(language.locale)), second.formatted(.number.locale(language.locale)))
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
                evidence: String(format: AppLanguage.localized("behavior.analysis.latencySamples", defaultValue: "%@ valid creation-to-completion latency observations from user completion events.", language: language), locale: language.locale, String(latency.count))
            ))
        }

        if !scopedTodos.isEmpty {
            let currentCompleted = scopedTodos.filter(\.isCompleted).count
            let evidence = String(format: AppLanguage.localized("behavior.analysis.currentCompletionShare", defaultValue: "Current to-do completion state: %@/%@.", language: language), locale: language.locale, currentCompleted.formatted(.number.locale(language.locale)), scopedTodos.count.formatted(.number.locale(language.locale)))
            lines.append(evidence)
            appendRateInsight(metric: .currentCompletionShare, successes: currentCompleted, total: scopedTodos.count, evidence: evidence, includeInText: false)
        }
        if !scopedAuditSnapshots.isEmpty {
            let completedBeforeDeletion = scopedAuditSnapshots.filter { $0.completedAt != nil }.count
            let evidence = String(format: AppLanguage.localized("behavior.analysis.deletedCompletedShare", defaultValue: "Among user-deletion snapshots from the last 90 days, completed before deletion: %@/%@.", language: language), locale: language.locale, completedBeforeDeletion.formatted(.number.locale(language.locale)), scopedAuditSnapshots.count.formatted(.number.locale(language.locale)))
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
                evidence: String(format: AppLanguage.localized("behavior.analysis.deletedSnapshotCount", defaultValue: "%@ user-deletion snapshots in the last 90 days.", language: language), locale: language.locale, scopedAuditSnapshots.count.formatted(.number.locale(language.locale)))
            ))
        }

        if !completionRecords.isEmpty {
            let elapsed = weightedMean(completionRecords.enumerated().map { index, record in
                (value: max(0, record.completedAt.timeIntervalSince(record.createdAt) / 3600), weight: completionWeights[index])
            })
            lines.append(String(format: AppLanguage.localized("behavior.analysis.weightedLatency", defaultValue: "Weighted elapsed time from creation to completion: %@.", language: language), locale: language.locale, String(formatHours(elapsed, language: language))))
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
            let evidence = String(format: AppLanguage.localized("behavior.analysis.tagLatencyEvidence", defaultValue: "Shortest creation-to-completion tag: '%@' average %@; longest: '%@' average %@.", language: language), locale: language.locale, String(fastest.tag), String(formatHours(fastest.weightedLatencyHours, language: language)), String(slowest.tag), String(formatHours(slowest.weightedLatencyHours, language: language)))
            lines.append(evidence)
            textualInsights.append(String(format: AppLanguage.localized("behavior.analysis.tagLatencySummary", defaultValue: "Recent records show shorter creation-to-completion time for '%@' than '%@'.", language: language), locale: language.locale, String(fastest.tag), String(slowest.tag)))
        }

        let dueDateCompleted = liveCompleted.compactMap { snapshot -> (due: Date, completedAt: Date)? in
            guard let due = snapshot.dueDate, let completedAt = snapshot.completedAt else { return nil }
            return (due, completedAt)
        }
        let early = dueDateCompleted.filter { $0.completedAt < $0.due }.count
        let onTime = dueDateCompleted.filter { calendar.isDate($0.completedAt, equalTo: $0.due, toGranularity: .minute) }.count
        let late = dueDateCompleted.count - early - onTime
        if !dueDateCompleted.isEmpty {
            let evidence = String(format: AppLanguage.localized("behavior.analysis.deadlineTiming", defaultValue: "Recent due-dated completions: early %@ / on time %@ / late %@.", language: language), locale: language.locale, early.formatted(.number.locale(language.locale)), onTime.formatted(.number.locale(language.locale)), late.formatted(.number.locale(language.locale)))
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
            lines.append(String(format: AppLanguage.localized("behavior.analysis.deadlineLeadTime", defaultValue: "Average creation-to-deadline lead time: %@.", language: language), locale: language.locale, String(formatHours(leadTimes.reduce(0, +) / Double(leadTimes.count), language: language))))
        }

        let activeTodos = scopedTodos.filter { !$0.isCompleted }
        let nearTerm = activeTodos.filter { snapshot in
            guard let due = snapshot.dueDate else { return false }
            return due <= weekOut
        }.count
        if nearTerm > 0 {
            let evidence = String(format: AppLanguage.localized("behavior.analysis.nearTermBacklog", defaultValue: "%@ incomplete to-dos are overdue or due within the next 7 days.", language: language), locale: language.locale, nearTerm.formatted(.number.locale(language.locale)))
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
                evidence: String(format: AppLanguage.localized("behavior.analysis.withoutDeadline", defaultValue: "%@ of %@ active to-dos have no due date.", language: language), locale: language.locale, withoutDue.formatted(.number.locale(language.locale)), activeTodos.count.formatted(.number.locale(language.locale))),
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
            appendRateInsight(metric: .completionUndoRate, successes: undoDateByTask.count, total: completionDateByTask.count, successDates: Array(undoDateByTask.values), totalDates: Array(completionDateByTask.values), evidence: String(format: AppLanguage.localized("behavior.analysis.completionUndoRate", defaultValue: "%@ completion undos among %@ user-completed to-dos.", language: language), locale: language.locale, undoDateByTask.count.formatted(.number.locale(language.locale)), completionDateByTask.count.formatted(.number.locale(language.locale))))

            let dueChanges = scopedEvents.filter { $0.kind == .dueDateChanged && $0.actorRawValue == TaskBehaviorActor.user.rawValue && $0.beforeDueDate != $0.afterDueDate }
            let dueChangeDates = latestDatesByTodo(dueChanges)
            appendRateInsight(metric: .dueDateChangeRate, successes: dueChangeDates.count, total: observedTodoIDs.count, successDates: dueChangeDates, totalDates: latestDatesByTodo(scopedEvents), evidence: String(format: AppLanguage.localized("behavior.analysis.dueDateChangeRate", defaultValue: "%@ of %@ observed to-dos had a user due-date change.", language: language), locale: language.locale, dueChangeDates.count.formatted(.number.locale(language.locale)), observedTodoIDs.count.formatted(.number.locale(language.locale))))
            let validDueChanges = dueChanges.filter { $0.beforeDueDate != nil && $0.afterDueDate != nil }
            let validDueDates = latestDatesByTodo(validDueChanges)
            let postponed = latestDatesByTodo(validDueChanges.filter { $0.afterDueDate! > $0.beforeDueDate! })
            appendRateInsight(metric: .dueDatePostponeRate, successes: postponed.count, total: validDueDates.count, successDates: postponed, totalDates: validDueDates, evidence: String(format: AppLanguage.localized("behavior.analysis.dueDatePostponeRate", defaultValue: "%@ of %@ to-dos with valid user due-date changes were postponed.", language: language), locale: language.locale, postponed.count.formatted(.number.locale(language.locale)), validDueDates.count.formatted(.number.locale(language.locale))))

            let createdEvents = scopedEvents.filter { $0.kind == .created && $0.actorRawValue == TaskBehaviorActor.user.rawValue && $0.timestamp <= now }
            let createdDates = Dictionary(grouping: createdEvents, by: \.todoID).compactMapValues { $0.map(\.timestamp).min() }
            let dueAtCreation = Set(createdEvents.filter { $0.afterDueDate != nil }.map(\.todoID))
            appendRateInsight(metric: .dueDateAtCreationRate, successes: dueAtCreation.count, total: createdDates.count, successDates: Array(dueAtCreation.compactMap { createdDates[$0] }), totalDates: Array(createdDates.values), evidence: String(format: AppLanguage.localized("behavior.analysis.dueDateAtCreationRate", defaultValue: "%@ of %@ user-created to-dos with valid creation events had a due date at creation.", language: language), locale: language.locale, dueAtCreation.count.formatted(.number.locale(language.locale)), createdDates.count.formatted(.number.locale(language.locale))))
            let manualEvents = scopedEvents.filter {
                $0.kind == .priorityChanged
                    && $0.actorRawValue == TaskBehaviorActor.user.rawValue
                    && ($0.beforeManualPriority != nil || $0.afterManualPriority != nil)
            }
            let manualDatesByCreatedTask: [UUID: Date] = Dictionary(
                grouping: manualEvents.filter { createdDates[$0.todoID] != nil },
                by: \.todoID
            ).compactMapValues { $0.map(\.timestamp).max() }
            appendRateInsight(metric: .manualPriorityChangeRate, successes: manualDatesByCreatedTask.count, total: createdDates.count, successDates: Array(manualDatesByCreatedTask.values), totalDates: Array(createdDates.values), evidence: String(format: AppLanguage.localized("behavior.analysis.manualPriorityChangeRate", defaultValue: "%@ of %@ user-created to-dos with valid creation events had a manual priority change.", language: language), locale: language.locale, manualDatesByCreatedTask.count.formatted(.number.locale(language.locale)), createdDates.count.formatted(.number.locale(language.locale))))
            let priorityEvents = scopedEvents.filter { $0.kind == .priorityChanged }.sorted { $0.timestamp < $1.timestamp }
            let aiEvents = priorityEvents.filter { $0.actorRawValue == TaskBehaviorActor.artificialIntelligence.rawValue }
            let overrides = aiEvents.filter { ai in
                priorityEvents.contains { later in
                    later.todoID == ai.todoID && later.actorRawValue == TaskBehaviorActor.user.rawValue && later.timestamp > ai.timestamp && later.timestamp.timeIntervalSince(ai.timestamp) <= 24 * 3600
                }
            }
            appendRateInsight(metric: .aiOverrideRate, successes: overrides.count, total: aiEvents.count, successDates: overrides.map(\.timestamp), totalDates: aiEvents.map(\.timestamp), evidence: String(format: AppLanguage.localized("behavior.analysis.aiOverrideRate", defaultValue: "%@ user overrides within 24 hours among %@ AI priority changes.", language: language), locale: language.locale, overrides.count.formatted(.number.locale(language.locale)), aiEvents.count.formatted(.number.locale(language.locale))))
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
        let scope = String(format: AppLanguage.localized("behavior.analysis.scope", defaultValue: "Scope: %@ current to-dos, %@ recent user-deletion snapshots, %@ typed change events, and %@ recent completions.", language: language), locale: language.locale, String(scopedTodos.count), String(scopedAuditSnapshots.count), String(scopedEvents.count), String(allCompletionRecords.count))
        return MemoryAnalysisResult(
            summary: lines.joined(separator: "\n"),
            insights: Array(textualInsights.prefix(8)),
            fastTags: fastTags,
            overdueRate: computedOverdueRate,
            productiveHour: detectedCompletionHour,
            analyzedCompletedCount: allCompletionRecords.count,
            recordTitle: AppLanguage.localized("행동 패턴 분석", defaultValue: "Behavior Pattern Analysis", language: language),
            accessScopeSummary: scope,
            processorDescription: AppLanguage.localized("behavior.analysis.processor", defaultValue: "Statistical (deterministic)", language: language),
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
        let value = hours.rounded().formatted(.number.locale(language.locale))
        return String(format: AppLanguage.localized("behavior.analysis.hours", defaultValue: "%@h", language: language), locale: language.locale, value)
    }
}
