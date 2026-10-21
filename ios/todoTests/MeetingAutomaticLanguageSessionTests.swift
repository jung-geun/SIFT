import AVFoundation
import CoreMedia
import Speech
import Testing
@testable import todo

@Suite("Automatic per-source live language handoff")
@MainActor
struct MeetingAutomaticLanguageSessionTests {
    @Test("10-second boundary, detector-time and Apple-preparation arrivals replay exactly once in sample order")
    func boundaryAndConcurrentHandoff() async throws {
        let speech = AutomaticSpeechRecorder()
        let detection = AutomaticDetectionLatch()
        let preparation = AutomaticPreparationLatch()
        let factory = AutomaticSpeechFactory(session: speech, preparation: preparation)
        let automatic = MeetingAutomaticLanguageSession(factory: factory, detector: { samples in
            await detection.detect(samples)
        }, detected: { _ in })
        let work = Task { try await automatic.run() }
        for value in 1...9 { automatic.enqueue(try pcm(Int16(value), count: 16_000)) }
        // 159999 samples cannot start detection, even after the worker runs.
        automatic.enqueue(try pcm(10, count: 15_999))
        await Task.yield()
        #expect(await detection.sampleCount == nil)
        automatic.enqueue(try pcm(11, count: 1))
        await detection.waitForStart()
        #expect(await detection.sampleCount == 160_000)
        #expect(await detection.first == Float(1) / 32_768)
        #expect(await detection.last == Float(11) / 32_768)
        automatic.enqueue(try pcm(12, count: 2_000))
        await detection.release("ja")
        await preparation.waitForStart()
        automatic.enqueue(try pcm(13, count: 3_000))
        await preparation.release()
        automatic.enqueue(try pcm(14, count: 4_000))
        automatic.finishInput()
        try await work.value
        #expect(factory.tags == ["ja"])
        let expected: [Int16] = (1...9).flatMap { Array(repeating: Int16($0), count: 16_000) }
            + Array(repeating: Int16(10), count: 15_999) + [11]
            + Array(repeating: Int16(12), count: 2_000)
            + Array(repeating: Int16(13), count: 3_000)
            + Array(repeating: Int16(14), count: 4_000)
        #expect(speech.samples == expected)
        #expect(speech.starts == [0, 16_000, 32_000, 48_000, 64_000, 80_000, 96_000, 112_000, 128_000,
                                  144_000, 159_999, 160_000, 162_000, 165_000])
    }

    @Test("two sources detect different languages independently and preserve their shared-timeline offsets", .timeLimit(.minutes(1)))
    func independentLanguagesAndShortRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = try track(root: root, kind: .microphone, offset: 0)
        let app = try track(root: root, kind: .application, offset: 72_000)
        let micSpeech = AutomaticSpeechRecorder()
        let appSpeech = AutomaticSpeechRecorder()
        let micFactory = AutomaticSpeechFactory(session: micSpeech)
        let appFactory = AutomaticSpeechFactory(session: appSpeech)
        let group = UUID().uuidString
        await mic.prepare(factory: micFactory, languageTag: "manual-not-a-hint", diarizationEnabled: false,
                          groupID: group, automaticLanguageDetection: true, languageDetector: { samples in
            #expect(samples.count == 160_000)
            #expect(samples[0] > 0)
            return "ko"
        })
        await app.prepare(factory: appFactory, languageTag: "manual-not-a-hint", diarizationEnabled: false,
                          groupID: group, automaticLanguageDetection: true, languageDetector: { samples in
            #expect(samples.count == 8_000)
            #expect(samples[0] < 0)
            return "fr"
        })
        #expect(mic.snapshot.isDetectingLanguage)
        #expect(app.snapshot.isDetectingLanguage)
        try mic.input.append(pcm(1_000, count: 160_000))
        try app.input.append(pcm(-2_000, count: 8_000))
        let a = try mic.finishAudio(metadata: nil)
        let b = try app.finishAudio(metadata: nil)
        // Finishing audio closes the replay FIFO. Observe each consumer's drain
        // before testing finalization; unrelated MainActor tests must not consume
        // this scenario's three-second finalization watchdog before replay runs.
        async let micDrained: Void = micSpeech.waitForDrain()
        async let appDrained: Void = appSpeech.waitForDrain()
        _ = await (micDrained, appDrained)
        async let micDone: Void = mic.finalize(timeout: .seconds(3))
        async let appDone: Void = app.finalize(timeout: .seconds(3))
        _ = await (micDone, appDone)
        #expect(micFactory.tags == ["ko"])
        #expect(appFactory.tags == ["fr"])
        #expect(mic.snapshot.detectedLanguageTag == "ko")
        #expect(app.snapshot.detectedLanguageTag == "fr")
        #expect(!mic.snapshot.isDetectingLanguage && !app.snapshot.isDetectingLanguage)
        #expect(micSpeech.samples == Array(repeating: 1_000, count: 160_000))
        #expect(appSpeech.samples == Array(repeating: -2_000, count: 8_000))
        #expect(a.audioManifest.totalSamples == 160_000)
        #expect(b.audioManifest.totalSamples == 8_000)
        #expect(b.sessionStartSample == 72_000)
    }

    @Test("An opening window without speech does not permanently disable later source speech")
    func speechAfterOpeningWindow() async throws {
        let speech = AutomaticSpeechRecorder()
        let opening = AutomaticDetectionLatch()
        let factory = AutomaticSpeechFactory(session: speech)
        let automatic = MeetingAutomaticLanguageSession(factory: factory, detector: { samples in
            if samples.first == 0 { return await opening.detect(samples) }
            #expect(samples.count == 4_000) // final partial window on short stop
            #expect(samples.allSatisfy { $0 == Float(3_000) / 32_768 })
            return "ja"
        }, detected: { _ in })
        let work = Task { try await automatic.run() }
        automatic.enqueue(try pcm(0, count: 160_000))
        await opening.waitForStart()
        #expect(factory.tags.isEmpty)
        // Add speech while the first estimate is still in flight. No samples
        // from that window may leak into the later estimate or be lost in replay.
        automatic.enqueue(try pcm(3_000, count: 4_000))
        automatic.finishInput()
        await opening.release(nil)
        try await work.value
        #expect(factory.tags == ["ja"])
        #expect(speech.samples == Array(repeating: 0, count: 160_000) + Array(repeating: 3_000, count: 4_000))
    }

    @Test("no speech, invalid tag, unsupported Apple, and detector error do not select a fallback", arguments: [0, 1, 2, 3])
    func optionalFailureKeepsRecording(mode: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try track(root: root, kind: .microphone)
        let speech = AutomaticSpeechRecorder()
        let factory = AutomaticSpeechFactory(session: speech, reject: mode == 2)
        await child.prepare(factory: factory, languageTag: "en-US", diarizationEnabled: false,
                            groupID: UUID().uuidString, automaticLanguageDetection: true, languageDetector: { _ in
            switch mode {
            case 0: return nil
            case 1: return "not-a-language"
            case 2: return "ja"
            default: throw AutomaticTestError.detector
            }
        })
        try child.input.append(pcm(7_000, count: 4_000))
        let artifact = try child.finishAudio(metadata: nil)
        await child.finalize(timeout: .seconds(3))
        #expect(child.transcriptionError != nil)
        #expect(child.snapshot.liveTranscriptionWarning != nil)
        #expect(!child.snapshot.isDetectingLanguage)
        #expect(factory.tags == (mode == 2 ? ["ja"] : []))
        #expect(artifact.audioManifest.totalSamples == 4_000)
        #expect(FileManager.default.fileExists(atPath: child.directoryURL.path))
        #expect(speech.samples.isEmpty)
    }

    @Test("cancel before detection completes cannot resurrect a source or create Apple")
    func cancellationDuringDetection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try track(root: root, kind: .application)
        let detection = AutomaticDetectionLatch()
        let factory = AutomaticSpeechFactory(session: AutomaticSpeechRecorder())
        await child.prepare(factory: factory, languageTag: "en-US", diarizationEnabled: false,
                            groupID: UUID().uuidString, automaticLanguageDetection: true,
                            languageDetector: { await detection.detect($0) })
        try child.input.append(pcm(3_000, count: 160_000))
        await detection.waitForStart()
        let cancellation = Task { await child.cancel(removeAudio: true) }
        while child.snapshot.isDetectingLanguage { await Task.yield() }
        await detection.release("ja")
        await cancellation.value
        #expect(factory.tags.isEmpty)
        #expect(child.snapshot.detectedLanguageTag == nil)
        #expect(!child.snapshot.isDetectingLanguage)
        #expect(!FileManager.default.fileExists(atPath: child.directoryURL.path))
    }

    @Test("cancel during Apple preparation cancels the late session without replay")
    func cancellationDuringPreparation() async throws {
        let speech = AutomaticSpeechRecorder()
        let preparation = AutomaticPreparationLatch()
        let factory = AutomaticSpeechFactory(session: speech, preparation: preparation)
        let automatic = MeetingAutomaticLanguageSession(factory: factory, detector: { _ in "de" }, detected: { _ in })
        let work = Task { try await automatic.run() }
        automatic.enqueue(try pcm(4_000, count: 160_000))
        await preparation.waitForStart()
        await automatic.cancel()
        await preparation.release()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(speech.wasCancelled)
        #expect(speech.samples.isEmpty)
    }

    @Test("bounded handoff overflow stops only optional analysis")
    func boundedBufferFailure() async throws {
        let speech = AutomaticSpeechRecorder()
        let detection = AutomaticDetectionLatch()
        let factory = AutomaticSpeechFactory(session: speech)
        let automatic = MeetingAutomaticLanguageSession(factory: factory, detector: { await detection.detect($0) }, detected: { _ in })
        let work = Task { try await automatic.run() }
        automatic.enqueue(try pcm(1_000, count: 160_000))
        await detection.waitForStart()
        for _ in 0..<12 { automatic.enqueue(try pcm(2_000, count: 160_000)) }
        await detection.release("en")
        await #expect(throws: MeetingAutomaticLanguageSession.Failure.bufferLimit) { try await work.value }
        #expect(factory.tags.isEmpty)
    }

    @Test("direct task cancellation wakes an empty source and finishes its result stream")
    func directTaskCancellation() async throws {
        let factory = AutomaticSpeechFactory(session: AutomaticSpeechRecorder())
        let automatic = MeetingAutomaticLanguageSession(factory: factory, detector: { _ in
            Issue.record("Cancelled empty source must not invoke inference")
            return "en"
        }, detected: { _ in })
        let work = Task { try await automatic.run() }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        var resultCount = 0
        for try await _ in automatic.results { resultCount += 1 }
        #expect(resultCount == 0)
        #expect(factory.tags.isEmpty)
    }

    @Test("a failed result stream wakes idle audio input and preserves the source error")
    func failedResultsWakeInput() async throws {
        let speech = AutomaticSpeechRecorder()
        let automatic = MeetingAutomaticLanguageSession(
            factory: AutomaticSpeechFactory(session: speech), detector: { _ in "en" }, detected: { _ in })
        let work = Task { try await automatic.run() }
        automatic.enqueue(try pcm(2_000, count: 160_000))
        while speech.samples.count != 160_000 { await Task.yield() }
        speech.failResults()
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { try await work.value; return false }
                catch { return error as? AutomaticTestError == .speech }
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return false }
                work.cancel()
                await automatic.cancel()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished)
        #expect(speech.wasCancelled)
    }

    @Test("empty stopped source finishes honestly without invoking detector or Apple")
    func emptyStop() async throws {
        let factory = AutomaticSpeechFactory(session: AutomaticSpeechRecorder())
        let automatic = MeetingAutomaticLanguageSession(factory: factory, detector: { _ in
            Issue.record("Empty audio must not invoke inference")
            return "en"
        }, detected: { _ in })
        automatic.finishInput()
        await #expect(throws: MeetingAutomaticLanguageSession.Failure.noSpeech) { try await automatic.run() }
        #expect(factory.tags.isEmpty)
    }

    private func track(root: URL, kind: MeetingAudioTrackKind, offset: Int64 = 0) throws -> MeetingCaptureTrackSession {
        try MeetingCaptureTrackSession(sourceKind: kind, sourceLabel: nil, sessionStartSample: offset,
                                       directoryURL: root.appendingPathComponent(UUID().uuidString), changed: {})
    }

    private func pcm(_ value: Int16, count: Int) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: MeetingAutomaticLanguageSession.canonicalFormat,
                                                  frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let pointer = try #require(buffer.int16ChannelData?[0])
        pointer.initialize(repeating: value, count: count)
        return buffer
    }
}

private nonisolated enum AutomaticTestError: Error { case detector, speech }

private nonisolated final class AutomaticSpeechFactory: MeetingTranscriptionSessionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var languages: [String] = []
    let session: AutomaticSpeechRecorder
    let preparation: AutomaticPreparationLatch?
    let reject: Bool
    var tags: [String] { lock.withLock { languages } }

    init(session: AutomaticSpeechRecorder, preparation: AutomaticPreparationLatch? = nil, reject: Bool = false) {
        self.session = session; self.preparation = preparation; self.reject = reject
    }

    func make(languageTag: String, purpose: MeetingTranscriptionPurpose) async throws -> any MeetingTranscriptionSession {
        lock.withLock { languages.append(languageTag) }
        if reject { throw MeetingTranscriptionError.unsupportedLocale(languageTag) }
        await preparation?.suspend()
        return session
    }
}

private nonisolated final class AutomaticSpeechRecorder: MeetingTranscriptionSession, @unchecked Sendable {
    let backend: MeetingTranscriptionBackend = .speechTranscriber
    let inputFormat = MeetingAutomaticLanguageSession.canonicalFormat
    let results: AsyncThrowingStream<MeetingTranscriptionResult, Error>
    private let output: AsyncThrowingStream<MeetingTranscriptionResult, Error>.Continuation
    private let lock = NSLock()
    private var recorded: [Int16] = []
    private var positions: [Int64] = []
    private var cancelled = false
    private let drain = AsyncStream<Void>.makeStream()
    var samples: [Int16] { lock.withLock { recorded } }
    var starts: [Int64] { lock.withLock { positions } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    init() {
        let stream = AsyncThrowingStream<MeetingTranscriptionResult, Error>.makeStream()
        results = stream.stream; output = stream.continuation
    }

    func waitForDrain() async {
        for await _ in drain.stream {}
    }

    func analyze(_ input: AsyncStream<AnalyzerInput>) async throws {
        defer { drain.continuation.finish() }
        for await input in input {
            try Task.checkCancellation()
            let buffer = input.buffer
            let pointer = try #require(buffer.int16ChannelData?[0])
            lock.withLock {
                recorded.append(contentsOf: UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength)))
                positions.append(input.bufferStartTime?.value ?? -1)
            }
        }
        output.finish()
    }

    func failResults() { output.finish(throwing: AutomaticTestError.speech) }

    func cancel() async {
        lock.withLock { cancelled = true }
        output.finish()
        drain.continuation.finish()
    }
}

private actor AutomaticDetectionLatch {
    private var result: CheckedContinuation<String?, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var sampleCount: Int?
    private(set) var first: Float?
    private(set) var last: Float?

    func detect(_ samples: [Float]) async -> String? {
        sampleCount = samples.count; first = samples.first; last = samples.last
        return await withCheckedContinuation { continuation in
            result = continuation
            started?.resume(); started = nil
        }
    }
    func waitForStart() async {
        if result != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release(_ tag: String?) { result?.resume(returning: tag); result = nil }
}

private actor AutomaticPreparationLatch {
    private var suspended: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func suspend() async {
        await withCheckedContinuation { continuation in
            suspended = continuation
            started?.resume(); started = nil
        }
    }
    func waitForStart() async {
        if suspended != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { suspended?.resume(); suspended = nil }
}
