import CoreML
import Foundation
import Testing
import WhisperKit
@testable import todo

@MainActor
@Suite("Whisper runtime window boundary")
struct MeetingWhisperWindowTests {
    private typealias Adapter = MeetingWhisperTranscribeTask
    private typealias Failure = MeetingOfflineTranscriptionService.Failure

    private func word(_ text: String, _ start: Float, _ end: Float, probability: Float = 1) -> WordTiming {
        WordTiming(word: text, tokens: [1044], start: start, end: end, probability: probability)
    }

    private var thankYou: TranscriptionSegment {
        // Real local model output from mixed-ko-en-60s.wav, recorded in
        // raw-sdk-timestamps.json (2026-10-19). Incremental chunk offset 854400
        // samples = 53.4s; only 105600 samples = 6.6s of actual input remain.
        // The SDK's padded-window hypothesis was local 26.3...29.1s, which
        // became 79.700005...82.5s after the correct chunk offset was applied.
        TranscriptionSegment(start: 26.3, end: 29.1, text: " Thank you.",
                             tokens: [50258, 50259, 50360, 50365, 1044, 291, 13, 51864, 50257],
                             words: [word(" Thank", 26.3, 27.7, probability: 0.36),
                                     word(" you.", 27.7, 29.1)])
    }

    @Test("Identical hypothesis is retained in full input and discarded only in a truly padded final chunk")
    func actualChunkExtent() throws {
        let full = try Adapter.segmentsWithinInput(seek: 0, segmentSize: 480_000, originalSegments: [thankYou])
        #expect(full == [thankYou])
        let padded = try Adapter.segmentsWithinInput(seek: 0, segmentSize: 105_600, originalSegments: [thankYou])
        #expect(padded.isEmpty)
        let wouldBeAbsolute = TranscriptionUtilities.updateSegmentTimings(segment: thankYou, seekOffsetIndex: 854_400)
        #expect(abs(wouldBeAbsolute.start - 79.7) < 0.00002)
        #expect(abs(wouldBeAbsolute.end - 82.5) < 0.00002)
    }

    @Test("Normal real speech keeps its existing sample-derived chunk offset exactly once")
    func actualSpeech() throws {
        // First English segment in the second raw chunk: local 3.9...7.68,
        // chunk offset 417600 samples = 26.1s, absolute 30.0...33.78.
        let local = TranscriptionSegment(start: 3.9, end: 7.68, text: " For this meeting,",
                                         tokens: [50258, 50259, 50360, 50365, 1171, 341, 3440, 11],
                                         words: [word(" For", 3.9, 3.94), word(" this meeting,", 3.94, 7.68)])
        let retained = try Adapter.segmentsWithinInput(seek: 0, segmentSize: 480_000, originalSegments: [local])
        #expect(retained == [local])
        let absolute = TranscriptionUtilities.updateSegmentTimings(segment: try #require(retained.first), seekOffsetIndex: 417_600)
        #expect(abs(absolute.start - 30) < 0.00001)
        #expect(abs(absolute.end - 33.78) < 0.00001)
        #expect(absolute.tokens == local.tokens)
        #expect(absolute.words?.first?.word == " For")
    }

    @Test("A full nonzero-seek window retains valid speech through its numeric end")
    func fullWindow() throws {
        let segment = TranscriptionSegment(seek: 480_000, start: 58, end: 60, text: "actual speech",
                                           words: [word("actual speech", 58, 60)])
        #expect(try Adapter.segmentsWithinInput(seek: 480_000, segmentSize: 480_000,
                                               originalSegments: [segment]) == [segment])
    }

    @Test("Partial clip uses seek plus actual segment size, bounds only segment end, and leaves words measured")
    func partialClip() throws {
        // Clip [11, 14.5] inside an input array, not a recording-global limit.
        let crossing = TranscriptionSegment(seek: 176_000, start: 14, end: 17, text: "actual tail",
                                            words: [word("actual", 14, 14.25), word(" tail", 14.25, 17)])
        let padded = TranscriptionSegment(seek: 176_000, start: 14.5, end: 16, text: "padding",
                                          words: [word("padding", 14.5, 16)])
        let result = try Adapter.segmentsWithinInput(seek: 176_000, segmentSize: 56_000,
                                                     originalSegments: [crossing, padded])
        let clipped = try #require(result.first)
        #expect(result.count == 1)
        #expect(clipped.start == 14)
        #expect(clipped.end == 14.5)
        #expect(clipped.words == crossing.words)
        #expect(clipped.text == crossing.text)
        #expect(clipped.seek == 176_000)
        #expect(clipped.tokens == crossing.tokens)
    }

    @Test("A final chunk retains real speech, clips crossing speech, and discards only wholly padded speech")
    func mixedLastWindow() throws {
        let actual = TranscriptionSegment(start: 0.2, end: 2, text: "hello", words: [word("hello", 0.2, 2)])
        let crossing = TranscriptionSegment(start: 6, end: 8, text: "tail", words: [word("tail", 6, 8)])
        let result = try Adapter.segmentsWithinInput(seek: 0, segmentSize: 105_600,
                                                     originalSegments: [actual, crossing, thankYou])
        #expect(result.count == 2)
        #expect(result.first == actual)
        #expect(result.last?.start == 6)
        #expect(result.last?.end == 6.6)
        #expect(result.last?.words == crossing.words)
    }

    @Test("Corrupt word times and probabilities cannot hide inside wholly padded speech")
    func corruptPaddedWords() {
        let badWords = [
            word("bad", .nan, 29), word("bad", 27, .infinity),
            word("bad", -1, 29), word("bad", 29, 28), word("bad", 27, 31),
            word("bad", 27, 29, probability: .nan), word("bad", 27, 29, probability: .infinity),
            word("bad", 27, 29, probability: -0.01), word("bad", 27, 29, probability: 1.01)
        ]
        for badWord in badWords {
            var segment = thankYou
            // A legitimate zero-duration DTW word must not stop validation of
            // later corrupt words, even when the whole segment is padding.
            segment.words = [word("zero", 26.3, 26.3), badWord]
            #expect(throws: Failure.invalidTimestamps) {
                try Adapter.segmentsWithinInput(seek: 0, segmentSize: 105_600, originalSegments: [segment])
            }
        }
        var crossing = TranscriptionSegment(start: 6, end: 8, text: "tail")
        crossing.words = [word("tail", 6, .infinity)]
        #expect(throws: Failure.invalidTimestamps) {
            try Adapter.segmentsWithinInput(seek: 0, segmentSize: 105_600, originalSegments: [crossing])
        }
    }

    @Test("Corrupt segment fields are rejected before either padding discard or partial clipping")
    func corruptSegments() {
        var corrupt: [TranscriptionSegment] = []
        for (start, end) in [(Float.nan, Float(29)), (26, .infinity), (-1, 29), (29, 28), (26, 31), (27, 27)] {
            var segment = thankYou
            segment.start = start
            segment.end = end
            corrupt.append(segment)
        }
        var mismatched = thankYou
        mismatched.seek = 1
        corrupt.append(mismatched)
        var badTemperature = thankYou
        badTemperature.temperature = .nan
        corrupt.append(badTemperature)
        var badLogprob = thankYou
        badLogprob.avgLogprob = .infinity
        corrupt.append(badLogprob)
        var badCompression = thankYou
        badCompression.compressionRatio = .nan
        corrupt.append(badCompression)
        var badNoSpeech = thankYou
        badNoSpeech.noSpeechProb = 1.01
        corrupt.append(badNoSpeech)
        var badTokenScore = thankYou
        badTokenScore.tokenLogProbs = [[1044: .nan]]
        corrupt.append(badTokenScore)
        for segment in corrupt {
            #expect(throws: Failure.invalidTimestamps) {
                try Adapter.segmentsWithinInput(seek: 0, segmentSize: 105_600, originalSegments: [segment])
            }
        }
    }

    @Test("Invalid or mismatched window metadata never gets normalized")
    func corruptWindowMetadata() {
        for (seek, count) in [(-1, 105_600), (0, 0), (0, -1), (0, 480_001), (Int.max, 1)] {
            #expect(throws: Failure.invalidTimestamps) {
                try Adapter.segmentsWithinInput(seek: seek, segmentSize: count, originalSegments: [])
            }
        }
        let wrongSeek = TranscriptionSegment(seek: 0, start: 31, end: 32, text: "wrong owner")
        let earlierWindow = TranscriptionSegment(seek: 480_000, start: 1, end: 2, text: "wrong window")
        for segment in [wrongSeek, earlierWindow] {
            #expect(throws: Failure.invalidTimestamps) {
                try Adapter.segmentsWithinInput(seek: 480_000, segmentSize: 480_000, originalSegments: [segment])
            }
        }
    }

    @Test("A zero-duration DTW word remains unchanged in valid actual speech")
    func zeroDurationWord() throws {
        let segment = TranscriptionSegment(start: 1, end: 2, text: "one two",
                                           words: [word("one", 1, 2), word(" two", 2, 2)])
        #expect(try Adapter.segmentsWithinInput(seek: 0, segmentSize: 105_600,
                                               originalSegments: [segment]) == [segment])
    }

    @Test("Hook rejection survives later windows but never leaks into another source task")
    func taskSourceOwnership() async throws {
        let microphone = makeTask()
        let systemAudio = makeTask()
        var corrupt = thankYou
        corrupt.seek = 1
        let rejected = await microphone.windowPostProcess(seek: 0, segmentSize: 105_600, originalSegments: [corrupt])
        #expect(rejected == [corrupt]) // preserve evidence, not a fabricated sentinel
        let actual = TranscriptionSegment(start: 1, end: 2, text: "source speech", tokens: [1044])
        _ = await microphone.windowPostProcess(seek: 0, segmentSize: 480_000, originalSegments: [actual])
        let first = microphone.finalizeTranscriptionResult(tokens: [1044], segments: rejected,
                                                           language: "en", timings: TranscriptionTimings())
        #expect(throws: Failure.invalidTimestamps) { try Adapter.validateWindowResults([first]) }
        let independent = await systemAudio.windowPostProcess(seek: 0, segmentSize: 105_600, originalSegments: [actual])
        #expect(independent == [actual])
        let second = systemAudio.finalizeTranscriptionResult(tokens: [1044], segments: independent,
                                                             language: "ko", timings: TranscriptionTimings())
        try Adapter.validateWindowResults([second])
        #expect(second.language == "ko")
        #expect(second.segments == [actual])
    }

    @Test("Runtime factory creates an app task with its injected tokenizer without loading models")
    func runtimeFactory() async throws {
        let model = try await MeetingWhisperKit(
            WhisperKitConfig(prewarm: false, load: false, download: false),
            languageTokenCodes: [50259: "en", 50264: "ko"]
        )
        let task = model.setupTranscribeTask(
            currentTimings: TranscriptionTimings(), progress: Progress(),
            audioProcessor: AudioProcessor(), audioEncoder: AudioEncoder(),
            featureExtractor: FeatureExtractor(), segmentSeeker: SegmentSeeker(),
            textDecoder: TextDecoder(), tokenizer: WindowTokenizer()
        )
        #expect(task is MeetingWhisperTranscribeTask)
        #expect(task.tokenizer.decode(tokens: [1044]) == "source speech")
        #expect(model.languageTokenCodes == [50259: "en", 50264: "ko"])
        #expect(model.modelState == .unloaded)
    }

    @Test("Unfiltered SOT evidence survives SDK handoff, window switches and manual requests")
    func decoderWindowEvidence() async throws {
        let base = EvidenceTextDecoder()
        let decoder = MeetingWhisperEvidenceDecoder(base: base, tokenizer: WindowTokenizer())
        var inputs = try decoder.prepareDecoderInputs(withPrompt: [50258])
        let encoder = try MLMultiArray(shape: [1], dataType: .float32)
        let automatic = DecodingOptions(language: nil, detectLanguage: true)
        let sampler = GreedyTokenSampler(temperature: 0, eotToken: 50257, decodingOptions: automatic)
        for (languageToken, language, noSpeechLogit) in [(50264, "ko", Float(-20)), (50259, "en", Float(20))] {
            decoder.beginWindow()
            base.setLogits(languageToken: languageToken, noSpeechLogit: noSpeechLogit)
            // Emulate stale masks left by SDK's no-segments continue path.
            (inputs as? DecodingInputs)?.decoderKeyPaddingMask[1] = 0
            inputs.cacheLength[0] = 37
            let detected = try await decoder.detectLanguage(from: encoder, using: inputs, sampler: sampler,
                                                            options: automatic, temperature: 0)
            #expect(detected.language == language)
            var options = automatic
            options.language = detected.language
            inputs = try await decoder.prefillDecoderInputs(inputs, withOptions: options)
            let decoded = try await decoder.decodeText(from: encoder, using: inputs, sampler: sampler,
                                                       options: options, callback: nil)
            #expect((decoded.noSpeechProb < 0.6) == (noSpeechLogit < 0))
            #expect(decoder.prompt == [50258, languageToken, 50360])
        }
        // A fresh source shares model weights, not the prior source's decision.
        let other = MeetingWhisperEvidenceDecoder(base: base, tokenizer: WindowTokenizer())
        #expect(other.prompt.isEmpty)
        base.setLogits(languageToken: 50264, noSpeechLogit: -20)
        let manual = DecodingOptions(language: "en", detectLanguage: false)
        decoder.beginWindow()
        inputs = try await decoder.prefillDecoderInputs(inputs, withOptions: manual)
        _ = try await decoder.decodeText(from: encoder, using: inputs, sampler: sampler, options: manual, callback: nil)
        #expect(base.decodedLanguages == ["ko", "en", "en"])
        #expect(decoder.prompt == [50258, 50259, 50360])
        #expect(base.predictions == 3) // automatic shares its SOT pass with speech evidence
    }

    @Test("SDK try? cannot turn failed detection into an English decode")
    func swallowedSDKDetectionError() async throws {
        let base = EvidenceTextDecoder()
        let decoder = MeetingWhisperEvidenceDecoder(base: base, tokenizer: WindowTokenizer())
        let inputs = try decoder.prepareDecoderInputs(withPrompt: [50258])
        let encoder = try MLMultiArray(shape: [1], dataType: .float32)
        let options = DecodingOptions(language: nil, detectLanguage: true)
        let sampler = GreedyTokenSampler(temperature: 0, eotToken: 50257, decodingOptions: options)
        base.invalid = true
        let detected = try? await decoder.detectLanguage(from: encoder, using: inputs, sampler: sampler,
                                                        options: options, temperature: 0)
        #expect(detected == nil)
        // Precisely the SDK's fallback prefill behavior after its try?.
        let fallback = try await decoder.prefillDecoderInputs(inputs, withOptions: options)
        await #expect(throws: MeetingWhisperEvidenceDecoder.Failure.self) {
            _ = try await decoder.decodeText(from: encoder, using: fallback, sampler: sampler, options: options, callback: nil)
        }
        #expect(base.decodedLanguages.isEmpty)
    }

    @Test("Language prefix removed by word alignment is restored only from the current input")
    func alignmentPromptEvidence() {
        let speech = TranscriptionSegment(start: 1, end: 2, text: "speech", tokens: [50365, 1044])
        let prompt = [50258, 50264, 50360]
        let retained = Adapter.preservingPrompt(prompt, in: [speech])
        #expect(retained[0].tokens == prompt + speech.tokens)
        #expect(Adapter.preservingPrompt(prompt, in: retained) == retained)
        #expect(Adapter.preservingPrompt([], in: [speech]) == [speech])
        #expect(Adapter.preservingPrompt(prompt, in: []).isEmpty)
    }

    @Test("SOT softmax is stable, uses the full vocabulary, and rejects corrupt logits")
    func noSpeechPosterior() throws {
        for type in [MLMultiArrayDataType.float16, .float32, .double] {
            let logits = try MLMultiArray(shape: [1, 1, 3], dataType: type)
            logits[0] = 1000; logits[1] = 1001; logits[2] = 1002
            let evidence = try MeetingWhisperEvidenceDecoder.sotEvidence(logits, noSpeechToken: 2, languageTokens: [0, 1])
            #expect(evidence.languageToken == 1)
            #expect(abs(evidence.noSpeech - 0.66524096) < 0.00001)
            logits[1] = NSNumber(value: Double.nan)
            #expect(throws: MeetingWhisperEvidenceDecoder.Failure.self) {
                try MeetingWhisperEvidenceDecoder.sotEvidence(logits, noSpeechToken: 2, languageTokens: [0, 1])
            }
        }
    }

    @Test("Automatic decode uses no locale or text hints and does not skip a subsecond stop")
    func automaticOptions() throws {
        let live = MeetingLiveLanguageDetection.decodingOptions()
        let offline = try MeetingOfflineTranscriptionService.decodingOptions(
            languageCode: nil, tokenizer: nil, isMultilingual: true, logitsSize: 51_866)
        for options in [live, offline] {
            #expect(options.language == nil)
            #expect(options.detectLanguage)
            #expect(options.usePrefillPrompt)
            #expect(options.promptTokens == nil && options.prefixTokens == nil)
            #expect(options.windowClipTime == 0)
            #expect(options.task == .transcribe)
        }
        #expect(live.temperatureFallbackCount == 0)
    }

    private func makeTask() -> Adapter {
        Adapter(currentTimings: TranscriptionTimings(), progress: Progress(),
                audioProcessor: AudioProcessor(), audioEncoder: AudioEncoder(),
                featureExtractor: FeatureExtractor(), segmentSeeker: SegmentSeeker(),
                textDecoder: TextDecoder(), tokenizer: WindowTokenizer())
    }

    private nonisolated struct WindowTokenizer: WhisperTokenizer {
        let specialTokens = SpecialTokens(
            endToken: 50257, englishToken: 50259, noSpeechToken: 50363,
            noTimestampsToken: 50364, specialTokenBegin: 50257, startOfPreviousToken: 50362,
            startOfTranscriptToken: 50258, timeTokenBegin: 50365,
            transcribeToken: 50360, translateToken: 50359, whitespaceToken: 220
        )
        let allLanguageTokens: Set<Int> = [50259, 50264]
        func encode(text: String) -> [Int] { [1044] }
        func decode(tokens: [Int]) -> String { "source speech" }
        func convertTokenToId(_ token: String) -> Int? {
            ["<|en|>": 50259, "<|ko|>": 50264, "<|transcribe|>": 50360][token]
        }
        func convertIdToToken(_ id: Int) -> String? {
            [50259: "<|en|>", 50264: "<|ko|>", 50360: "<|transcribe|>"][id]
        }
        func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
            (["source speech"], [tokenIds])
        }
    }

    private nonisolated final class EvidenceTextDecoder: TextDecoding {
        var tokenizer: (any WhisperTokenizer)? = WindowTokenizer()
        var isModelMultilingual = true
        let supportsWordTimestamps = true
        let logitsSize: Int? = 51_866
        var logitsFilters: [any LogitsFiltering]?
        let kvCacheEmbedDim: Int? = 1
        let kvCacheMaxSequenceLength: Int? = 448
        let windowSize: Int? = 1
        let embedSize: Int? = 1
        var invalid = false
        var predictions = 0
        var decodedLanguages: [String] = []
        private var languageToken = 50264
        private var noSpeechLogit: Float = -20

        func setLogits(languageToken: Int, noSpeechLogit: Float) {
            self.languageToken = languageToken; self.noSpeechLogit = noSpeechLogit
        }

        func predictLogits(_ input: any TextDecoderInputType) async throws -> (any TextDecoderOutputType)? {
            let input = try #require(input as? TextDecoderMLMultiArrayInputType)
            #expect(input.inputIds[0].intValue == 50258)
            #expect(input.cacheLength[0].intValue == 0)
            #expect(input.decoderKeyPaddingMask[1].intValue == -10000)
            predictions += 1
            let logits = try MLMultiArray(shape: [1, 1, 51_866], dataType: .float32)
            let values = logits.dataPointer.assumingMemoryBound(to: Float.self)
            values.update(repeating: -30, count: logits.count)
            values[languageToken] = invalid ? .nan : 10
            values[50363] = noSpeechLogit
            return TextDecoderMLMultiArrayOutputType(logits: logits)
        }

        func detectLanguage(from encoderOutput: any AudioEncoderOutputType, using inputs: any DecodingInputsType,
                            sampler: any TokenSampling, options: DecodingOptions, temperature: FloatType) async throws -> DecodingResult {
            Issue.record("The SDK's swallowing/default-locale detector must not be used")
            throw MeetingWhisperEvidenceDecoder.Failure.missingLanguage
        }

        func decodeText(from encoderOutput: any AudioEncoderOutputType, using inputs: any DecodingInputsType,
                        sampler: any TokenSampling, options: DecodingOptions, callback: TranscriptionCallback?) async throws -> DecodingResult {
            decodedLanguages.append(options.language ?? "nil")
            return .emptyResults // the SDK's zero posterior must be replaced
        }
    }
}
