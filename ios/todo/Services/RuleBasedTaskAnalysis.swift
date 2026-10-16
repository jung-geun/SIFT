import Foundation
import NaturalLanguage

struct TodoPriorityCandidateSnapshot: Sendable, Equatable {
    let id: UUID
    let title: String
    let notes: String
    let tags: [String]
    let dueDate: Date?
    let estimatedDurationMinutes: Int
    let todoSource: TodoSource
    let sourceThreadID: String
    let createdAt: Date
    let manualPriority: Int?
    let triage: TodoTriage
    let isCompleted: Bool
}

struct FastTagSignal: Sendable, Equatable {
    let normalizedTag: String
    let sampleCount: Int
    let weightedLatencyHours: Double
}

struct RulePersonalizationSnapshot: Sendable, Equatable {
    let appliedAt: Date?
    let confidence: BehaviorConfidence
    let weights: ScheduleWeights
    let productiveHour: Int?
    let fastTags: [FastTagSignal]
    let normalizedPersonaKeywords: [String]

    static let empty = RulePersonalizationSnapshot(
        appliedAt: nil,
        confidence: .insufficient,
        weights: ScheduleWeights(),
        productiveHour: nil,
        fastTags: [],
        normalizedPersonaKeywords: []
    )
}

struct RuleAnalysisContext: Sendable {
    let now: Date
    let calendar: Calendar
    let candidates: [TodoPriorityCandidateSnapshot]
    let calendarEvents: [CalendarService.CalendarEventSummary]
    let personalization: RulePersonalizationSnapshot
}

enum RuleAnalysisContextBuilder {
    static func make(
        todos: [Todo],
        calendarEvents: [CalendarService.CalendarEventSummary],
        persona: PersonaContext,
        now: Date,
        calendar: Calendar,
        memory: MemoryService = .shared
    ) -> RuleAnalysisContext {
        let profile = memory.behaviorProfile
        let usePersonalization = profile.confidence.allowsPersonalization &&
            profile.windowEnd.timeIntervalSince(now) >= -30 * 24 * 3_600
        let weights = usePersonalization ? ScheduleWeights.adaptive(from: memory) : ScheduleWeights()
        let fastTags: [FastTagSignal] = usePersonalization
            ? memory.fastTags
                .prefix(3)
                .map {
                    FastTagSignal(
                        normalizedTag: UserVocabularyService.normalizedKey($0),
                        sampleCount: 5,
                        weightedLatencyHours: 0
                    )
                }
            : []
        let personalization = RulePersonalizationSnapshot(
            appliedAt: usePersonalization ? memory.lastAnalysisDate : nil,
            confidence: usePersonalization ? profile.confidence : .insufficient,
            weights: weights,
            productiveHour: usePersonalization ? memory.productiveHour : nil,
            fastTags: fastTags,
            normalizedPersonaKeywords: persona.weightedKeywords
                .map(UserVocabularyService.normalizedKey)
                .filter { !$0.isEmpty }
                .sorted()
        )
        return RuleAnalysisContext(
            now: now,
            calendar: calendar,
            candidates: todos.map {
                TodoPriorityCandidateSnapshot(
                    id: $0.id,
                    title: $0.title,
                    notes: $0.notes,
                    tags: $0.tags,
                    dueDate: $0.dueDate,
                    estimatedDurationMinutes: $0.estimatedDurationMinutes,
                    todoSource: $0.todoSource,
                    sourceThreadID: $0.sourceThreadID,
                    createdAt: $0.createdAt,
                    manualPriority: $0.manualPriority,
                    triage: $0.triage,
                    isCompleted: $0.isCompleted
                )
            },
            calendarEvents: calendarEvents,
            personalization: personalization
        )
    }
}

nonisolated struct RuleTextParser: Sendable {
    private let tokens: [String]

    init(_ text: String) {
        let normalized = UserVocabularyService.normalizedKey(text.replacingOccurrences(of: "#", with: " "))
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        var parsed: [String] = []
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            let token = String(normalized[range])
            if !token.isEmpty { parsed.append(token) }
            return true
        }
        tokens = parsed
    }

    var isEmpty: Bool { tokens.isEmpty }

    var firstToken: String { tokens.first ?? "" }

    func containsAny(_ cues: [String]) -> Bool {
        cues.contains { contains($0) }
    }

    func contains(_ cue: String) -> Bool {
        let cueTokens = Self.tokenize(cue)
        guard !cueTokens.isEmpty, cueTokens.count <= tokens.count else { return false }
        for start in 0...(tokens.count - cueTokens.count) {
            guard Array(tokens[start..<(start + cueTokens.count)]) == cueTokens else { continue }
            let lower = max(0, start - 2)
            let upper = min(tokens.count - 1, start + cueTokens.count + 1)
            if !tokens[lower...upper].contains(where: RuleTextParser.negationTokens.contains) {
                return true
            }
        }
        return false
    }

    private static func tokenize(_ value: String) -> [String] {
        let normalized = UserVocabularyService.normalizedKey(value.replacingOccurrences(of: "#", with: " "))
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        var result: [String] = []
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            result.append(String(normalized[range]))
            return true
        }
        return result
    }

    private static let negationTokens: Set<String> = [
        "아님", "아니다", "않음", "않다", "불필요", "취소",
        "not", "no", "never", "cancelled", "canceled"
    ]
}


nonisolated enum RuleBasedPriorityAnalyzer {
    static let urgentCues = ["긴급", "즉시", "오늘", "지금", "바로", "마감", "기한 임박", "최우선", "asap", "urgent", "today", "now", "immediately", "deadline", "due soon", "critical"]
    static let importantCues = ["중요", "핵심", "필수", "우선", "결재", "제출", "important", "priority", "required", "approval", "submit", "must"]
    static let deferralCues = ["선택", "참고", "여유", "언젠가", "낮은 우선순위", "optional", "reference", "someday", "low priority", "when possible"]

    static func classify(
        _ candidate: TodoPriorityCandidateSnapshot,
        context: RuleAnalysisContext
    ) -> PriorityResult {
        let title = RuleTextParser(candidate.title)
        let notes = RuleTextParser(candidate.notes)
        let tags = candidate.tags.map(RuleTextParser.init)
        let combined = RuleTextParser([candidate.title, candidate.notes, candidate.tags.joined(separator: " ")].joined(separator: " "))
        let urgent = combined.containsAny(urgentCues)
        let important = combined.containsAny(importantCues)
        let deferral = combined.containsAny(deferralCues)
        let deadline = deadlineScore(candidate.dueDate, now: context.now)
        let urgency = clamp(deadline * 0.7 + (urgent ? 2 : 0) + (candidate.todoSource == .email ? 1 : 0) - (deferral ? 1.5 : 0))

        let personaInTitleOrTags = context.personalization.normalizedPersonaKeywords.contains { keyword in
            title.contains(keyword) || tags.contains { $0.contains(keyword) }
        }
        let personaInNotes = context.personalization.normalizedPersonaKeywords.contains { keyword in
            notes.contains(keyword)
        }
        let fastTag = tags.contains { tag in
            context.personalization.fastTags.contains { $0.normalizedTag == tag.firstToken }
        }
        var importance = 5.0
        if important { importance += 2 }
        if personaInTitleOrTags { importance += 1.5 } else if personaInNotes { importance += 1 }
        if fastTag { importance += 0.5 }
        if deferral { importance -= 1 }

        let siblingCount = candidate.sourceThreadID.isEmpty ? 0 : context.candidates.filter {
            $0.id != candidate.id && !$0.isCompleted && $0.triage == .todo && $0.sourceThreadID == candidate.sourceThreadID
        }.count
        let chaining = candidate.sourceThreadID.isEmpty ? 2 : siblingCount >= 2 ? 7 : siblingCount == 1 ? 5 : 2
        let axes = AxisScores(
            deadlineProximity: clamp(deadline),
            urgency: clamp(urgency),
            importance: clamp(importance),
            chaining: clamp(Double(chaining))
        )
        let recommended = recommendedTime(for: candidate, context: context)
        let reason: String
        if deadline >= 10 { reason = AppLanguage.localized("기한초과", defaultValue: "Overdue", language: AppLanguage.current) }
        else if deadline >= 7 { reason = AppLanguage.localized("priority.reason.rules.upcomingDeadline", defaultValue: "Upcoming deadline", language: AppLanguage.current) }
        else if urgent { reason = AppLanguage.localized("priority.reason.rules.urgentSignal", defaultValue: "Explicit urgency signal", language: AppLanguage.current) }
        else if important || personaInTitleOrTags || personaInNotes || fastTag { reason = AppLanguage.localized("priority.reason.rules.importantSignal", defaultValue: "Importance signal", language: AppLanguage.current) }
        else if siblingCount > 0 { reason = AppLanguage.localized("priority.reason.rules.sameThread", defaultValue: "Same email thread", language: AppLanguage.current) }
        else { reason = AppLanguage.localized("priority.reason.rules.default", defaultValue: "Default priority rules", language: AppLanguage.current) }
        return PriorityResult(
            todoID: candidate.id,
            score: ScheduleScorer.normalizedScore(axes, weights: context.personalization.weights),
            reason: String(reason.prefix(40)),
            detail: "",
            needsNotification: candidate.dueDate.map { $0 > context.now && $0.timeIntervalSince(context.now) < 86_400 } ?? false,
            recommendedTime: recommended,
            personaFit: personaInTitleOrTags || personaInNotes,
            engine: .heuristic,
            axes: axes,
            chainingDetail: "",
            executionPath: .rules(.noProviderOptIn)
        )
    }

    static func deadlineScore(_ due: Date?, now: Date) -> Double {
        guard let due else { return 0 }
        let hours = due.timeIntervalSince(now) / 3_600
        switch hours {
        case ..<0: return 10
        case ..<1: return 9
        case ..<6: return 8
        case ..<24: return 7
        case ..<72: return 6
        case ..<168: return 5
        case ..<720: return 3
        default: return 2
        }
    }

    static func recommendedTime(
        for candidate: TodoPriorityCandidateSnapshot,
        context: RuleAnalysisContext
    ) -> Date? {
        guard let hour = context.personalization.productiveHour else { return nil }
        let day = context.calendar.dateComponents([.year, .month, .day], from: context.now)
        guard let today = context.calendar.date(from: DateComponents(
            timeZone: context.calendar.timeZone,
            year: day.year,
            month: day.month,
            day: day.day,
            hour: hour
        )) else { return nil }
        let minutes = min(480, max(5, candidate.estimatedDurationMinutes))
        let intervalStart = today > context.now
            ? today
            : context.calendar.date(byAdding: .day, value: 1, to: today)
        guard let start = intervalStart,
              start > context.now,
              let end = context.calendar.date(byAdding: .minute, value: minutes, to: start)
        else { return nil }
        if context.calendarEvents.contains(where: { start < $0.endDate && $0.startDate < end }) {
            return nil
        }
        return start
    }

    private static func clamp(_ value: Double) -> Double { min(10, max(0, value)) }
}

nonisolated enum TodoPriorityOrdering {
    static func higherPriorityFirst(_ lhs: Todo, _ rhs: Todo) -> Bool {
        if lhs.effectivePriority != rhs.effectivePriority { return lhs.effectivePriority > rhs.effectivePriority }
        if lhs.isOverdue != rhs.isOverdue { return lhs.isOverdue }
        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?) where left != right: return left < right
        case (nil, .some): return false
        case (.some, nil): return true
        default: break
        }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
