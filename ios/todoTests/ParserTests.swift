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
}

// MARK: -

@Suite("PersonaGenerationService JSON 파서")
struct PersonaJSONParserTests {

    private let sut = PersonaGenerationService()

    @Test("정상 JSON → persona·insights 추출")
    func normal() {
        let raw = #"{"persona":"테스트 페르소나 요약.","insights":["패턴 1","패턴 2"]}"#
        let (persona, insights) = sut.parsePersonaJSON(raw)
        #expect(persona == "테스트 페르소나 요약.")
        #expect(insights == ["패턴 1", "패턴 2"])
    }

    @Test("코드블록 래핑 → brace 추출 후 파싱")
    func codeblock() {
        let raw = "```json\n{\"persona\":\"요약\",\"insights\":[\"인사이트\"]}\n```"
        let (persona, insights) = sut.parsePersonaJSON(raw)
        #expect(persona == "요약")
        #expect(insights == ["인사이트"])
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

        let candidates = TodoAISortScope.candidates(from: [todo, review])

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
        let rejected = TodoAISortScope.apply(reviewResult, in: candidates)

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
        let applied = TodoAISortScope.apply(todoResult, in: candidates)

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

    @Test("강화된 행동 패턴 휴리스틱은 마감 준수와 빠른 태그를 반영한다")
    func memoryHeuristicCapturesDueDateSignals() {
        let result = MemoryService.computeAnalysis(todos: makeHeuristicTodos())

        #expect(result.summary.isEmpty == false)
        #expect(result.fastTags.isEmpty == false)
        #expect(result.productiveHour != nil)
        #expect(result.insights.contains { $0.contains("정시") || $0.contains("지연") })
    }

    @Test("완료 기록이 없어도 7일 내 백로그 압박은 요약된다")
    func memoryHeuristicCapturesBacklogWithoutCompletions() {
        let backlogOnly = Todo(title: "주간 보고 제출")
        backlogOnly.dueDate = makeDate(dayOffset: 3, hour: 18)

        let result = MemoryService.computeAnalysis(todos: [backlogOnly])

        #expect(result.summary.contains("7일 내 마감 미완료"))
        #expect(result.insights.contains { $0.contains("미완료 항목") })
        #expect(result.productiveHour == nil)
    }

    @Test("페르소나 휴리스틱은 텍스트와 2~3개 인사이트를 생성한다")
    func personaHeuristicGeneratesTextAndInsights() {
        let result = PersonaGenerationService().generateHeuristicPersona(
            existingPersona: "업무 마감과 회의 준비를 중시한다.",
            todos: makeHeuristicTodos()
        )

        #expect(result.personaText.isEmpty == false)
        #expect((2...3).contains(result.insights.count))
    }
}
