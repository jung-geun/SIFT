import Foundation
import NaturalLanguage
import WhisperKit

/// The v1.1.0 SDK falls back to Hub downloads if its local tokenizer load
/// fails. Supply a locally parsed tokenizer *before* loading models instead;
/// `loadTokenizerIfNeeded` then has no occasion to contact the Hub.
enum MeetingWhisperOfflineLoader {
    static func load(modelDirectory: URL, tokenizerDirectory: URL) async throws -> WhisperKit {
        // This API parses local bytes only; unlike ModelUtilities.loadTokenizer,
        // AutoTokenizerWrapper.from(modelFolder:) has no pretrained/Hub fallback.
        let tokens = try await AutoTokenizerWrapper.from(modelFolder: tokenizerDirectory)
        try Task.checkCancellation()
        let config = WhisperKitConfig(
            modelFolder: modelDirectory.path,
            tokenizerFolder: tokenizerDirectory,
            prewarm: false,
            load: false,
            download: false
        )
        let model = try await WhisperKit(config)
        model.tokenizer = MeetingWhisperLocalTokenizer(tokens)
        try await model.loadModels()
        // Supplying the tokenizer before load intentionally bypasses the SDK's
        // Hub fallback, but also bypasses its multilingual-variant detection.
        // The pinned large-v3 graph must expose the expected vocabulary before
        // explicit language prompts or word timestamps are decoded.
        guard model.textDecoder.logitsSize == 51_866,
              model.audioEncoder.embedSize == 1_280 else {
            await model.unloadModels()
            throw MeetingWhisperModelError.corruptArtifact
        }
        model.textDecoder.isModelMultilingual = true
        return model
    }
}

/// Adapts the SDK's local-only TokenizerWrapper to WhisperTokenizer. The SDK's
/// own WhisperTokenizerWrapper initializer is internal at v1.1.0, so the
/// upstream token selection and word grouping are mirrored here.
private final class MeetingWhisperLocalTokenizer: WhisperTokenizer {
    private let tokenizer: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(_ tokenizer: TokenizerWrapper) {
        self.tokenizer = tokenizer
        func id(_ token: String, fallback: Int) -> Int {
            tokenizer.convertTokenToId(token) ?? fallback
        }
        specialTokens = SpecialTokens(
            endToken: id("<|endoftext|>", fallback: 50257),
            englishToken: id("<|en|>", fallback: 50259),
            noSpeechToken: id("<|nospeech|>", fallback: 50362),
            noTimestampsToken: id("<|notimestamps|>", fallback: 50363),
            specialTokenBegin: id("<|endoftext|>", fallback: 50257),
            startOfPreviousToken: id("<|startofprev|>", fallback: 50361),
            startOfTranscriptToken: id("<|startoftranscript|>", fallback: 50258),
            timeTokenBegin: id("<|0.00|>", fallback: 50364),
            transcribeToken: id("<|transcribe|>", fallback: 50359),
            translateToken: id("<|translate|>", fallback: 50358),
            whitespaceToken: id(" ", fallback: 220)
        )
        let tokenBoundary = specialTokens.specialTokenBegin
        allLanguageTokens = Set(Constants.languageCodes.compactMap {
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
