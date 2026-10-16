import Foundation
import Testing
@testable import todo

/// Python and Swift independently pack typed questions, then run the actual pinned tokenizer.
@Suite("Laya typed tokenizer parity")
@MainActor
struct LayaTokenizerParityTests {
    private struct ReferenceQuestion: Decodable {
        struct Option: Decodable { let id: String; let description: String }
        let name: String
        let version: Int
        let instructions: String
        let type: String
        let options: [Option]?
        let levels: [String]?
        let falseDescription: String?
        let trueDescription: String?

        func question() throws -> LayaQuestion {
            let kind: LayaQuestion.Kind
            switch type {
            case "choice": kind = .choice(try #require(options).map { .init(id: $0.id, description: $0.description) })
            case "score": kind = .score(levels: try #require(levels))
            case "noul": kind = .predicate(falseDescription: try #require(falseDescription), trueDescription: try #require(trueDescription))
            default: throw LayaPriorityEncoding.EncodingError.invalidQuestion
            }
            return LayaQuestion(name: name, version: version, instructions: instructions, kind: kind)
        }
    }

    private struct ReferenceState: Decodable {
        let title: String
        let details: String
        let due: String
        let context: String
        let wasTruncated: Bool
    }

    private struct ReferenceCase: Decodable {
        let id: String
        let question: ReferenceQuestion
        let state: ReferenceState
        let input_ids: [Int]
        let attention_mask: [Int]
        let marker_pos: [Int]
        let question_type: Int
        let state_json: String
        let state_was_truncated: Bool
        let token_count: Int
    }
    private struct ReferenceFile: Decodable { let schema_version: Int; let cases: [ReferenceCase] }

    @Test("typed prompts and complete packed JSON match the Python mmBERT reference")
    func swiftEncodingMatchesPythonReference() async throws {
        let bundle = Bundle(for: LayaTokenizerParityFixtureLocator.self)
        let directory = try #require(bundle.resourceURL)
        let vectorsURL = try #require(bundle.url(forResource: "laya_multilingual_vectors", withExtension: "json"))
        let tokenizer = try await LayaPriorityTokenizer(modelDirectory: directory)
        let reference = try JSONDecoder().decode(ReferenceFile.self, from: Data(contentsOf: vectorsURL))
        #expect(reference.schema_version == 2)
        for row in reference.cases {
            let input = try tokenizer.encode(
                state: LayaDecisionState(title: row.state.title, details: row.state.details, due: row.state.due,
                                         context: row.state.context, wasTruncated: row.state.wasTruncated),
                question: row.question.question()
            )
            #expect(input.tokenIDs == row.input_ids, "tokens: \(row.id)")
            #expect(input.attentionMask == row.attention_mask, "attention: \(row.id)")
            #expect(input.markerPositions == row.marker_pos, "markers: \(row.id)")
            #expect(input.question.type.index == row.question_type, "head type: \(row.id)")
            #expect(input.stateJSON == row.state_json, "packed evidence: \(row.id)")
            #expect(input.stateWasTruncated == row.state_was_truncated, "omissions: \(row.id)")
            #expect(input.tokenCount == row.token_count, "token count: \(row.id)")
        }
    }

    @Test("four-day and four-time scheduling questions fit the deployed tokenizer without dropping candidates")
    func scheduleQuestionBudget() async throws {
        let directory = try #require(Bundle(for: LayaTokenizerParityFixtureLocator.self).resourceURL)
        let tokenizer = try await LayaPriorityTokenizer(modelDirectory: directory)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 8)))
        let todo = Todo(title: "File report")
        todo.dueDate = now.addingTimeInterval(14 * 86400)
        todo.estimatedDurationMinutes = 30
        let base = PriorityResult(todoID: todo.id, score: 0.8, reason: "", detail: "", needsNotification: false,
                                  recommendedTime: nil, personaFit: false, engine: .laya, axes: nil)
        let rows = try await LayaPriorityEngine.schedule([base], todos: [todo], events: [], now: now, calendar: calendar) { _, question in
            let input = try tokenizer.encode(state: LayaDecisionState(title: todo.title, details: "Must file report"), question: question)
            #expect(input.activeOptions == 4)
            return try LayaAnswer(question: question, logits: [10, 0, 0, 0], rawProbabilities: [1, 0, 0, 0],
                                  actionProbability: 1, stateWasTruncated: input.stateWasTruncated,
                                  tokenCount: input.tokenCount, modelRevision: "fixture")
        }
        let start = try #require(rows.first?.recommendedTime)
        #expect(start == calendar.date(byAdding: .hour, value: 9, to: calendar.startOfDay(for: now)))
        let deadline = try #require(todo.dueDate)
        #expect(start.addingTimeInterval(30 * 60) <= deadline)
    }
}

private final class LayaTokenizerParityFixtureLocator {}
