import AVFoundation
import Combine
import Foundation
import os
/// Plays the logical meeting timeline. Physical FLAC overlaps are skipped so
/// part boundaries never replay the preceding two seconds.
@MainActor
final class MeetingAudioPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    @Published var outputLevelPercent = 100 {
        didSet {
            let clamped = min(max(outputLevelPercent, 0), 400)
            if outputLevelPercent != clamped {
                outputLevelPercent = clamped
            }
            let mix = Self.outputMix(for: clamped)
            node.volume = mix.volume
            equalizer.globalGain = mix.gainDB
        }
    }

    private let engine = AVAudioEngine()
    @Published private(set) var playbackProgress = 0.0
    private var logicalTotalSamples: Int64 = 0
    @Published private(set) var playbackMilliseconds: Int64 = 0
    private var playbackSampleRate: Int64 = 0
    @Published private(set) var isPaused = false
    private let node = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 0)
    private let logger = Logger(subsystem: "pieroot.todo", category: "MeetingPlayback")
    private var scheduler: MeetingPlaybackStreamScheduler?
    private var pendingStartProgress: Double?
    private var isStartingPlayback = false
    /// The logical sample the current schedule started from. node.playerTime
    /// resets to 0 on every (re)schedule, so progress = base + node.sampleTime.
    private var baseLogicalSample: Int64 = 0
    init() {
        engine.attach(node)
        engine.attach(equalizer)
        equalizer.globalGain = 0
    }

    nonisolated static func outputMix(for percent: Int) -> (volume: Float, gainDB: Float) {
        let clamped = min(max(percent, 0), 400)
        let ratio = Double(clamped) / 100
        if clamped <= 100 {
            return (Float(ratio), 0)
        }
        return (1, Float(min(12, 20 * log10(ratio))))
    }

    nonisolated static func milliseconds(forLogicalSample sample: Int64, sampleRate: Int64) -> Int64 {
        guard sample > 0, sampleRate > 0 else { return 0 }
        return (sample / sampleRate) * 1_000 + ((sample % sampleRate) * 1_000 / sampleRate)
    }

    /// Resolves the position play() should start from: the still-armed seek
    /// target when set, else the last known playback progress. A value at or
    /// past the end collapses to zero so replaying after natural completion
    /// restarts from the beginning instead of resuming a stale end/seek value.
    nonisolated static func resolvedStartProgress(pending: Double?, current: Double) -> Double {
        let resolved = pending ?? current
        guard resolved.isFinite else { return 0 }
        return resolved >= 1 ? 0 : min(max(resolved, 0), 1)
    }

    func play(manifest: MeetingAudioManifest) async throws {
        guard !isStartingPlayback else { return }
        if isPaused {
            node.play()
            isPaused = false
            isPlaying = true
            return
        }
        isStartingPlayback = true
        defer { isStartingPlayback = false }
        // Keep the armed seek until it is resolved after session activation below.
        stop(resetProgress: false)
        do {
            try await MeetingAudioSessionController.shared.activateForPlayback()
        } catch {
            throw PlaybackError.operation("activateSession", error)
        }
        let startProgress = Self.resolvedStartProgress(
            pending: pendingStartProgress,
            current: playbackProgress
        )
        var playbackStarted = false
        defer {
            if !playbackStarted {
                stop()
                Task { await MeetingAudioSessionController.shared.deactivate() }
            }
        }
        guard !manifest.parts.isEmpty else { throw PlaybackError.noAudio }
        logicalTotalSamples = manifest.totalSamples
        playbackSampleRate = manifest.sampleRate
        let startSample = Int64(startProgress * Double(logicalTotalSamples))
        playbackProgress = startProgress
        playbackMilliseconds = Self.milliseconds(
            forLogicalSample: startSample,
            sampleRate: playbackSampleRate
        )
        baseLogicalSample = startSample

        guard let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(manifest.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw PlaybackError.invalidManifest
        }
        engine.connect(node, to: equalizer, format: playbackFormat)
        engine.connect(equalizer, to: engine.mainMixerNode, format: playbackFormat)
        let cursor: MeetingLogicalAudioCursor
        do {
            cursor = try MeetingLogicalAudioCursor(manifest: manifest)
        } catch {
            throw PlaybackError.operation("openTimeline", error)
        }
        let streamScheduler = MeetingPlaybackStreamScheduler(cursor: cursor, node: node, format: playbackFormat)
        streamScheduler.onEvent = { [weak self, weak streamScheduler] event in
            Task { @MainActor in
                guard let self, let streamScheduler, streamScheduler === self.scheduler else { return }
                switch event {
                case .finished(let epoch):
                    // A seek after this event was emitted supersedes it; ignore
                    // so a stale end-of-timeline doesn't stop the new playback.
                    guard epoch == streamScheduler.currentEpoch() else { return }
                    self.handlePlaybackFinished()
                case .failed(let error, let epoch):
                    guard epoch == streamScheduler.currentEpoch() else { return }
                    self.report(PlaybackError.operation("streamDecode", error))
                    self.stop()
                }
            }
        }
        scheduler = streamScheduler
        do {
            if startSample > 0 {
                try streamScheduler.seek(toLogicalSample: startSample, resumePlaying: false)
            } else {
                try streamScheduler.start()
            }
        } catch {
            throw PlaybackError.operation("streamDecode", error)
        }
        do {
            try engine.start()
        } catch {
            throw PlaybackError.operation("startEngine", error)
        }
        node.play()
        playbackStarted = true
        pendingStartProgress = nil
        isPlaying = true
    }

    private func handlePlaybackFinished() {
        completePlayback(totalSamples: logicalTotalSamples, sampleRate: playbackSampleRate)
    }

    func completePlayback(totalSamples: Int64, sampleRate: Int64) {
        let finalMilliseconds = Self.milliseconds(
            forLogicalSample: totalSamples,
            sampleRate: sampleRate
        )
        stop(resetProgress: false)
        playbackProgress = 1
        playbackMilliseconds = finalMilliseconds
    }

    func refreshPlaybackProgress() {
        guard isPlaying,
              logicalTotalSamples > 0,
              let renderTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: renderTime)
        else { return }
        let logical = baseLogicalSample + playerTime.sampleTime
        playbackProgress = min(1, max(0, Double(logical) / Double(logicalTotalSamples)))
        playbackMilliseconds = Self.milliseconds(
            forLogicalSample: logical,
            sampleRate: playbackSampleRate
        )
    }

    /// Scrubs to a fraction of the timeline. Before playback starts, this keeps
    /// the visible position armed so the waveform doesn't snap back to the start.
    /// Once playback is prepared, it also repositions the scheduled audio.
    func seek(toProgress progress: Double, totalMilliseconds: Int64? = nil) {
        guard progress.isFinite else { return }
        let clamped = min(max(progress, 0), 1)
        pendingStartProgress = clamped

        guard let scheduler, logicalTotalSamples > 0 else {
            playbackProgress = clamped
            if let totalMilliseconds {
                playbackMilliseconds = Int64(clamped * Double(totalMilliseconds))
            }
            return
        }

        let target = Int64(clamped * Double(logicalTotalSamples))
        do {
            try scheduler.seek(toLogicalSample: target, resumePlaying: isPlaying)
            baseLogicalSample = target
            playbackProgress = min(1, max(0, Double(target) / Double(logicalTotalSamples)))
            playbackMilliseconds = Self.milliseconds(
                forLogicalSample: target,
                sampleRate: playbackSampleRate
            )
            // Already applied to the live engine; nothing left to consume at the
            // next play(), so don't let this linger and get replayed after this
            // session stops/finishes.
            pendingStartProgress = nil
        } catch {
            report(PlaybackError.operation("seek", error))
            stop()
        }
    }

    func pause() {
        node.pause()
        isPaused = true
        isPlaying = false
    }
    static func userFacingErrorMessage(_ error: Error, language: AppLanguage) -> String {
        if let playbackError = error as? PlaybackError {
            return playbackError.errorDescription(language: language)
        }
        return AppLanguage.localized(
            "error.meeting.playback.operation",
            defaultValue: language == .english
                ? "The meeting recording could not be played."
                : "회의 녹음을 재생할 수 없습니다.",
            language: language,
            comment: "Generic playback error shown to users; diagnostics stay in logs."
        )
    }

    func report(_ error: Error) {
        switch error {
        case let playbackError as PlaybackError:
            switch playbackError {
            case .noAudio:
                logger.error("Playback failure reason=noAudio")
            case .invalidManifest:
                logger.error("Playback failure reason=invalidManifest")
            case .operation(let operation, let underlying):
                let diagnostic = underlying as NSError
                logger.error(
                    "Playback failure operation=\(operation, privacy: .public) domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code, privacy: .public) description=\(diagnostic.localizedDescription, privacy: .private)"
                )
                DiagnosticRecorder.shared.record(
                    error: underlying,
                    component: "meeting.playback",
                    operation: operation
                )
            }
        default:
            let diagnostic = error as NSError
            logger.error(
                "Playback failure domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code, privacy: .public) description=\(diagnostic.localizedDescription, privacy: .private)"
            )
            DiagnosticRecorder.shared.record(
                error: error,
                component: "meeting.playback",
                operation: "playback"
            )
        }
        errorMessage = Self.userFacingErrorMessage(error, language: .current)
    }

    func dismissError() {
        errorMessage = nil
    }

    func stop(resetProgress: Bool = true) {
        scheduler?.cancel()
        scheduler = nil
        node.stop()
        engine.disconnectNodeOutput(node)
        engine.stop()
        if resetProgress {
            playbackProgress = 0
            playbackMilliseconds = 0
            pendingStartProgress = nil
        }
        logicalTotalSamples = 0
        playbackSampleRate = 0
        baseLogicalSample = 0
        isPaused = false
        isPlaying = false
    }

    deinit {
        node.stop()
        engine.stop()
    }

    enum PlaybackError: LocalizedError {
        case noAudio
        case invalidManifest
        case operation(String, Error)

        var errorDescription: String? {
            errorDescription(language: .current)
        }

        func errorDescription(language: AppLanguage) -> String {
            switch self {
            case .noAudio:
                return AppLanguage.localized(
                    "error.meeting.playback.noAudio",
                    defaultValue: language == .english
                        ? "There is no original recording to play."
                        : "재생할 원본 녹음이 없습니다.",
                    language: language,
                    comment: "Meeting playback error shown when a recording has no audio parts."
                )
            case .invalidManifest:
                return AppLanguage.localized(
                    "error.meeting.playback.invalidManifest",
                    defaultValue: language == .english
                        ? "The original recording manifest is invalid."
                        : "원본 녹음 manifest가 올바르지 않습니다.",
                    language: language,
                    comment: "Meeting playback error shown when the recording manifest is invalid."
                )
            case .operation:
                return AppLanguage.localized(
                    "error.meeting.playback.operation",
                    defaultValue: language == .english ? "The meeting recording could not be played." : "회의 녹음을 재생할 수 없습니다.",
                    language: language,
                    comment: "Generic meeting playback error; provider diagnostics stay in logs."
                )
            }
        }
    }
}
