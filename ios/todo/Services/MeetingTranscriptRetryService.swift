import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Re-runs on-device transcription from the saved FLAC timeline for meetings
/// whose live Speech finalization failed or timed out. Raw audio and the
/// provisional transcript are never touched until a full result exists.
struct MeetingTranscriptRetryService {
    private let transcriptionSessionFactory: any MeetingTranscriptionSessionFactory

    init(transcriptionSessionFactory: any MeetingTranscriptionSessionFactory = DefaultMeetingTranscriptionSessionFactory()) {
        self.transcriptionSessionFactory = transcriptionSessionFactory
    }

    /// Re-runs on-device transcription from the saved FLAC timeline. Raw audio
    /// and the provisional transcript remain untouched until this completes.
    func retranscribe(
        manifest: MeetingAudioManifest, languageTag: String,
        progress: @escaping @Sendable (MeetingTranscriptionProgress.Update) -> Void = { _ in }
    ) async throws -> [LiveTranscriptEntry] {
        progress(.init(.preparingAudio))
        let session = try await transcriptionSessionFactory.make(languageTag: languageTag, purpose: .retry)
        guard let canonicalFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(manifest.sampleRate),
            channels: 1,
            interleaved: true
        ) else {
            throw RetryError.format
        }
        let converter = try MeetingPCMConverter(
            inputFormat: canonicalFormat,
            outputFormat: session.inputFormat
        )
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        progress(.init(.recognizing, completedMilliseconds: 0))
        let feeding = Task(priority: .userInitiated) {
            defer { continuation.finish() }
            let cursor = try MeetingLogicalAudioCursor(manifest: manifest)
            while let buffer = try cursor.nextPCMBuffer(maxFrames: 16_384, outputFormat: canonicalFormat) {
                try Task.checkCancellation()
                for analyzerBuffer in try converter.convert(buffer) {
                    continuation.yield(AnalyzerInput(buffer: analyzerBuffer))
                }
            }
            for analyzerBuffer in try converter.finish() {
                continuation.yield(AnalyzerInput(buffer: analyzerBuffer))
            }
        }
        let collecting = Task {
            var reducer = LiveTranscriptReducer()
            for try await result in session.results {
                reducer.replace(Self.entry(for: result))
                let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                if result.isFinal, end.isFinite, end >= 0 {
                    let bounded = min(end, Double(manifest.totalSamples) / Double(manifest.sampleRate))
                    progress(.init(.recognizing, completedMilliseconds: Int64(bounded * 1_000)))
                }
            }
            return reducer.entries
        }
        let analyzing = Task {
            try await session.analyze(stream)
        }
        do {
            try await feeding.value
            try await analyzing.value
            let entries = try await collecting.value
            progress(.init(.validating))
            return entries
        } catch {
            feeding.cancel()
            collecting.cancel()
            analyzing.cancel()
            await session.cancel()
            throw RetryError.operation("retranscribe", error)
        }
    }

    private static func entry(for result: MeetingTranscriptionResult) -> LiveTranscriptEntry {
        let start = result.range.start
        let duration = result.range.duration
        let startSeconds = start.timescale == 0 ? 0 : Double(start.value) / Double(start.timescale)
        let endSeconds = duration.timescale == 0
            ? startSeconds
            : startSeconds + Double(duration.value) / Double(duration.timescale)
        let startMs = Int64((startSeconds * 1_000).rounded(.down))
        let endMs = max(startMs + 1, Int64((endSeconds * 1_000).rounded(.down)))
        return LiveTranscriptEntry(
            id: "\(start.value):\(start.timescale):\(duration.value):\(duration.timescale)",
            startMs: startMs,
            endMs: endMs,
            text: String(result.text.characters),
            confidence: result.confidence,
            timedRuns: MeetingTimedTextRun.extract(from: result.text, startMs: startMs, endMs: endMs),
            isFinal: result.isFinal
        )
    }

    enum RetryError: LocalizedError {
        case format
        case operation(String, Error)

        var errorDescription: String? {
            errorDescription(language: .current)
        }

        func errorDescription(language: AppLanguage) -> String {
            switch self {
            case .format:
                return AppLanguage.localized(
                    "error.meeting.transcriptRetry.format",
                    defaultValue: language == .english
                        ? "The original recording format could not be prepared."
                        : "원본 녹음 포맷을 준비할 수 없습니다.",
                    language: language,
                    comment: "Meeting transcript retry error shown when the source recording format cannot be prepared."
                )
            case .operation:
                return AppLanguage.localized(
                    "error.meeting.transcriptRetry.operation",
                    defaultValue: language == .english ? "The transcript retry failed." : "전사 재시도에 실패했습니다.",
                    language: language,
                    comment: "Generic transcript retry error; provider diagnostics stay in logs."
                )
            }
        }
    }
}
