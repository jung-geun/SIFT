import Foundation

/// Fixed SHA-256 inventory of the 2024-09-30 4-decoder-layer large-v3-turbo conversion.
/// HF tree APIs at the revisions below provide LFS SHA-256; git blobs were
/// downloaded from those exact revisions and hashed as bytes, not git oids.
nonisolated enum MeetingWhisperManifest {
    nonisolated static let modelRepository = "argmaxinc/whisperkit-coreml"
    nonisolated static let modelRevision = "0f63a7800b00dd0226abd051b906c246e1907482"
    nonisolated static let variant = "openai_whisper-large-v3-v20240930_626MB"
    // WhisperKit 1.1.0 maps detected .largev3 to this tokenizer repository.
    nonisolated static let tokenizerRepository = "openai/whisper-large-v3"
    nonisolated static let tokenizerRevision = "06f233fe06e710322aca913c1bc4249a0d71fce1"

    nonisolated enum Source: Sendable { case model, tokenizer }
    nonisolated struct File: Sendable {
        let source: Source
        let path: String
        let size: Int64
        let sha256: String

        var localPath: String {
            switch source {
            case .model: return "model/" + path
            case .tokenizer: return "tokenizer/" + path
            }
        }
        var remoteURL: URL {
            let repository = source == .model ? modelRepository : tokenizerRepository
            let revision = source == .model ? modelRevision : tokenizerRevision
            let prefix = source == .model ? variant + "/" : ""
            return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(prefix)\(path)")!
        }
    }

    nonisolated static let files: [File] = [
        File(source: .model, path: "AudioEncoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "56793886ab1adb9ca8a4e335efbe8af6640f40d958ab2d29c3ad2d7d6f712e95"),
        File(source: .model, path: "AudioEncoder.mlmodelc/coremldata.bin", size: 348, sha256: "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3"),
        File(source: .model, path: "AudioEncoder.mlmodelc/metadata.json", size: 1_922, sha256: "a87a3375afe79e88e27af30247e234e706b98679dedfd1b021a74f7ee108c669"),
        File(source: .model, path: "AudioEncoder.mlmodelc/model.mil", size: 934_263, sha256: "3cec2580fb07b12a88087f0e1586c6ba2982980eb36499561e1ffca2b0950442"),
        File(source: .model, path: "AudioEncoder.mlmodelc/weights/weight.bin", size: 421_968_768, sha256: "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1"),
        File(source: .model, path: "MelSpectrogram.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce"),
        File(source: .model, path: "MelSpectrogram.mlmodelc/coremldata.bin", size: 329, sha256: "2bfc12cffc2e45e039c7a18f384f09adffb72c182fcd93f9413d405d1a6c1130"),
        File(source: .model, path: "MelSpectrogram.mlmodelc/metadata.json", size: 1_850, sha256: "2bc552e09a6f124d9e6c178dd1a6979e010206acb26308b2224887c9dcbeb35f"),
        File(source: .model, path: "MelSpectrogram.mlmodelc/model.mil", size: 10_143, sha256: "c270b95b5f81d7f7d0b8a3e8f991d4e5812a37cad29349868a35b91f3a6a4463"),
        File(source: .model, path: "MelSpectrogram.mlmodelc/weights/weight.bin", size: 373_376, sha256: "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49"),
        File(source: .model, path: "TextDecoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "3913b8c9716b284a917cf3744f4d415f2a05e2b910594a14c6cc10092284d3f8"),
        File(source: .model, path: "TextDecoder.mlmodelc/coremldata.bin", size: 633, sha256: "3faabaf66930e66956d8291d0ff485fb382496e30a91a7185548b9b898ce90a9"),
        File(source: .model, path: "TextDecoder.mlmodelc/metadata.json", size: 4_924, sha256: "994f6030d7b1a8be999940444c3cf5d6a57d40ddd4423cf1d1fc93520aa1b052"),
        File(source: .model, path: "TextDecoder.mlmodelc/model.mil", size: 217_177, sha256: "dbe833be9e64348c95b7fa598d0ae4309a91aedce4e82fa500a714b0e4b5d754"),
        File(source: .model, path: "TextDecoder.mlmodelc/weights/weight.bin", size: 203_199_860, sha256: "d69700903d518ada33170ab77faaaf464496fb9ff65752c6d5a6109aa2fb02db"),
        File(source: .model, path: "config.json", size: 1_149, sha256: "f01d83dd891791d6f12421c05d3ed8ebbe70866f10d6c9a7a7e80b558ce5a0f1"),
        File(source: .model, path: "generation_config.json", size: 2_767, sha256: "7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6"),
        File(source: .tokenizer, path: "added_tokens.json", size: 34_648, sha256: "3c51f66c4c21f9e126970078f11ae77a78c74aee8df606ee9daba86e467108e0"),
        File(source: .tokenizer, path: "config.json", size: 1_272, sha256: "ad0e8d1e46f4d01f7861a21509e5d0f977d6cc1f367a370603c92541d819807b"),
        File(source: .tokenizer, path: "generation_config.json", size: 3_903, sha256: "fbdfa70135de9b1d31553393f14e80aaeb1936ea36576b2ba864055943c09d23"),
        File(source: .tokenizer, path: "merges.txt", size: 493_869, sha256: "2df2990a395e35e8dfbc7511e08c12d56018d8d04691e0133e5d63b21e154dc6"),
        File(source: .tokenizer, path: "normalizer.json", size: 52_666, sha256: "bf1c507dc8724ca9cf9903640dacfb69dae2f00edee4f21ceba106a7392f26dd"),
        File(source: .tokenizer, path: "preprocessor_config.json", size: 340, sha256: "7ccc62c6f2765af1f3b46c00c9b5894426835a05021c8b9c01eecb6dfb542711"),
        File(source: .tokenizer, path: "special_tokens_map.json", size: 2_072, sha256: "1c70773c078cb2ca96e0fcff113102f1d3e2b1504272c3bb63b035d4a6700d87"),
        File(source: .tokenizer, path: "tokenizer.json", size: 2_480_617, sha256: "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca"),
        File(source: .tokenizer, path: "tokenizer_config.json", size: 282_843, sha256: "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"),
        File(source: .tokenizer, path: "vocab.json", size: 1_036_558, sha256: "e2aa043ef015641d363d8288e7c241c85e36a5c761fb303598e0710233344387")
    ]
    nonisolated static let totalBytes: Int64 = files.reduce(0) { $0 + $1.size }
}
