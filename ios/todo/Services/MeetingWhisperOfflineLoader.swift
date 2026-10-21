import Foundation
import NaturalLanguage
import WhisperKit

/// The v1.1.0 SDK falls back to Hub downloads if its local tokenizer load
/// fails. Supply a locally parsed tokenizer *before* loading models instead;
/// `loadTokenizerIfNeeded` then has no occasion to contact the Hub.
enum MeetingWhisperOfflineLoader {
    static func load(modelDirectory: URL, tokenizerDirectory: URL) async throws -> MeetingWhisperKit {
        // This API parses local bytes only; unlike ModelUtilities.loadTokenizer,
        // AutoTokenizerWrapper.from(modelFolder:) has no pretrained/Hub fallback.
        let tokens = try await AutoTokenizerWrapper.from(modelFolder: tokenizerDirectory)
        try Task.checkCancellation()
        let languageTokenCodes = try validatedLanguageTokenCodes(
            tokenID: tokens.convertTokenToId, tokenText: tokens.convertIdToToken
        )
        let specialTokens = try validatedSpecialTokens(tokenID: tokens.convertTokenToId, tokenText: tokens.convertIdToToken)
        let config = WhisperKitConfig(
            modelFolder: modelDirectory.path,
            tokenizerFolder: tokenizerDirectory,
            prewarm: false,
            load: false,
            download: false
        )
        let model = try await MeetingWhisperKit(config, languageTokenCodes: languageTokenCodes)
        let tokenizer = MeetingWhisperLocalTokenizer(tokens, specialTokens: specialTokens)
        model.tokenizer = tokenizer
        try await model.loadModels()
        // Supplying the tokenizer before load intentionally bypasses the SDK's
        // Hub fallback, but also bypasses its multilingual-variant detection.
        // The pinned large-v3 graph must expose the expected vocabulary before
        // explicit language prompts or word timestamps are decoded.
        guard model.textDecoder.logitsSize == 51_866,
              model.audioEncoder.embedSize == 1_280,
              tokenizer.allLanguageTokens == Set(languageTokenCodes.keys) else {
            await model.unloadModels()
            throw MeetingWhisperModelError.corruptArtifact
        }
        model.textDecoder.isModelMultilingual = true
        return model
    }

    /// Validate raw local lookups, not the adapter's fallback special-token IDs.
    /// The pinned large-v3 vocabulary has SOT followed by exactly 100 languages.
    static func validatedLanguageTokenCodes(
        tokenID: (String) -> Int?, tokenText: (Int) -> String?
    ) throws -> [Int: String] {
        guard tokenID("<|startoftranscript|>") == 50_258,
              tokenText(50_258) == "<|startoftranscript|>",
              MeetingLanguageCatalog.whisperLanguageCodes.count == 100 else {
            throw MeetingWhisperModelError.corruptArtifact
        }
        var codes: [Int: String] = [:]
        codes.reserveCapacity(100)
        for code in MeetingLanguageCatalog.whisperLanguageCodes {
            let token = "<|\(code)|>"
            guard let id = tokenID(token), (50_259...50_358).contains(id),
                  tokenText(id) == token, codes.updateValue(code, forKey: id) == nil else {
                throw MeetingWhisperModelError.corruptArtifact
            }
        }
        guard codes.count == 100 else { throw MeetingWhisperModelError.corruptArtifact }
        return codes
    }

    /// The large-v3 language addition shifts task/no-speech/timestamp tokens.
    /// An absent local token must fail loading, not inherit the SDK's older IDs.
    static func validatedSpecialTokens(tokenID: (String) -> Int?, tokenText: (Int) -> String?) throws -> SpecialTokens {
        func require(_ token: String, _ expected: Int) throws -> Int {
            guard tokenID(token) == expected, tokenText(expected) == token else {
                throw MeetingWhisperModelError.corruptArtifact
            }
            return expected
        }
        return try SpecialTokens(
            endToken: require("<|endoftext|>", 50257), englishToken: require("<|en|>", 50259),
            noSpeechToken: require("<|nospeech|>", 50363), noTimestampsToken: require("<|notimestamps|>", 50364),
            specialTokenBegin: require("<|endoftext|>", 50257), startOfPreviousToken: require("<|startofprev|>", 50362),
            startOfTranscriptToken: require("<|startoftranscript|>", 50258), timeTokenBegin: require("<|0.00|>", 50365),
            transcribeToken: require("<|transcribe|>", 50360), translateToken: require("<|translate|>", 50359),
            whitespaceToken: 220
        )
    }
}

/// Adapts the SDK's local-only TokenizerWrapper to WhisperTokenizer. The SDK's
/// own WhisperTokenizerWrapper initializer is internal at v1.1.0, so the
/// upstream token selection and word grouping are mirrored here.
private final class MeetingWhisperLocalTokenizer: WhisperTokenizer {
    private let tokenizer: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(_ tokenizer: TokenizerWrapper, specialTokens: SpecialTokens) {
        self.tokenizer = tokenizer
        self.specialTokens = specialTokens
        let tokenBoundary = specialTokens.specialTokenBegin
        allLanguageTokens = Set(MeetingLanguageCatalog.whisperLanguageCodes.compactMap {
            tokenizer.convertTokenToId("<|\($0)|>")
        }.filter { $0 > tokenBoundary })
    }

    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let decoded = tokenizer.decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin })
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(decoded)
        let code = recognizer.dominantLanguage.flatMap {
            Locale(identifier: $0.rawValue).language.languageCode?.identifier
        }
        let (subwords, subtokens) = splitOnUnicode(tokenIds)
        if let code, ["zh", "ja", "th", "lo", "my", "yue"].contains(code) {
            return (subwords, subtokens)
        }
        var words: [String] = []
        var groups: [[Int]] = []
        for (subword, tokens) in zip(subwords, subtokens) {
            let special = tokens[0] >= specialTokens.specialTokenBegin
            let separated = subword.hasPrefix(" ")
                || UnicodeScalar(subword.trimmingCharacters(in: .whitespaces))
                    .map { CharacterSet.punctuationCharacters.contains($0) } == true
            if special || separated || words.isEmpty {
                words.append(subword)
                groups.append(tokens)
            } else {
                words[words.count - 1] += subword
                groups[groups.count - 1].append(contentsOf: tokens)
            }
        }
        return (words, groups)
    }

    private func splitOnUnicode(_ tokens: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let decodedFull = tokenizer.decode(tokens: tokens)
        let replacement = "\u{fffd}"
        var words: [String] = []
        var groups: [[Int]] = []
        var pending: [Int] = []
        for token in tokens {
            pending.append(token)
            let decoded = tokenizer.decode(tokens: pending)
            var genuineReplacement = false
            if let range = decoded.range(of: replacement), range.upperBound <= decodedFull.endIndex {
                genuineReplacement = decodedFull[range] == replacement
            }
            if !decoded.contains(replacement) || genuineReplacement {
                words.append(decoded)
                groups.append(pending)
                pending = []
            }
        }
        return (words, groups)
    }
}
