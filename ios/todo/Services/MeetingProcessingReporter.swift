import Combine
import Foundation

/// Drives the live progress UI for the post-transcription pipeline
/// (전사 → AI 검수 → 요약). Owned per-screen as a `@StateObject`; the durable
/// record of *what* changed lives in the transcript/`rawResultData`, so a
/// transient reporter is fine even across navigation.
@MainActor
final class MeetingProcessingReporter: ObservableObject {
    enum SkipReason: Equatable {
        case disabled
        case unavailable
        case modelNotLoaded
        case emptyTranscript
    }

    enum ProofreadOutcome: Equatable {
        case changed(count: Int, engine: String)
        case unchanged(engine: String)
        case skipped(reason: SkipReason)
        case failed(engine: String?, message: String)
    }

    enum Phase: Equatable {
        case idle
        /// Re-transcription (speech-to-text) running from the saved audio.
        case transcribing
        /// Correction pass running, with the engine label (AFM or local LLM).
        case proofreading(engine: String)
        /// Summary/analysis running after correction.
        case summarizing(engine: String)
        /// Finished with the actual proofreading result, never a fabricated success.
        case completed(proofread: ProofreadOutcome, analysisEngine: String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Whether the current run includes a transcription stage. Automatic
    /// post-processing reuses the saved transcript, while "다시 전사" sets this
    /// true so the UI includes the 전사 step.
    @Published private(set) var includesTranscription = false

    var isBusy: Bool {
        switch phase {
        case .transcribing, .proofreading, .summarizing: true
        case .idle, .completed: false
        }
    }

    /// Begin a run that starts by re-transcribing the saved audio.
    func startTranscribing() {
        includesTranscription = true
        phase = .transcribing
    }

    func set(_ phase: Phase) { self.phase = phase }

    func reset() {
        includesTranscription = false
        phase = .idle
    }
}
