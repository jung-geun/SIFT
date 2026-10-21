import CoreML
import Foundation
import WhisperKit

/// Keeps speech/language evidence and SDK window adaptation local to each task,
/// before incremental chunk offsets. Never reuses a source's language decision.
nonisolated final class MeetingWhisperKit: WhisperKit {
    let languageTokenCodes: [Int: String]

    init(_ config: WhisperKitConfig, languageTokenCodes: [Int: String]) async throws {
        self.languageTokenCodes = languageTokenCodes
        try await super.init(config)
    }

    override func setupTranscribeTask(
        currentTimings: TranscriptionTimings,
        progress: Progress,
        audioProcessor: any AudioProcessing,
        audioEncoder: any AudioEncoding,
        featureExtractor: any FeatureExtracting,
        segmentSeeker: any SegmentSeeking,
        textDecoder: any TextDecoding,
        tokenizer: any WhisperTokenizer
    ) -> TranscribeTask {
        MeetingWhisperTranscribeTask(
            currentTimings: currentTimings,
            progress: progress,
            audioProcessor: audioProcessor,
            audioEncoder: audioEncoder,
            featureExtractor: featureExtractor,
            segmentSeeker: segmentSeeker,
            textDecoder: textDecoder,
            tokenizer: tokenizer
        )
    }

    override func runTranscribeTask(
        audioArray: [Float],
        decodeOptions: DecodingOptions? = nil,
        callback: TranscriptionCallback? = nil,
        segmentCallback: SegmentDiscoveryCallback? = nil
    ) async throws -> [TranscriptionResult] {
        let results = try await super.runTranscribeTask(
            audioArray: audioArray, decodeOptions: decodeOptions,
            callback: callback, segmentCallback: segmentCallback
        )
        try MeetingWhisperTranscribeTask.validateWindowResults(results)
        return results
    }
}

nonisolated final class MeetingWhisperTranscribeTask: TranscribeTask {
    private let windowSamples: Int
    private var rejectedWindow = false
    private let evidenceDecoder: MeetingWhisperEvidenceDecoder

    override init(
        currentTimings: TranscriptionTimings,
        progress: Progress?,
        audioProcessor: (any AudioProcessing)? = nil,
        audioEncoder: any AudioEncoding,
        featureExtractor: any FeatureExtracting,
        segmentSeeker: any SegmentSeeking,
        textDecoder: any TextDecoding,
        tokenizer: any WhisperTokenizer
    ) {
        windowSamples = featureExtractor.windowSamples ?? Constants.defaultWindowSamples
        let decoder = MeetingWhisperEvidenceDecoder(base: textDecoder, tokenizer: tokenizer)
        evidenceDecoder = decoder
        super.init(
            currentTimings: currentTimings, progress: progress,
            audioProcessor: audioProcessor, audioEncoder: audioEncoder,
            featureExtractor: featureExtractor,
            segmentSeeker: segmentSeeker, textDecoder: decoder, tokenizer: tokenizer
        )
    }

    override func windowPreprocess(for paddedAudio: any AudioProcessorOutputType, seek: Int, segmentSize: Int) async {
        evidenceDecoder.beginWindow()
    }

    override func windowPostProcess(
        seek: Int, segmentSize: Int, originalSegments: [TranscriptionSegment]
    ) async -> [TranscriptionSegment] {
        do {
            let segments = try Self.segmentsWithinInput(
                seek: seek, segmentSize: segmentSize,
                windowSamples: windowSamples, originalSegments: originalSegments
            )
            return Self.preservingPrompt(evidenceDecoder.prompt, in: segments)
        } catch {
            // The SDK hook cannot throw. Preserve the rejected data unchanged,
            // and carry rejection through finalization to runTranscribeTask.
            rejectedWindow = true
            return originalSegments
        }
    }

    override func finalizeTranscriptionResult(
        tokens: [Int], segments: [TranscriptionSegment],
        language: String?, timings: TranscriptionTimings
    ) -> TranscriptionResult {
        let result = super.finalizeTranscriptionResult(
            tokens: tokens, segments: segments, language: language, timings: timings
        )
        guard rejectedWindow else { return result }
        return RejectedWindowResult(
            text: result.text, segments: result.segments, language: result.language,
            timings: result.timings, seekTime: result.seekTime
        )
    }

    static func validateWindowResults(_ results: [TranscriptionResult]) throws {
        guard !results.contains(where: { $0 is RejectedWindowResult }) else {
            throw MeetingOfflineTranscriptionService.Failure.invalidTimestamps
        }
    }


    /// Alignment can remove the empty/zero-length first slice carrying SOT.
    /// Copy only the actual decoder input prefix, never result.language or a
    /// previous window's decision, to the first surviving slice of this window.
    static func preservingPrompt(_ prompt: [Int], in segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        guard !prompt.isEmpty, let first = segments.first,
              !first.tokens.contains(50_258) else { return segments }
        var retained = segments
        retained[0].tokens = prompt + first.tokens
        return retained
    }
    /// SDK SegmentSeeker times include `seek` within this input array; they do
    /// not yet include the incremental file chunk offset. `segmentSize` is the
    /// actual input/clip extent, not the padded model window or recording length.
    static func segmentsWithinInput(
        seek: Int, segmentSize: Int,
        windowSamples: Int = Constants.defaultWindowSamples,
        originalSegments: [TranscriptionSegment]
    ) throws -> [TranscriptionSegment] {
        let (inputEndSample, inputOverflow) = seek.addingReportingOverflow(segmentSize)
        let (_, windowOverflow) = seek.addingReportingOverflow(windowSamples)
        guard seek >= 0, segmentSize > 0, windowSamples > 0,
              segmentSize <= windowSamples, !inputOverflow, !windowOverflow else {
            throw MeetingOfflineTranscriptionService.Failure.invalidTimestamps
        }
        let sampleRate = Float(WhisperKit.sampleRate)
        let windowStart = Float(seek) / sampleRate
        let paddedEnd = windowStart + Float(windowSamples) / sampleRate
        let inputEnd = Float(inputEndSample) / sampleRate
        // Aligned starts can round down to the nearest centisecond in the SDK.
        // Upper bounds retain strict output's two-ULP arithmetic slack only;
        // invalid ends must not become eligible for padding discard or clipping.
        let minimum = max(0, min(windowStart, (windowStart * 100).rounded() / 100).nextDown.nextDown)
        let maximum = paddedEnd.nextUp.nextUp
        func validTimes(_ start: Float, _ end: Float) -> Bool {
            start.isFinite && end.isFinite && start >= minimum && end >= start && end <= maximum
        }
        var firstChange: Int?
        for (index, segment) in originalSegments.enumerated() {
            guard segment.seek == seek,
                  validTimes(segment.start, segment.end),
                  segment.temperature.isFinite, segment.avgLogprob.isFinite,
                  segment.compressionRatio.isFinite,
                  segment.noSpeechProb.isFinite, (0...1).contains(segment.noSpeechProb),
                  segment.tokenLogProbs.allSatisfy({ $0.values.allSatisfy(\.isFinite) }) else {
                throw MeetingOfflineTranscriptionService.Failure.invalidTimestamps
            }
            guard segment.end > segment.start
                    || segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingOfflineTranscriptionService.Failure.invalidTimestamps
            }
            // Validate EVERY word before considering padding. In particular a
            // valid-looking padded segment must not conceal NaN/reversed words.
            for word in segment.words ?? [] {
                guard validTimes(word.start, word.end), word.probability.isFinite,
                      (0...1).contains(word.probability) else {
                    throw MeetingOfflineTranscriptionService.Failure.invalidTimestamps
                }
            }
            if firstChange == nil, segment.start >= inputEnd || segment.end > inputEnd {
                firstChange = index
            }
        }
        guard let firstChange else { return originalSegments }
        var retained: [TranscriptionSegment] = []
        retained.reserveCapacity(originalSegments.count)
        retained.append(contentsOf: originalSegments[..<firstChange])
        for var segment in originalSegments[firstChange...] {
            guard segment.start < inputEnd else { continue }
            segment.end = min(segment.end, inputEnd)
            // Keep real word measurements intact; strict output validation owns
            // literal coverage and clipping timed runs to the retained segment.
            retained.append(segment)
        }
        return retained
    }
}

/// Rejection is task-local, not mutable state on the shared model. The SDK's
/// nonthrowing hooks return this only on failure; no timestamps are fabricated.
private nonisolated final class RejectedWindowResult: TranscriptionResult, @unchecked Sendable {}

/// The pinned SDK swallows detectLanguage errors and hard-codes noSpeechProb=0.
/// Intercept that boundary per task: one unfiltered SOT prediction supplies both
/// language argmax and a real no-speech posterior. Manual decode still uses its
/// explicit language; it only needs the SOT pass for speech evidence.
nonisolated final class MeetingWhisperEvidenceDecoder: TextDecoding {
    enum Failure: Error { case invalidInputs, invalidLogits, missingLanguage }
    private var base: any TextDecoding
    private let tokens: any WhisperTokenizer
    private var detectionError: Error?
    private var noSpeech: Float?
    private(set) var prompt: [Int] = []

    init(base: any TextDecoding, tokenizer: any WhisperTokenizer) {
        self.base = base
        tokens = tokenizer
    }

    func beginWindow() { detectionError = nil; noSpeech = nil; prompt = [] }

    var tokenizer: (any WhisperTokenizer)? { get { base.tokenizer } set { base.tokenizer = newValue } }
    var isModelMultilingual: Bool { get { base.isModelMultilingual } set { base.isModelMultilingual = newValue } }
    var supportsWordTimestamps: Bool { base.supportsWordTimestamps }
    var logitsSize: Int? { base.logitsSize }
    var logitsFilters: [any LogitsFiltering]? { get { base.logitsFilters } set { base.logitsFilters = newValue } }
    var kvCacheEmbedDim: Int? { base.kvCacheEmbedDim }
    var kvCacheMaxSequenceLength: Int? { base.kvCacheMaxSequenceLength }
    var windowSize: Int? { base.windowSize }
    var embedSize: Int? { base.embedSize }

    func predictLogits(_ inputs: any TextDecoderInputType) async throws -> (any TextDecoderOutputType)? {
        try await base.predictLogits(inputs)
    }

    func prepareDecoderInputs(withPrompt prompt: [Int]) throws -> any DecodingInputsType {
        try base.prepareDecoderInputs(withPrompt: prompt)
    }

    func prefillDecoderInputs(_ inputs: any DecodingInputsType, withOptions options: DecodingOptions?) async throws -> any DecodingInputsType {
        try await base.prefillDecoderInputs(inputs, withOptions: options)
    }

    func detectLanguage(from encoderOutput: any AudioEncoderOutputType, using inputs: any DecodingInputsType,
                        sampler: any TokenSampling, options: DecodingOptions, temperature: FloatType) async throws -> DecodingResult {
        do {
            let evidence = try await measure(from: encoderOutput, using: inputs)
            guard let id = evidence.languageToken,
                  let token = tokens.convertIdToToken(id),
                  token.hasPrefix("<|"), token.hasSuffix("|>"),
                  tokens.convertTokenToId(token) == id else { throw Failure.missingLanguage }
            let code = String(token.dropFirst(2).dropLast(2))
            guard MeetingLanguageCatalog.whisperLanguageCodes.contains(code) else { throw Failure.missingLanguage }
            var result = DecodingResult.emptyResults
            result.language = code
            result.noSpeechProb = noSpeech!
            return result
        } catch {
            // TranscribeTask uses try? for this call. Its next decode MUST fail,
            // not silently prefill English or reuse the previous window prompt.
            detectionError = error
            throw error
        }
    }

    private func measure(from encoderOutput: any AudioEncoderOutputType, using inputs: any DecodingInputsType) async throws -> (languageToken: Int?, noSpeech: Float) {
        try Task.checkCancellation()
        guard let inputs = inputs as? DecodingInputs, let encoded = encoderOutput as? MLMultiArray else {
            throw Failure.invalidInputs
        }
        // Also resets masks after a skipped silent window (SDK skips its reset).
        inputs.reset(maxTokenContext: inputs.kvCacheUpdateMask.count)
        inputs.inputIds[0] = NSNumber(value: tokens.specialTokens.startOfTranscriptToken)
        guard let output = try await base.predictLogits(TextDecoderMLMultiArrayInputType(
            inputIds: inputs.inputIds, cacheLength: inputs.cacheLength,
            keyCache: inputs.keyCache, valueCache: inputs.valueCache,
            kvCacheUpdateMask: inputs.kvCacheUpdateMask, encoderOutputEmbeds: encoded,
            decoderKeyPaddingMask: inputs.decoderKeyPaddingMask
        )) as? TextDecoderMLMultiArrayOutputType, let logits = output.logits,
              logits.count == logitsSize,
              tokens.allLanguageTokens.allSatisfy({ $0 >= 0 && $0 < logits.count }) else { throw Failure.invalidLogits }
        let evidence = try Self.sotEvidence(logits, noSpeechToken: tokens.specialTokens.noSpeechToken,
                                            languageTokens: tokens.allLanguageTokens)
        noSpeech = evidence.noSpeech
        try Task.checkCancellation()
        return evidence
    }

    /// Read the contiguous vocabulary directly; no per-logit NSNumber allocation
    /// or full-vocabulary copy. Compute stable, unfiltered softmax before choosing
    /// a language from the language-only subset (not from text or UI locale).
    static func sotEvidence(_ logits: MLMultiArray, noSpeechToken: Int,
                            languageTokens: Set<Int>) throws -> (languageToken: Int?, noSpeech: Float) {
        guard logits.shape.dropLast().allSatisfy({ $0.intValue == 1 }),
              logits.strides.last?.intValue == 1,
              noSpeechToken >= 0, noSpeechToken < logits.count,
              languageTokens.allSatisfy({ $0 >= 0 && $0 < logits.count }) else { throw Failure.invalidLogits }
        func measure<T>(_ type: T.Type, convert: (T) -> Double) throws -> (Int?, Float) {
            let values = logits.dataPointer.assumingMemoryBound(to: type)
            var maximum = -Double.infinity
            for index in 0..<logits.count {
                let value = convert(values[index])
                guard value.isFinite else { throw Failure.invalidLogits }
                maximum = max(maximum, value)
            }
            var languageToken: Int?
            var languageMaximum = -Double.infinity
            for token in languageTokens {
                let value = convert(values[token])
                if value > languageMaximum || (value == languageMaximum && token < (languageToken ?? Int.max)) {
                    languageMaximum = value
                    languageToken = token
                }
            }
            var denominator = 0.0
            for index in 0..<logits.count { denominator += exp(convert(values[index]) - maximum) }
            return (languageToken, Float(exp(convert(values[noSpeechToken]) - maximum) / denominator))
        }
        switch logits.dataType {
        case .float16: return try measure(UInt16.self, convert: Self.widenFloat16)
        case .float32: return try measure(Float.self, convert: Double.init)
        case .double: return try measure(Double.self, convert: { $0 })
        default: throw Failure.invalidLogits
        }
    }

    /// IEEE-754 half storage is portable even where Swift Float16 has no
    /// BinaryFloatingPoint conformance (Intel Catalyst). No tensor copy/boxing.
    @inline(__always)
    private static func widenFloat16(_ bits: UInt16) -> Double {
        let exponent = UInt32((bits >> 10) & 0x1f)
        let fraction = UInt32(bits & 0x03ff)
        if exponent == 0 {
            return Double(fraction) * (bits & 0x8000 == 0 ? 0x1p-24 : -0x1p-24)
        }
        let sign = UInt32(bits & 0x8000) << 16
        let widenedExponent = exponent == 0x1f ? 0xff : exponent + 112
        return Double(Float(bitPattern: sign | (widenedExponent << 23) | (fraction << 13)))
    }

    func decodeText(from encoderOutput: any AudioEncoderOutputType, using inputs: any DecodingInputsType,
                    sampler: any TokenSampling, options: DecodingOptions, callback: TranscriptionCallback?) async throws -> DecodingResult {
        try Task.checkCancellation()
        if let detectionError { throw detectionError }
        guard options.language != nil else { throw Failure.missingLanguage }
        if noSpeech == nil { _ = try await measure(from: encoderOutput, using: inputs) }
        // Keep just the actual SOT/language/task prefix, not vocabulary hints.
        let initial = inputs.initialPrompt
        if let sot = initial.firstIndex(of: tokens.specialTokens.startOfTranscriptToken), sot + 2 < initial.count {
            prompt = Array(initial[sot...sot + 2])
        }
        var result = try await base.decodeText(from: encoderOutput, using: inputs, sampler: sampler, options: options, callback: callback)
        result.noSpeechProb = noSpeech!
        result.fallback = DecodingFallback(options: options,
                                          isFirstTokenLogProbTooLow: result.fallback?.fallbackReason == "firstTokenLogProbThreshold",
                                          noSpeechProb: result.noSpeechProb, compressionRatio: result.compressionRatio,
                                          avgLogProb: result.avgLogProb)
        return result
    }

    static func updateKVCache(keyTensor: MLMultiArray, keySlice: MLMultiArray, valueTensor: MLMultiArray,
                              valueSlice: MLMultiArray, insertAtIndex index: Int) {
        TextDecoder.updateKVCache(keyTensor: keyTensor, keySlice: keySlice, valueTensor: valueTensor,
                                  valueSlice: valueSlice, insertAtIndex: index)
    }
}
