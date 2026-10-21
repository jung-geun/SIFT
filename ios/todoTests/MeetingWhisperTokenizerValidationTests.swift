import Foundation
import Testing
import WhisperKit
@testable import todo

@MainActor
@Suite("Whisper local tokenizer validation")
struct MeetingWhisperTokenizerValidationTests {
    // Independent snapshot of the actual pinned large-v3 vocabulary ordering.
    private static let pinnedCodes = """
    en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su yue
    """.split(separator: " ").map(String.init)

    private var rawTokens: [String: Int] {
        var tokens = Dictionary(uniqueKeysWithValues: Self.pinnedCodes.enumerated().map {
            ("<|\($0.element)|>", 50_259 + $0.offset)
        })
        tokens["<|startoftranscript|>"] = 50_258
        return tokens
    }

    private func validate(_ tokens: [String: Int], reverse: [Int: String]? = nil) throws -> [Int: String] {
        // Build reverse without uniqueKeysWithValues so deliberately colliding
        // corrupt fixtures reach the production validator rather than trapping.
        let reverse = reverse ?? tokens.reduce(into: [Int: String]()) { $0[$1.value] = $1.key }
        return try MeetingWhisperOfflineLoader.validatedLanguageTokenCodes(
            tokenID: { tokens[$0] }, tokenText: { reverse[$0] }
        )
    }

    @Test("All 100 raw token round trips produce exact immutable-map input including legacy codes")
    func pinnedVocabulary() throws {
        let codes = try validate(rawTokens)
        #expect(codes.count == 100)
        #expect(Set(codes.keys) == Set(50_259...50_358))
        for (offset, code) in Self.pinnedCodes.enumerated() {
            #expect(codes[50_259 + offset] == code)
        }
        #expect(codes[50_264] == "ko")
        #expect(codes[50_356] == "jw")
        #expect(codes[50_358] == "yue")
        #expect(codes[50_258] == nil)
    }

    @Test("SOT must be raw token 50258 in both directions, never a wrapper fallback")
    func pinnedSOT() {
        for replacement in [Int?.none, 50_257, 50_259, 50_260] {
            var tokens = rawTokens
            tokens["<|startoftranscript|>"] = replacement
            #expect(throws: MeetingWhisperModelError.self) { try validate(tokens) }
        }
        let tokens = rawTokens
        var reverse = tokens.reduce(into: [Int: String]()) { $0[$1.value] = $1.key }
        reverse[50_258] = "<|wrong|>"
        #expect(throws: MeetingWhisperModelError.self) { try validate(tokens, reverse: reverse) }
    }

    @Test("Every language is required, unique, in range, and round-trips its own spelling")
    func corruptLanguageLookups() {
        for code in Self.pinnedCodes {
            var missing = rawTokens
            missing["<|\(code)|>"] = nil
            #expect(throws: MeetingWhisperModelError.self) { try validate(missing) }
        }
        for id in [50_258, 50_359, -1, Int.max] {
            var outOfRange = rawTokens
            outOfRange["<|bn|>"] = id
            #expect(throws: MeetingWhisperModelError.self) { try validate(outOfRange) }
        }
        var aliased = rawTokens
        aliased["<|bn|>"] = 50_259
        #expect(throws: MeetingWhisperModelError.self) { try validate(aliased) }
        let tokens = rawTokens
        var reverse = tokens.reduce(into: [Int: String]()) { $0[$1.value] = $1.key }
        reverse[50_358] = "<|zh|>"
        #expect(throws: MeetingWhisperModelError.self) { try validate(tokens, reverse: reverse) }
    }

    @Test("Pinned large-v3 special tokens cannot fall back to older language/task IDs")
    func specialTokenEvidence() throws {
        let tokens = ["<|endoftext|>": 50257, "<|en|>": 50259, "<|nospeech|>": 50363,
                      "<|notimestamps|>": 50364, "<|startofprev|>": 50362, "<|startoftranscript|>": 50258,
                      "<|0.00|>": 50365, "<|transcribe|>": 50360, "<|translate|>": 50359]
        let reverse = Dictionary(uniqueKeysWithValues: tokens.map { ($0.value, $0.key) })
        let special = try MeetingWhisperOfflineLoader.validatedSpecialTokens(tokenID: { tokens[$0] }, tokenText: { reverse[$0] })
        #expect(special.noSpeechToken == 50363)
        #expect(special.transcribeToken == 50360)
        for (token, id) in tokens {
            var missing = tokens
            missing[token] = nil
            #expect(throws: MeetingWhisperModelError.self) {
                try MeetingWhisperOfflineLoader.validatedSpecialTokens(tokenID: { missing[$0] }, tokenText: { reverse[$0] })
            }
            var mismatched = reverse
            mismatched[id] = "<|en|>"
            if token != "<|en|>" {
                #expect(throws: MeetingWhisperModelError.self) {
                    try MeetingWhisperOfflineLoader.validatedSpecialTokens(tokenID: { tokens[$0] }, tokenText: { mismatched[$0] })
                }
            }
        }
    }
}
