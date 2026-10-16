import Foundation
import Hub
import Tokenizers

/// Loads only the tokenizer shipped alongside the pinned Core ML model.
/// Never fetches tokenizer assets independently of its matching graph revision.
struct LayaPriorityTokenizer {
    private let tokenizer: any Tokenizer

    init(modelDirectory: URL) async throws {
        let tokenizerFileURL = modelDirectory.appendingPathComponent("tokenizer.json")
        guard FileManager.default.fileExists(atPath: tokenizerFileURL.path) else {
            throw LayaPriorityEncoding.EncodingError.invalidTokenizer
        }
        let tokenizerData = try HubApi.shared.configuration(fileURL: tokenizerFileURL)
        let tokenizerConfig = Config([
            "tokenizer_class": "PreTrainedTokenizerFast",
            "clean_up_tokenization_spaces": false
        ])
        let loaded = try PreTrainedTokenizer(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)

        guard loaded.convertTokenToId("<bos>") == LayaPriorityEncoding.clsID,
              loaded.convertTokenToId("<eos>") == LayaPriorityEncoding.sepID,
              loaded.convertTokenToId("<mask>") == LayaPriorityEncoding.maskID,
              loaded.convertTokenToId("<pad>") == LayaPriorityEncoding.padID else {
            throw LayaPriorityEncoding.EncodingError.invalidTokenizer
        }
        tokenizer = loaded
    }

    func encode(state: LayaDecisionState, question: LayaQuestion) throws -> LayaPriorityEncoding.Input {
        try LayaPriorityEncoding.make(
            state: state, question: question,
            encode: { tokenizer.encode(text: $0, addSpecialTokens: false) }
        )
    }
}
