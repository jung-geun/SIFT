import Foundation

/// Audio positions come from exported samples or SDK segment callbacks, never a
/// token/window count (incremental Whisper window IDs restart for each chunk).
nonisolated struct MeetingTranscriptionProgress: Equatable, Sendable {
    enum Stage: Int, Sendable {
        case waiting, loadingModel, preparingAudio, recognizing, validating
    }

    struct Update: Sendable {
        let stage: Stage
        let completedMilliseconds: Int64?
        let date: Date

        init(_ stage: Stage, completedMilliseconds: Int64? = nil, date: Date = Date()) {
            self.stage = stage
            self.completedMilliseconds = completedMilliseconds
            self.date = date
        }
    }

    let totalMilliseconds: Int64
    let startedAt: Date
    private(set) var stage: Stage = .waiting
    private(set) var stageStartedAt: Date
    private(set) var lastActivityAt: Date
    private(set) var completedMilliseconds: Int64 = 0

    init(totalMilliseconds: Int64, now: Date = Date()) {
        self.totalMilliseconds = max(0, totalMilliseconds)
        startedAt = now
        stageStartedAt = now
        lastActivityAt = now
    }

    mutating func receive(_ update: Update) {
        // SDK token callbacks can arrive after a completed decode/validation.
        guard update.stage.rawValue >= stage.rawValue else { return }
        if update.stage != stage {
            stage = update.stage
            stageStartedAt = max(startedAt, update.date)
            completedMilliseconds = 0
        }
        lastActivityAt = max(lastActivityAt, update.date)
        if let position = update.completedMilliseconds {
            completedMilliseconds = max(completedMilliseconds, min(totalMilliseconds, max(0, position)))
        }
    }

    var fraction: Double? {
        guard totalMilliseconds > 0, stage == .preparingAudio || stage == .recognizing else { return nil }
        // A last segment can include padded audio. Only the caller's validation
        // and durable commit establish completion, not a decoder timestamp.
        let limit = stage == .recognizing ? max(0, totalMilliseconds - 1) : totalMilliseconds
        return Double(min(limit, completedMilliseconds)) / Double(totalMilliseconds)
    }

    func elapsed(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(startedAt)) }

    /// A current-run estimate for transcription only. No fabricated device-speed
    /// baseline, model-loading estimate, or countdown to zero during a slow window.
    func estimatedRemaining(at now: Date) -> TimeInterval? {
        guard stage == .recognizing, completedMilliseconds >= 10_000,
              completedMilliseconds < totalMilliseconds else { return nil }
        let elapsed = max(0, now.timeIntervalSince(stageStartedAt))
        guard elapsed >= 2 else { return nil }
        let remaining = elapsed * Double(totalMilliseconds - completedMilliseconds) / Double(completedMilliseconds)
        return remaining.isFinite ? remaining : nil
    }

    static func timestamp(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds) / 1_000
        if seconds >= 3_600 {
            return String(format: "%lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }
}
