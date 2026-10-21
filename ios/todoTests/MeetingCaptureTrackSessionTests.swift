import AVFoundation
import CoreMedia
import Speech
import Testing
@testable import todo

@Suite("Independent capture track lifecycle")
@MainActor
struct MeetingCaptureTrackSessionTests {
    @Test("deferred language records lossless audio without invoking Apple ASR")
    func deferredLanguageKeepsOriginal() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try track(root: root, kind: .microphone)
        await child.prepare(factory: FailingFactory(), languageTag: "bn", diarizationEnabled: false,
                            groupID: UUID().uuidString.lowercased(), deferTranscription: true)
        try child.input.append(pcm(value: 12_000))
        let artifact = try child.finishAudio(metadata: nil)
        await child.finalize(timeout: .seconds(1))
        #expect(child.transcriptionError == nil)
        #expect(artifact.provisionalResult.segments.isEmpty)
        #expect(artifact.audioManifest.totalSamples == 16_000)
        #expect(try savedPCM(artifact).allSatisfy { $0 == 12_000 })
    }

    @Test("mute during suspended speech preparation cannot reopen an old microphone request", arguments: [false, true])
    func mutedPreparationCannotReopen(renewConsent: Bool) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = try track(root: root, kind: .microphone)
        let app = try track(root: root, kind: .application)
        let inputs = TrackInputs(microphone: mic.input, application: app.input)
        let router = try MeetingAudioSourceRouter(automaticallyRenders: false, consume: { source, buffer in
            try inputs.append(buffer, source: source)
        }, failed: { _, _ in Issue.record("Unexpected router failure") })
        router.start(hostTime: 100, microphoneEnabled: false)
        router.setEnabled(true, source: .appAudio, hostTime: 100)
        let consent = MeetingMicrophoneConsentGate()
        let approval = consent.beginApproval()
        #expect(consent.approve(approval, enabled: true))
        let latch = TrackSpeechPreparationLatch()
        let factory = SuspendedTrackFactory(latch: latch, session: ScriptedTrackSpeechSession())
        let preparation = Task { @MainActor in
            await mic.prepare(factory: factory, languageTag: "en-US", diarizationEnabled: false,
                              groupID: UUID().uuidString.lowercased())
            return consent.isCurrent(approval) && consent.deliver {
                router.setEnabled(true, source: .microphone, hostTime: 100)
            }
        }
        await latch.waitForStart()
        consent.revoke { router.setEnabled(false, source: .microphone, hostTime: 100) }
        if renewConsent {
            #expect(consent.approve(consent.beginApproval(), enabled: true))
        }
        await latch.release()
        #expect(await preparation.value == false)
        for index in 0..<4 {
            let time = 100 + Double(index) * 0.25
            router.enqueue(try pcm(value: 31_000, count: 4_000), source: .microphone, hostTime: time)
            router.enqueue(try pcm(value: -12_000, count: 4_000), source: .appAudio, hostTime: time)
        }
        try await router.finish(hostTime: 101)
        let microphone = try mic.finishAudio(metadata: nil)
        let application = try app.finishAudio(metadata: await router.captureSourceMetadata(for: .appAudio))
        #expect(microphone.audioManifest.totalSamples == 0)
        #expect(application.audioManifest.totalSamples == 16_000)
        #expect(try savedPCM(application).allSatisfy { $0 == -12_000 })
        await mic.cancel(removeAudio: true)
        await app.cancel(removeAudio: false)
    }

    @Test("colliding ASR ranges retain each child's text, finality and segment namespace", .timeLimit(.minutes(1)))
    func transcriptNamespacesDoNotCollide() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = try track(root: root, kind: .microphone)
        let app = try track(root: root, kind: .application)
        let micSpeech = ScriptedTrackSpeechSession()
        let appSpeech = ScriptedTrackSpeechSession()
        let groupID = UUID().uuidString.lowercased()
        await mic.prepare(factory: ScriptedTrackFactory(session: micSpeech), languageTag: "en-US",
                          diarizationEnabled: false, groupID: groupID)
        await app.prepare(factory: ScriptedTrackFactory(session: appSpeech), languageTag: "en-US",
                          diarizationEnabled: false, groupID: groupID)
        try mic.input.append(pcm(value: 1_000))
        try app.input.append(pcm(value: -1_000))
        micSpeech.emit("microphone final", final: true)
        micSpeech.emit("late volatile replacement", final: false)
        appSpeech.emit("application final", final: true)
        // This scenario has emitted its complete scripted ASR result stream.
        // Drain those results before starting the independent finalization timer.
        micSpeech.finishResults()
        appSpeech.finishResults()
        while mic.snapshot.liveTranscriptRows.map(\.text) != ["microphone final"]
            || app.snapshot.liveTranscriptRows.map(\.text) != ["application final"] {
            try Task.checkCancellation()
            await Task.yield()
        }
        _ = try mic.finishAudio(metadata: nil)
        _ = try app.finishAudio(metadata: nil)
        await mic.finalize(timeout: .seconds(2))
        await app.finalize(timeout: .seconds(2))
        let a = try mic.transcriptionResult()
        let b = try app.transcriptionResult()
        #expect(a.segments.map(\.text) == ["microphone final"])
        #expect(b.segments.map(\.text) == ["application final"])
        #expect(a.segments.first?.isFinal == true)
        #expect(a.segments.first?.startMs == b.segments.first?.startMs)
        #expect(a.segments.first?.id != b.segments.first?.id)
        #expect(mic.snapshot.liveTranscriptRows.map(\.text) == ["microphone final"])
        #expect(app.snapshot.liveTranscriptRows.map(\.text) == ["application final"])
    }

    @Test("simultaneous sources preserve independent full-scale FLAC and child namespaces")
    func independentSavedAudio() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = try track(root: root, kind: .microphone, offset: 0)
        let app = try track(root: root, kind: .application, offset: 0)
        let inputs = TrackInputs(microphone: mic.input, application: app.input)
        let router = try MeetingAudioSourceRouter(automaticallyRenders: false, consume: { source, buffer in
            try inputs.append(buffer, source: source)
        }, failed: { _, _ in Issue.record("Unexpected router failure") })
        router.start(hostTime: 100, microphoneEnabled: true)
        router.setEnabled(true, source: .appAudio, hostTime: 100)
        for index in 0..<4 {
            let hostTime = 100 + Double(index) * 0.25
            router.enqueue(try pcm(value: 30_000, count: 4_000), source: .microphone, hostTime: hostTime)
            router.enqueue(try pcm(value: -30_000, count: 4_000), source: .appAudio, hostTime: hostTime)
        }
        try await router.finish(hostTime: 101)
        let a = try mic.finishAudio(metadata: await router.captureSourceMetadata(for: .microphone))
        let b = try app.finishAudio(metadata: await router.captureSourceMetadata(for: .appAudio))
        #expect(a.meetingID != b.meetingID)
        #expect(a.directoryURL != b.directoryURL)
        #expect(a.audioManifest.totalSamples == 16_000)
        #expect(b.audioManifest.totalSamples == 16_000)
        #expect(a.sessionStartSample == 0)
        #expect(b.sessionStartSample == 0)
        #expect(try savedPCM(a).allSatisfy { $0 == 30_000 })
        #expect(try savedPCM(b).allSatisfy { $0 == -30_000 })
        await mic.cancel(removeAudio: false)
        await app.cancel(removeAudio: false)
    }

    @Test("ASR setup failure does not close its FLAC writer or poison another child")
    func speechFailureIsIndependent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let failed = try track(root: root, kind: .application)
        let other = try track(root: root, kind: .microphone)
        await failed.prepare(factory: FailingFactory(), languageTag: "en-US", diarizationEnabled: false,
                             groupID: UUID().uuidString.lowercased())
        try failed.input.append(pcm(value: 5_000))
        try other.input.append(pcm(value: -7_000))
        let failedAudio = try failed.finishAudio(metadata: nil)
        let otherAudio = try other.finishAudio(metadata: nil)
        await failed.finalize(timeout: .seconds(1))
        await other.finalize(timeout: .seconds(1))
        #expect(failed.transcriptionError != nil)
        #expect(other.transcriptionError == nil)
        #expect(failed.snapshot.liveTranscriptionWarning != nil)
        #expect(failedAudio.audioManifest.totalSamples == 16_000)
        #expect(otherAudio.audioManifest.totalSamples == 16_000)
        #expect(try savedPCM(failedAudio).allSatisfy { $0 == 5_000 })
        #expect(try savedPCM(otherAudio).allSatisfy { $0 == -7_000 })
        #expect(throws: Error.self) { try failed.transcriptionResult() }
    }

    @Test("audio durability precedes ASR finalization and closes late PCM admission")
    func fastAudioFinishIsIdempotent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try track(root: root, kind: .screen)
        try child.input.append(pcm(value: 11_000))
        let first = try child.finishAudio(metadata: nil)
        #expect(!child.finalized)
        #expect(try savedPCM(first).count == 16_000)
        try child.input.append(pcm(value: 22_000))
        let second = try child.finishAudio(metadata: nil)
        #expect(first.audioManifest == second.audioManifest)
        #expect(try savedPCM(second).allSatisfy { $0 == 11_000 })
        await child.finalize(timeout: .seconds(1))
        #expect(child.finalized)
    }

    @Test("cancel removes only its own audio and rejects stale callbacks")
    func cancellationIsIndependent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let removed = try track(root: root, kind: .application)
        let retained = try track(root: root, kind: .microphone)
        try removed.input.append(pcm(value: 4_000))
        try retained.input.append(pcm(value: 8_000))
        await removed.cancel(removeAudio: true)
        try removed.input.append(pcm(value: 32_000))
        try retained.input.append(pcm(value: 8_000))
        let artifact = try retained.finishAudio(metadata: nil)
        #expect(!FileManager.default.fileExists(atPath: removed.directoryURL.path))
        #expect(artifact.audioManifest.totalSamples == 32_000)
        #expect(try savedPCM(artifact).allSatisfy { $0 == 8_000 })
        await retained.cancel(removeAudio: false)
    }

    @Test("source metadata is child-local and cannot exceed the saved prefix")
    func metadataIsBoundedToChild() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try track(root: root, kind: .application, offset: 123_456)
        try child.input.append(pcm(value: 2_000))
        let metadata = MeetingCaptureSourceMetadata(boundaries: [
            MeetingCaptureSourceBoundary(sample: 0, source: .appAudio, action: .enabled, selection: nil),
            MeetingCaptureSourceBoundary(sample: 16_000, source: .appAudio, action: .disabled, selection: nil),
            MeetingCaptureSourceBoundary(sample: 16_001, source: .appAudio, action: .selection, selection: "private source")
        ])
        let artifact = try child.finishAudio(metadata: metadata)
        #expect(artifact.sessionStartSample == 123_456)
        #expect(artifact.audioManifest.captureSourceMetadata?.boundaries.count == 2)
        #expect(artifact.audioManifest.captureSourceMetadata?.boundaries.first?.sample == 0)
        await child.cancel(removeAudio: false)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("meeting-track-\(UUID().uuidString)", isDirectory: true)
    }

    private func track(root: URL, kind: MeetingAudioTrackKind, offset: Int64 = 0) throws -> MeetingCaptureTrackSession {
        let id = UUID().uuidString.lowercased()
        return try MeetingCaptureTrackSession(meetingID: id, sourceKind: kind, sourceLabel: nil,
            sessionStartSample: offset,
            directoryURL: root.appendingPathComponent(id, isDirectory: true).appendingPathComponent("audio", isDirectory: true),
            changed: {})
    }

    private func pcm(value: Int16, count: Int = 16_000) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = try #require(buffer.int16ChannelData?[0])
        samples.initialize(repeating: value, count: count)
        return buffer
    }

    private func savedPCM(_ artifact: MeetingCaptureTrackArtifact) throws -> [Int16] {
        let part = try #require(artifact.audioManifest.parts.first)
        let file = try AVAudioFile(forReading: artifact.directoryURL.appendingPathComponent(part.fileName),
                                  commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: try #require(buffer.int16ChannelData?[0]), count: Int(buffer.frameLength)))
    }
}

private nonisolated final class TrackInputs: @unchecked Sendable {
    let microphone: MeetingCaptureTrackInput
    let application: MeetingCaptureTrackInput
    init(microphone: MeetingCaptureTrackInput, application: MeetingCaptureTrackInput) {
        self.microphone = microphone
        self.application = application
    }
    func append(_ buffer: AVAudioPCMBuffer, source: MeetingAudioSourceRouter.Source) throws {
        try (source == .microphone ? microphone : application).append(buffer)
    }
}

private struct FailingFactory: MeetingTranscriptionSessionFactory {
    func make(languageTag: String, purpose: MeetingTranscriptionPurpose) async throws -> any MeetingTranscriptionSession {
        throw MeetingTranscriptionError.setupFailed
    }
}

private struct ScriptedTrackFactory: MeetingTranscriptionSessionFactory {
    let session: ScriptedTrackSpeechSession
    func make(languageTag: String, purpose: MeetingTranscriptionPurpose) async throws -> any MeetingTranscriptionSession {
        session
    }
}

private final class ScriptedTrackSpeechSession: MeetingTranscriptionSession, @unchecked Sendable {
    let backend: MeetingTranscriptionBackend = .speechTranscriber
    let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                    channels: 1, interleaved: true)!
    let results: AsyncThrowingStream<MeetingTranscriptionResult, Error>
    private let continuation: AsyncThrowingStream<MeetingTranscriptionResult, Error>.Continuation

    init() {
        let stream = AsyncThrowingStream<MeetingTranscriptionResult, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        results = stream.stream
        continuation = stream.continuation
    }

    func emit(_ text: String, final: Bool) {
        continuation.yield(MeetingTranscriptionResult(
            range: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)),
            text: AttributedString(text), alternatives: [], isFinal: final, confidence: nil))
    }

    func finishResults() { continuation.finish() }

    func analyze(_ input: AsyncStream<AnalyzerInput>) async throws {
        for await _ in input { try Task.checkCancellation() }
        continuation.finish()
    }

    func cancel() async { continuation.finish() }
}

private struct SuspendedTrackFactory: MeetingTranscriptionSessionFactory {
    let latch: TrackSpeechPreparationLatch
    let session: ScriptedTrackSpeechSession
    func make(languageTag: String, purpose: MeetingTranscriptionPurpose) async throws -> any MeetingTranscriptionSession {
        await latch.suspend()
        return session
    }
}

private actor TrackSpeechPreparationLatch {
    private var suspended: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            suspended = continuation
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitForStart() async {
        if suspended != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        suspended?.resume()
        suspended = nil
    }
}
