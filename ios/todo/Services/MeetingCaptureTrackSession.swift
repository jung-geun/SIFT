@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech


struct MeetingLiveCaptureTrack: Identifiable, Equatable {
    let meetingID: String
    let sourceKind: MeetingAudioTrackKind
    let sourceLabel: String?
    let sessionStartSample: Int64
    let recordedAudioSamples: Int64
    let recordedAudioPartCount: Int
    let liveTranscriptRows: [MeetingLiveTranscriptRow]
    let liveSpeakerOrdinals: [String: Int]
    let liveSpeakerPhase: MeetingCaptureCoordinator.LiveSpeakerPhase
    let liveTranscriptionWarning: String?
    let liveDiarizationWarning: String?
    var isDetectingLanguage: Bool = false
    var detectedLanguageTag: String? = nil
    var id: String { meetingID }

    var conversationSourceLabel: String {
        let kind = sourceKind.displayName()
        guard let label = sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return kind }
        return "\(kind) · \(label)"
    }
}

/// Router-queue confined writer, with independently detachable best-effort consumers.
/// The router borrows its PCM buffer; neither consumer may retain that buffer.
nonisolated final class MeetingCaptureTrackInput: @unchecked Sendable {
    let writer: MeetingFLACPartWriter
    private let lock = NSLock()
    private var transcription: MeetingTranscriptionInputPipeline?
    private var automaticTranscription: MeetingAutomaticLanguageSession?
    private var speakers: MeetingDiarizationInputPipeline?
    private var accepting = true
    private var lastPublished: Int64 = 0
    private var failure: Error?
    private let progress: @Sendable (Int64, Int) -> Void

    init(writer: MeetingFLACPartWriter, progress: @escaping @Sendable (Int64, Int) -> Void) {
        self.writer = writer
        self.progress = progress
    }

    func attach(transcription: MeetingTranscriptionInputPipeline?) {
        lock.withLock { self.transcription = transcription }
    }

    func attach(automaticTranscription: MeetingAutomaticLanguageSession?) {
        lock.withLock { self.automaticTranscription = automaticTranscription }
    }

    func attach(speakers: MeetingDiarizationInputPipeline?) {
        lock.withLock { self.speakers = speakers }
    }

    func close() { lock.withLock { accepting = false; transcription = nil; automaticTranscription = nil; speakers = nil } }
    var recordedFailure: Error? { lock.withLock { failure } }

    func recordFailure(_ error: Error) { lock.withLock { failure = failure ?? error } }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        try lock.withLock {
            guard accepting else { return }
            let start = writer.totalSamples
            try writer.append(buffer)
            transcription?.enqueue(buffer)
            automaticTranscription?.enqueue(buffer)
            speakers?.enqueue(buffer, startSample: start)
            if writer.totalSamples >= lastPublished + 4_000 {
                lastPublished = writer.totalSamples
                progress(writer.totalSamples, writer.completedParts.count + 1)
            }
        }
    }
}

/// One child identity owns every mutable speech/speaker state and every saved sample.
/// Source admission/drain is owned by the router; finishAudio is called after its fence.
@MainActor
final class MeetingCaptureTrackSession {
    let meetingID: String
    let sourceKind: MeetingAudioTrackKind
    let sourceLabel: String?
    let directoryURL: URL
    private(set) var sessionStartSample: Int64
    private(set) var input: MeetingCaptureTrackInput!
    private(set) var timeline: MeetingLiveSpeakerTimeline?
    private(set) var transcriptionError: Error?
    private(set) var audioError: Error?
    private(set) var artifact: MeetingCaptureTrackArtifact?
    private(set) var finalized = false
    private var entries: [LiveTranscriptEntry] = []
    private var reducer = LiveTranscriptReducer()
    private var rowBuilder = MeetingLiveTranscriptRowBuilder()
    private var rows: [MeetingLiveTranscriptRow] = []
    private var samples: Int64 = 0
    private var partCount = 0
    private var transcriptionWarning: String?
    private var diarizationWarning: String?
    private var phase: MeetingCaptureCoordinator.LiveSpeakerPhase = .inactive
    private var session: (any MeetingTranscriptionSession)?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var transcriptionPipeline: MeetingTranscriptionInputPipeline?
    private var automaticSession: MeetingAutomaticLanguageSession?
    private var isDetectingLanguage = false
    private var detectedLanguageTag: String?
    private var resultsTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var speakerPipeline: MeetingDiarizationInputPipeline?
    private var speakerFinish: Task<Void, Never>?
    private var speakerSessionID: UUID?
    private var generation = UUID()
    private var speakerGeneration = UUID()
    private var cancelled = false
    private let finalizationGate = MeetingCaptureTerminationGate<Void>()
    private let changed: @MainActor () -> Void

    init(
        meetingID: String = UUID().uuidString.lowercased(), sourceKind: MeetingAudioTrackKind,
        sourceLabel: String?, sessionStartSample: Int64, directoryURL: URL? = nil,
        changed: @escaping @MainActor () -> Void
    ) throws {
        self.meetingID = meetingID
        self.sourceKind = sourceKind
        self.sourceLabel = sourceLabel
        self.sessionStartSample = sessionStartSample
        self.directoryURL = directoryURL ?? AppDataContainer.activeMeetingAudioDirectory(meetingID: meetingID)
        self.changed = changed
        let writer = try MeetingFLACPartWriter(directory: self.directoryURL)
        input = MeetingCaptureTrackInput(writer: writer) { [weak self] samples, parts in
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled, self.artifact == nil else { return }
                self.samples = samples
                self.partCount = parts
                self.changed()
            }
        }
    }

    func setStartSample(_ sample: Int64) { sessionStartSample = sample }

    var snapshot: MeetingLiveCaptureTrack {
        MeetingLiveCaptureTrack(
            meetingID: meetingID, sourceKind: sourceKind, sourceLabel: sourceLabel,
            sessionStartSample: sessionStartSample, recordedAudioSamples: samples,
            recordedAudioPartCount: partCount, liveTranscriptRows: rows,
            liveSpeakerOrdinals: timeline?.ordinals ?? [:], liveSpeakerPhase: phase,
            liveTranscriptionWarning: transcriptionWarning, liveDiarizationWarning: diarizationWarning,
            isDetectingLanguage: isDetectingLanguage, detectedLanguageTag: detectedLanguageTag
        )
    }

    var provisionalResult: MeetingResult {
        MeetingProvisionalResultBuilder.make(meetingID: meetingID, entries: entries)
    }

    func prepare(
        factory: any MeetingTranscriptionSessionFactory, languageTag: String,
        diarizationEnabled: Bool, groupID: String, deferTranscription: Bool = false,
        automaticLanguageDetection: Bool = false,
        languageDetector: @escaping MeetingLiveLanguageDetector = { try await MeetingLiveLanguageDetection.detect(samples: $0) }
    ) async {
        let ticket = generation
        if automaticLanguageDetection {
            isDetectingLanguage = true
            let automatic = MeetingAutomaticLanguageSession(factory: factory, detector: languageDetector) { [weak self] tag in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == ticket, !self.cancelled, self.transcriptionError == nil else { return }
                    self.detectedLanguageTag = tag
                    self.isDetectingLanguage = false
                    self.changed()
                }
            }
            automaticSession = automatic
            input.attach(automaticTranscription: automatic)
            resultsTask = Task { [weak self] in
                do {
                    for try await result in automatic.results {
                        try Task.checkCancellation()
                        guard let self, self.generation == ticket, !self.cancelled,
                              self.transcriptionError == nil else { break }
                        self.accept(result)
                    }
                } catch { await self?.failTranscription(error, ticket: ticket) }
            }
            analysisTask = Task { [weak self] in
                do { try await automatic.run() }
                catch { await self?.failTranscription(error, ticket: ticket) }
            }
            changed()
            await prepareSpeakers(enabled: diarizationEnabled, groupID: groupID)
            return
        }
        if deferTranscription {
            transcriptionWarning = MeetingLanguageCopy.text("meeting.languages.deferred", "This language uses Whisper after recording stops. Original audio is saved; live Apple transcription is unavailable for this selection.")
            changed()
            await prepareSpeakers(enabled: diarizationEnabled, groupID: groupID)
            return
        }
        do {
            let session = try await factory.make(languageTag: languageTag, purpose: .live)
            guard !cancelled, generation == ticket, !Task.isCancelled else {
                await session.cancel()
                return
            }
            let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(128))
            self.session = session
            continuation = stream.continuation
            let canonical = AVAudioFormat(commonFormat: .pcmFormatInt16,
                sampleRate: Double(MeetingMediaTimeline.sampleRate), channels: 1, interleaved: true)!
            let pipeline = try MeetingTranscriptionInputPipeline(
                inputFormat: canonical, outputFormat: session.inputFormat, maximumQueuedBuffers: 128,
                consume: { stream.continuation.yield($0) },
                failed: { [weak self] error in
                    Task { @MainActor in await self?.failTranscription(error, ticket: ticket) }
                }
            )
            transcriptionPipeline = pipeline
            input.attach(transcription: pipeline)
            resultsTask = Task { [weak self, session] in
                do {
                    for try await result in session.results {
                        try Task.checkCancellation()
                        guard let self, self.generation == ticket, !self.cancelled,
                              self.transcriptionError == nil else { break }
                        self.accept(result)
                    }
                } catch { await self?.failTranscription(error, ticket: ticket) }
            }
            analysisTask = Task { [weak self, session] in
                do { try await session.analyze(stream.stream) }
                catch { await self?.failTranscription(error, ticket: ticket) }
            }
        } catch { await failTranscription(error, ticket: ticket) }
        guard !cancelled, generation == ticket, !Task.isCancelled else { return }
        await prepareSpeakers(enabled: diarizationEnabled, groupID: groupID)
    }

    private func prepareSpeakers(enabled: Bool, groupID: String) async {
        guard enabled else { return }
        guard !Self.thermallyConstrained else {
            diarizationWarning = Self.thermalWarning
            changed()
            return
        }
        guard await MeetingDiarizationModelStore.shared.isInstalled() else {
            diarizationWarning = MeetingAppAudioCapture.message(
                "meeting.diarization.notInstalled",
                "Install the speaker model in Settings → Beta features to identify speakers. Recording continues.",
                "화자를 식별하려면 설정 → 베타 기능에서 화자 모델을 설치하세요. 녹음은 계속됩니다.")
            changed()
            return
        }
        guard !cancelled, !Task.isCancelled else { return }
        let worker: any MeetingDiarizationProcessing
        if let warmed = MeetingLiveSpeakerPrewarmer.shared.take(groupID: groupID) {
            worker = warmed
        } else {
            let id = UUID()
            guard MeetingDiarizationExecutionGate.shared.beginLive(id, groupID: groupID) else {
                diarizationWarning = MeetingAppAudioCapture.message(
                    "meeting.diarization.busy",
                    "Another meeting's speaker analysis is running. Recording and transcription continue.",
                    "다른 회의의 화자 분석이 진행 중입니다. 녹음과 전사는 계속됩니다.")
                changed()
                return
            }
            worker = MeetingDiarizationWorker(preset: .live, sessionID: id)
        }
        let id = worker.sessionID
        let ticket = speakerGeneration
        speakerSessionID = id
        timeline = MeetingLiveSpeakerTimeline(meetingID: meetingID, sessionID: id)
        phase = .preparing
        let pipeline = MeetingDiarizationInputPipeline(
            worker: worker,
            prepared: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.speakerGeneration == ticket, self.phase == .preparing else { return }
                    self.phase = .waitingForInference
                    self.changed()
                }
            },
            deliver: { [weak self] update in
                await MainActor.run { [weak self] in
                    guard let self, self.speakerGeneration == ticket, self.phase != .stopped,
                          var timeline = self.timeline, timeline.apply(update) else { return }
                    self.timeline = timeline
                    self.phase = .analyzing
                    self.refreshRows()
                }
            },
            failed: { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.speakerGeneration == ticket else { return }
                    self.phase = .stopped
                    self.diarizationWarning = MeetingAppAudioCapture.message(
                        "meeting.diarization.interrupted",
                        "Live speaker detection stopped. Recording and transcription continue.",
                        "실시간 화자 감지가 중단되었습니다. 녹음과 전사는 계속됩니다.")
                    self.changed()
                    await self.cancelSpeakers()
                }
            }
        )
        speakerPipeline = pipeline
        input.attach(speakers: pipeline)
        changed()
    }

    /// Only this source's optional inference is shed; recording and Apple STT stay open.
    func handleThermalPressure() async {
        guard Self.thermallyConstrained, speakerPipeline != nil else { return }
        phase = .stopped
        diarizationWarning = Self.thermalWarning
        changed()
        await cancelSpeakers()
    }

    private static var thermallyConstrained: Bool {
        ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    private static var thermalWarning: String {
        MeetingAppAudioCapture.message(
            "meeting.diarization.thermal",
            "The device is hot, so live speaker detection stopped. Recording and transcription continue.",
            "기기 온도가 높아 실시간 화자 감지를 멈췄습니다. 녹음과 전사는 계속됩니다.")
    }

    private func accept(_ result: MeetingTranscriptionResult) {
        let start = max(0, Int64((result.range.start.seconds * 1_000).rounded(.down)))
        let end = max(start + 1, Int64((CMTimeRangeGetEnd(result.range).seconds * 1_000).rounded(.down)))
        let range = result.range
        let entry = LiveTranscriptEntry(
            id: "\(range.start.value):\(range.start.timescale):\(range.duration.value):\(range.duration.timescale)",
            startMs: start, endMs: end, text: String(result.text.characters), confidence: result.confidence,
            timedRuns: MeetingTimedTextRun.extract(from: result.text, startMs: start, endMs: end), isFinal: result.isFinal)
        reducer.replace(entry)
        entries = reducer.entries
        refreshRows()
    }

    private func refreshRows() {
        rows = rowBuilder.rows(for: entries, timeline: timeline)
        changed()
    }

    private func failTranscription(_ error: Error, ticket: UUID) async {
        guard generation == ticket, !cancelled, !(error is CancellationError), transcriptionError == nil else { return }
        transcriptionError = error
        isDetectingLanguage = false
        if automaticSession != nil {
            switch error {
            case MeetingAutomaticLanguageSession.Failure.noSpeech:
                transcriptionWarning = MeetingLanguageCopy.text("meeting.languages.live.noSpeech", "No speech was available to detect this source’s language. Original audio is saved for automatic transcription after recording.")
            case MeetingAutomaticLanguageSession.Failure.invalidLanguage:
                transcriptionWarning = MeetingLanguageCopy.text("meeting.languages.live.invalidLanguage", "This source’s language could not be identified reliably. Original audio is saved; no fallback language was selected.")
            case MeetingAutomaticLanguageSession.Failure.bufferLimit:
                transcriptionWarning = MeetingLanguageCopy.text("meeting.languages.live.bufferLimit", "Live language preparation exceeded this source’s audio buffer. Original audio is saved for automatic transcription after recording.")
            case is MeetingTranscriptionError:
                transcriptionWarning = MeetingLanguageCopy.text("meeting.languages.live.appleUnavailable", "Apple live transcription could not run for this source’s detected language. Original audio is saved for automatic transcription after recording.")
            default:
                transcriptionWarning = MeetingLanguageCopy.text("meeting.languages.live.detectionFailed", "Automatic live transcription failed for this source. Original audio is saved; no fallback language was selected.")
            }
        } else {
            transcriptionWarning = MeetingAppAudioCapture.message(
                "meeting.capture.source.transcriptionStopped",
                "Live transcription stopped for this source. Its original audio is still being saved.",
                "이 소스의 실시간 전사가 중단되었습니다. 원본 음성은 계속 저장됩니다.")
        }
        input.attach(transcription: nil)
        input.attach(automaticTranscription: nil)
        changed()
        // Do not await our own results/analysis task from its error handler.
        await transcriptionPipeline?.cancel()
        await automaticSession?.cancel()
        continuation?.finish()
        await session?.cancel()
        resultsTask?.cancel()
        analysisTask?.cancel()
    }

    /// No analyzer/model wait belongs in this fast audio durability phase.
    func finishAudio(metadata: MeetingCaptureSourceMetadata?) throws -> MeetingCaptureTrackArtifact {
        if let artifact { return artifact }
        input.close()
        audioError = audioError ?? input.recordedFailure
        _ = try input.writer.finish()
        automaticSession?.finishInput()
        let parent = directoryURL.deletingLastPathComponent().lastPathComponent
        var manifest = input.writer.manifest(relativeDirectory: "\(parent)/\(directoryURL.lastPathComponent)")
        if let metadata {
            manifest.captureSourceMetadata = MeetingCaptureSourceMetadata(boundaries: metadata.boundaries.filter {
                $0.sample <= manifest.totalSamples
            })
        }
        samples = input.writer.totalSamples
        partCount = manifest.parts.count
        let result = MeetingCaptureTrackArtifact(meetingID: meetingID, sourceKind: sourceKind,
            sourceLabel: sourceLabel, sessionStartSample: sessionStartSample, directoryURL: directoryURL,
            audioManifest: manifest, provisionalResult: provisionalResult)
        artifact = result
        beginSpeakerFinish()
        changed()
        return result
    }

    func recordAudioFailure(_ error: Error) { audioError = audioError ?? error }

    func finalize(timeout: Duration) async {
        await finalizationGate.run { [weak self] in await self?.performFinalization(timeout: timeout) }
    }

    private func performFinalization(timeout: Duration) async {
        guard !finalized, !cancelled else { return }
        automaticSession?.finishInput()
        do { try await transcriptionPipeline?.finish() }
        catch { await failTranscription(error, ticket: generation) }
        continuation?.finish()
        if transcriptionError == nil {
            let analysis = analysisTask
            let results = resultsTask
            let session = session
            let automatic = automaticSession
            let completed = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await analysis?.value; await results?.value; return true }
                group.addTask {
                    do { try await Task.sleep(for: timeout) } catch { return true }
                    await session?.cancel()
                    await automatic?.cancel()
                    analysis?.cancel()
                    results?.cancel()
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !completed {
                await failTranscription(MeetingCaptureCoordinator.CaptureError.transcriptFinalizationTimeout, ticket: generation)
            }
        }
        beginSpeakerFinish()
        await speakerFinish?.value
        guard !cancelled else { return }
        releaseSpeakers()
        transcriptionPipeline = nil
        automaticSession = nil
        continuation = nil
        session = nil
        resultsTask = nil
        analysisTask = nil
        finalized = true
        changed()
    }

    func transcriptionResult() throws -> MeetingResult {
        guard finalized else { throw MeetingCaptureCoordinator.CaptureError.invalidState }
        if let transcriptionError { throw transcriptionError }
        return try provisionalResult.validated()
    }

    private func beginSpeakerFinish() {
        input.attach(speakers: nil)
        guard speakerFinish == nil, let speakerPipeline else { return }
        let sessionID = speakerSessionID
        speakerFinish = Task { [weak self] in
            try? await speakerPipeline.finish()
            guard let self, self.speakerSessionID == sessionID else { return }
            self.releaseSpeakers()
        }
    }

    private func releaseSpeakers() {
        speakerPipeline = nil
        speakerFinish = nil
        if let speakerSessionID { MeetingDiarizationExecutionGate.shared.endLive(speakerSessionID) }
        speakerSessionID = nil
        if phase != .stopped { phase = .inactive }
    }

    private func cancelSpeakers() async {
        speakerGeneration = UUID()
        input.attach(speakers: nil)
        await speakerPipeline?.cancel()
        await speakerFinish?.value
        releaseSpeakers()
    }

    func cancel(removeAudio: Bool) async {
        guard !cancelled else { return }
        cancelled = true
        generation = UUID()
        input.close()
        isDetectingLanguage = false
        await automaticSession?.cancel()
        await transcriptionPipeline?.cancel()
        continuation?.finish()
        await session?.cancel()
        resultsTask?.cancel()
        analysisTask?.cancel()
        await resultsTask?.value
        await analysisTask?.value
        await cancelSpeakers()
        _ = try? input.writer.finish()
        session = nil
        transcriptionPipeline = nil
        automaticSession = nil
        continuation = nil
        resultsTask = nil
        analysisTask = nil
        if removeAudio { try? FileManager.default.removeItem(at: directoryURL) }
    }
}
