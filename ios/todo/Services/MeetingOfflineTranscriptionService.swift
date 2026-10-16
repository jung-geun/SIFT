@preconcurrency import AVFoundation
import Foundation
import WhisperKit

/// Saved-audio-only transcription. The caller owns stop/retry/recovery and must
/// compare `sourceTranscriptRevision` before committing the replacement result.
/// No meeting, source FLAC, or manifest is mutated by this service.
/// Export holds at most 65,536 decoded frames per cursor read; the temporary
/// 16-bit mono WAV occupies two bytes per logical sample plus its header.
/// WhisperKit stages 30 seconds with one buffered chunk, not a full-recording
/// float array. Only final text/timing results accumulate across the recording.
nonisolated struct MeetingOfflineTranscriptionService: Sendable {
    struct Output: Sendable {
        let result: MeetingResult
        let sourceTranscriptRevision: Int
        /// SDK language codes, in encounter order, without collapsing mixed speech
        /// to a single selected app language. Empty for silent audio.
        let detectedLanguages: [String]

        var languageTag: String? {
            guard detectedLanguages.count == 1 else { return nil }
            let code = detectedLanguages[0]
            return AppLanguage.supportedLanguage(for: code)?.speechLanguageTag ?? code
        }
    }

    enum Failure: Error, Equatable, LocalizedError {
        case invalidManifest, invalidRevision, unsupportedLanguage
        case invalidTimestamps, audioUnavailable, transcriptionFailed, cleanupFailed

        var errorDescription: String? { errorDescription(language: .current) }

        func errorDescription(language: AppLanguage) -> String {
            // Never retain or interpolate SDK errors: they can contain transcript text.
            let key: String
            let english: String
            switch self {
            case .invalidManifest:
                key = "meeting.offlineTranscription.error.invalidManifest"
                english = "The saved recording timeline is invalid."
            case .invalidRevision:
                key = "meeting.offlineTranscription.error.invalidRevision"
                english = "The source transcript revision is invalid."
            case .unsupportedLanguage:
                key = "meeting.offlineTranscription.error.unsupportedLanguage"
                english = "The requested transcription language is unsupported."
            case .invalidTimestamps:
                key = "meeting.offlineTranscription.error.invalidTimestamps"
                english = "Offline transcription returned invalid audio timestamps."
            case .audioUnavailable:
                key = "meeting.offlineTranscription.error.audioUnavailable"
                english = "The saved recording could not be prepared."
            case .transcriptionFailed:
                key = "meeting.offlineTranscription.error.transcriptionFailed"
                english = "Offline transcription failed."
            case .cleanupFailed:
                key = "meeting.offlineTranscription.error.cleanupFailed"
                english = "Temporary transcription audio could not be removed."
            }
            return AppLanguage.localized(key, defaultValue: english, language: language,
                                         comment: "Saved-audio transcription error without private diagnostics.")
        }
    }

    private let store: MeetingWhisperModelStore

    init(store: MeetingWhisperModelStore = .shared) {
        self.store = store
    }

    /// `nil` detects language (including mixed-language recordings). Explicit
    /// supported app tags and regional aliases request that language, not an automatic hint.
    /// The result has the next revision and fresh IDs, with no inherited speakers
    /// or extraction metadata. Silence is a valid empty result, not fallback text.
    @concurrent
    func transcribe(
        manifest: MeetingAudioManifest,
        sourceTranscriptRevision: Int,
        languageTag: String? = nil,
        rootURL: URL = AppDataContainer.meetingDirectory(),
        progress: @escaping @Sendable (MeetingTranscriptionProgress.Update) -> Void = { _ in }
    ) async throws -> Output {
        try Self.validateRevision(sourceTranscriptRevision)
        let language = try Self.languageCode(for: languageTag)
        progress(.init(.loadingModel))
        do {
            return try await store.withLoadedModel { model in
                // The pinned loader initializes SDK logging; disable it after loading
                // and before decoding, including SDK error logs containing tokens.
                Logging.updateLogLevel(.none)
                progress(.init(.preparingAudio, completedMilliseconds: 0))
                return try await Self.withExportedWAV(manifest: manifest, rootURL: rootURL, progress: { samples in
                    progress(.init(.preparingAudio, completedMilliseconds: samples * 1_000 / MeetingMediaTimeline.sampleRate))
                }) { wav in
                    let options = DecodingOptions(
                        verbose: false,
                        task: .transcribe,
                        language: language,
                        detectLanguage: language == nil,
                        skipSpecialTokens: true,
                        withoutTimestamps: false,
                        wordTimestamps: true,
                        concurrentWorkerCount: 1
                    )
                    let results: [TranscriptionResult]
                    progress(.init(.recognizing, completedMilliseconds: 0))
                    model.segmentDiscoveryCallback = { segments in
                        // These callbacks already contain absolute sample-derived
                        // chunk offsets. Never multiply windowId by 30 seconds.
                        let seconds = segments.reduce(0.0) { position, segment in
                            guard segment.end.isFinite, segment.end >= 0 else { return position }
                            return max(position, min(Double(segment.end), Double(manifest.totalSamples) / 16_000))
                        }
                        progress(.init(.recognizing, completedMilliseconds: Int64(seconds * 1_000)))
                    }
                    defer { model.segmentDiscoveryCallback = nil }
                    do {
                        results = try await model.transcribe(
                            audioPath: wav.path,
                            audioInputOptions: AudioInputOptions(
                                channelMode: .specificChannel(0),
                                audioLoadingMode: .incremental(chunkDurationSeconds: 30, maxBufferedChunks: 1)
                            ),
                            decodeOptions: options
                        )
                    } catch {
                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                        throw Failure.transcriptionFailed
                    }
                    try Task.checkCancellation()
                    progress(.init(.validating))
                    return try await Self.makeOutput(
                        results, totalSamples: manifest.totalSamples,
                        sourceTranscriptRevision: sourceTranscriptRevision
                    )
                }
            }
        } catch let error as MeetingWhisperModelError {
            throw error
        } catch let error as Failure {
            throw error
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw Failure.transcriptionFailed
        }
    }

    static func languageCode(for tag: String?) throws -> String? {
        guard let tag else { return nil }
        guard let language = AppLanguage.supportedLanguage(for: tag),
              let code = language.locale.language.languageCode?.identifier else {
            throw Failure.unsupportedLanguage
        }
        return code
    }

    private static func validateRevision(_ revision: Int) throws {
        guard revision >= 0, revision < MeetingCanonicalID.maximumSafeInteger else {
            throw Failure.invalidRevision
        }
    }

    /// SDK incremental transcription has already applied sample-derived offsets
    /// to both segments and words. Do not add seekTime, seek, or callback counts.
    /// WhisperKit 1.1.0 SegmentSeeker can retain zero-duration DTW words when
    /// there is no gap to expand them (updateSegmentsWithWordTimings). They are
    /// not measured intervals: preserve the segment text without timed runs.
    @MainActor
    static func makeOutput(
        _ results: [TranscriptionResult],
        totalSamples: Int64,
        sourceTranscriptRevision: Int
    ) throws -> Output {
        try validateRevision(sourceTranscriptRevision)
        guard totalSamples >= 0, totalSamples <= MeetingMediaTimeline.maximumSamples else {
            throw Failure.invalidManifest
        }
        let limit = Double(totalSamples) / Double(MeetingMediaTimeline.sampleRate)
        let limitMs = totalSamples * 1_000 / MeetingMediaTimeline.sampleRate
        var segments: [MeetingSegment] = []
        var languages: [String] = []
        for result in results {
            var hasSpeech = false
            for source in result.segments {
                // Decoder timestamps can include the padded tail of a 30-second
                // window. Clip that tail, but never accept arbitrary finite ends.
                guard source.seek >= 0, Int64(source.seek) <= totalSamples else {
                    throw Failure.invalidTimestamps
                }
                // SDK adds local Float times and chunk offsets separately; a
                // bound recomputed from their combined integer seek can differ
                // by Float rounding. Allow only that numeric slack, not new time.
                let windowEnd = (Float(source.seek) / Float(MeetingMediaTimeline.sampleRate)
                    + Float(Constants.defaultWindowSamples) / Float(MeetingMediaTimeline.sampleRate)).nextUp.nextUp
                try validateTimes(start: source.start, end: source.end, windowEnd: windowEnd)
                // Check numeric corruption even after an unalignable word. Zero
                // duration is legitimate SDK output, not trusted word timing.
                for word in source.words ?? [] {
                    try validateTimes(start: word.start, end: word.end, windowEnd: windowEnd)
                }
                // Timestamp/special-token-only slices decode to empty text with
                // skipSpecialTokens. No app interval is needed for these markers.
                guard !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                guard source.end > source.start, Double(source.start) < limit else {
                    throw Failure.invalidTimestamps
                }
                let startMs = Int64((Double(source.start) * 1_000).rounded(.down))
                let endMs = min(limitMs, Int64((min(Double(source.end), limit) * 1_000).rounded(.down)))
                guard endMs > startMs else { throw Failure.invalidTimestamps }
                let runs = trustedRuns(source, startMs: startMs, endMs: endMs)
                segments.append(MeetingSegment(
                    startMs: startMs, endMs: endMs, speakerIDs: [],
                    text: source.text, isFinal: true, timedRuns: runs
                ))
                hasSpeech = true
            }
            if hasSpeech, !result.language.isEmpty, !languages.contains(result.language) {
                languages.append(result.language)
            }
        }
        segments.sort { ($0.startMs, $0.endMs, $0.id) < ($1.startMs, $1.endMs, $1.id) }
        let result = try MeetingResult(
            transcriptRevision: sourceTranscriptRevision + 1, segments: segments
        ).validated()
        return Output(result: result, sourceTranscriptRevision: sourceTranscriptRevision,
                      detectedLanguages: languages)
    }

    private static func validateTimes(start: Float, end: Float, windowEnd: Float) throws {
        guard start.isFinite, end.isFinite, start >= 0, end >= start, end <= windowEnd else {
            throw Failure.invalidTimestamps
        }
    }

    /// Require complete literal coverage (apart from whitespace), valid Character
    /// boundaries, probabilities, and nonoverlapping measured times. Never search
    /// ahead for a repeated word, normalize Unicode, or interpolate missing timing.
    private static func trustedRuns(
        _ segment: TranscriptionSegment, startMs: Int64, endMs: Int64
    ) -> [MeetingTimedTextRun]? {
        guard let words = segment.words, !words.isEmpty else { return nil }
        let text = segment.text
        let boundaries = Set(text.indices).union([text.endIndex])
        var position = text.startIndex
        var previousEnd: Float?
        var runs: [MeetingTimedTextRun] = []
        func skipWhitespace() {
            while position < text.endIndex,
                  text[position].unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                position = text.index(after: position)
            }
        }
        for word in words {
            guard word.end > word.start,
                  word.probability.isFinite, (0...1).contains(word.probability),
                  previousEnd.map({ word.start >= $0 }) ?? true else { return nil }
            previousEnd = word.end
            let literal = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            skipWhitespace()
            guard !literal.isEmpty,
                  let range = text.range(of: literal, options: [.anchored, .literal], range: position..<text.endIndex),
                  boundaries.contains(range.lowerBound), boundaries.contains(range.upperBound) else { return nil }
            // Clip real measurements to the segment/recording, never expand them.
            let lower = max(Double(word.start) * 1_000, Double(startMs))
            let upper = min(Double(word.end) * 1_000, Double(endMs))
            guard lower < upper else { return nil }
            let start = Int64(lower.rounded(.down))
            let end = Int64(upper.rounded(.down))
            guard end > start, start >= (runs.last?.endMs ?? startMs) else { return nil }
            let utf16 = NSRange(range, in: text)
            runs.append(MeetingTimedTextRun(utf16Offset: utf16.location, utf16Length: utf16.length,
                                           startMs: start, endMs: end))
            position = range.upperBound
        }
        skipWhitespace()
        return position == text.endIndex ? runs : nil
    }

    /// Own the directory *before* writing begins so partial export, inference
    /// failure, cancellation, and successful inference all remove the parent.
    static func withExportedWAV<T: Sendable>(
        manifest: MeetingAudioManifest,
        rootURL: URL,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        progress: @Sendable (Int64) -> Void = { _ in },
        body: (URL) async throws -> T
    ) async throws -> T {
        try validateManifest(manifest, rootURL: rootURL)
        try Task.checkCancellation()
        let directory = temporaryRoot.appendingPathComponent("meeting-offline-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let wav = directory.appendingPathComponent("recording.wav")
            do {
                try writeWAV(manifest: manifest, rootURL: rootURL, destination: wav, progress: progress)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw Failure.audioUnavailable
            }
            try Task.checkCancellation()
            let result = try await body(wav)
            try Task.checkCancellation()
            do { try fm.removeItem(at: directory) } catch { throw Failure.cleanupFailed }
            return result
        } catch {
            if fm.fileExists(atPath: directory.path) {
                do { try fm.removeItem(at: directory) } catch { throw Failure.cleanupFailed }
            }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let failure = error as? Failure { throw failure }
            throw Failure.audioUnavailable
        }
    }

    private static func validateManifest(_ manifest: MeetingAudioManifest, rootURL: URL) throws {
        let components = manifest.relativeDirectory.split(separator: "/", omittingEmptySubsequences: false)
        guard manifest.sampleRate == MeetingMediaTimeline.sampleRate,
              manifest.totalSamples > 0, manifest.totalSamples <= MeetingMediaTimeline.maximumSamples,
              !manifest.parts.isEmpty, manifest.parts.count <= MeetingMediaTimeline.maximumParts,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Failure.invalidManifest
        }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(manifest.relativeDirectory).standardizedFileURL.resolvingSymlinksInPath()
        guard directory.path.hasPrefix(root.path + "/") else { throw Failure.invalidManifest }
        var next: Int64 = 0
        for (index, part) in manifest.parts.sorted(by: { $0.partIndex < $1.partIndex }).enumerated() {
            guard part.partIndex == index,
                  part.fileName == String(format: "part-%02d.flac", index),
                  part.ownedStartSample == next,
                  part.ownedEndSample > next, part.ownedEndSample <= manifest.totalSamples,
                  part.ownedEndSample - next <= MeetingMediaTimeline.ownedSamplesPerPart,
                  part.partStartSample == max(0, next - MeetingMediaTimeline.overlapSamples),
                  directory.appendingPathComponent(part.fileName).resolvingSymlinksInPath().path.hasPrefix(directory.path + "/")
            else { throw Failure.invalidManifest }
            next = part.ownedEndSample
        }
        guard next == manifest.totalSamples else { throw Failure.invalidManifest }
    }

    private static func writeWAV(
        manifest: MeetingAudioManifest, rootURL: URL, destination: URL,
        progress: @Sendable (Int64) -> Void
    ) throws {
        let cursor = try MeetingLogicalAudioCursor(manifest: manifest, rootURL: rootURL)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(manifest.sampleRate),
                                        channels: 1, interleaved: false) else { throw Failure.audioUnavailable }
        let file = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(manifest.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        var written: Int64 = 0
        while let buffer = try cursor.nextPCMBuffer(maxFrames: 65_536, outputFormat: format) {
            try Task.checkCancellation()
            guard Int64(buffer.frameLength) <= manifest.totalSamples - written else { throw Failure.invalidManifest }
            try file.write(from: buffer)
            written += Int64(buffer.frameLength)
            progress(written)
        }
        guard written == manifest.totalSamples else { throw Failure.invalidManifest }
        // AVAudioFile closes and finalizes the WAV header before its URL is used.
    }
}
