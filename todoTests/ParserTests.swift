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
}
