import Foundation
import Testing
@testable import todo

@Suite("Memo task extraction")
struct MemoTaskExtractionTests {
    @Test("Parses task titles from JSON wrapped in prose")
    func parsesTitlesFromWrappedJSON() throws {
        let raw = "Here you go: {\"tasks\":[{\"title\":\"Send budget draft\"},{\"title\":\"Book room\"}]} thanks"
        let titles = try MemoTaskExtraction.titles(fromResponse: raw)
        #expect(titles == ["Send budget draft", "Book room"])
    }

    @Test("Drops blank, overlong, and repeated titles, keeping first-seen order")
    func dropsInvalidAndRepeatedTitles() throws {
        let long = String(repeating: "a", count: MemoTaskExtraction.maxTitleLength + 1)
        let raw = """
        {"tasks":[{"title":"  Ship   release "},{"title":""},{"title":"\(long)"},{"title":"ship release"},{"title":"Call Kim"}]}
        """
        let titles = try MemoTaskExtraction.titles(fromResponse: raw)
        #expect(titles == ["Ship release", "Call Kim"])
    }

    @Test("A response without a tasks object is rejected, not treated as empty success")
    func rejectsMalformedResponse() {
        #expect(throws: MemoTaskExtractionError.invalidResponse) {
            try MemoTaskExtraction.titles(fromResponse: "no json here")
        }
    }

    @Test("An empty tasks array yields no titles")
    func emptyTasksYieldNothing() throws {
        #expect(try MemoTaskExtraction.titles(fromResponse: "{\"tasks\":[]}").isEmpty)
    }

    @Test("Duplicate detection ignores case and extra whitespace")
    func duplicateDetectionNormalizes() {
        #expect(MemoTaskExtraction.isDuplicate("  Book   ROOM ", of: ["book room"]))
        #expect(!MemoTaskExtraction.isDuplicate("Book room 2", of: ["book room"]))
    }

    @Test("Unavailable model throws instead of inventing tasks")
    func unavailableModelInventsNothing() async {
        let service = MemoTaskExtractionService(isAvailable: { false })
        await #expect(throws: MemoTaskExtractionError.unavailable) {
            try await service.suggest(from: "Buy milk tomorrow")
        }
    }
}

@Suite("Memo slicing and cross-slice merge")
struct MemoSlicingTests {
    @Test("Every slice respects the character bound and no text is lost")
    func slicesAreBoundedAndComplete() {
        let lines = (1...200).map { "line \($0) with some words" }
        let memo = lines.joined(separator: "\n")
        let slices = MemoTaskExtraction.slices(of: memo, maxCharacters: 300)
        #expect(slices.count > 1)
        #expect(slices.allSatisfy { $0.count <= 300 })
        let rejoined = slices.joined(separator: "\n")
        #expect(lines.allSatisfy { rejoined.contains($0) })
    }

    @Test("An overlong single line is hard-split into bounded pieces")
    func overlongLineIsSplit() {
        let memo = String(repeating: "x", count: 2_500)
        let slices = MemoTaskExtraction.slices(of: memo, maxCharacters: 1_000)
        #expect(slices.map(\.count) == [1_000, 1_000, 500])
    }

    @Test("Blank memo produces no slices")
    func blankMemoHasNoSlices() {
        #expect(MemoTaskExtraction.slices(of: " \n \n").isEmpty)
    }

    @Test("Merge removes repeats across slices and keeps first-seen order")
    func mergeDedupesAcrossSlices() {
        let merged = MemoTaskExtraction.merge([["Send budget", "Book room"], ["book  ROOM", "Call Kim"]])
        #expect(merged == ["Send budget", "Book room", "Call Kim"])
    }

    @Test("Model is called once per slice and results are merged")
    func suggestCallsPerSlice() async throws {
        let log = PromptLog()
        let service = MemoTaskExtractionService(
            respond: { _, prompt, _ in
                log.append(prompt)
                return prompt.contains("alpha") ? #"{"tasks":[{"title":"Ship A"}]}"# : #"{"tasks":[{"title":"Ship A"},{"title":"Ship B"}]}"#
            },
            isAvailable: { true }
        )
        let memo = String(repeating: "alpha ", count: 300) + "\n" + String(repeating: "beta ", count: 300)
        let titles = try await service.suggest(from: memo)
        let prompts = log.values
        #expect(prompts.count == MemoTaskExtraction.slices(of: memo).count)
        #expect(prompts.count >= 2)
        #expect(titles == ["Ship A", "Ship B"])
    }
}

private final class PromptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
