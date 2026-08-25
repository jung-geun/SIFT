import Foundation
import Testing
@testable import todo
// MARK: - Tier 1: 파서 단위테스트 (FM 불필요, 결정론적)
//
// 모든 파서가 고정 픽스처 JSON/텍스트를 올바르게 처리하는지 검증한다.
// Apple Intelligence 없이도 실행 가능 — CI 파이프라인 포함.

@Suite("AppDateFormat 날짜 파싱")
struct DateParserTests {

    @Test("offset 포함 ISO8601 파싱")
    func parseWithOffset() {
        #expect(AppDateFormat.parseLLMDate("2026-12-31T23:59:00+09:00") != nil)
    }

    @Test("offset 없는 ISO8601 → 현지 기준")
    func parseWithoutOffset() {
        #expect(AppDateFormat.parseLLMDate("2026-12-31T23:59:00") != nil)
    }

    @Test("날짜만 → 자정 기준")
    func parseDateOnly() {
        #expect(AppDateFormat.parseLLMDate("2026-12-31") != nil)
    }

    @Test("llmString → parseLLMDate 왕복 1초 이내")
    func roundtrip() {
        let now = Date()
        let str = AppDateFormat.llmString(from: now)
        let back = AppDateFormat.parseLLMDate(str)
        #expect(back != nil)
        if let back {
            #expect(abs(back.timeIntervalSince(now)) < 1.0)
        }
    }

    @Test("메일 본문의 UTC+9 suffix를 절대시각으로 보존한다")
    func parseMailDatePreservesUTCPlusNine() throws {
        let parsed = try #require(AppDateFormat.parseMailDate("2026-07-10 17:30 UTC+9"))
        let expected = try fixedDate("2026-07-10T17:30:00+09:00")
        #expect(abs(parsed.timeIntervalSince(expected)) < 1.0)
    }

    @Test("Zulu 시각을 같은 절대시각으로 해석한다")
    func parseMailDatePreservesZulu() throws {
        let parsed = try #require(AppDateFormat.parseMailDate("2026-07-10 08:30 Z"))
        let expected = try fixedDate("2026-07-10T17:30:00+09:00")
        #expect(abs(parsed.timeIntervalSince(expected)) < 1.0)
    }

    @Test("offset 없는 메일 날짜도 기존처럼 파싱한다")
    func parseMailDateOffsetlessStillParses() {
        #expect(AppDateFormat.parseMailDate("2026-07-10T17:30:00") != nil)
    }

    @Test("날짜-only 마감은 같은 원문 시간대의 23:59로 보정한다")
    func allDayDeadlineNormalizesToEndOfDay() throws {
        let date = try fixedDate("2026-07-10T00:00:00+09:00")
        let calendar = AppDateFormat.sourceCalendar(
            for: "2026-07-10T00:00:00+09:00",
            fallback: Calendar(identifier: .gregorian)
        )
        let expected = try fixedDate("2026-07-10T23:59:00+09:00")

        let normalized = AppDateFormat.normalizedAllDayDeadline(date, calendar: calendar)

        #expect(normalized.isAllDay)
        #expect(abs(normalized.date.timeIntervalSince(expected)) < 1.0)
    }

    @Test("시각이 있는 마감은 보정하지 않는다")
    func timedDeadlineIsNotNormalized() throws {
        let date = try fixedDate("2026-07-10T17:30:00+09:00")
        let normalized = AppDateFormat.normalizedAllDayDeadline(date)

        #expect(normalized.isAllDay == false)
        #expect(abs(normalized.date.timeIntervalSince(date)) < 1.0)
    }

    @Test("이메일 프롬프트는 시간대 보존 규칙을 명시한다")
    func emailPromptRequiresTimezonePreservationContract() {
        let instruction = Prompts.EmailFM.systemInstruction(language: .korean)
        #expect(instruction.contains("UTC+9"))
        #expect(instruction.contains("ISO8601 offset"))
        #expect(instruction.contains("현지 offset"))
    }
}

@Suite("ReminderTiming regressions")
struct ReminderTimingTests {

    @Test("79시간 남은 일정은 72시간 전 자동 알림으로 분류한다")
    func automaticOffsetUsesSeventyTwoHoursForFarFutureDueDate() throws {
        let now = try fixedDate("2026-07-07T10:05:00+09:00")
        let dueDate = try fixedDate("2026-07-10T17:30:00+09:00")

        let offset = try #require(ReminderTiming.automaticOffset(now: now, dueDate: dueDate))
        #expect(offset == TimeInterval(-72 * 3600))
    }

    @Test("알림 본문은 실제 2시간 리드를 그대로 보여준다")
    func notificationBodyUsesExactTwoHourLead() throws {
        let dueDate = try fixedDate("2026-07-10T12:00:00+09:00")
        let calendar = AppDateFormat.sourceCalendar(
            for: "2026-07-10T12:00:00+09:00",
            fallback: Calendar(identifier: .gregorian)
        )

        let body = ReminderTiming.notificationBody(
            offset: -2 * 3600,
            dueDate: dueDate,
            calendar: calendar,
            language: .korean
        )

        #expect(body.contains("2시간 후 마감"))
        #expect(body.contains("6시간") == false)
    }

    @Test("혼합 리드는 일 단위로 뭉개지지 않는다")
    func detailLabelDoesNotFloorMixedLeadToThreeDays() {
        let label = ReminderTiming.detailLabel(for: -(79 * 3600), language: .korean)

        #expect(label == "마감 3일 7시간 전")
        #expect(label != "마감 3일 전")
    }

    @Test("일+분 리드는 0시간 없이 정확하게 표시된다")
    func detailLabelFormatsDayAndMinuteWithoutZeroHourSegment() {
        let label = ReminderTiming.detailLabel(for: -(24 * 3600 + 30 * 60), language: .korean)

        #expect(label == "마감 1일 30분 전")
        #expect(label != "마감 1일 0시간 전")
    }

    @Test("review triage는 알림 스케줄 대상에서 제외된다")
    func schedulableRejectsReviewTodos() throws {
        let now = try fixedDate("2026-07-07T10:05:00+09:00")
        let dueDate = try fixedDate("2026-07-10T17:30:00+09:00")
        let todo = Todo(title: "등록 대기 일정", dueDate: dueDate, reminderOffsets: [-2 * 3600])
        todo.triageStatus = TodoTriage.review.rawValue

        #expect(ReminderTiming.schedulable(todo, now: now) == false)
    }
}


@Suite("EmailContentAnalyzer timezone regressions")
struct EmailContentAnalyzerTimezoneTests {
    @Test("본문 밖 trailing UTC+9 토큰도 마감 시각에 반영한다")
    func emailContentAnalyzerPreservesTrailingUTCPlusNine() throws {
        let now = try fixedDate("2026-07-01T00:00:00+09:00")
        let expectedDueDate = try fixedDate("2026-07-10T17:30:00+09:00")
        let message = try makeGmailMessage(body: "Deadline: 2026-07-10 17:30 UTC+9까지 제출")

        let extraction = EmailContentAnalyzer().analyze(message, now: now)
        let dueDate = try #require(extraction?.dueDate)

        #expect(abs(dueDate.timeIntervalSince(expectedDueDate)) < 1.0)
    }
}



// MARK: -

@Suite("OnDeviceLLMIntelligenceEngine 스케줄 V9 파서")
@MainActor
struct ScheduleV9ParserTests {

    private let sut = OnDeviceLLMIntelligenceEngine()

    @Test("UUID와 짧은 task_id 토큰 모두 PriorityResult로 복원한다")
    func normal() {
        let uuidTodo = Todo()
        let uuidJSON = """
        {"scheduled_tasks":[{"task_id":"\(uuidTodo.id.uuidString)","scoring":{"deadline_proximity":5.0,"urgency":5.0,"task_importance":7.0,"task_chaining":2.0},"reasoning":{"summary":"중요 업무","chaining_detail":""},"recommended_schedule":{"start_time":""}}]}
        """
        let uuidResults = sut.parseScheduleResponseV9(text: uuidJSON, todos: [uuidTodo], persona: .empty)
        #expect(uuidResults?.count == 1)
        #expect(uuidResults?.first?.todoID == uuidTodo.id)

        let compactTodos = [Todo(title: "자료 조사"), Todo(title: "초안 작성")]
        let compactJSON = """
        {"scheduled_tasks":[{"task_id":"T2","scoring":{"deadline_proximity":4.0,"urgency":6.0,"task_importance":7.0,"task_chaining":8.0},"reasoning":{"summary":"초안 작성이 후속 작업과 직접 연결됩니다.","chaining_detail":"조사 다음 단계"},"recommended_schedule":{"start_time":""}}]}
        """
        let compactResults = sut.parseScheduleResponseV9(text: compactJSON, todos: compactTodos, persona: .empty)
        #expect(compactResults?.count == 1)
        #expect(compactResults?.first?.todoID == compactTodos[1].id)
    }

    @Test("코드펜스와 잘린 루트 JSON에서도 완성된 task 객체를 회수한다")
    func recoversCompletedTasksFromFencedPartialJSON() {
        let todos = [Todo(title: "첫 번째"), Todo(title: "두 번째")]
        let partialJSON = """
        ```json
        {
          "scheduled_tasks": [
            {
              "task_id": "T1",
              "scoring": {
                "deadline_proximity": 5,
                "urgency": 5,
                "task_importance": 8,
                "task_chaining": 2
              },
              "recommended_schedule": {
                "start_time": ""
              }
            },
            {
              "task_id": "T2",
              "scoring": {
        """

        let results = sut.parseScheduleResponseV9(text: partialJSON, todos: todos, persona: .empty)

        #expect(results?.count == 1)
        #expect(results?.first?.todoID == todos[0].id)
        #expect(results?.first?.reason.isEmpty == false)
    }
}

@Suite("Todo.apply metadata persistence")
struct TodoApplyTests {
    @Test("AI 요청 제공자와 폴백 사유를 저장한다")
    func persistsRoutingMetadata() {
        let todo = Todo(title: "세금 신고")
        let result = PriorityResult(
            todoID: todo.id,
            score: 0.91,
            reason: "오늘 마감",
            detail: "Gemini fallback result",
            needsNotification: true,
            recommendedTime: nil,
            personaFit: true,
            engine: .heuristic,
            axes: AxisScores(deadlineProximity: 9, urgency: 8, importance: 7, chaining: 2),
            chainingDetail: "",
            requestedProviderRawValue: PersonaAIProvider.gemini.rawValue,
            fallbackReason: "Gemini API key is missing"
        )

        todo.apply(result)

        #expect(todo.aiRequestedProvider == PersonaAIProvider.gemini.rawValue)
        #expect(todo.aiFallbackReason == "Gemini API key is missing")
        #expect(todo.aiEngine == PriorityEngine.heuristic.rawValue)
    }

    @Test("AI 정리 scope는 review를 제외하고 todo만 반영한다")
    func aiSortScopeExcludesReviewTodosAndDoesNotApplyReviewResults() {
        let todo = Todo(title: "진행중 업무")
        todo.triageStatus = TodoTriage.todo.rawValue
        let review = Todo(title: "등록 대기 후보")
        review.triageStatus = TodoTriage.review.rawValue

        let candidates = TodoPriorityScope.candidates(from: [todo, review])

        #expect(candidates.map(\.id) == [todo.id])

        let reviewResult = PriorityResult(
            todoID: review.id,
            score: 0.99,
            reason: "등록 대기 제외",
            detail: "",
            needsNotification: false,
            recommendedTime: nil,
            personaFit: false,
            engine: .onDeviceMLX,
            axes: AxisScores(deadlineProximity: 5, urgency: 5, importance: 5, chaining: 2)
        )
        let rejected = TodoPriorityScope.apply(reviewResult, in: candidates)

        #expect(rejected == nil)
        #expect(review.computedPriorityScore == 0.0)

        let todoResult = PriorityResult(
            todoID: todo.id,
            score: 0.73,
            reason: "오늘 처리",
            detail: "",
            needsNotification: false,
            recommendedTime: nil,
            personaFit: true,
            engine: .onDeviceMLX,
            axes: AxisScores(deadlineProximity: 5, urgency: 5, importance: 5, chaining: 2)
        )
        let applied = TodoPriorityScope.apply(todoResult, in: candidates)

        #expect(applied === todo)
        #expect(todo.computedPriorityScore == 0.73)
    }
}

@Suite("AnalysisHeuristicTests")
struct AnalysisHeuristicTests {
    private func makeDate(dayOffset: Int, hour: Int) -> Date {
        let calendar = Calendar.current
        let base = calendar.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
    }

    private func makeHeuristicTodos() -> [Todo] {
        let study = Todo(title: "과제 제출 준비")
        study.tags = ["study"]
        study.createdAt = makeDate(dayOffset: -4, hour: 9)
        study.dueDate = makeDate(dayOffset: -3, hour: 18)
        study.completedAt = makeDate(dayOffset: -4, hour: 21)
        study.isCompleted = true

        let meeting = Todo(title: "회의 자료 정리")
        meeting.tags = ["meeting"]
        meeting.createdAt = makeDate(dayOffset: -5, hour: 9)
        meeting.dueDate = makeDate(dayOffset: -3, hour: 21)
        meeting.completedAt = makeDate(dayOffset: -3, hour: 21)
        meeting.isCompleted = true

        let finance = Todo(title: "세금 서류 제출")
        finance.tags = ["finance"]
        finance.createdAt = makeDate(dayOffset: -6, hour: 9)
        finance.dueDate = makeDate(dayOffset: -3, hour: 13)
        finance.completedAt = makeDate(dayOffset: -3, hour: 21)
        finance.isCompleted = true

        let active = Todo(title: "프로젝트 마감 검토")
        active.tags = ["meeting", "project"]
        active.createdAt = makeDate(dayOffset: -1, hour: 10)
        active.dueDate = makeDate(dayOffset: 2, hour: 18)

        return [study, meeting, finance, active]
    }

    @Test("행동 패턴 휴리스틱은 작은 표본을 페르소나 신호로 과대 해석하지 않는다")
    func memoryHeuristicGatesSparseSignals() {
        let result = MemoryService.computeAnalysis(todos: makeHeuristicTodos(), language: .korean)

        #expect(result.summary.isEmpty == false)
        #expect(result.fastTags.isEmpty)
        #expect(result.productiveHour == nil)
        #expect(result.behaviorProfile.insight(for: .overdueCompletionRate)?.denominator == 3)
        #expect(result.behaviorProfile.insight(for: .completionConcentrationHour)?.confidence == .insufficient)
    }

    @Test("완료 기록이 없어도 7일 내 백로그 압박은 요약된다")
    func memoryHeuristicCapturesBacklogWithoutCompletions() {
        let backlogOnly = Todo(title: "주간 보고 제출")
        backlogOnly.dueDate = makeDate(dayOffset: 3, hour: 18)

        let result = MemoryService.computeAnalysis(todos: [backlogOnly], language: .korean)

        #expect(result.summary.contains("7일 내 마감 미완료"))
        #expect(result.insights.contains { $0.contains("미완료 TODO") })
        #expect(result.productiveHour == nil)
    }

    @Test("페르소나 휴리스틱은 텍스트와 2~3개 인사이트를 생성한다")
    func personaHeuristicGeneratesTextAndInsights() {
        let result = PersonaGenerationService().generateHeuristicPersona(
            existingPersona: "업무 마감과 회의 준비를 중시한다.",
            todos: makeHeuristicTodos(),
            language: .korean
        )
        #expect(result.personaText.isEmpty == false)
        #expect((2...3).contains(result.insights.count))
        #expect(!result.personaText.contains("과제 제출 준비"))
        #expect(result.personaText.contains("최근 기록") || result.personaText.contains("분석 근거"))
        #expect(!result.personaText.contains("자주 사용된 태그"))
    }
}



private func fixedDate(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
    return try #require(formatter.date(from: string))
}

private func makeGmailMessage(
    subject: String = "제출 일정 안내",
    body: String
) throws -> GmailMessage {
    GmailMessage(
        id: "msg-1",
        threadID: "thread-1",
        messageID: "<msg-1@example.com>",
        subject: subject,
        from: "PM <pm@example.com>",
        snippet: body,
        body: body,
        htmlBody: nil,
        receivedAt: try fixedDate("2026-07-01T00:00:00+09:00"),
        labelIds: [],
        isBulk: false
    )
}
