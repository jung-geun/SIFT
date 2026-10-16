import Foundation

/// Typed questions for the pinned 256-token, 32-option graph; expose 2–4 active options.
/// Field-aware packing keeps valid JSON and both ends of long evidence, reporting omissions.
nonisolated struct LayaPriorityEncoding {
    static let sequenceLength = 256
    static let headLength = 256
    static let maxOptions = 32
    static let padID = 0
    static let clsID = 2
    static let sepID = 1
    static let maskID = 4

    struct Input: Equatable {
        let tokenIDs: [Int]
        let attentionMask: [Int]
        let markerPositions: [Int]
        let activeOptions: Int
        let question: LayaQuestion
        let stateWasTruncated: Bool
        let tokenCount: Int
        let stateJSON: String
    }

    enum EncodingError: Error {
        case invalidTokenizer
        case invalidState
        case invalidQuestion
        case promptTooLong
    }

    static func make(
        state: LayaDecisionState,
        question: LayaQuestion,
        encode: (String) -> [Int]
    ) throws -> Input {
        guard !state.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EncodingError.invalidState
        }
        try question.validate()
        func sanitized(_ text: String) -> String { text.replacingOccurrences(of: "<mask>", with: " ") }
        let questionTokens = encode("\(question.type.rawValue) question: \(sanitized(question.instructions))")
        let optionTokens = question.renderedOptions.map { encode(" " + sanitized($0)) }
        // Reject unsupported question shapes rather than silently losing rubric criteria.
        guard optionTokens.allSatisfy({ $0.count <= 48 }),
              questionTokens.count + optionTokens.reduce(0, { $0 + $1.count + 1 }) <= headLength else {
            throw EncodingError.promptTooLong
        }
        var ids = [clsID] + questionTokens + [sepID]
        var markers = [Int]()
        for option in optionTokens {
            markers.append(ids.count)
            ids.append(maskID)
            ids.append(contentsOf: option)
        }
        ids.append(sepID)
        let room = sequenceLength - ids.count - 1
        guard room >= 64 else { throw EncodingError.promptTooLong }
        let packed = try pack(state: state, budget: room, encode: encode)
        ids.append(contentsOf: packed.tokens)
        ids.append(sepID)
        let used = ids.count
        ids.append(contentsOf: repeatElement(padID, count: sequenceLength - used))
        return Input(
            tokenIDs: ids,
            attentionMask: Array(repeating: 1, count: used) + Array(repeating: 0, count: sequenceLength - used),
            markerPositions: markers,
            activeOptions: markers.count,
            question: question,
            stateWasTruncated: state.wasTruncated || packed.truncated,
            tokenCount: used,
            stateJSON: packed.json
        )
    }

    private static func quoted(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else { throw EncodingError.invalidState }
        return text
    }

    private static func pack(
        state: LayaDecisionState, budget: Int, encode: (String) -> [Int]
    ) throws -> (json: String, tokens: [Int], truncated: Bool) {
        // Bound tokenization work without discarding the end of long mail or task evidence.
        func bounded(_ value: String, limit: Int) -> (text: String, truncated: Bool) {
            let prefix = value.prefix(limit + 1)
            guard prefix.count > limit else { return (String(prefix), false) }
            return (String(prefix.prefix(limit / 2)) + " … " + String(value.suffix(limit / 2)), true)
        }
        let originals = [state.context, state.due, state.title, state.details]
        let limits = [512, 128, 512, 4096]
        let boundedFields = zip(originals, limits).map { bounded($0.0, limit: $0.1) }
        let values = boundedFields.map { $0.text.replacingOccurrences(of: "<mask>", with: " ") }
        func render(_ fields: [String]) throws -> String {
            "{\"context\": \(try quoted(fields[0])), \"due\": \(try quoted(fields[1])), \"title\": \(try quoted(fields[2])), \"details\": \(try quoted(fields[3]))}"
        }
        let full = try render(values)
        let fullTokens = encode(full)
        if fullTokens.count <= budget {
            return (full, fullTokens, boundedFields.contains { $0.truncated })
        }
        // Quotas include each field's JSON quotes. Keep factual time context and title from
        // consuming the evidence budget. Short fields give their unused space to details.
        func fit(_ value: String, tokens: Int) throws -> String {
            if try encode(quoted(value)).count <= tokens { return value }
            let characters = Array(value)
            var low = 0
            var high = characters.count
            var best = ""
            while low <= high {
                let count = (low + high) / 2
                let candidate = count == 0 ? "" : String(characters.prefix((count + 1) / 2)) + " … " + String(characters.suffix(count / 2))
                if try encode(quoted(candidate)).count <= tokens {
                    best = candidate
                    low = count + 1
                } else {
                    high = count - 1
                }
            }
            return best
        }
        var fields = [
            try fit(values[0], tokens: min(40, budget / 4)),
            try fit(values[1], tokens: min(24, budget / 8)),
            try fit(values[2], tokens: min(40, budget / 4)),
            ""
        ]
        let fixedCost = try encode(render(fields)).count
        var detailsBudget = max(2, budget - fixedCost)
        while true {
            fields[3] = try fit(values[3], tokens: detailsBudget)
            let json = try render(fields)
            let tokens = encode(json)
            if tokens.count <= budget { return (json, tokens, true) }
            guard detailsBudget > 2 else { throw EncodingError.invalidState }
            detailsBudget = max(2, detailsBudget - max(1, tokens.count - budget))
        }
    }
}
