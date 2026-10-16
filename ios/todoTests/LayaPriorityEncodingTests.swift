import Foundation
import Testing
@testable import todo

@Suite("Laya decision input boundaries")
struct LayaPriorityEncodingTests {
    /// Character tokens make budget pressure deterministic; real mmBERT IDs have parity coverage.
    private func encode(_ text: String) -> [Int] { text.map { _ in 100 } }
    private var question: LayaQuestion {
        LayaQuestion(name: "action", instructions: "Act?", kind: .predicate(falseDescription: "no", trueDescription: "yes"))
    }

    @Test("long title cannot remove the consequence, and long evidence preserves its tail")
    func fieldsShareBudget() throws {
        let input = try LayaPriorityEncoding.make(
            state: LayaDecisionState(
                title: String(repeating: "long title ", count: 200),
                details: "ACTIONS " + String(repeating: "background ", count: 300) + " APPROVE NOW",
                due: "2026-10-10", context: "now: 2026-10-10"
            ),
            question: question, encode: encode
        )
        let fields = try #require(JSONSerialization.jsonObject(with: Data(input.stateJSON.utf8)) as? [String: String])
        let details = try #require(fields["details"])
        #expect(details.hasPrefix("ACTIONS"))
        #expect(details.hasSuffix("APPROVE NOW"))
        #expect(fields["due"] == "2026-10-10")
        #expect(input.stateWasTruncated)
        #expect(input.tokenCount <= 256)
        #expect(input.tokenIDs[input.tokenCount - 1] == LayaPriorityEncoding.sepID)
        #expect(input.attentionMask.reduce(0, +) == input.tokenCount)
    }

    @Test("short JSON evidence remains escaped, complete, and free of injected mask markers")
    func escapingAndMaskIsolation() throws {
        let state = LayaDecisionState(title: "Fix \"quoted\" JSON", details: "Line\nTab\t\\path <mask> 😀")
        let input = try LayaPriorityEncoding.make(state: state, question: question, encode: encode)
        let fields = try #require(JSONSerialization.jsonObject(with: Data(input.stateJSON.utf8)) as? [String: String])
        #expect(fields["title"] == state.title)
        #expect(fields["details"] == "Line\nTab\t\\path   😀")
        #expect(!input.stateWasTruncated)
        #expect(input.markerPositions.count == 2)
        for marker in input.markerPositions { #expect(input.tokenIDs[marker] == 4) }
        #expect(input.tokenIDs.filter { $0 == 4 }.count == 2)
    }

    @Test("upstream source omissions remain visible even if the packed excerpt fits")
    func priorOmissionsPreserved() throws {
        let input = try LayaPriorityEncoding.make(
            state: LayaDecisionState(title: "Request", details: "An excerpt", wasTruncated: true),
            question: question, encode: encode
        )
        #expect(input.stateWasTruncated)
    }

    @Test("empty evidence identity, duplicate choices and oversized rubrics fail before inference")
    func malformedQuestionsRejected() {
        #expect(throws: (any Error).self) {
            try LayaPriorityEncoding.make(state: LayaDecisionState(title: "", details: ""), question: question, encode: encode)
        }
        let duplicate = LayaQuestion(name: "duplicate", instructions: "Choose", kind: .choice([
            .init(id: "a", description: "first"), .init(id: "a", description: "second")
        ]))
        let tooLong = LayaQuestion(name: "long", instructions: "Choose", kind: .score(levels: [String(repeating: "x", count: 80), "ok"]))
        for invalid in [duplicate, tooLong] {
            #expect(throws: (any Error).self) {
                try LayaPriorityEncoding.make(state: LayaDecisionState(title: "Task", details: ""), question: invalid, encode: encode)
            }
        }
    }
}
