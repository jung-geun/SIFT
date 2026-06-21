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

    @Test("빈 문자열 → nil")
    func parseEmpty() {
        #expect(AppDateFormat.parseLLMDate("") == nil)
    }

    @Test("공백만 → nil")
    func parseWhitespace() {
        #expect(AppDateFormat.parseLLMDate("   ") == nil)
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

    @Test("빈 insights 배열")
    func emptyInsights() {
        let raw = #"{"persona":"요약","insights":[]}"#
        let (persona, _) = sut.parsePersonaJSON(raw)
        #expect(persona == "요약")
    }

    @Test("JSON 파싱 실패 → raw fallback (persona에 원본 텍스트)")
    func fallbackOnInvalidJSON() {
        let raw = "JSON이 아닌 텍스트입니다."
        let (persona, insights) = sut.parsePersonaJSON(raw)
        #expect(persona == raw)
        #expect(insights.isEmpty)
    }

    @Test("persona 키 없음 → raw fallback")
    func missingPersonaKey() {
        let raw = #"{"insights":["패턴"]}"#
        let (persona, _) = sut.parsePersonaJSON(raw)
        // persona 키 없으면 빈 문자열 → fallback to raw
        #expect(!persona.isEmpty)
    }
}

// MARK: -

@Suite("OnDeviceLLMEmailEngine 이메일 추출 파서")
struct EmailExtractionParserTests {

    private let sut = OnDeviceLLMEmailEngine()
    private let now = Date()

    /// 테스트용 GmailMessage 헬퍼
    private func makeMsg(
        subject: String = "테스트 제목",
        from: String = "홍길동 <hong@example.com>"
    ) -> GmailMessage {
        GmailMessage(
            id: "test-id", threadID: "t1", messageID: "<test@msg>",
            subject: subject, from: from,
            snippet: "", body: "본문", receivedAt: now, labelIds: [], isBulk: false
        )
    }

    @Test("정상 JSON → EmailExtraction 반환")
    func normalExtraction() {
        let future = now.addingTimeInterval(86_400 * 7)   // 1주일 후
        let iso = AppDateFormat.llmString(from: future)
        let json = "{\"dueDate\":\"\(iso)\",\"triage\":\"todo\",\"notes\":\"요약\"}"
        let result = sut.parseExtraction(json: json, msg: makeMsg(), now: now)
        #expect(result != nil)
        #expect(result?.keywordScore == 1)
        #expect(result?.notes.contains("요약") == true)
    }

    @Test("dueDate null → nil")
    func nullDate() {
        let json = #"{"dueDate":"null","triage":"review","notes":"요약"}"#
        #expect(sut.parseExtraction(json: json, msg: makeMsg(), now: now) == nil)
    }

    @Test("dueDate 빈 문자열 → nil")
    func emptyDate() {
        let json = #"{"dueDate":"","triage":"review","notes":""}"#
        #expect(sut.parseExtraction(json: json, msg: makeMsg(), now: now) == nil)
    }

    @Test("과거 날짜 → nil (d > now 검증)")
    func pastDate() {
        let past = now.addingTimeInterval(-86_400)   // 어제
        let iso = AppDateFormat.llmString(from: past)
        let json = "{\"dueDate\":\"\(iso)\",\"triage\":\"todo\",\"notes\":\"\"}"
        #expect(sut.parseExtraction(json: json, msg: makeMsg(), now: now) == nil)
    }

    @Test("triage review → keywordScore 0")
    func reviewTriage() {
        let future = now.addingTimeInterval(86_400 * 7)
        let iso = AppDateFormat.llmString(from: future)
        let json = "{\"dueDate\":\"\(iso)\",\"triage\":\"review\",\"notes\":\"\"}"
        let result = sut.parseExtraction(json: json, msg: makeMsg(), now: now)
        #expect(result?.keywordScore == 0)
    }

    @Test("손상된 JSON → nil")
    func brokenJSON() {
        #expect(sut.parseExtraction(json: "not json", msg: makeMsg(), now: now) == nil)
    }
}

// MARK: -

@Suite("CloudIntelligenceEngine 랭킹 파서")
@MainActor
struct RankingParserTests {

    /// CloudIntelligenceEngine은 API 호출 없이 parseRankings만 테스트
    private let sut = CloudIntelligenceEngine(provider: .claude, apiKey: "test-key", model: "claude-haiku-4-5-20251001")

    @Test("정상 4축 JSON → PriorityResult 반환")
    func normal() {
        let uuid = UUID().uuidString
        let json = """
        {"scheduled_tasks":[{"task_id":"\(uuid)","scoring":{"deadline_proximity":8.0,"urgency":7.0,"task_importance":9.0,"task_chaining":2.0},"reasoning":{"summary":"중요 업무","chaining_detail":""},"recommended_schedule":{"start_time":""},"needs_notification":true,"persona_fit":true}]}
        """
        let results = sut.parseRankings(text: json)
        #expect(results.count == 1)
        #expect(results.first?.todoID == UUID(uuidString: uuid))
        #expect(results.first?.needsNotification == true)
        #expect(results.first?.personaFit == true)
    }

    @Test("score 정규화 (0~1 범위 보장)")
    func scoreNormalized() {
        let uuid = UUID().uuidString
        let json = """
        {"scheduled_tasks":[{"task_id":"\(uuid)","scoring":{"deadline_proximity":10.0,"urgency":10.0,"task_importance":10.0,"task_chaining":9.0},"reasoning":{"summary":"최고 우선순위","chaining_detail":""},"recommended_schedule":{"start_time":""},"needs_notification":true,"persona_fit":true}]}
        """
        let results = sut.parseRankings(text: json)
        if let score = results.first?.score {
            #expect(score >= 0.0)
            #expect(score <= 1.0)
        }
    }

    @Test("task_id 유효하지 않은 UUID → 필터링")
    func invalidUUID() {
        let json = """
        {"scheduled_tasks":[{"task_id":"not-a-uuid","scoring":{"deadline_proximity":5.0,"urgency":5.0,"task_importance":5.0,"task_chaining":2.0},"reasoning":{"summary":"","chaining_detail":""},"recommended_schedule":{"start_time":""},"needs_notification":false,"persona_fit":false}]}
        """
        let results = sut.parseRankings(text: json)
        #expect(results.isEmpty)
    }

    @Test("잘못된 JSON → 빈 배열")
    func invalidJSON() {
        #expect(sut.parseRankings(text: "not json").isEmpty)
    }

    @Test("마크다운 코드블록 래핑 → brace 추출 후 파싱")
    func markdownWrapped() {
        let uuid = UUID().uuidString
        let json = """
        ```json
        {"scheduled_tasks":[{"task_id":"\(uuid)","scoring":{"deadline_proximity":5.0,"urgency":5.0,"task_importance":5.0,"task_chaining":2.0},"reasoning":{"summary":"테스트","chaining_detail":""},"recommended_schedule":{"start_time":""},"needs_notification":false,"persona_fit":false}]}
        ```
        """
        let results = sut.parseRankings(text: json)
        #expect(results.count == 1)
    }
}

// MARK: -

@Suite("OnDeviceLLMIntelligenceEngine 스케줄 V9 파서")
@MainActor
struct ScheduleV9ParserTests {

    private let sut = OnDeviceLLMIntelligenceEngine()

    @Test("정상 V9 JSON → PriorityResult 반환")
    func normal() {
        var todo = Todo()
        let uuid = todo.id.uuidString
        let json = """
        {"scheduled_tasks":[{"task_id":"\(uuid)","scoring":{"deadline_proximity":5.0,"urgency":5.0,"task_importance":7.0,"task_chaining":2.0},"reasoning":{"summary":"중요 업무","chaining_detail":""},"recommended_schedule":{"start_time":""}}]}
        """
        let results = sut.parseScheduleResponseV9(text: json, todos: [todo], persona: .empty)
        #expect(results != nil)
        #expect(results?.count == 1)
        #expect(results?.first?.todoID == todo.id)
    }

    @Test("task_id todos 불일치 → JSON UUID 그대로 사용, personaFit=false")
    func mismatchID() {
        let jsonUUID = UUID()
        let todo = Todo()   // 다른 UUID
        let json = """
        {"scheduled_tasks":[{"task_id":"\(jsonUUID.uuidString)","scoring":{"deadline_proximity":5.0,"urgency":5.0,"task_importance":5.0,"task_chaining":2.0},"reasoning":{"summary":"","chaining_detail":""},"recommended_schedule":{"start_time":""}}]}
        """
        let results = sut.parseScheduleResponseV9(text: json, todos: [todo], persona: .empty)
        // 파서는 todos 배열과 대조하지 않고 JSON UUID를 todoID로 직접 사용
        #expect(results?.count == 1)
        #expect(results?.first?.todoID == jsonUUID)
        #expect(results?.first?.personaFit == false)
    }

    @Test("잘못된 JSON → nil")
    func invalidJSON() {
        let results = sut.parseScheduleResponseV9(text: "not json", todos: [], persona: .empty)
        #expect(results == nil)
    }

    @Test("scoring 4축 값 0~10 클램프 확인")
    func scoringClamp() {
        var todo = Todo()
        let uuid = todo.id.uuidString
        // 범위 초과값 입력
        let json = """
        {"scheduled_tasks":[{"task_id":"\(uuid)","scoring":{"deadline_proximity":99.0,"urgency":-5.0,"task_importance":50.0,"task_chaining":0.5},"reasoning":{"summary":"클램프 테스트","chaining_detail":""},"recommended_schedule":{"start_time":""}}]}
        """
        let results = sut.parseScheduleResponseV9(text: json, todos: [todo], persona: .empty)
        #expect(results != nil)
        if let score = results?.first?.score {
            #expect(score >= 0.0)
            #expect(score <= 1.0)
        }
    }
}
