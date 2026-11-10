import Foundation

/// Failures are explicit. An unavailable or failed model never yields invented tasks.
nonisolated enum MemoTaskExtractionError: Error, Equatable {
    case unavailable
    case timedOut
    case invalidResponse
}

/// Pure parsing and duplicate detection, independent of the on-device model.
nonisolated enum MemoTaskExtraction {
    static let maxTasks = 20
    static let maxTitleLength = 120
    /// Keeps instructions + slice + output inside the ~4k-token on-device window.
    static let maxSliceCharacters = 1_200

    private struct Payload: Decodable {
        let tasks: [Item]
    }

    private struct Item: Decodable {
        let title: String
    }

    /// Accepts a JSON object with a `tasks` array, tolerating prose around it.
    /// Blank, overlong, and repeated titles are dropped; order is preserved.
    static func titles(fromResponse raw: String) throws -> [String] {
        var json = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = json.firstIndex(of: "{"), let last = json.lastIndex(of: "}") {
            json = String(json[first...last])
        }
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { throw MemoTaskExtractionError.invalidResponse }

        return merge([payload.tasks.map(\.title)])
    }

    /// Joins per-slice results: trims, drops blank/overlong titles, removes repeats across slices.
    static func merge(_ lists: [[String]]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for title in lists.joined() {
            let title = normalized(title)
            guard !title.isEmpty, title.count <= maxTitleLength else { continue }
            guard seen.insert(key(title)).inserted else { continue }
            result.append(title)
            if result.count == maxTasks { break }
        }
        return result
    }

    /// Line-preserving slices no longer than `maxCharacters`. A single overlong line is hard-split.
    static func slices(of text: String, maxCharacters: Int = maxSliceCharacters) -> [String] {
        var slices: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { slices.append(trimmed) }
            current = ""
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(line)
            while rest.count > maxCharacters {
                flush()
                slices.append(String(rest.prefix(maxCharacters)))
                rest = rest.dropFirst(maxCharacters)
            }
            if current.count + rest.count + 1 > maxCharacters { flush() }
            current += (current.isEmpty ? "" : "\n") + rest
        }
        flush()
        return slices
    }

    /// Case- and whitespace-insensitive match against existing todo titles.
    static func isDuplicate(_ title: String, of existing: [String]) -> Bool {
        let target = key(title)
        return existing.contains { key($0) == target }
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func key(_ text: String) -> String {
        normalized(text).lowercased()
    }
}

/// Turns free-form memo text into candidate task titles using the on-device model.
/// Returned titles are candidates only; the caller decides what becomes a Todo.
nonisolated struct MemoTaskExtractionService {
    var respond: @Sendable (_ instructions: String, _ userPrompt: String, _ maximumTokens: Int) async throws -> String = {
        try await LiveFoundationModelsRuntime().respondText(instructions: $0, userPrompt: $1, maximumResponseTokens: $2)
    }
    var isAvailable: () -> Bool = { FoundationModelsAvailability.isAvailable }
    var limit: Duration = .seconds(90)

    static let instructions = """
    You extract actionable to-do items from raw meeting or working notes.
    Return only a JSON object: {"tasks":[{"title":"..."}]}.
    Each title is a short imperative action written in the same language as the notes.
    Include only actions the notes explicitly commit to or require. Do not invent tasks.
    If there are none, return {"tasks":[]}.
    """

    /// Each slice is one bounded model call. Any slice failure fails the whole
    /// suggestion instead of silently dropping that part of the memo.
    func suggest(from memo: String) async throws -> [String] {
        guard isAvailable() else { throw MemoTaskExtractionError.unavailable }
        var perSlice: [[String]] = []
        for slice in MemoTaskExtraction.slices(of: memo) {
            let respond = respond
            let raw: String
            do {
                raw = try await AsyncDeadline.run(limit) {
                    try await respond(Self.instructions, slice, 800)
                }
            } catch is AsyncDeadline.Expired {
                throw MemoTaskExtractionError.timedOut
            }
            perSlice.append(try MemoTaskExtraction.titles(fromResponse: raw))
        }
        return MemoTaskExtraction.merge(perSlice)
    }
}
