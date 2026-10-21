import AVFoundation
import AudioToolbox
import Combine
import CoreMedia
import Foundation
import os
import Speech


struct LiveTranscriptEntry: Identifiable, Equatable {
    let id: String
    let startMs: Int64
    let endMs: Int64
    let text: String
    /// Average per-word transcription confidence (0...1) from accuracy-first
    /// batch re-transcription; nil for the live path, which does not request it.
    let confidence: Double?
    let timedRuns: [MeetingTimedTextRun]?
    /// Final segments cannot be replaced by a later volatile overlap.
    let isFinal: Bool

    init(
        id: String,
        startMs: Int64,
        endMs: Int64,
        text: String,
        confidence: Double? = nil,
        timedRuns: [MeetingTimedTextRun]? = nil,
        isFinal: Bool = false
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.confidence = confidence
        self.timedRuns = timedRuns
        self.isFinal = isFinal
    }
}

/// Display-only live caption turn: raw transcript text plus tentative speakers.
struct MeetingLiveTranscriptRow: Identifiable, Equatable {
    let id: String
    let startMs: Int64
    let endMs: Int64
    let text: String
    let speakerIDs: [String]
}

/// Derives display-only labels from the covered prefix without rewriting raw
/// transcript entries. Cache keys include speaker evidence, not text finality:
/// fixed text can still acquire labels as the live timeline advances.
struct MeetingLiveTranscriptRowBuilder {
    private var cache: [String: (entry: LiveTranscriptEntry, coverage: Int64, intervals: [MeetingSpeakerInterval], rows: [MeetingLiveTranscriptRow])] = [:]

    mutating func rows(
        for entries: [LiveTranscriptEntry],
        timeline: MeetingLiveSpeakerTimeline?
    ) -> [MeetingLiveTranscriptRow] {
        guard let timeline else {
            // Without live speaker evidence every row is simply the raw entry.
            cache = [:]
            return entries.map {
                MeetingLiveTranscriptRow(id: $0.id, startMs: $0.startMs, endMs: $0.endMs, text: $0.text, speakerIDs: [])
            }
        }
        let coverage = timeline.coveredThroughSample
        let intervals = timeline.activeIntervals
        var next: [String: (entry: LiveTranscriptEntry, coverage: Int64, intervals: [MeetingSpeakerInterval], rows: [MeetingLiveTranscriptRow])] = [:]
        var rows: [MeetingLiveTranscriptRow] = []
        for entry in entries {
            let start = entry.startMs * MeetingSpeakerAlignment.samplesPerMillisecond
            let end = entry.endMs * MeetingSpeakerAlignment.samplesPerMillisecond
            // An open interval growing beyond this entry cannot change its label.
            let relevant = intervals.compactMap { interval -> MeetingSpeakerInterval? in
                let lower = max(start, interval.startSample)
                let upper = min(end, interval.endSample)
                guard upper > lower else { return nil }
                return MeetingSpeakerInterval(speakerID: interval.speakerID, startSample: lower, endSample: upper)
            }
            let entryCoverage = min(coverage, end)
            if let cached = cache[entry.id], cached.entry == entry,
               cached.coverage == entryCoverage, cached.intervals == relevant {
                next[entry.id] = cached
                rows.append(contentsOf: cached.rows)
                continue
            }
            let entryRows = Self.rows(for: entry, intervals: relevant, coverage: entryCoverage)
            next[entry.id] = (entry, entryCoverage, relevant, entryRows)
            rows.append(contentsOf: entryRows)
        }
        cache = next
        return rows
    }

    private static func rows(
        for entry: LiveTranscriptEntry,
        intervals: [MeetingSpeakerInterval],
        coverage: Int64
    ) -> [MeetingLiveTranscriptRow] {
        guard let runs = entry.timedRuns, !runs.isEmpty else {
            let ids = MeetingSpeakerAlignment.assignLiveSegment(
                startMs: entry.startMs, endMs: entry.endMs, intervals: intervals, coveredThroughSample: coverage
            )
            return [MeetingLiveTranscriptRow(id: entry.id, startMs: entry.startMs, endMs: entry.endMs, text: entry.text, speakerIDs: ids)]
        }
        // Strict word alignment waits for the entire word, never a tiny fragment.
        let labels = MeetingSpeakerAlignment.assign(runs: runs, intervals: intervals, coveredThroughSample: coverage)
        let units = Array(entry.text.utf16)
        let turns = MeetingSpeakerAlignment.turns(
            textLength: units.count, startMs: entry.startMs, endMs: entry.endMs, runs: runs, labels: labels
        )
        return turns.enumerated().compactMap { index, turn in
            let lower = min(max(0, turn.utf16Start), units.count)
            let upper = min(max(lower, turn.utf16End), units.count)
            let text = String(decoding: units[lower..<upper], as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || turns.count == 1 else { return nil }
            return MeetingLiveTranscriptRow(
                id: index == 0 ? entry.id : "\(entry.id)#\(index)",
                startMs: turn.startMs, endMs: turn.endMs, text: text, speakerIDs: turn.speakerIDs
            )
        }
    }
}

struct MeetingCaptureArtifact: Sendable {
    let meetingID: String
    let tracks: [MeetingCaptureTrackArtifact]
}

struct MeetingAppAudioSourceSnapshot: Identifiable, Equatable {
    let id: String
    let meetingID: String?
    let sourceKind: MeetingAudioTrackKind
    let sourceLabel: String?
    let state: MeetingAppAudioCapture.State
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

/// Consent obtained before a revoke/interruption cannot authorize a later start.
nonisolated final class MeetingMicrophoneConsentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var permitted = false
    private var interrupted = false
    var isInterrupted: Bool { lock.withLock { interrupted } }
    func clearInterruption() { lock.withLock { interrupted = false } }
    var isPermitted: Bool { lock.withLock { permitted } }
    func beginApproval() -> Int {
        lock.withLock { generation += 1; permitted = false; return generation }
    }
    @discardableResult
    func approve(_ ticket: Int, enabled: Bool) -> Bool {
        lock.withLock {
            guard generation == ticket, !interrupted else { return false }
            permitted = enabled
            return permitted
        }
    }
    @discardableResult
    func revoke(_ close: () -> Void) -> Int {
        lock.withLock { generation += 1; permitted = false; close(); return generation }
    }
    @discardableResult
    func interrupt(_ close: () -> Void) -> Int {
        lock.withLock { interrupted = true; generation += 1; permitted = false; close(); return generation }
    }
    func isCurrent(_ ticket: Int) -> Bool { lock.withLock { generation == ticket } }
    @discardableResult
    func deliver(_ body: () -> Void) -> Bool {
        lock.withLock {
            guard permitted else { return false }
            body()
            return true
        }
    }
}


/// The audio queue never crosses MainActor to find a child writer.
private nonisolated final class MeetingTrackRoutingSink: @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [MeetingAudioSourceRouter.Source: MeetingCaptureTrackInput] = [:]

    func attach(_ input: MeetingCaptureTrackInput?, source: MeetingAudioSourceRouter.Source) {
        lock.withLock { inputs[source] = input }
    }

    func append(_ buffer: AVAudioPCMBuffer, source: MeetingAudioSourceRouter.Source) throws {
        try lock.withLock { try inputs[source]?.append(buffer) }
    }
    func recordFailure(_ error: Error, source: MeetingAudioSourceRouter.Source) {
        lock.withLock { inputs[source]?.recordFailure(error) }
    }


    func removeAll() { lock.withLock { inputs.removeAll() } }
}

private nonisolated final class MeetingMicrophoneRouteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func invalidate() { lock.withLock { active = false } }

    func close(_ router: MeetingAudioSourceRouter) -> Bool {
        lock.withLock {
            guard active else { return false }
            active = false
            router.setEnabled(false, source: .microphone,
                              hostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
            return true
        }
    }
}

/// Preflight app audio is never retained or saved before the recording commits.
nonisolated final class MeetingAppAudioInputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var router: MeetingAudioSourceRouter?
    private var applicationSource: MeetingAudioSourceRouter.Source = .appAudio
    let microphoneConsent = MeetingMicrophoneConsentGate()
    func attach(_ router: MeetingAudioSourceRouter?, source: MeetingAudioSourceRouter.Source = .appAudio) {
        lock.withLock { self.router = router; applicationSource = source }
    }
    func enqueue(_ buffer: AVAudioPCMBuffer, hostTime: Double, source: MeetingAudioSourceRouter.Source) {
        if source == .microphone {
            microphoneConsent.deliver {
                lock.withLock { router }?.enqueueOwned(buffer, source: source, hostTime: hostTime)
            }
        } else {
            lock.withLock { router?.enqueueOwned(buffer, source: applicationSource, hostTime: hostTime) }
        }
    }
    func setEnabled(_ enabled: Bool, hostTime: Double) {
        lock.withLock { router?.setEnabled(enabled, source: applicationSource, hostTime: hostTime) }
    }
    @discardableResult
    func revokeMicrophone() -> Int {
        microphoneConsent.revoke {
            lock.withLock { router }?.setEnabled(false, source: .microphone,
                hostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        }
    }
    func stopMicrophoneDelivery() { microphoneConsent.revoke {} }
    @discardableResult
    func interruptMicrophone() -> Int {
        microphoneConsent.interrupt {
            lock.withLock { router }?.setEnabled(false, source: .microphone,
                hostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        }
    }
}

@MainActor
final class MeetingCaptureCoordinator: ObservableObject {
    private static let syncParticipants = NSHashTable<MeetingCaptureCoordinator>.weakObjects()
    static var hasActiveCaptureForCloudSync: Bool {
        syncParticipants.allObjects.contains { coordinator in
            if coordinator.starting { return true }
            switch coordinator.status {
            case .recording, .paused, .stopping, .finalizingTranscript, .extractingActions: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: MeetingStatus = .ready
    @Published private(set) var elapsedMediaMs: Int64 = 0
    @Published private(set) var failure: String?
    @Published private(set) var recordedAudioSamples: Int64 = 0
    @Published private(set) var recordedAudioPartCount = 0
    @Published private(set) var finalizationDetail = ""
    @Published private(set) var liveTracks: [MeetingLiveCaptureTrack] = []
    @Published private(set) var appAudioSources: [MeetingAppAudioSourceSnapshot] = []
    enum LiveSpeakerPhase: Equatable {
        case inactive, preparing, waitingForInference, analyzing, stopped
    }
    /// Snapshot at capture start; a settings change applies only to the next recording.
    private(set) var recordingDiarizationEnabled = false
    @Published private(set) var recoveredCaptures: [PendingMeetingCaptureRecovery] = []

    @Published private(set) var microphoneEnabled = true
    @Published private(set) var appAudioState: MeetingAppAudioCapture.State = .disabled
    @Published private(set) var microphoneRoutes = [MeetingMicrophoneRoute]()
    @Published private(set) var selectedMicrophoneRouteID: String?
    @Published private(set) var microphoneWarning: String?
    @Published private(set) var microphoneAudioBufferCount: Int64 = 0
    @Published private(set) var appAudioBufferCount: Int64 = 0
    @Published private(set) var microphoneRMS = 0.0
    @Published private(set) var appAudioRMS = 0.0
    var appAudioAvailability: MeetingAppAudioCapture.Availability { MeetingAppAudioCapture.availability }
    private var selectedAppAudioSourceDescription: String? { appAudioCapture?.selectedSourceDescription }
    private var appAudioCapture: MeetingAppAudioCapture?
    private var appAudioInputSink: MeetingAppAudioInputSink?
    private var pickerMicrophoneApproval: Int?
    @Published private(set) var usesSystemPickerMicrophone = false
    private var requestedPickerMicrophone = false
    private var microphoneTapInstalled = false
    private var microphoneChangeGeneration = 0
    private var changingMicrophone = false
    private var starting = false
    private var captureGeneration = UUID()
    private var voiceProcessingRequested = false
    private var preferredMicrophoneRouteID: String?
    private var ownsRecordingAudioSession = false
    private var microphoneRouteObserver: NSObjectProtocol?
    private var microphoneInterruptionObserver: NSObjectProtocol?
    private var microphoneRouteGate: MeetingMicrophoneRouteGate?
    private var captureDiagnosticID = "not-started"
    private var lastSourceDiagnosticSamples: Int64 = 0
    #if targetEnvironment(macCatalyst)
    private var catalystMicrophone: MeetingCatalystMicrophoneCapture?
    private var activeCatalystMicrophoneID: String?
    #endif

    private static var supportsAppAudioAPI: Bool {
        if #available(iOS 27.0, macCatalyst 18.2, *) { return true }
        return false
    }

    private static var hostTime: Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    private static var appAudioPreparationError: MeetingAppAudioCapture.CaptureError {
        .unavailable(AppLanguage.localized(
            "meeting.capture.appAudioPreparationStopped",
            defaultValue: AppLanguage.current == .english
                ? "App audio stopped during recording preparation. Select the source again."
                : "녹음 준비 중 앱 오디오가 중지되었습니다. 오디오 소스를 다시 선택하세요.",
            language: .current,
            comment: "App audio was revoked or failed while preparing the recording."
        ))
    }

    private enum TerminalIntent { case stop, cancel }
    private struct AppSource {
        let capture: MeetingAppAudioCapture
        let sink: MeetingAppAudioInputSink
        let source: MeetingAudioSourceRouter.Source
        var trackID: String?
    }
    private var appSources: [String: AppSource] = [:]
    private var addingAppSource = false
    private var primaryAppSourceID: String?

    private let engine = AVAudioEngine()
    private var transcriptionSessionFactory: any MeetingTranscriptionSessionFactory
    private let trackSink = MeetingTrackRoutingSink()
    private let terminationGate = MeetingCaptureTerminationGate<Void>()
    private var canonicalPipeline: MeetingAudioSourceRouter?
    private var tracks: [String: MeetingCaptureTrackSession] = [:]
    private var trackOrder: [String] = []
    private var activeSourceTracks: [MeetingAudioSourceRouter.Source: String] = [:]
    private var sourceRetirements: [MeetingAudioSourceRouter.Source: Task<Void, Never>] = [:]
    private var trackFinalizations: [String: Task<Void, Never>] = [:]
    private var thermalObserver: NSObjectProtocol?
    private var activeMeetingID: String?
    private var activeLanguageTag = ""
    private var activeSummaryLanguageTag: String?
    private(set) var recordingDefersTranscription = false
    private(set) var recordingAutomaticLanguageDetection = false
    private var activeTimezoneIdentifier = ""
    private var terminalIntent: TerminalIntent?
    private var terminalArtifact: MeetingCaptureArtifact?
    private var terminalError: Error?
    private(set) var reportableError: Error?
    private let logger = Logger(subsystem: "pieroot.todo", category: "MeetingCapture")

    init(transcriptionSessionFactory: (any MeetingTranscriptionSessionFactory)? = nil) {
        self.transcriptionSessionFactory = transcriptionSessionFactory ?? DefaultMeetingTranscriptionSessionFactory()
        Self.syncParticipants.add(self)
    }

    func setVocabularySnapshotProvider(_ provider: @escaping @Sendable () async -> UserVocabularySnapshot) {
        transcriptionSessionFactory = DefaultMeetingTranscriptionSessionFactory(snapshotProvider: provider)
    }

    func start(
        meetingID: String, languageTag: String, microphoneEnabled: Bool = true,
        appAudioEnabled: Bool = false, consentConfirmed: Bool = false, summaryLanguageTag: String? = nil,
        deferTranscription: Bool = false, automaticLanguageDetection: Bool = false
    ) async throws {
        guard !starting, status == .ready || status == .cancelled || status == .failed else { throw CaptureError.invalidState }
        guard microphoneEnabled || appAudioEnabled else { throw CaptureError.noAudioSource }
        starting = true
        defer { starting = false }
        // A failed picker must never clean up a previous recording's saved path.
        resetCaptureReferences()
        terminationGate.reset()
        terminalIntent = nil
        terminalError = nil
        terminalArtifact = nil
        captureGeneration = UUID()
        let generation = captureGeneration
        captureDiagnosticID = generation.uuidString
        microphoneAudioBufferCount = 0
        appAudioBufferCount = 0
        microphoneRMS = 0
        appAudioRMS = 0
        lastSourceDiagnosticSamples = 0
        logger.info("Audio capture session=\(self.captureDiagnosticID, privacy: .public) requested microphone=\(microphoneEnabled) appAudio=\(appAudioEnabled)")
        self.microphoneEnabled = microphoneEnabled
        microphoneWarning = nil
        reportableError = nil
        recordingDiarizationEnabled = false
        let appSink = MeetingAppAudioInputSink()
        let capture = makeAppAudioCapture(sink: appSink, generation: generation)
        appAudioCapture = capture
        appAudioInputSink = appSink
        #if !targetEnvironment(macCatalyst)
        usesSystemPickerMicrophone = appAudioEnabled
        requestedPickerMicrophone = microphoneEnabled
        capture.microphoneRequested = microphoneEnabled
        monitorMicrophoneInterruptions(sink: appSink, generation: generation)
        #endif
        do {
            if automaticLanguageDetection {
                // Validate pinned local bytes before accepting any audio. This
                // lease never downloads, and hashing runs on the model actor.
                try await MeetingWhisperModelStore.shared.withVerifiedModel { _, _ in () }
            }
            // No writer, analyzer, microphone permission, or retained audio exists
            // until the system picker has consented and the app stream has started.
            if appAudioEnabled { try await capture.selectSourceAndWait(consentConfirmed: consentConfirmed) }
            try Task.checkCancellation()
            guard captureGeneration == generation else { throw CancellationError() }
            if microphoneEnabled && !usesSystemPickerMicrophone {
                let ticket = appSink.microphoneConsent.beginApproval()
                guard await Self.requestMicrophonePermission() else { throw CaptureError.microphoneDenied }
                appSink.microphoneConsent.approve(ticket, enabled: true)
            }
            try Task.checkCancellation()
            guard captureGeneration == generation else { throw CancellationError() }
            try await startPrepared(meetingID: meetingID, languageTag: languageTag, summaryLanguageTag: summaryLanguageTag,
                                    deferTranscription: deferTranscription,
                                    automaticLanguageDetection: automaticLanguageDetection,
                                    microphoneEnabled: usesSystemPickerMicrophone ? appSink.microphoneConsent.isPermitted : microphoneEnabled,
                                    appAudioEnabled: appAudioEnabled,
                                    generation: generation, appSink: appSink)
        } catch {
            if terminalIntent != nil {
                // Stop/cancel already owns cleanup. Startup unwinding must not
                // discard a prefix being journaled by the winning stop request.
                await terminationGate.run { [weak self] in await self?.performTerminalOperation() }
                throw CancellationError()
            }
            appSink.attach(nil)
            stopMicrophoneHardware()
            await capture.stop()
            await canonicalPipeline?.cancel()
            await MeetingLiveSpeakerPrewarmer.shared.releaseUnused()
            for track in tracks.values { await discardTrack(track) }
            await deactivateRecordingSession()
            resetCaptureReferences()
            self.microphoneEnabled = false
            status = error is CancellationError ? .cancelled : .failed
            if !(error is CancellationError) {
                failure = userFacingFailure(for: error, operation: "start")
                logDiagnostic(error, operation: "start")
            }
            throw error
        }
    }

    private func startPrepared(
        meetingID: String, languageTag: String, summaryLanguageTag: String?, deferTranscription: Bool,
        automaticLanguageDetection: Bool, microphoneEnabled: Bool,
        appAudioEnabled: Bool, generation: UUID, appSink: MeetingAppAudioInputSink
    ) async throws {
        voiceProcessingRequested = SettingsStore.shared.effectiveMeetingVoiceProcessingEnabled
        recordingDiarizationEnabled = SettingsStore.shared.effectiveMeetingDiarizationEnabled
        activeMeetingID = meetingID
        activeLanguageTag = languageTag
        activeSummaryLanguageTag = summaryLanguageTag
        recordingDefersTranscription = deferTranscription
        recordingAutomaticLanguageDetection = automaticLanguageDetection
        activeTimezoneIdentifier = TimeZone.current.identifier
        let microphoneSetup = microphoneEnabled && !usesSystemPickerMicrophone && appSink.microphoneConsent.isPermitted
            ? try await prepareMicrophone() : nil
        try Task.checkCancellation()
        guard captureGeneration == generation else { throw CancellationError() }
        if appAudioEnabled, appAudioState != .waitingForAudio && appAudioState != .receivingAudio {
            throw Self.appAudioPreparationError
        }
        let callbackBridge = MeetingCaptureCallbackBridge(self)
        let pipeline = try MeetingAudioSourceRouter(
            consume: { [trackSink] source, buffer in try trackSink.append(buffer, source: source) },
            failed: { [trackSink] source, error in
                trackSink.recordFailure(error, source: source)
                Task { @MainActor in
                    guard let coordinator = callbackBridge.coordinator,
                          coordinator.captureGeneration == generation else { return }
                    await coordinator.handleSourceFailure(error, source: source)
                }
            }
        )
        canonicalPipeline = pipeline
        if microphoneEnabled {
            _ = try await createTrack(source: .microphone, kind: .microphone,
                                      label: nil, startSample: 0)
        }
        if appAudioEnabled, let capture = appAudioCapture {
            let track = try await createTrack(source: .appAudio, kind: capture.sourceKind,
                                              label: capture.selectedSourceDescription, startSample: 0)
            primaryAppSourceID = capture.sourceID
            appSources[capture.sourceID] = AppSource(capture: capture, sink: appSink, source: .appAudio, trackID: track.meetingID)
        }
        if tracks.values.allSatisfy({ $0.timeline == nil }) {
            await MeetingLiveSpeakerPrewarmer.shared.releaseUnused()
        }
        try Task.checkCancellation()
        guard captureGeneration == generation else { throw CancellationError() }
        if appAudioEnabled, appAudioState != .waitingForAudio && appAudioState != .receivingAudio {
            throw Self.appAudioPreparationError
        }
        elapsedMediaMs = 0
        recordedAudioSamples = 0
        recordedAudioPartCount = 0
        microphoneWarning = microphoneSetup?.notice
        status = .recording
        let startTime = Self.hostTime
        let approved = appSink.microphoneConsent.isPermitted
        self.microphoneEnabled = approved
        pipeline.start(hostTime: startTime, microphoneEnabled: approved)
        pipeline.setSelection(preferredMicrophoneRouteID, source: .microphone, hostTime: startTime)
        if appAudioEnabled {
            pipeline.setSelection(selectedAppAudioSourceDescription, source: .appAudio, hostTime: startTime)
            pipeline.setEnabled(true, source: .appAudio, hostTime: startTime)
        }
        for (source, id) in activeSourceTracks {
            if let offset = pipeline.sessionStartSample(for: source) { tracks[id]?.setStartSample(offset) }
            if let track = tracks[id] { try journalActive(track) }
        }
        appSink.attach(pipeline)
        if approved, let microphoneSetup {
            let microphoneRequest = microphoneChangeGeneration
            do {
                try await startMicrophoneHardware(format: microphoneSetup.format, mixer: pipeline)
            } catch {
                // A source-level Off/interruption supersedes only this microphone
                // start, not an independently approved application recording.
                guard error is CancellationError, !Task.isCancelled,
                      captureGeneration == generation, terminalIntent == nil,
                      microphoneChangeGeneration != microphoneRequest || !appSink.microphoneConsent.isPermitted else {
                    throw error
                }
            }
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for track in self.tracks.values { await track.handleThermalPressure() }
            }
        }
        publishTracks()
        publishAppSources()
        await refreshMicrophoneRoutes()
    }

    @discardableResult
    private func createTrack(
        source: MeetingAudioSourceRouter.Source, kind: MeetingAudioTrackKind,
        label: String?, startSample: Int64
    ) async throws -> MeetingCaptureTrackSession {
        guard let groupID = activeMeetingID else { throw CaptureError.invalidState }
        let generation = captureGeneration
        let track = try MeetingCaptureTrackSession(sourceKind: kind, sourceLabel: label,
            sessionStartSample: startSample, changed: { [weak self] in self?.publishTracks() })
        tracks[track.meetingID] = track
        trackOrder.append(track.meetingID)
        await track.prepare(factory: transcriptionSessionFactory, languageTag: activeLanguageTag,
                            diarizationEnabled: recordingDiarizationEnabled, groupID: groupID,
                            deferTranscription: recordingDefersTranscription,
                            automaticLanguageDetection: recordingAutomaticLanguageDetection)
        guard generation == captureGeneration, terminalIntent == nil, !Task.isCancelled else {
            await discardTrack(track)
            throw CancellationError()
        }
        activeSourceTracks[source] = track.meetingID
        trackSink.attach(track.input, source: source)
        publishTracks()
        return track
    }

    private func journalActive(_ track: MeetingCaptureTrackSession) throws {
        guard let parentMeetingID = activeMeetingID else { throw CaptureError.invalidState }
        try MeetingCaptureRecoveryStore.markActive(
            meetingID: track.meetingID, parentMeetingID: parentMeetingID, sourceKind: track.sourceKind,
            sourceLabel: track.sourceLabel, sessionStartSample: track.sessionStartSample,
            languageTag: activeLanguageTag, timezoneIdentifier: activeTimezoneIdentifier,
            directoryURL: track.directoryURL, summaryLanguageTag: activeSummaryLanguageTag,
            deferredTranscription: recordingDefersTranscription || recordingAutomaticLanguageDetection,
            automaticLanguageDetection: recordingAutomaticLanguageDetection)
    }

    private func publishTracks() {
        liveTracks = trackOrder.compactMap { tracks[$0]?.snapshot }
        recordedAudioSamples = liveTracks.reduce(Int64(0)) { $0 + $1.recordedAudioSamples }
        recordedAudioPartCount = liveTracks.reduce(0) { $0 + $1.recordedAudioPartCount }
        let end = liveTracks.map { $0.sessionStartSample + $0.recordedAudioSamples }.max() ?? 0
        elapsedMediaMs = end * 1_000 / MeetingMediaTimeline.sampleRate
        publishSourceDeliveryDiagnostics()
    }

    private func publishAppSources() {
        appAudioSources = appSources.map { id, source in
            MeetingAppAudioSourceSnapshot(id: id, meetingID: source.trackID,
                sourceKind: source.capture.sourceKind, sourceLabel: source.capture.selectedSourceDescription,
                state: source.capture.state)
        }.sorted { $0.id < $1.id }
    }

    func transcriptionResult(for meetingID: String) throws -> MeetingResult {
        guard let track = tracks[meetingID] else { throw CaptureError.invalidState }
        return try track.provisionalResult.validated()
    }

    func transcriptionFailure(for meetingID: String) -> Error? { tracks[meetingID]?.transcriptionError }

    func liveTimeline(for meetingID: String) -> MeetingLiveSpeakerTimeline? { tracks[meetingID]?.timeline }

    private func makeAppAudioCapture(
        sink: MeetingAppAudioInputSink, generation: UUID,
        sourceID: String = UUID().uuidString.lowercased(), source: MeetingAudioSourceRouter.Source = .appAudio
    ) -> MeetingAppAudioCapture {
        MeetingAppAudioCapture(sourceID: sourceID,
            receive: { buffer, hostTime, received in sink.enqueue(buffer, hostTime: hostTime, source: received) },
            stateChanged: { [weak self] state in
                guard let self, self.captureGeneration == generation else { return }
                let isPrimary = self.primaryAppSourceID == nil || self.primaryAppSourceID == sourceID
                if isPrimary { self.appAudioState = state }
                if isPrimary, self.usesSystemPickerMicrophone {
                    switch state {
                    case .selecting:
                        sink.revokeMicrophone()
                        self.microphoneEnabled = false
                        self.pickerMicrophoneApproval = sink.microphoneConsent.beginApproval()
                    case .waitingForAudio:
                        let approved = self.pickerMicrophoneApproval.map {
                            sink.microphoneConsent.approve($0, enabled: self.requestedPickerMicrophone && self.appAudioCapture?.microphoneApproved == true)
                        } ?? false
                        self.microphoneEnabled = approved
                        self.canonicalPipeline?.setEnabled(approved, source: .microphone, hostTime: Self.hostTime)
                        if !approved, self.requestedPickerMicrophone {
                            self.microphoneWarning = MeetingAppAudioCapture.message(
                                "meeting.capture.source.microphoneOff",
                                "Microphone is off in the system picker. Enable it there to record microphone audio.",
                                "시스템 선택기에서 마이크가 꺼져 있습니다. 마이크 오디오를 녹음하려면 선택기에서 켜주세요.")
                        }
                    case .disabled, .unavailable:
                        if self.appAudioCapture?.microphoneApproved != true {
                            sink.revokeMicrophone()
                            self.microphoneEnabled = false
                            Task { @MainActor [weak self] in await self?.retireSource(.microphone, revoke: true) }
                        }
                    case .receivingAudio: break
                    }
                }
                switch state {
                case .disabled, .selecting, .unavailable:
                    sink.setEnabled(false, hostTime: Self.hostTime)
                case .waitingForAudio, .receivingAudio: break
                }
                self.publishAppSources()
                if case .unavailable = state, self.activeSourceTracks[source] != nil, self.terminalIntent == nil {
                    Task { @MainActor [weak self] in await self?.retireSource(source, revoke: true) }
                }
            },
            microphoneFailed: { [weak self] reason in
                guard let self, self.captureGeneration == generation else { return }
                sink.revokeMicrophone()
                self.microphoneEnabled = false
                self.microphoneRMS = 0
                self.microphoneWarning = reason
                Task { @MainActor [weak self] in await self?.retireSource(.microphone, revoke: true) }
            }
        )
    }

    /// A source mute never changes a different source's admission or child identity.
    func setAppAudioEnabled(_ enabled: Bool, consentConfirmed: Bool = false) async throws {
        guard status == .recording || status == .paused, terminalIntent == nil else { throw CaptureError.invalidState }
        if enabled {
            guard consentConfirmed else { throw MeetingAppAudioCapture.CaptureError.consentRequired }
            #if !targetEnvironment(macCatalyst)
            if let id = primaryAppSourceID, let existing = appSources[id],
               existing.capture.state == .disabled, existing.capture.microphoneApproved,
               let router = canonicalPipeline {
                do {
                    if activeSourceTracks[existing.source] == nil {
                        let track = try await createTrack(source: existing.source, kind: existing.capture.sourceKind,
                            label: MeetingAppAudioCapture.systemSelectedContent, startSample: 0)
                        router.setEnabled(true, source: existing.source, hostTime: Self.hostTime)
                        track.setStartSample(router.sessionStartSample(for: existing.source) ?? 0)
                        try journalActive(track)
                        appSources[id]?.trackID = track.meetingID
                    }
                    router.setEnabled(true, source: existing.source, hostTime: Self.hostTime)
                    existing.sink.attach(router, source: existing.source)
                    try existing.capture.resumeAppAudio()
                    publishTracks()
                    publishAppSources()
                    return
                } catch {
                    await retireSource(existing.source, revoke: true)
                    throw error
                }
            }
            #endif
            if appSources.values.contains(where: { $0.capture.state == .waitingForAudio || $0.capture.state == .receivingAudio }) { return }
            try await addAppAudioSource(consentConfirmed: consentConfirmed)
        } else {
            let revokeTime = Self.hostTime
            for source in appSources.values {
                source.sink.setEnabled(false, hostTime: revokeTime)
                canonicalPipeline?.setEnabled(false, source: source.source, hostTime: revokeTime)
            }
            for id in Array(appSources.keys) { await stopAppAudioSource(id: id, revoke: true) }
        }
    }

    func addAppAudioSource(consentConfirmed: Bool) async throws {
        guard status == .recording || status == .paused, terminalIntent == nil,
              !addingAppSource, let router = canonicalPipeline else { throw CaptureError.invalidState }
        guard consentConfirmed else { throw MeetingAppAudioCapture.CaptureError.consentRequired }
        let running = appSources.values.filter { $0.capture.state == .waitingForAudio || $0.capture.state == .receivingAudio }
        guard running.count < 4, MeetingAppAudioCapture.supportsMultipleSources || running.isEmpty else {
            throw CaptureError.invalidState
        }
        addingAppSource = true
        defer { addingAppSource = false }
        let generation = captureGeneration
        let id = UUID().uuidString.lowercased()
        let source = MeetingAudioSourceRouter.Source.application(id)
        let sink = MeetingAppAudioInputSink()
        let capture = makeAppAudioCapture(sink: sink, generation: generation, sourceID: id, source: source)
        capture.microphoneRequested = false
        appSources[id] = AppSource(capture: capture, sink: sink, source: source, trackID: nil)
        publishAppSources()
        do {
            try await capture.selectSourceAndWait(consentConfirmed: consentConfirmed)
            guard generation == captureGeneration, terminalIntent == nil else { throw CancellationError() }
            let track = try await createTrack(source: source, kind: capture.sourceKind,
                                              label: capture.selectedSourceDescription, startSample: 0)
            guard capture.state == .waitingForAudio || capture.state == .receivingAudio else { throw Self.appAudioPreparationError }
            router.setSelection(capture.selectedSourceDescription, source: source, hostTime: Self.hostTime)
            router.setEnabled(true, source: source, hostTime: Self.hostTime)
            track.setStartSample(router.sessionStartSample(for: source) ?? 0)
            try journalActive(track)
            appSources[id]?.trackID = track.meetingID
            sink.attach(router, source: source)
            if primaryAppSourceID == nil || appAudioCapture?.state == .disabled {
                primaryAppSourceID = id
                appAudioCapture = capture
                appAudioState = capture.state
            }
            publishTracks()
            publishAppSources()
        } catch {
            sink.attach(nil)
            await capture.stop()
            await retireSource(source, revoke: true)
            appSources[id] = nil
            publishAppSources()
            throw error
        }
    }

    func stopAppAudioSource(id: String) async {
        await stopAppAudioSource(id: id, revoke: false)
    }

    private func stopAppAudioSource(id: String, revoke: Bool) async {
        guard let existing = appSources[id] else { return }
        if revoke { canonicalPipeline?.setEnabled(false, source: existing.source, hostTime: Self.hostTime) }
        #if !targetEnvironment(macCatalyst)
        if existing.capture.microphoneApproved, microphoneEnabled, usesSystemPickerMicrophone {
            if !revoke { await retireSource(existing.source, revoke: false) }
            existing.capture.disableAppAudioRetainingMicrophone()
            publishAppSources()
            return
        }
        #endif
        await retireSource(existing.source, revoke: revoke)
        existing.sink.attach(nil)
        await existing.capture.stop()
        appSources[id] = nil
        if primaryAppSourceID == id {
            primaryAppSourceID = nil
            appAudioCapture = nil
            appAudioState = .disabled
        }
        publishAppSources()
    }


    func refreshMicrophoneRoutes() async {
        let snapshot = await MeetingAudioSessionController.shared.microphoneRoutes()
        microphoneRoutes = snapshot.available
        #if targetEnvironment(macCatalyst)
        selectedMicrophoneRouteID = microphoneEnabled && (status == .recording || status == .paused)
            ? activeCatalystMicrophoneID : preferredMicrophoneRouteID
        #else
        selectedMicrophoneRouteID = microphoneEnabled && (status == .recording || status == .paused)
            ? snapshot.selectedID : preferredMicrophoneRouteID
        #endif
    }

    private var canChooseInactiveMicrophone: Bool {
        status == .ready || status == .cancelled || status == .failed
            || ((status == .recording || status == .paused) && !microphoneEnabled && terminalIntent == nil)
    }

    /// nil restores system input selection. Inputs are microphones, not meeting apps.
    func selectMicrophoneRoute(id: String?) async throws {
        guard !usesSystemPickerMicrophone else { throw CaptureError.invalidState }
        if canChooseInactiveMicrophone {
            guard !starting, !changingMicrophone else { throw CaptureError.invalidState }
            let snapshot = await MeetingAudioSessionController.shared.microphoneRoutes()
            guard !starting, !changingMicrophone, canChooseInactiveMicrophone else { throw CaptureError.invalidState }
            guard id == nil || snapshot.available.contains(where: { $0.id == id }) else {
                throw MeetingAudioSessionController.RouteError.unavailable
            }
            preferredMicrophoneRouteID = id
            selectedMicrophoneRouteID = id
            microphoneRoutes = snapshot.available
            canonicalPipeline?.setSelection(id, source: .microphone, hostTime: Self.hostTime)
            return
        }
        guard !changingMicrophone, microphoneEnabled,
              status == .recording || status == .paused, terminalIntent == nil,
              let mixer = canonicalPipeline else { throw CaptureError.invalidState }
        changingMicrophone = true
        defer { changingMicrophone = false }
        let generation = captureGeneration
        microphoneChangeGeneration += 1
        let request = microphoneChangeGeneration
        mixer.setEnabled(false, source: .microphone, hostTime: Self.hostTime)
        stopMicrophoneHardware()
        let approval = appAudioInputSink?.microphoneConsent.beginApproval()
        microphoneEnabled = false
        await retireSource(.microphone, revoke: true)
        do {
            try await MeetingAudioSessionController.shared.selectMicrophoneRoute(id: id)
            preferredMicrophoneRouteID = id
            logger.info("Audio source session=\(self.captureDiagnosticID, privacy: .public) microphone route selected systemDefault=\(id == nil)")
        } catch {
            logDiagnostic(error, operation: "microphoneRouteSelection")
            throw error
        }
        guard generation == captureGeneration, request == microphoneChangeGeneration,
              terminalIntent == nil else { throw CancellationError() }
        #if targetEnvironment(macCatalyst)
        let format: AVAudioFormat? = nil // AVCaptureAudioDataOutput supplies its actual native format with each sample.
        #else
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard Self.isValidFormat(format) else { throw CaptureError.invalidAudioFormat }
        #endif
        try Task.checkCancellation()
        guard let approval, appAudioInputSink?.microphoneConsent.approve(approval, enabled: true) == true else {
            throw CancellationError()
        }
        try await startMicrophoneHardware(format: format, mixer: mixer)
        await refreshMicrophoneRoutes()
    }

    /// Off closes the PCM gate before stopping hardware. App audio is unchanged.
    func setMicrophoneEnabled(_ enabled: Bool, consentConfirmed: Bool = false) async throws {
        guard status == .recording || status == .paused, terminalIntent == nil,
              let mixer = canonicalPipeline else { throw CaptureError.invalidState }
        if !enabled {
            microphoneChangeGeneration += 1
            requestedPickerMicrophone = false
            appAudioCapture?.microphoneRequested = false
            mixer.setEnabled(false, source: .microphone, hostTime: Self.hostTime)
            appAudioInputSink?.revokeMicrophone()
            appAudioCapture?.revokeMicrophone()
            stopMicrophoneHardware()
            microphoneEnabled = false
            microphoneRMS = 0
            await retireSource(.microphone, revoke: true)
            #if !targetEnvironment(macCatalyst)
            if usesSystemPickerMicrophone, appAudioState == .disabled {
                await appAudioCapture?.stop()
                usesSystemPickerMicrophone = false
            }
            #endif
            logger.info("Audio source session=\(self.captureDiagnosticID, privacy: .public) microphone disabled")
            return
        }
        guard !changingMicrophone else { throw CaptureError.invalidState }
        guard !microphoneEnabled else { return }
        #if !targetEnvironment(macCatalyst)
        if usesSystemPickerMicrophone {
            guard consentConfirmed else { throw MeetingAppAudioCapture.CaptureError.consentRequired }
            // iOS shows an active broadcast sheet rather than a new selection
            // while sharing. A fresh local microphone approval leaves app audio running.
            requestedPickerMicrophone = false
            appAudioCapture?.microphoneRequested = false
            usesSystemPickerMicrophone = false
        }
        #endif
        changingMicrophone = true
        defer { changingMicrophone = false }
        let generation = captureGeneration
        appAudioInputSink?.microphoneConsent.clearInterruption()
        microphoneChangeGeneration += 1
        let request = microphoneChangeGeneration
        let approval = appAudioInputSink?.microphoneConsent.beginApproval()
        guard await Self.requestMicrophonePermission() else { throw CaptureError.microphoneDenied }
        guard generation == captureGeneration, request == microphoneChangeGeneration,
              terminalIntent == nil else { throw CancellationError() }
        let setup = try await prepareMicrophone()
        guard generation == captureGeneration, request == microphoneChangeGeneration,
              terminalIntent == nil else { throw CancellationError() }
        try Task.checkCancellation()
        guard let approval, appAudioInputSink?.microphoneConsent.approve(approval, enabled: true) == true else {
            throw CancellationError()
        }
        try await startMicrophoneHardware(format: setup.format, mixer: mixer)
        if let notice = setup.notice { microphoneWarning = notice }
        await refreshMicrophoneRoutes()
    }

    private func startMicrophoneHardware(format: AVAudioFormat?, mixer: MeetingAudioSourceRouter) async throws {
        let generation = captureGeneration
        let request = microphoneChangeGeneration
        guard let consent = appAudioInputSink?.microphoneConsent,
              consent.isPermitted, terminalIntent == nil else { throw CancellationError() }
        do {
            if !microphoneEnabled { await retireSource(.microphone, revoke: true) }
            if let retiring = sourceRetirements[.microphone] { await retiring.value }
            guard captureGeneration == generation, microphoneChangeGeneration == request,
                  consent.isPermitted, terminalIntent == nil else { throw CancellationError() }
            if activeSourceTracks[.microphone] == nil {
                let track = try await createTrack(source: .microphone, kind: .microphone,
                                                  label: nil, startSample: 0)
                guard captureGeneration == generation, microphoneChangeGeneration == request,
                      consent.isPermitted, terminalIntent == nil else {
                    if activeSourceTracks[.microphone] == track.meetingID {
                        await retireSource(.microphone, revoke: true)
                    }
                    throw CancellationError()
                }
                guard consent.deliver({ mixer.setEnabled(true, source: .microphone, hostTime: Self.hostTime) }) else {
                    await retireSource(.microphone, revoke: true)
                    throw CancellationError()
                }
                track.setStartSample(mixer.sessionStartSample(for: .microphone) ?? 0)
                try journalActive(track)
            }
            #if targetEnvironment(macCatalyst)
            let capture = MeetingCatalystMicrophoneCapture(
                receive: { buffer, hostTime in
                    consent.deliver { mixer.enqueueOwned(buffer, source: .microphone, hostTime: hostTime) }
                },
                failed: { [weak self] error in
                    mixer.setEnabled(false, source: .microphone,
                                     hostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
                    Task { @MainActor in
                        guard let self, self.captureGeneration == generation,
                              self.microphoneChangeGeneration == request, self.terminalIntent == nil else { return }
                        self.stopMicrophoneHardware()
                        self.microphoneEnabled = false
                        self.microphoneRMS = 0
                        self.microphoneWarning = AppLanguage.localized(
                            "meeting.capture.microphoneStopped",
                            defaultValue: AppLanguage.current == .english
                                ? "Microphone capture stopped. Check the selected input and enable it again."
                                : "마이크 캡처가 중지되었습니다. 선택한 입력을 확인한 후 다시 켜주세요.",
                            language: .current,
                            comment: "Mac microphone disconnected or capture failed."
                        )
                        self.logDiagnostic(error, operation: "microphoneCapture")
                        await self.retireSource(.microphone, revoke: true)
                        await self.refreshMicrophoneRoutes()
                    }
                }
            )
            catalystMicrophone = capture
            let deviceID = try await capture.start(deviceID: preferredMicrophoneRouteID, running: status == .recording)
            guard captureGeneration == generation, microphoneChangeGeneration == request,
                  consent.isPermitted, terminalIntent == nil else {
                capture.stop()
                throw CancellationError()
            }
            activeCatalystMicrophoneID = deviceID
            guard consent.deliver({
                mixer.setSelection(deviceID, source: .microphone, hostTime: Self.hostTime)
                mixer.setEnabled(true, source: .microphone, hostTime: Self.hostTime)
            }) else {
                capture.stop()
                throw CancellationError()
            }
            // Capture callbacks hold their hardware lock before consulting consent.
            // Never acquire that lock while holding the consent lock.
            if status == .recording { capture.activate() } else { capture.pause() }
            #else
            guard let format else { throw CaptureError.invalidAudioFormat }
            guard !usesSystemPickerMicrophone else { throw CaptureError.invalidState }
            guard captureGeneration == generation, microphoneChangeGeneration == request,
                  consent.isPermitted, terminalIntent == nil else { throw CancellationError() }
            installMicrophoneTap(format: format, mixer: mixer)
            mixer.setSelection(AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid,
                               source: .microphone, hostTime: Self.hostTime)
            guard consent.deliver({ mixer.setEnabled(true, source: .microphone, hostTime: Self.hostTime) }) else {
                throw CancellationError()
            }
            engine.prepare()
            if status == .recording { try engine.start() }
            monitorMicrophoneRoute(mixer: mixer)
            #endif
            microphoneEnabled = true
            microphoneWarning = nil
            logger.info("Audio source session=\(self.captureDiagnosticID, privacy: .public) microphone enabled")
        } catch {
            if captureGeneration == generation, microphoneChangeGeneration == request {
                mixer.setEnabled(false, source: .microphone, hostTime: Self.hostTime)
                stopMicrophoneHardware()
            }
            if !(error is CancellationError) { logDiagnostic(error, operation: "microphoneEnable") }
            throw error
        }
    }

    private func installMicrophoneTap(format: AVAudioFormat, mixer: MeetingAudioSourceRouter) {
        let consent = appAudioInputSink?.microphoneConsent
        engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, time in
            // Arrival time must never move samples across a privacy gate.
            guard time.isHostTimeValid else { return }
            consent?.deliver {
                mixer.enqueue(buffer, source: .microphone, hostTime: AVAudioTime.seconds(forHostTime: time.hostTime))
            }
        }
        microphoneTapInstalled = true
    }

    private func stopMicrophoneHardware() {
        #if targetEnvironment(macCatalyst)
        catalystMicrophone?.stop()
        catalystMicrophone = nil
        activeCatalystMicrophoneID = nil
        #else
        microphoneRouteGate?.invalidate()
        microphoneRouteGate = nil
        if let microphoneRouteObserver {
            NotificationCenter.default.removeObserver(microphoneRouteObserver)
            self.microphoneRouteObserver = nil
        }
        if microphoneTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            microphoneTapInstalled = false
        }
        engine.stop()
        #endif
    }

    private func monitorMicrophoneInterruptions(sink: MeetingAppAudioInputSink, generation: UUID) {
        if let microphoneInterruptionObserver { NotificationCenter.default.removeObserver(microphoneInterruptionObserver) }
        microphoneInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: value) == .began else { return }
            // Revoke on the posting thread, including during permission/STT preparation.
            // .ended and .shouldResume never reopen recording consent.
            let wasRecordingMicrophone = sink.microphoneConsent.isPermitted
            sink.interruptMicrophone()
            guard let coordinator = self else { return }
            Task { @MainActor in
                guard coordinator.captureGeneration == generation, coordinator.terminalIntent == nil,
                      sink.microphoneConsent.isInterrupted else { return }
                let wasRequested = coordinator.requestedPickerMicrophone || coordinator.microphoneEnabled
                coordinator.microphoneChangeGeneration += 1
                coordinator.appAudioCapture?.revokeMicrophone()
                coordinator.stopMicrophoneHardware()
                coordinator.requestedPickerMicrophone = false
                coordinator.appAudioCapture?.microphoneRequested = false
                coordinator.microphoneEnabled = false
                coordinator.microphoneRMS = 0
                await coordinator.retireSource(.microphone, revoke: true)
                if wasRecordingMicrophone || wasRequested {
                    coordinator.microphoneWarning = MeetingAppAudioCapture.message(
                        "meeting.capture.source.microphoneInterrupted",
                        "Microphone capture was interrupted. Check the input and explicitly enable it again. App audio remains selected.",
                        "마이크 캡처가 중단되었습니다. 입력을 확인한 후 직접 다시 켜주세요. 앱 오디오 선택은 유지됩니다.")
                }
            }
        }
    }

    private func monitorMicrophoneRoute(mixer: MeetingAudioSourceRouter) {
        let generation = captureGeneration
        let request = microphoneChangeGeneration
        let expectedInputID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
        let expectedSampleRate = AVAudioSession.sharedInstance().sampleRate
        let gate = MeetingMicrophoneRouteGate()
        microphoneRouteGate = gate
        microphoneRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self, weak mixer] _ in
            let session = AVAudioSession.sharedInstance()
            guard session.currentRoute.inputs.first?.uid != expectedInputID
                    || session.sampleRate != expectedSampleRate else { return }
            // Close on the notification thread, before a newly selected system
            // input can leak through while MainActor is busy updating the UI.
            guard let mixer, gate.close(mixer) else { return }
            Task { @MainActor in
                guard let self, self.captureGeneration == generation,
                      self.microphoneChangeGeneration == request,
                      self.terminalIntent == nil else { return }
                self.stopMicrophoneHardware()
                self.microphoneEnabled = false
                self.microphoneRMS = 0
                self.logger.notice("Audio source session=\(self.captureDiagnosticID, privacy: .public) microphone route changed; gate closed")
                self.microphoneWarning = AppLanguage.localized(
                    "meeting.capture.microphoneRouteChanged",
                    defaultValue: AppLanguage.current == .english
                        ? "The audio route changed. Check the microphone input and enable it again."
                        : "오디오 경로가 변경되었습니다. 마이크 입력을 확인한 후 다시 켜주세요.",
                    language: .current,
                    comment: "Microphone capture stopped after an audio route change."
                )
                await self.retireSource(.microphone, revoke: true)
                await self.refreshMicrophoneRoutes()
            }
        }
    }

    private func prepareMicrophone() async throws -> (format: AVAudioFormat?, notice: String?) {
        #if targetEnvironment(macCatalyst)
        // AVCaptureDeviceInput, not AVAudioSession's system route, selects the Mac microphone.
        let notice = voiceProcessingRequested ? AppLanguage.localized(
            "meeting.capture.macMicrophoneRaw",
            defaultValue: AppLanguage.current == .english
                ? "The selected Mac microphone uses native audio capture without voice noise reduction."
                : "선택한 Mac 마이크는 음성 노이즈 감소 없이 기본 오디오로 캡처합니다.",
            language: .current,
            comment: "AVCapture microphone path does not provide AVAudioEngine voice processing."
        ) : nil
        return (nil, notice)
        #else
        try await configureSession(voiceProcessing: voiceProcessingRequested)
        try await MeetingAudioSessionController.shared.selectMicrophoneRoute(id: preferredMicrophoneRouteID)
        let node = engine.inputNode
        var notice: String?
        if voiceProcessingRequested {
            var valid = false
            do {
                try node.setVoiceProcessingEnabled(true)
                engine.prepare()
                valid = Self.isValidFormat(node.outputFormat(forBus: 0))
            } catch {
                logDiagnostic(error, operation: "voiceProcessing")
            }
            if !valid {
                try? node.setVoiceProcessingEnabled(false)
                try await configureSession(voiceProcessing: false)
                try await MeetingAudioSessionController.shared.selectMicrophoneRoute(id: preferredMicrophoneRouteID)
                engine.prepare()
                notice = AppLanguage.localized(
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
        return (format, notice)
        #endif
    }

    private static func requestMicrophonePermission() async -> Bool {
        #if targetEnvironment(macCatalyst)
        return await AVCaptureDevice.requestAccess(for: .audio)
        #else
        return await AVAudioApplication.requestRecordPermission()
        #endif
    }

    func pause() {
        guard status == .recording else { return }
        microphoneRMS = 0
        appAudioRMS = 0
        canonicalPipeline?.pause(hostTime: Self.hostTime)
        #if targetEnvironment(macCatalyst)
        catalystMicrophone?.pause()
        #else
        engine.pause()
        #endif
        status = .paused
    }

    func resume() throws {
        guard status == .paused else { throw CaptureError.invalidState }
        #if targetEnvironment(macCatalyst)
        if microphoneEnabled { catalystMicrophone?.resume() }
        #else
        if microphoneEnabled, !usesSystemPickerMicrophone, microphoneTapInstalled,
           appAudioInputSink?.microphoneConsent.isPermitted == true { try engine.start() }
        #endif
        canonicalPipeline?.resume(hostTime: Self.hostTime)
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
            canonicalPipeline?.pause(hostTime: Self.hostTime)
            status = .stopping
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
        finalizationDetail = MeetingAppAudioCapture.message("meeting.capture.finalization.sources", "Finalizing source transcripts", "소스별 전사를 확정하는 중")
        let pending = trackOrder.compactMap { tracks[$0] }
        await withTaskGroup(of: Void.self) { group in
            for track in pending {
                group.addTask { await track.finalize(timeout: timeout) }
            }
        }
        for task in trackFinalizations.values { await task.value }
        publishTracks()
        finalizationDetail = MeetingAppAudioCapture.message("meeting.capture.finalization.saving", "Saving the meeting records", "회의 기록을 저장하는 중")
        status = .finalizingTranscript
    }


    func cancel() async {
        guard terminalIntent == nil else {
            await terminationGate.run { [weak self] in await self?.performTerminalOperation() }
            return
        }
        terminalIntent = .cancel
        canonicalPipeline?.pause(hostTime: Self.hostTime)
        await terminationGate.run { [weak self] in await self?.performTerminalOperation() }
        status = .cancelled
        recordingDiarizationEnabled = false
    }

    private func handleSourceFailure(_ error: Error, source: MeetingAudioSourceRouter.Source) async {
        guard terminalIntent == nil else { return }
        if let id = activeSourceTracks[source] { tracks[id]?.recordAudioFailure(error) }
        logDiagnostic(error, operation: "sourceCapture")
        failure = MeetingAppAudioCapture.message(
            "meeting.capture.source.stopped",
            "One audio source stopped. Other selected sources continue recording.",
            "오디오 소스 하나가 중지되었습니다. 선택한 다른 소스의 녹음은 계속됩니다.")
        if source == .microphone {
            appAudioInputSink?.revokeMicrophone()
            stopMicrophoneHardware()
            microphoneEnabled = false
            microphoneWarning = MeetingAppAudioCapture.message(
                "meeting.capture.source.microphoneStopped",
                "Microphone capture stopped. Other sources continue recording.",
                "마이크 캡처가 중지되었습니다. 다른 소스의 녹음은 계속됩니다.")
        } else if let id = appSources.first(where: { $0.value.source == source })?.key {
            let entry = appSources[id]
            entry?.sink.attach(nil)
            await entry?.capture.stop()
            appSources[id] = nil
            publishAppSources()
        }
        await retireSource(source, revoke: true)
    }

    /// A retire fence prevents an old callback/writer from reaching the next child.
    private func retireSource(_ source: MeetingAudioSourceRouter.Source, revoke: Bool) async {
        if let retiring = sourceRetirements[source] { await retiring.value; return }
        guard let id = activeSourceTracks.removeValue(forKey: source), let track = tracks[id],
              let router = canonicalPipeline else { return }
        let closeTime = Self.hostTime
        if revoke { router.setEnabled(false, source: source, hostTime: closeTime) }
        else { router.close(source: source, hostTime: closeTime) }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var metadata: MeetingCaptureSourceMetadata?
            do {
                metadata = try await router.retire(source: source, hostTime: closeTime)
            } catch { track.recordAudioFailure(error) }
            self.trackSink.attach(nil, source: source)
            do {
                let artifact = try track.finishAudio(metadata: metadata)
                if artifact.audioManifest.totalSamples > 0 {
                    try self.journalStopped(track, artifact: artifact)
                    self.trackFinalizations[id] = Task { await track.finalize(timeout: .seconds(180)) }
                } else {
                    await self.discardTrack(track)
                    self.tracks[id] = nil
                    self.trackOrder.removeAll { $0 == id }
                }
            } catch {
                track.recordAudioFailure(error)
                self.logDiagnostic(error, operation: "sourceAudioFinalization")
                self.trackFinalizations[id] = Task { await track.cancel(removeAudio: false) }
            }
            self.publishTracks()
        }
        sourceRetirements[source] = task
        await task.value
        sourceRetirements[source] = nil
    }

    private func journalStopped(_ track: MeetingCaptureTrackSession, artifact: MeetingCaptureTrackArtifact) throws {
        let recovery = try MeetingCaptureRecoveryStore.markStopped(
            meetingID: track.meetingID, audioManifest: artifact.audioManifest,
            provisionalResult: artifact.provisionalResult,
            errorMessage: track.audioError.map { userFacingFailure(for: $0, operation: "sourceCapture") })
        recoveredCaptures.removeAll { $0.meetingID == track.meetingID }
        recoveredCaptures.append(recovery)
    }
    private func discardTrack(_ track: MeetingCaptureTrackSession) async {
        await track.cancel(removeAudio: true)
        try? MeetingCaptureRecoveryStore.remove(meetingID: track.meetingID)
        try? FileManager.default.removeItem(at: track.directoryURL.deletingLastPathComponent())
    }


    private func performTerminalOperation() async {
        guard let terminalIntent else { return }
        captureGeneration = UUID()
        let stopTime = Self.hostTime
        // Freeze group admission before any async hardware stop. Accepted valid
        // source tails drain into their own writers; no stop callback mutes them.
        canonicalPipeline?.pause(hostTime: stopTime)
        appAudioInputSink?.stopMicrophoneDelivery()
        if let microphoneInterruptionObserver {
            NotificationCenter.default.removeObserver(microphoneInterruptionObserver)
            self.microphoneInterruptionObserver = nil
        }
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        stopMicrophoneHardware()
        for source in appSources.values { source.sink.attach(nil); await source.capture.stop() }
        appAudioCapture = nil
        appAudioState = .disabled
        microphoneEnabled = false
        microphoneRMS = 0
        appAudioRMS = 0
        for task in sourceRetirements.values { await task.value }
        switch terminalIntent {
        case .cancel:
            await canonicalPipeline?.cancel()
            for track in tracks.values { await discardTrack(track) }
            for task in trackFinalizations.values { await task.value }
            await deactivateRecordingSession()
            resetCaptureReferences()
        case .stop:
            do { try await canonicalPipeline?.finish(hostTime: stopTime) }
            catch { terminalError = terminalError ?? error; logDiagnostic(error, operation: "sourceDrain") }
            for (source, id) in activeSourceTracks {
                guard let track = tracks[id] else { continue }
                let metadata = await canonicalPipeline?.captureSourceMetadata(for: source)
                do {
                    let artifact = try track.finishAudio(metadata: metadata)
                    if artifact.audioManifest.totalSamples > 0 {
                        try journalStopped(track, artifact: artifact)
                    } else {
                        await discardTrack(track)
                        tracks[id] = nil
                        trackOrder.removeAll { $0 == id }
                    }
                } catch {
                    track.recordAudioFailure(error)
                    logDiagnostic(error, operation: "sourceAudioFinalization")
                    trackFinalizations[id] = Task { await track.cancel(removeAudio: false) }
                }
            }
            canonicalPipeline = nil
            activeSourceTracks.removeAll()
            trackSink.removeAll()
            let artifacts = trackOrder.compactMap { tracks[$0]?.artifact }.filter { $0.audioManifest.totalSamples > 0 }
            if let meetingID = activeMeetingID, !artifacts.isEmpty {
                terminalArtifact = MeetingCaptureArtifact(meetingID: meetingID, tracks: artifacts)
            } else { terminalError = terminalError ?? CaptureError.noAudioSource }
            await deactivateRecordingSession()
            publishTracks()
            publishAppSources()
        }
    }

    private func resetCaptureReferences() {
        appAudioInputSink?.revokeMicrophone()
        appAudioInputSink?.attach(nil)
        appAudioInputSink = nil
        appAudioCapture = nil
        appSources.removeAll()
        primaryAppSourceID = nil
        pickerMicrophoneApproval = nil
        requestedPickerMicrophone = false
        usesSystemPickerMicrophone = false
        if let microphoneInterruptionObserver {
            NotificationCenter.default.removeObserver(microphoneInterruptionObserver)
            self.microphoneInterruptionObserver = nil
        }
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        canonicalPipeline = nil
        trackSink.removeAll()
        tracks.removeAll()
        trackOrder.removeAll()
        activeSourceTracks.removeAll()
        sourceRetirements.removeAll()
        trackFinalizations.removeAll()
        liveTracks = []
        appAudioSources = []
        recoveredCaptures = []
        activeMeetingID = nil
    }

    /// Only counters and a random capture-session token leave the audio path.
    /// No PCM values, transcript, route UID, app/window name or absolute PTS.
    private func publishSourceDeliveryDiagnostics(force: Bool = false) {
        guard let mixer = canonicalPipeline else { return }
        let delivered = mixer.deliveryMetrics()
        let levels = mixer.sourceLevels()
        microphoneRMS = microphoneEnabled && status == .recording ? levels.microphoneRMS : 0
        appAudioRMS = status == .recording ? levels.appAudioRMS : 0
        let firstDelivery = (microphoneAudioBufferCount == 0 && delivered.microphoneBuffers > 0)
            || (appAudioBufferCount == 0 && delivered.appAudioBuffers > 0)
        microphoneAudioBufferCount = delivered.microphoneBuffers
        appAudioBufferCount = delivered.appAudioBuffers
        guard force || firstDelivery || recordedAudioSamples >= lastSourceDiagnosticSamples + 80_000 else { return }
        lastSourceDiagnosticSamples = recordedAudioSamples
        let queue = mixer.metrics()
        logger.info("Audio delivery session=\(self.captureDiagnosticID, privacy: .public) micBuffers=\(delivered.microphoneBuffers) appBuffers=\(delivered.appAudioBuffers) savedSamples=\(self.recordedAudioSamples) queueHighWater=\(queue.highWaterMark) queueCapacity=\(queue.capacity)")
    }


    func acknowledgeRecoveredCapture(meetingID: String) {
        recoveredCaptures.removeAll { $0.meetingID == meetingID }
    }

    func completeFinalization() {
        finalizationDetail = ""
        status = .ready
    }

    func failFinalization(_ error: Error) async {
        // Initial persistence may fail before finalizeTranscript() releases the
        // live model. Never leave its gate held for subsequent meetings/retries.
        for track in tracks.values { await track.cancel(removeAudio: false) }
        for task in trackFinalizations.values { await task.value }
        logDiagnostic(error, operation: "finalization")
        failure = userFacingFailure(for: error, operation: "finalization")
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
        reportableError = nil
        failure = message
    }

    func reportFailure(
        _ error: Error,
        message: String? = nil,
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) {
        logDiagnostic(error, operation: "reported", file: file, line: line, function: function)
        failure = message ?? userFacingFailure(for: error, operation: "reported")
    }

    func dismissFailure() {
        failure = nil
    }
    private func logDiagnostic(
        _ error: Error,
        operation: String,
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) {
        reportableError = error
        DiagnosticRecorder.shared.record(
            error: error,
            component: "meeting.capture",
            operation: "\(operation).session.\(captureDiagnosticID)",
            file: file,
            line: line,
            function: function
        )
        let diagnostic = error as NSError
        logger.error(
            "Capture failure session=\(self.captureDiagnosticID, privacy: .public) operation=\(operation, privacy: .public) domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code, privacy: .public)"
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
        ownsRecordingAudioSession = true
        try await MeetingAudioSessionController.shared.activateForRecording(
            voiceProcessing: voiceProcessing,
            coexistWithAppAudio: Self.supportsAppAudioAPI
        )
    }

    private func deactivateRecordingSession() async {
        guard ownsRecordingAudioSession else { return }
        ownsRecordingAudioSession = false
        await MeetingAudioSessionController.shared.deactivate()
    }

    private static func isValidFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    enum CaptureError: LocalizedError {
        case microphoneDenied, unsupportedLanguage, invalidState, transcriptFinalizationTimeout, invalidAudioFormat, noAudioSource

        var errorDescription: String? {
            errorDescription(language: .current)
        }

        func errorDescription(language: AppLanguage) -> String {
            switch self {
            case .noAudioSource:
                return AppLanguage.localized(
                    "error.meeting.capture.noAudioSource",
                    defaultValue: language == .english ? "Enable the microphone or select app audio before recording." : "녹음 전에 마이크를 켜거나 앱 오디오를 선택하세요.",
                    language: language,
                    comment: "Recording requires at least one selected audio source."
                )
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
