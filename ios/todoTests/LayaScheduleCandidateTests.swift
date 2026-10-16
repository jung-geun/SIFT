import Foundation
import Testing
@testable import todo

@Suite("Laya processing slot candidates")
@MainActor
struct LayaScheduleCandidateTests {
    @Test("candidates respect deadline, calendar conflicts, and earlier TODO reservations")
    func availableSlotsRespectConstraints() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 12, hour: 8)))
        let noon = try #require(calendar.date(byAdding: .hour, value: 4, to: now))
        let three = try #require(calendar.date(byAdding: .hour, value: 7, to: now))
        let due = try #require(calendar.date(byAdding: .hour, value: 8, to: now))
        let todo = Todo(title: "File the appeal")
        todo.estimatedDurationMinutes = 60
        todo.dueDate = due
        let meeting = CalendarService.CalendarEventSummary(
            title: "Meeting", startDate: try #require(calendar.date(byAdding: .hour, value: 1, to: now)),
            endDate: try #require(calendar.date(byAdding: .hour, value: 2, to: now)),
            isRecurring: false, isAllDay: false, identifier: "meeting",
            calendarTitle: "Calendar", calendarID: "calendar"
        )
        let slots = LayaPriorityEngine.availableDays(todo: todo, events: [meeting], now: now, calendar: calendar)
        #expect(slots == [[noon, three]])

        let reserved = [DateInterval(start: noon, duration: 3600)]
        let remaining = LayaPriorityEngine.availableDays(
            todo: todo, events: [meeting], reserved: reserved, now: now, calendar: calendar
        )
        #expect(remaining == [[three]])
    }

    @Test("overdue TODO never receives a future recommendation")
    func overdueHasNoSlot() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let todo = Todo(title: "Overdue")
        todo.dueDate = now.addingTimeInterval(-60)
        #expect(LayaPriorityEngine.availableDays(todo: todo, events: [], now: now, calendar: .current).isEmpty)
    }

    @Test("startDate is a lower bound and touching intervals remain feasible")
    func startAndIntervalBoundaries() throws {
        let (calendar, now) = try fixture()
        let noon = now.addingTimeInterval(4 * 3600)
        let three = now.addingTimeInterval(7 * 3600)
        let todo = Todo(title: "After the briefing")
        todo.estimatedDurationMinutes = 60
        todo.startDate = noon
        todo.dueDate = three.addingTimeInterval(3600)
        let adjacent = [
            DateInterval(start: noon.addingTimeInterval(-3600), duration: 3600),
            DateInterval(start: noon.addingTimeInterval(3600), duration: 3600)
        ]
        #expect(LayaPriorityEngine.availableDays(
            todo: todo, events: [], reserved: adjacent, now: now, calendar: calendar
        ) == [[noon, three]])
        todo.startDate = three.addingTimeInterval(1)
        #expect(LayaPriorityEngine.availableDays(
            todo: todo, events: [], now: now, calendar: calendar
        ).isEmpty)
    }

    @Test("four-level urgency uses expected score and importance uses the predicate distribution")
    func distributionMapping() throws {
        let todo = Todo(title: "Commitment")
        let base = result(todo, score: 0.4)
        let importance = try answer(.importance, logits: [log(0.25), log(0.75)])
        for level in 0..<4 {
            var logits = Array(repeating: -8.0, count: 4)
            logits[level] = 8
            let urgency = try answer(.urgency, logits: logits)
            let mapped = LayaPriorityEngine.applyingJudgements(
                to: base, urgency: urgency, importance: importance,
                weights: ScheduleWeights(), language: .english
            )
            let axes = try #require(mapped.axes)
            let expected = try #require(urgency.expectedScore)
            #expect(abs(axes.urgency - Double(level) / 3 * 10) < 0.001)
            #expect(abs(axes.urgency - expected / 3 * 10) < 0.000001)
            #expect(abs(axes.importance - 6.5) < 0.000001)
            #expect(axes.deadlineProximity == base.axes?.deadlineProximity)
            #expect(axes.chaining == base.axes?.chaining)
            #expect(mapped.score == ScheduleScorer.normalizedScore(axes, weights: ScheduleWeights()))
        }
    }

    @Test("uncertainty holds the corresponding rule axis and preserves fully held priority")
    func independentHeldAxes() throws {
        let base = result(Todo(title: "Uncertain"), score: 0.4)
        let heldUrgency = try answer(.urgency, logits: [0, 0, 0, 0])
        let decisiveUrgency = try answer(.urgency, logits: [0, 0, 0, 4])
        let decisiveImportance = try answer(.importance, logits: [0, 4])
        let heldImportance = try answer(.importance, logits: [0, 4], truncated: true)
        let english = LayaPriorityEngine.applyingJudgements(
            to: base, urgency: heldUrgency, importance: decisiveImportance,
            weights: ScheduleWeights(), language: .english
        )
        #expect(english.axes?.urgency == base.axes?.urgency)
        #expect(english.axes?.importance != base.axes?.importance)
        let korean = LayaPriorityEngine.applyingJudgements(
            to: base, urgency: decisiveUrgency, importance: heldImportance,
            weights: ScheduleWeights(), language: .korean
        )
        #expect(korean.axes?.importance == base.axes?.importance)
        #expect(korean.axes?.urgency != base.axes?.urgency)
        let bothHeld = LayaPriorityEngine.applyingJudgements(
            to: base, urgency: heldUrgency, importance: heldImportance,
            weights: ScheduleWeights(), language: .english
        )
        #expect(bothHeld.axes == base.axes)
        #expect(bothHeld.score == base.score)
    }

    @Test("decision state preserves bounded original evidence and factual time context")
    func originalEvidenceState() throws {
        let (_, now) = try fixture()
        let todo = Todo(title: "原文 제출")
        todo.notes = "번역하지 않는 원본 메모"
        todo.tags = ["계약", "家庭"]
        todo.estimatedDurationMinutes = 45
        todo.dueDate = now.addingTimeInterval(90 * 60)
        let persona = PersonaContext(types: [], description: "照護者")
        let state = LayaPriorityEngine.decisionState(todo: todo, persona: persona, now: now)
        #expect(state.title == todo.title)
        #expect(state.details.contains(todo.notes))
        #expect(state.details.contains("계약; 家庭"))
        #expect(state.details.contains(persona.description))
        #expect(state.context.contains(AppDateFormat.llmString(from: now)))
        #expect(state.context.contains("minutes to deadline: 90"))
        #expect(state.context.contains("estimated duration minutes: 45"))
        #expect(!state.wasTruncated)
        todo.notes = "처음" + String(repeating: "가", count: 2000) + "끝"
        todo.tags = Array(repeating: "긴 태그", count: 9)
        let bounded = LayaPriorityEngine.decisionState(todo: todo, persona: persona, now: now)
        #expect(bounded.wasTruncated)
        #expect(bounded.details.contains("처음"))
        #expect(bounded.details.contains("끝"))
        #expect(bounded.details.count < 2100)
    }

    @Test("final scores, not baseline order, get first opportunity; uncertain choices use first valid slot")
    func finalPriorityReservesFirst() async throws {
        let (calendar, now) = try fixture()
        let low = Todo(title: "Initially high")
        let high = Todo(title: "Initially low")
        for todo in [low, high] {
            todo.estimatedDurationMinutes = 60
            todo.dueDate = now.addingTimeInterval(5 * 3600)
        }
        let lowScore = LayaPriorityEngine.applyingJudgements(
            to: result(low, score: 0.9),
            urgency: try answer(.urgency, logits: [4, 0, 0, 0]),
            importance: try answer(.importance, logits: [4, 0]),
            weights: ScheduleWeights(), language: .english
        )
        let highScore = LayaPriorityEngine.applyingJudgements(
            to: result(high, score: 0.1),
            urgency: try answer(.urgency, logits: [0, 0, 0, 4]),
            importance: try answer(.importance, logits: [0, 4]),
            weights: ScheduleWeights(), language: .english
        )
        var asked = [UUID]()
        let scheduled = try await LayaPriorityEngine.schedule(
            [lowScore, highScore], todos: [low, high], events: [], now: now, calendar: calendar
        ) { todo, question in
            asked.append(todo.id)
            var logits = Array(repeating: 0.0, count: question.labels.count)
            logits[logits.count - 1] = 4
            // A preferred last slot is still held when the action head rejects acting.
            return try answer(question, logits: logits, action: 0)
        }
        #expect(scheduled.map(\.todoID) == [high.id, low.id])
        #expect(asked == [high.id])
        #expect(scheduled[0].recommendedTime == now.addingTimeInterval(3600))
        #expect(scheduled[1].recommendedTime == now.addingTimeInterval(4 * 3600))
        let first = try #require(scheduled[0].recommendedTime)
        let second = try #require(scheduled[1].recommendedTime)
        let deadline = try #require(low.dueDate)
        #expect(first.addingTimeInterval(3600) <= second)
        #expect(second.addingTimeInterval(3600) <= deadline)

        // When just one slot remains, the final high-priority item owns it.
        low.dueDate = now.addingTimeInterval(2 * 3600)
        high.dueDate = low.dueDate
        let scarce = try await LayaPriorityEngine.schedule(
            [lowScore, highScore], todos: [low, high], events: [], now: now, calendar: calendar
        ) { _, _ in throw TestFailure.prediction }
        #expect(scarce[0].todoID == high.id)
        #expect(scarce[0].recommendedTime == now.addingTimeInterval(3600))
        #expect(scarce[1].recommendedTime == nil)
    }

    @Test("typed day and time choices use stable IDs and describe deadline slack")
    func decisiveSlotChoices() async throws {
        let (calendar, now) = try fixture()
        let todo = Todo(title: "Choose tomorrow")
        todo.estimatedDurationMinutes = 60
        todo.dueDate = now.addingTimeInterval(2 * 24 * 3600)
        var questions = [LayaQuestion]()
        let scheduled = try await LayaPriorityEngine.schedule(
            [result(todo, score: 0.5)], todos: [todo], events: [], now: now, calendar: calendar
        ) { _, question in
            questions.append(question)
            guard case .choice(let options) = question.kind else {
                throw LayaAnswer.Failure.invalidOutput
            }
            #expect(Set(options.map(\.id)).count == options.count)
            var logits = Array(repeating: 0.0, count: options.count)
            logits[1] = 4
            return try answer(question, logits: logits)
        }
        let tomorrowNoon = now.addingTimeInterval(28 * 3600)
        #expect(scheduled.first?.recommendedTime == tomorrowNoon)
        #expect(questions.map(\.name) == ["processing_day", "processing_time"])
        let timeQuestion = try #require(questions.last)
        guard case .choice(let times) = timeQuestion.kind else {
            Issue.record("Time question must be a typed choice")
            return
        }
        #expect(times[1].id == "slot_\(Int(tomorrowNoon.timeIntervalSince1970))")
        #expect(times[1].description.contains("1140 min"))
        let dayQuestion = try #require(questions.first)
        guard case .choice(let days) = dayQuestion.kind else {
            Issue.record("Day question must be a typed choice")
            return
        }
        let tomorrow = calendar.startOfDay(for: tomorrowNoon)
        #expect(days[1].id == "day_\(Int(tomorrow.timeIntervalSince1970))")
    }

    @Test("stable ties keep deadline then creation then ID ordering before reservations")
    func stableTieOrder() async throws {
        let (calendar, now) = try fixture()
        let early = Todo(title: "Earlier deadline")
        let old = Todo(title: "Older")
        let new = Todo(title: "Newer")
        let noDue = Todo(title: "No deadline")
        let noDueTwin = Todo(title: "Same creation time, no deadline")
        noDue.createdAt = now
        noDueTwin.createdAt = now
        early.dueDate = now.addingTimeInterval(24 * 3600)
        old.dueDate = now.addingTimeInterval(48 * 3600)
        new.dueDate = old.dueDate
        old.createdAt = now.addingTimeInterval(-3600)
        new.createdAt = now
        let todos = [noDueTwin, noDue, new, old, early]
        let scheduled = try await LayaPriorityEngine.schedule(
            todos.map { result($0, score: 0.5) }, todos: todos, events: [], now: now, calendar: calendar
        ) { _, question in try answer(question, logits: Array(repeating: 0, count: question.labels.count)) }
        let idTieOrder = [noDue.id, noDueTwin.id].sorted { $0.uuidString < $1.uuidString }
        #expect(scheduled.map(\.todoID) == [early.id, old.id, new.id] + idTieOrder)
        #expect(scheduled[0].recommendedTime == now.addingTimeInterval(3600))
        #expect(scheduled[1].recommendedTime == now.addingTimeInterval(4 * 3600))
        #expect(scheduled[2].recommendedTime == now.addingTimeInterval(7 * 3600))
    }

    @Test("model failures propagate; no feasible slot never invokes the model")
    func errorsAndNoAvailability() async throws {
        let (calendar, now) = try fixture()
        let todo = Todo(title: "Unavailable")
        todo.dueDate = now
        let unscheduled = try await LayaPriorityEngine.schedule(
            [result(todo, score: 0.5)], todos: [todo], events: [], now: now, calendar: calendar
        ) { _, _ in throw TestFailure.prediction }
        #expect(unscheduled.first?.recommendedTime == nil)
        todo.dueDate = nil
        do {
            _ = try await LayaPriorityEngine.schedule(
                [result(todo, score: 0.5)], todos: [todo], events: [], now: now, calendar: calendar
            ) { _, _ in throw TestFailure.prediction }
            Issue.record("Prediction failure must propagate")
        } catch TestFailure.prediction {
            // Existing routing, not this consumer, owns fallback on errors.
        }
    }


    @Test("baseline exclusions survive the Laya scoring and scheduling pipeline")
    func baselineExclusions() async throws {
        let (calendar, now) = try fixture()
        let eligible = Todo(title: "Eligible")
        let manual = Todo(title: "Manual")
        manual.manualPriority = 1
        let review = Todo(title: "Review")
        review.triageStatus = TodoTriage.review.rawValue
        let completed = Todo(title: "Completed")
        completed.isCompleted = true
        let todos = [manual, review, completed, eligible]
        let baseline = try await HeuristicEngine().prioritize(
            todos: todos, events: [], persona: .empty, progress: nil
        )
        #expect(baseline.map(\.todoID) == [eligible.id])
        let heldUrgency = try answer(.urgency, logits: [0, 0, 0, 0])
        let heldImportance = try answer(.importance, logits: [0, 0])
        let scored = baseline.map {
            LayaPriorityEngine.applyingJudgements(
                to: $0, urgency: heldUrgency, importance: heldImportance,
                weights: ScheduleWeights(), language: .english
            )
        }
        let scheduled = try await LayaPriorityEngine.schedule(
            scored, todos: todos, events: [], now: now, calendar: calendar
        ) { _, question in try answer(question, logits: Array(repeating: 0, count: question.labels.count)) }
        #expect(scheduled.map(\.todoID) == [eligible.id])
        #expect(scheduled.first?.axes == baseline.first?.axes)
        #expect(scheduled.first?.score == baseline.first?.score)
    }

    private enum TestFailure: Error { case prediction }

    private func fixture() throws -> (Calendar, Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 12, hour: 8)))
        return (calendar, now)
    }

    private func result(_ todo: Todo, score: Double) -> PriorityResult {
        PriorityResult(
            todoID: todo.id, score: score, reason: "Rule baseline", detail: "Rule evidence",
            needsNotification: true, recommendedTime: nil, personaFit: true, engine: .heuristic,
            axes: AxisScores(deadlineProximity: 4, urgency: 3, importance: 4, chaining: 5)
        )
    }

    private func answer(
        _ question: LayaQuestion, logits: [Double], truncated: Bool = false, action: Double = 1
    ) throws -> LayaAnswer {
        let expValues = logits.map { exp($0 - (logits.max() ?? 0)) }
        let total = expValues.reduce(0, +)
        return try LayaAnswer(
            question: question, logits: logits, rawProbabilities: expValues.map { $0 / total },
            actionProbability: action, stateWasTruncated: truncated, tokenCount: 128,
            modelRevision: LayaDecisionService.modelRevision
        )
    }
}
