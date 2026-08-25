import Foundation
import Testing
@testable import todo

@Suite("RuleBasedPriorityAnalyzer")
struct RuleBasedPriorityAnalyzerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func candidate(
        id: UUID = UUID(),
        title: String = "",
        dueDate: Date? = nil,
        source: TodoSource = .manual
    ) -> TodoPriorityCandidateSnapshot {
        TodoPriorityCandidateSnapshot(
            id: id,
            title: title,
            notes: "",
            tags: [],
            dueDate: dueDate,
            estimatedDurationMinutes: 30,
            todoSource: source,
            sourceThreadID: "",
            createdAt: now,
            manualPriority: nil,
            triage: .todo,
            isCompleted: false
        )
    }

    private func context(_ candidates: [TodoPriorityCandidateSnapshot]) -> RuleAnalysisContext {
        RuleAnalysisContext(
            now: now,
            calendar: Calendar(identifier: .gregorian),
            candidates: candidates,
            calendarEvents: [],
            personalization: .empty
        )
    }

    @Test("cue matching respects token boundaries and two-token negation")
    func cueBoundaryAndNegation() {
        let negated = candidate(title: "not urgent: quarterly reference")
        let partial = candidate(title: "긴급하지 않은 분기 보고서")
        let positive = candidate(title: "#urgent-submit")
        let values = context([negated, partial, positive])
        #expect(RuleBasedPriorityAnalyzer.classify(negated, context: values).axes?.urgency == 0)
        #expect(RuleBasedPriorityAnalyzer.classify(partial, context: values).axes?.urgency == 0)
        #expect((RuleBasedPriorityAnalyzer.classify(positive, context: values).axes?.urgency ?? 0) > 0)
    }

    @Test("review, completed, and manually prioritized todos are outside priority scope")
    func priorityScopeExcludesIneligibleTodos() {
        let review = Todo(title: "review")
        review.triageStatus = TodoTriage.review.rawValue
        let completed = Todo(title: "completed")
        completed.isCompleted = true
        let manual = Todo(title: "manual")
        manual.manualPriority = TodoPriority.high.rawValue
        #expect(TodoPriorityScope.candidates(from: [review, completed, manual]).isEmpty)
    }

    @Test("productive hour recommendation is suppressed by half-open calendar overlap")
    func productiveHourOverlap() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let context = RuleAnalysisContext(
            now: now,
            calendar: calendar,
            candidates: [],
            calendarEvents: [
                CalendarService.CalendarEventSummary(
                    title: "meeting",
                    startDate: calendar.date(byAdding: .day, value: 1, to: now)!,
                    endDate: calendar.date(byAdding: .minute, value: 31, to: calendar.date(byAdding: .day, value: 1, to: now)!)!,
                    isRecurring: false,
                    isAllDay: false,
                    identifier: "event",
                    calendarTitle: "calendar",
                    calendarID: "calendar"
                )
            ],
            personalization: RulePersonalizationSnapshot(
                appliedAt: now,
                confidence: .high,
                weights: ScheduleWeights(),
                productiveHour: calendar.component(.hour, from: now),
                fastTags: [],
                normalizedPersonaKeywords: []
            )
        )
        let item = candidate()
        #expect(RuleBasedPriorityAnalyzer.recommendedTime(for: item, context: context) == nil)
    }
    @Test("negated urgent cue does not add lexical urgency")
    func negatedUrgencyIsIgnored() {
        let item = candidate(title: "긴급 아님: 분기 보고서 참고")
        let result = RuleBasedPriorityAnalyzer.classify(item, context: context([item]))
        #expect(result.axes?.urgency == 0)
    }

    @Test("overdue deadline outranks an undated task")
    func overdueOutranksNoDueDate() {
        let overdue = candidate(title: "제출", dueDate: now.addingTimeInterval(-1))
        let undated = candidate(title: "제출")
        let values = context([overdue, undated])
        let overdueResult = RuleBasedPriorityAnalyzer.classify(overdue, context: values)
        let undatedResult = RuleBasedPriorityAnalyzer.classify(undated, context: values)
        #expect(overdueResult.score > undatedResult.score)
    }

    @Test("deadline boundaries remain stable")
    func deadlineBoundaries() {
        let oneHour = candidate(dueDate: now.addingTimeInterval(3_600))
        let sixHours = candidate(dueDate: now.addingTimeInterval(21_600))
        let values = context([oneHour, sixHours])
        #expect(RuleBasedPriorityAnalyzer.classify(oneHour, context: values).axes?.deadlineProximity == 8)
        #expect(RuleBasedPriorityAnalyzer.classify(sixHours, context: values).axes?.deadlineProximity == 7)
    }
}
