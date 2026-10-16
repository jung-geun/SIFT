import Foundation
import Testing
@testable import todo

@Suite("Typed Laya decision results")
struct LayaDecisionAnswerTests {
    private func answer(
        _ question: LayaQuestion, logits: [Double], raw: [Double],
        action: Double = 1, truncated: Bool = false
    ) throws -> LayaAnswer {
        try LayaAnswer(
            question: question, logits: logits, rawProbabilities: raw,
            actionProbability: action, stateWasTruncated: truncated,
            tokenCount: 100, modelRevision: "test-revision"
        )
    }

    @Test("predicate true is the second option, never the legacy yes-first index")
    func predicateDirection() throws {
        let yes = try answer(.emailCandidate, logits: [-1000, 1000], raw: [0, 1])
        #expect(yes.question.type == .noul)
        #expect(yes.question.labels == ["false", "true"])
        #expect(try LayaEmailDecisionService.outcome(for: yes) == .candidate)
        #expect(yes.predicateProbability == 1)
        #expect(yes.selectedID == "true")
        #expect(yes.isDecisive)
        let no = try answer(.emailCandidate, logits: [1000, -1000], raw: [1, 0])
        #expect(no.predicateProbability == 0)
        #expect(no.selectedID == "false")
        #expect(try LayaEmailDecisionService.outcome(for: no) == .notCandidate)
    }

    @Test("email ambiguity, escalation and omitted evidence remain uncertain in either direction")
    func emailUncertainty() throws {
        for logits in [[1.0, 1.0], [0.0, 0.1], [0.1, 0.0]] {
            let ambiguous = try answer(.emailCandidate, logits: logits, raw: [0.5, 0.5])
            #expect(try LayaEmailDecisionService.outcome(for: ambiguous) == .uncertain)
        }
        for logits in [[10.0, 0.0], [0.0, 10.0]] {
            let escalated = try answer(.emailCandidate, logits: logits, raw: [0.5, 0.5], action: 0.1)
            #expect(try LayaEmailDecisionService.outcome(for: escalated) == .uncertain)
            let incomplete = try answer(.emailCandidate, logits: logits, raw: [0.5, 0.5], truncated: true)
            #expect(try LayaEmailDecisionService.outcome(for: incomplete) == .uncertain)
        }
        #expect(throws: (any Error).self) {
            try LayaEmailDecisionService.outcome(for: answer(.importance, logits: [0, 10], raw: [0, 1]))
        }
    }

    /// Deterministic budget pressure without loading model assets or invoking inference.
    private func emailEncoding(subject: String, sender: String, body: String) throws -> LayaPriorityEncoding.Input {
        try LayaPriorityEncoding.make(
            state: LayaEmailDecisionService.decisionState(subject: subject, sender: sender, body: body),
            question: .emailCandidate,
            encode: { text in stride(from: 0, to: text.utf8.count, by: 4).map { _ in 100 } }
        )
    }

    @Test("email evidence preserves original language, whitespace, quotes and later requests")
    func originalEmailEvidence() throws {
        let subject = "주간 \"계획\""
        let sender = "팀 <team@example.com>"
        let body = "안내\n> 과거 요청\n--\n끝에 회신해 주세요."
        let input = try emailEncoding(subject: subject, sender: sender, body: body)
        let fields = try #require(JSONSerialization.jsonObject(with: Data(input.stateJSON.utf8)) as? [String: String])
        #expect(fields["title"] == subject)
        #expect(fields["context"] == sender)
        #expect(fields["details"] == body)
        #expect(fields["due"] == "")
        #expect(!input.stateWasTruncated)
        #expect(input.question == .emailCandidate)
    }

    @Test("long raw email fields retain head and tail and omissions force uncertainty")
    func longEmailEvidence() throws {
        let input = try emailEncoding(
            subject: "제목 시작 " + String(repeating: "배경 ", count: 1000) + " 끝 제목",
            sender: "Sender start " + String(repeating: "name ", count: 1000) + " <sender@example.com>",
            body: "본문 시작\n" + String(repeating: "참고 자료\n", count: 2000) + "\n마지막 요청: 승인해 주세요."
        )
        let fields = try #require(JSONSerialization.jsonObject(with: Data(input.stateJSON.utf8)) as? [String: String])
        #expect(try #require(fields["title"]).hasPrefix("제목 시작"))
        #expect(try #require(fields["title"]).hasSuffix("끝 제목"))
        #expect(try #require(fields["context"]).hasPrefix("Sender start"))
        #expect(try #require(fields["context"]).hasSuffix("<sender@example.com>"))
        #expect(try #require(fields["details"]).hasPrefix("본문 시작"))
        #expect(try #require(fields["details"]).hasSuffix("마지막 요청: 승인해 주세요."))
        #expect(fields["due"] == "")
        #expect(input.stateWasTruncated)
        #expect(input.tokenCount <= LayaPriorityEncoding.sequenceLength)
        let result = try LayaAnswer(
            question: input.question, logits: [0, 10], rawProbabilities: [0, 1],
            actionProbability: 1, stateWasTruncated: input.stateWasTruncated,
            tokenCount: input.tokenCount, modelRevision: "test-revision"
        )
        #expect(try LayaEmailDecisionService.outcome(for: result) == .uncertain)
    }

    @Test("ordinal result uses expected level, not argmax or model-output slots beyond active options")
    func weightedScore() throws {
        let distribution = [0.1, 0.2, 0.3, 0.4]
        let value = try answer(.urgency, logits: distribution.map(log), raw: distribution)
        #expect(abs(try #require(value.expectedScore) - 2) < 1e-12)
        #expect(value.predicateProbability == nil)
        #expect(value.selectedID == "3")
    }

    @Test("ties, escalations and incomplete evidence cannot become decisive recommendations")
    func uncertaintyGate() throws {
        let tie = try answer(.importance, logits: [1, 1], raw: [0.5, 0.5])
        #expect(tie.selectedIndex == 0)
        #expect(!tie.isDecisive)
        let escalation = try answer(.importance, logits: [0, 10], raw: [0, 1], action: 0.1)
        #expect(!escalation.isDecisive)
        let incomplete = try answer(.importance, logits: [0, 10], raw: [0, 1], truncated: true)
        #expect(!incomplete.isDecisive)
    }

    @Test("nonfinite logits, invalid distributions and missing active options are rejected")
    func invalidResults() {
        for logits in [[Double.nan, 0], [0, Double.infinity], [1]] {
            #expect(throws: (any Error).self) {
                try answer(.importance, logits: logits, raw: [0.5, 0.5])
            }
        }
        for raw in [[0.2, 0.2], [-0.2, 1.2], [Double.nan, 0], [1]] {
            #expect(throws: (any Error).self) {
                try answer(.importance, logits: [0, 1], raw: raw)
            }
        }
    }
}
