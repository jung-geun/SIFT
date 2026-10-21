import Foundation
import WhisperKit

/// Offline-only first-window detection. The shared model store owns inference
/// serialization, local verification and deletion leases across all sources.
nonisolated enum MeetingLiveLanguageDetection {
    enum Failure: Error { case invalidAudio, detectionFailed }

    /// Callable actual-audio smoke seam: normalized 16 kHz mono, at most 10 s.
    /// A short prefix is valid. Nil is silence/no usable speech, not a locale.
    @concurrent
    static func detect(samples: [Float], store: MeetingWhisperModelStore = .shared) async throws -> String? {
        try Task.checkCancellation()
        guard !samples.isEmpty else { return nil }
        guard samples.count <= MeetingAutomaticLanguageSession.detectionSampleLimit,
              samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw Failure.invalidAudio }
        // Digital silence needs no model work and cannot become an English guess.
        guard samples.contains(where: { $0 != 0 }) else { return nil }
        do {
            return try await store.withLoadedModel { model in
                Logging.updateLogLevel(.none)
                try Task.checkCancellation()
                // The app's task-local decoder measures the unfiltered SOT
                // no-speech posterior: the pinned SDK otherwise returns zero.
                // Text is also required; language logits alone aren't speech.
                let options = decodingOptions()
                let results = try await model.transcribe(audioArray: samples, decodeOptions: options)
                try Task.checkCancellation()
                for result in results {
                    var windowLanguages: [Int: String] = [:]
                    for segment in result.segments {
                        let prompt = MeetingOfflineTranscriptionService.promptLanguage(
                            in: segment.tokens, languageTokenCodes: model.languageTokenCodes)
                        if prompt.hasPrompt { windowLanguages[segment.seek] = prompt.code }
                        guard segment.noSpeechProb.isFinite, segment.noSpeechProb < 0.6,
                              !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        guard let code = windowLanguages[segment.seek],
                              MeetingLanguageCatalog.whisperLanguageCodes.contains(code) else {
                            throw MeetingAutomaticLanguageSession.Failure.invalidLanguage
                        }
                        return code
                    }
                }
                return nil
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? MeetingWhisperModelError { throw error }
            if let error = error as? MeetingAutomaticLanguageSession.Failure { throw error }
            // SDK diagnostics may embed text; never retain or surface them.
            throw Failure.detectionFailed
        }
    }

    static func decodingOptions() -> DecodingOptions {
        DecodingOptions(
            verbose: false, task: .transcribe, language: nil,
            temperatureFallbackCount: 0, detectLanguage: true,
            skipSpecialTokens: true, withoutTimestamps: true,
            wordTimestamps: false, windowClipTime: 0, concurrentWorkerCount: 1
        )
    }
}
