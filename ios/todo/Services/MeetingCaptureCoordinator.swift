import AVFoundation
import AudioToolbox
import Combine
import CoreMedia
import Foundation
import os
import Speech

private struct TranscriptRangeKey: Hashable {
    let startValue: Int64
    let startTimescale: Int32
    let durationValue: Int64
    let durationTimescale: Int32

    init(_ range: CMTimeRange) {
        startValue = range.start.value
        startTimescale = range.start.timescale
        durationValue = range.duration.value
        durationTimescale = range.duration.timescale
    }

    var startSeconds: Double {
        guard startTimescale != 0 else { return 0 }
        return Double(startValue) / Double(startTimescale)
    }

    var endSeconds: Double {
        guard durationTimescale != 0 else { return startSeconds }
        return startSeconds + Double(durationValue) / Double(durationTimescale)
    }
}

struct LiveTranscriptEntry: Identifiable, Equatable {
    let id: String
    let startMs: Int64
    let endMs: Int64
    let text: String
    /// nil until post-stop whole-recording diarization completes.
    let speakerIDs: [String]
    /// Average per-word transcription confidence (0...1) from accuracy-first
    /// batch re-transcription; nil for the live path, which does not request it.
    let confidence: Double?
    /// Final segments cannot be replaced by a later volatile overlap.
    let isFinal: Bool

    init(
        id: String,
        startMs: Int64,
        endMs: Int64,
        text: String,
        speakerIDs: [String],
        confidence: Double? = nil,
        isFinal: Bool = false
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speakerIDs = speakerIDs
        self.confidence = confidence
        self.isFinal = isFinal
    }
}

struct MeetingCaptureArtifact: Sendable {
    let directoryURL: URL
    let audioManifest: MeetingAudioManifest
}

@MainActor
final class MeetingCaptureTerminationGate<Outcome: Sendable> {
    private var task: Task<Outcome, Never>?

    func run(
        _ operation: @escaping @MainActor @Sendable () async -> Outcome
    ) async -> Outcome {
        if let task { return await task.value }
        let task = Task { @MainActor in await operation() }
        self.task = task
        return await task.value
    }

    func reset() {
        task = nil
    }
}

private final class MeetingCaptureProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var meetingID: String?
    private var lastScheduledSamples: Int64 = 0

    func reset(meetingID: String) {
        lock.lock()
        self.meetingID = meetingID
        lastScheduledSamples = 0
        lock.unlock()
    }

    func shouldPublish(meetingID: String, samples: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.meetingID == meetingID,
              samples >= lastScheduledSamples + 4_000 else { return false }
        lastScheduledSamples = samples
        return true
    }

    func invalidate() {
        lock.lock()
        meetingID = nil
        lock.unlock()
    }
}

@MainActor
final class MeetingCaptureCoordinator: ObservableObject {
    @Published private(set) var status: MeetingStatus = .ready
    @Published private(set) var provisionalText = ""
    @Published private(set) var elapsedMediaMs: Int64 = 0
    @Published private(set) var failure: String?
    @Published private(set) var liveTranscriptEntries = [LiveTranscriptEntry]()
    @Published private(set) var finalizedTranscript = ""
    @Published private(set) var recordedAudioSamples: Int64 = 0
    @Published private(set) var recordedAudioPartCount = 0
    @Published private(set) var finalizationProgress = 0.0
    @Published private(set) var finalizationDetail = ""
    @Published private(set) var liveTranscriptionWarning: String?
    @Published private(set) var recoveredCapture: PendingMeetingCaptureRecovery?

    private enum TerminalIntent { case stop, failure, cancel }

    private let engine = AVAudioEngine()
    private var transcriptionSessionFactory: any MeetingTranscriptionSessionFactory
    private let terminationGate = MeetingCaptureTerminationGate<Void>()
    private let progressGate = MeetingCaptureProgressGate()
    private var transcriptionSession: (any MeetingTranscriptionSession)?
    private var flacPartWriter: MeetingFLACPartWriter?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var canonicalPipeline: MeetingCanonicalAudioPipeline?
    private var transcriptionInputPipeline: MeetingTranscriptionInputPipeline?
    private var transcriptionTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var activeMeetingID: String?
    private var activeLanguageTag = ""
    private var activeTimezoneIdentifier = ""
    private var activeFileURL: URL?
    private var inputFinished = false
    private var terminalIntent: TerminalIntent?
    private var terminalArtifact: MeetingCaptureArtifact?
    private var terminalError: Error?
    private var liveTranscriptionError: Error?
    private let logger = Logger(subsystem: "pieroot.todo", category: "MeetingCapture")
    private var liveTranscriptReducer = LiveTranscriptReducer()
    private var transcriptChunks: [TranscriptRangeKey: String] = [:]

    init(transcriptionSessionFactory: (any MeetingTranscriptionSessionFactory)? = nil) {
        self.transcriptionSessionFactory = transcriptionSessionFactory ?? DefaultMeetingTranscriptionSessionFactory()
    }

    func setVocabularySnapshotProvider(_ provider: @escaping @Sendable () async -> UserVocabularySnapshot) {
        transcriptionSessionFactory = DefaultMeetingTranscriptionSessionFactory(snapshotProvider: provider)
    }

    func start(meetingID: String, languageTag: String) async throws {
        guard status == .ready || status == .cancelled || status == .failed else { throw CaptureError.invalidState }
        guard await AVAudioApplication.requestRecordPermission() else { throw CaptureError.microphoneDenied }
        let transcriptionSession = try await transcriptionSessionFactory.make(
            languageTag: languageTag,
            purpose: .live
        )
        let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(256))
        // Voice Processing I/O must be configured before reading the tap format.
        let requestedVoiceProcessing = SettingsStore.shared.effectiveMeetingVoiceProcessingEnabled
        try await configureSession(voiceProcessing: requestedVoiceProcessing)
        let node = engine.inputNode

        var voiceProcessingFallbackNotice: String?
        var usingVoiceProcessing = false
        if requestedVoiceProcessing {
            do {
                try node.setVoiceProcessingEnabled(true)
                engine.prepare()
                usingVoiceProcessing = Self.isValidFormat(node.outputFormat(forBus: 0))
            } catch {
                usingVoiceProcessing = false
            }
            if !usingVoiceProcessing {
                // Revert to the raw, minimally processed path so capture still
                // works rather than crashing or recording nothing.
                try? node.setVoiceProcessingEnabled(false)
                try await configureSession(voiceProcessing: false)
                engine.prepare()
                voiceProcessingFallbackNotice = AppLanguage.localized(
                    "meeting.capture.voiceProcessingFallback",
                    defaultValue: AppLanguage.current == .english
                        ? "Voice noise reduction is unavailable; recording the raw input instead."
                        : "음성 노이즈 감소를 사용할 수 없어 원본 입력으로 녹음합니다.",
                    language: .current,
                    comment: "Warning shown when voice processing cannot be enabled for a meeting recording."
                )
            }
        } else {
            try? node.setVoiceProcessingEnabled(false)
        }

        let format = node.outputFormat(forBus: 0)
        guard Self.isValidFormat(format) else { throw CaptureError.invalidAudioFormat }
        guard let canonicalFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(MeetingMediaTimeline.sampleRate),
            channels: 1,
            interleaved: true
        ) else {
            throw CaptureError.invalidAudioFormat
        }
        let audioDirectory = AppDataContainer.activeMeetingAudioDirectory(meetingID: meetingID)
        let writer = try MeetingFLACPartWriter(directory: audioDirectory)
        let callbackBridge = MeetingCaptureCallbackBridge(self)
        let transcriptionPipeline = try MeetingTranscriptionInputPipeline(
            inputFormat: canonicalFormat,
            outputFormat: transcriptionSession.inputFormat,
            consume: { stream.continuation.yield($0) },
            failed: { error in
                Task { @MainActor in
                    await callbackBridge.coordinator?.handleLiveTranscriptionFailure(error)
                }
            }
        )
        let pipeline = try MeetingCanonicalAudioPipeline(
            inputFormat: format,
            consume: { [progressGate] canonicalBuffer in
                try writer.append(canonicalBuffer)
                let samples = writer.totalSamples
                let partCount = writer.completedParts.count + 1
                transcriptionPipeline.enqueue(canonicalBuffer)
                if progressGate.shouldPublish(meetingID: meetingID, samples: samples) {
                    Task { @MainActor in
                        callbackBridge.coordinator?.publishRecordedAudio(
                            meetingID: meetingID,
                            samples: samples,
                            partCount: partCount
                        )
                    }
                }
            },
            dropped: { error in
                Task { @MainActor in
                    await callbackBridge.coordinator?.handleCaptureFailure(error)
                }
            }
        )

        self.transcriptionSession = transcriptionSession
        flacPartWriter = writer
        inputContinuation = stream.continuation
        terminationGate.reset()
        terminalIntent = nil
        terminalError = nil
        terminalArtifact = nil
        liveTranscriptionError = nil
        liveTranscriptionWarning = nil
        activeFileURL = audioDirectory
        activeMeetingID = meetingID
        activeLanguageTag = languageTag
        activeTimezoneIdentifier = TimeZone.current.identifier
        progressGate.reset(meetingID: meetingID)
        self.canonicalPipeline = pipeline
        transcriptionInputPipeline = transcriptionPipeline
        inputFinished = false
        transcriptChunks.removeAll(keepingCapacity: true)
        liveTranscriptEntries = []
        finalizedTranscript = ""
        elapsedMediaMs = 0
        liveTranscriptReducer.reset()
        recordedAudioSamples = 0
        recordedAudioPartCount = 0
        liveTranscriptionWarning = voiceProcessingFallbackNotice
        status = .recording

        transcriptionTask = Task { [weak self, transcriptionSession] in
            do {
                for try await result in transcriptionSession.results {
                    try Task.checkCancellation()
                    await MainActor.run { self?.acceptTranscriptionResult(result) }
                }
            } catch {
                let shouldCleanup = await MainActor.run { self?.recordLiveTranscriptionFailure(error) ?? false }
                if shouldCleanup {
                    Task { @MainActor [weak self] in
                        await self?.stopLiveTranscription()
                    }
                }
            }
        }
        analysisTask = Task { [weak self, transcriptionSession] in
            do {
                try await transcriptionSession.analyze(stream.stream)
            } catch {
                let shouldCleanup = await MainActor.run { self?.recordLiveTranscriptionFailure(error) ?? false }
                if shouldCleanup {
                    Task { @MainActor [weak self] in
                        await self?.stopLiveTranscription()
                    }
                }
            }
        }

        node.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            pipeline.enqueueTapBuffer(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            node.removeTap(onBus: 0)
            engine.stop()
            await MeetingAudioSessionController.shared.deactivate()
            inputContinuation?.finish()
            await transcriptionPipeline.cancel()
            await transcriptionSession.cancel()
            transcriptionTask?.cancel()
            analysisTask?.cancel()
            await pipeline.cancel()
            canonicalPipeline = nil
            transcriptionInputPipeline = nil
            self.transcriptionSession = nil
            flacPartWriter = nil
            inputContinuation = nil
            if let activeFileURL { try? FileManager.default.removeItem(at: activeFileURL.deletingLastPathComponent()) }
            self.activeFileURL = nil
            activeMeetingID = nil
            progressGate.invalidate()
            status = .failed
            failure = userFacingFailure(for: error, operation: "start")
            logDiagnostic(error, operation: "start")
            throw error
        }
    }

    func pause() {
        guard status == .recording else { return }
        engine.pause()
        status = .paused
    }

    func resume() throws {
        guard status == .paused else { throw CaptureError.invalidState }
        try engine.start()
        status = .recording
    }

    /// Fast phase: close and journal the valid audio prefix before slow
    /// transcription finalization. The first terminal request wins.
    func stopCapture() async throws -> MeetingCaptureArtifact {
        guard status == .recording || status == .paused || terminalIntent != nil else {
            throw CaptureError.invalidState
        }
        if terminalIntent == nil {
            terminalIntent = .stop
            status = .stopping
            finalizationProgress = 0.1
            finalizationDetail = AppLanguage.localized(
                "meeting.capture.finalization.audio",
                defaultValue: AppLanguage.current == .english
                    ? "Finishing the original recording"
                    : "원본 녹음 파일을 마무리하는 중",
                language: .current,
                comment: "Progress detail shown while finalizing the original meeting recording."
            )
        }
        await terminationGate.run { [weak self] in await self?.performTerminalOperation() }
        if case .cancel? = terminalIntent { throw CancellationError() }
        if let terminalError { throw terminalError }
        guard let terminalArtifact else { throw CaptureError.invalidState }
        return terminalArtifact
    }

    func finalizeTranscript(timeout: Duration = .seconds(180)) async throws {
        guard status == .stopping else { throw CaptureError.invalidState }
        finalizationProgress = 0.6
        finalizationDetail = AppLanguage.localized(
            "meeting.capture.finalization.transcript",
            defaultValue: AppLanguage.current == .english
                ? "Finalizing the transcript"
                : "전사 결과를 확정하는 중",
            language: .current,
            comment: "Progress detail shown while finalizing a meeting transcript."
        )
        do {
            try await transcriptionInputPipeline?.finish()
        } catch {
            await handleLiveTranscriptionFailure(error)
        }
        finishInputStream()
        if let liveTranscriptionError {
            await stopLiveTranscription()
            clearTranscriptionReferences()
            throw liveTranscriptionError
        }
        let analysis = analysisTask
        let transcription = transcriptionTask
        let session = transcriptionSession
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await analysis?.value
                await transcription?.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                await session?.cancel()
                analysis?.cancel()
                transcription?.cancel()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        clearTranscriptionReferences()
        guard finished else {
            finalizationDetail = AppLanguage.localized(
                "meeting.capture.finalization.timeout",
                defaultValue: AppLanguage.current == .english
                    ? "Transcript finalization timed out. The original recording and provisional transcript were preserved."
                    : "전사 확정이 시간 내에 끝나지 않았습니다. 원본 녹음과 임시 전사를 보존했습니다.",
                language: .current,
                comment: "Detail shown when transcript finalization times out while preserving recoverable meeting data."
            )
            throw CaptureError.transcriptFinalizationTimeout
        }
        finalizedTranscript = provisionalText
        finalizationProgress = 0.9
        finalizationDetail = AppLanguage.localized(
            "meeting.capture.finalization.saving",
            defaultValue: AppLanguage.current == .english
                ? "Saving the meeting record"
                : "회의 기록을 저장하는 중",
            language: .current,
            comment: "Progress detail shown while saving the finalized meeting record."
        )
        status = .finalizingTranscript
    }


    func cancel() async {
        guard terminalIntent == nil else {
            await terminationGate.run { [weak self] in await self?.performTerminalOperation() }
            return
        }
        terminalIntent = .cancel
        await terminationGate.run { [weak self] in await self?.performTerminalOperation() }
        transcriptChunks.removeAll(keepingCapacity: false)
        liveTranscriptEntries = []
        provisionalText = ""
        finalizedTranscript = ""
        liveTranscriptReducer.reset()
        status = .cancelled
    }

    private func handleCaptureFailure(_ error: Error) async {
        guard terminalIntent == nil || {
            if case .stop? = terminalIntent { return true }
            return false
        }() else { return }
        if terminalError == nil { terminalError = error }
        if terminalIntent == nil { terminalIntent = .failure }
        logDiagnostic(error, operation: "capture")
        await terminationGate.run { [weak self] in await self?.performTerminalOperation() }
        failure = userFacingFailure(for: error, operation: "capture")
        status = .failed
    }

    private func performTerminalOperation() async {
        guard let terminalIntent else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        switch terminalIntent {
        case .cancel:
            await canonicalPipeline?.cancel()
            await stopLiveTranscription()
            _ = try? flacPartWriter?.finish()
            await MeetingAudioSessionController.shared.deactivate()
            let directory = activeFileURL?.deletingLastPathComponent()
            resetCaptureReferences()
            if let directory { try? FileManager.default.removeItem(at: directory) }
        case .stop, .failure:
            var canonicalError: Error?
            do {
                try await canonicalPipeline?.finish()
            } catch {
                canonicalError = error
            }
            canonicalPipeline = nil
            guard let writer = flacPartWriter,
                  let directory = activeFileURL,
                  let meetingID = activeMeetingID else {
                terminalError = terminalError ?? CaptureError.invalidState
                await MeetingAudioSessionController.shared.deactivate()
                return
            }
            do {
                _ = try writer.finish()
                let parent = directory.deletingLastPathComponent().lastPathComponent
                let manifest = writer.manifest(relativeDirectory: "\(parent)/\(directory.lastPathComponent)")
                publishRecordedAudio(meetingID: meetingID, samples: writer.totalSamples, partCount: manifest.parts.count)
                let recovery = PendingMeetingCaptureRecovery(
                    meetingID: meetingID,
                    languageTag: activeLanguageTag,
                    timezoneIdentifier: activeTimezoneIdentifier,
                    manifest: manifest,
                    provisionalResult: MeetingProvisionalResultBuilder.make(
                        meetingID: meetingID,
                        entries: liveTranscriptEntries,
                        elapsedMediaMs: elapsedMediaMs
                    ),
                    errorMessage: terminalError.map { userFacingFailure(for: $0, operation: "finalization") }
                )
                try MeetingCaptureRecoveryStore.write(recovery)
                recoveredCapture = recovery
                terminalArtifact = MeetingCaptureArtifact(directoryURL: directory, audioManifest: manifest)
                flacPartWriter = nil
                if let canonicalError { terminalError = terminalError ?? canonicalError }
                if case .failure = terminalIntent { await stopLiveTranscription() }
                await MeetingAudioSessionController.shared.deactivate()
                progressGate.invalidate()
                activeMeetingID = nil
            } catch {
                terminalError = error
                await MeetingAudioSessionController.shared.deactivate()
            }
        }
    }

    private func recordLiveTranscriptionFailure(_ error: Error) -> Bool {
        guard liveTranscriptionError == nil else { return false }
        liveTranscriptionError = error
        liveTranscriptionWarning = AppLanguage.localized(
            "meeting.capture.transcription.warning",
            defaultValue: AppLanguage.current == .english
                ? "Live transcription stopped. The recording is still being saved, and you can transcribe it again from the saved audio after stopping."
                : "실시간 전사가 중단됐습니다. 녹음은 계속 저장되며 종료 후 저장된 음성으로 다시 전사할 수 있습니다.",
            language: .current,
            comment: "Warning shown when live transcription stops but canonical audio capture continues."
        )
        return true
    }

    private func handleLiveTranscriptionFailure(_ error: Error) async {
        guard recordLiveTranscriptionFailure(error) else { return }
        await stopLiveTranscription()
    }

    private func stopLiveTranscription() async {
        await transcriptionInputPipeline?.cancel()
        finishInputStream()
        await transcriptionSession?.cancel()
        transcriptionTask?.cancel()
        analysisTask?.cancel()
        await transcriptionTask?.value
        await analysisTask?.value
    }

    private func finishInputStream() {
        guard !inputFinished else { return }
        inputFinished = true
        inputContinuation?.finish()
    }

    private func clearTranscriptionReferences() {
        transcriptionInputPipeline = nil
        inputContinuation = nil
        transcriptionSession = nil
        transcriptionTask = nil
        analysisTask = nil
    }

    private func resetCaptureReferences() {
        canonicalPipeline = nil
        flacPartWriter = nil
        clearTranscriptionReferences()
        activeFileURL = nil
        activeMeetingID = nil
        progressGate.invalidate()
    }

    private func acceptTranscriptionResult(_ result: MeetingTranscriptionResult) {
        let replacement = TranscriptRangeKey(result.range)
        let entry = LiveTranscriptEntry(
            id: "\(replacement.startValue):\(replacement.startTimescale):\(replacement.durationValue):\(replacement.durationTimescale)",
            startMs: Int64((replacement.startSeconds * 1_000).rounded(.down)),
            endMs: Int64((replacement.endSeconds * 1_000).rounded(.down)),
            text: String(result.text.characters),
            speakerIDs: [],
            confidence: result.confidence,
            isFinal: result.isFinal
        )
        liveTranscriptReducer.replace(entry)
        liveTranscriptEntries = liveTranscriptReducer.entries
        provisionalText = liveTranscriptEntries.map(\.text).joined(separator: " ")
    }

    private func publishRecordedAudio(meetingID: String, samples: Int64, partCount: Int) {
        guard activeMeetingID == meetingID,
              samples > recordedAudioSamples else { return }
        recordedAudioSamples = samples
        recordedAudioPartCount = partCount
        elapsedMediaMs = samples * 1_000 / MeetingMediaTimeline.sampleRate
    }

    func acknowledgeRecoveredCapture(meetingID: String) {
        guard recoveredCapture?.meetingID == meetingID else { return }
        recoveredCapture = nil
    }

    func completeFinalization() {
        finalizationProgress = 1
        finalizationDetail = ""
        status = .ready
    }

    func failFinalization(_ error: Error) {
        logDiagnostic(error, operation: "finalization")
        failure = userFacingFailure(for: error, operation: "finalization")
        finalizationProgress = 0
        finalizationDetail = AppLanguage.localized(
            "meeting.capture.finalization.cleanupFailed",
            defaultValue: AppLanguage.current == .english
                ? "Cleanup failed. The original recording and provisional transcript were preserved."
                : "정리에 실패했습니다. 원본 녹음과 임시 전사를 보존했습니다.",
            language: .current,
            comment: "Detail shown when post-capture cleanup fails while preserving recoverable meeting data."
        )
        status = .failed
    }

    func reportFailure(_ message: String) {
        failure = message
    }

    func reportFailure(_ error: Error) {
        logDiagnostic(error, operation: "reported")
        failure = userFacingFailure(for: error, operation: "reported")
    }

    func dismissFailure() {
        failure = nil
    }
    private func logDiagnostic(_ error: Error, operation: String) {
        let diagnostic = error as NSError
        logger.error(
            "Capture failure operation=\(operation, privacy: .public) domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code, privacy: .public) description=\(diagnostic.localizedDescription, privacy: .private)"
        )
    }

    private func userFacingFailure(for error: Error, operation _: String) -> String {
        if let captureError = error as? CaptureError {
            return captureError.errorDescription(language: .current)
        }
        return AppLanguage.localized(
            "error.meeting.capture.operation",
            defaultValue: AppLanguage.current == .english
                ? "The meeting recording could not be completed."
                : "회의 녹음을 완료하지 못했습니다.",
            language: .current,
            comment: "Generic meeting capture/finalization error; private diagnostics remain in logs."
        )
    }

    private func configureSession(voiceProcessing: Bool) async throws {
        try await MeetingAudioSessionController.shared.activateForRecording(voiceProcessing: voiceProcessing)
    }

    private static func isValidFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    enum CaptureError: LocalizedError {
        case microphoneDenied, unsupportedLanguage, invalidState, transcriptFinalizationTimeout, invalidAudioFormat

        var errorDescription: String? {
            errorDescription(language: .current)
        }

        func errorDescription(language: AppLanguage) -> String {
            switch self {
            case .microphoneDenied:
                return AppLanguage.localized(
                    "error.meeting.capture.microphoneDenied",
                    defaultValue: language == .english ? "Microphone access is required." : "마이크 권한이 필요합니다.",
                    language: language,
                    comment: "Meeting recording error shown when microphone permission is denied."
                )
            case .unsupportedLanguage:
                return AppLanguage.localized(
                    "error.meeting.capture.unsupportedLanguage",
                    defaultValue: language == .english
                        ? "On-device transcription is unavailable for the selected language."
                        : "선택한 언어의 기기 내 전사를 사용할 수 없습니다.",
                    language: language,
                    comment: "Meeting recording error shown when on-device transcription does not support the selected language."
                )
            case .invalidState:
                return AppLanguage.localized(
                    "error.meeting.capture.invalidState",
                    defaultValue: language == .english
                        ? "This action is not available in the current recording state."
                        : "현재 녹음 상태에서는 이 작업을 수행할 수 없습니다.",
                    language: language,
                    comment: "Meeting recording error shown when an operation is requested in an invalid state."
                )
            case .transcriptFinalizationTimeout:
                return AppLanguage.localized(
                    "error.meeting.capture.transcriptFinalizationTimeout",
                    defaultValue: language == .english
                        ? "Transcript finalization timed out."
                        : "전사 확정이 시간 내에 끝나지 않았습니다.",
                    language: language,
                    comment: "Meeting recording error shown when transcript finalization exceeds its timeout."
                )
            case .invalidAudioFormat:
                return AppLanguage.localized(
                    "error.meeting.capture.invalidAudioFormat",
                    defaultValue: language == .english
                        ? "The microphone audio format could not be prepared. Please try again."
                        : "마이크 오디오 포맷을 준비할 수 없습니다. 다시 시도해주세요.",
                    language: language,
                    comment: "Meeting recording error shown when the microphone audio format cannot be prepared."
                )
            }
        }
    }
}
