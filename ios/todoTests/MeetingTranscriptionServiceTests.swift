import AVFoundation
import Speech
import Testing
@testable import todo

@Suite("Meeting transcription backend selection")
struct MeetingTranscriptionServiceTests {
    @Test("AFM-unavailable devices select Dictation before Speech") @MainActor
    func selectsDictationWhenAFMUnavailable() async throws {
        let recorder = SelectionRecorder()
        let factory = DefaultMeetingTranscriptionSessionFactory(
            foundationModelsAvailable: { false },
            capabilityProbe: { backend, _ in
                backend == .dictationTranscriber
                    ? .supported(resolvedLocaleIdentifier: "ko-KR")
                    : .unsupportedAsset
            },
            sessionBuilder: { backend, locale, _, _ in
                await recorder.append(backend: backend, locale: locale.identifier)
                return FakeMeetingTranscriptionSession(backend: backend)
            }
        )

        let session = try await factory.make(languageTag: "ko-KR", purpose: .live)
        let calls = await recorder.calls
        #expect(session.backend == .dictationTranscriber)
        #expect(calls == ["dictationTranscriber:ko-KR"])
    }

    @Test("static capability failure tries the secondary backend once") @MainActor
    func fallsBackOnlyAfterStaticCapabilityFailure() async throws {
        let recorder = SelectionRecorder()
        let factory = DefaultMeetingTranscriptionSessionFactory(
            foundationModelsAvailable: { true },
            capabilityProbe: { backend, _ in
                backend == .speechTranscriber ? .unsupportedAsset : .supported(resolvedLocaleIdentifier: "en-US")
            },
            sessionBuilder: { backend, locale, _, _ in
                await recorder.append(backend: backend, locale: locale.identifier)
                return FakeMeetingTranscriptionSession(backend: backend)
            }
        )

        let session = try await factory.make(languageTag: "en-US", purpose: .retry)
        let calls = await recorder.calls
        #expect(session.backend == .dictationTranscriber)
        #expect(calls == ["dictationTranscriber:en-US"])
    }

    @Test("forced backend never probes or builds an alternative") @MainActor
    func forcedBackendDoesNotFallback() async {
        let probe = SelectionProbe()
        let factory = DefaultMeetingTranscriptionSessionFactory(
            foundationModelsAvailable: { true },
            capabilityProbe: { backend, _ in
                await probe.append(backend)
                return .unsupportedLocale
            },
            sessionBuilder: { _, _, _, _ in FakeMeetingTranscriptionSession(backend: .speechTranscriber) },
            forcedBackend: .dictationTranscriber
        )

        do {
            _ = try await factory.make(languageTag: "ko-KR", purpose: .live)
            Issue.record("unsupported forced backend unexpectedly built a session")
        } catch {
            #expect(error as? MeetingTranscriptionError == .unsupportedLocale("ko-KR"))
        }
        let backends = await probe.backends
        #expect(backends == [.dictationTranscriber])
    }

    @Test("builder failure does not select a second backend") @MainActor
    func builderFailureDoesNotFallback() async {
        let probe = SelectionProbe()
        let factory = DefaultMeetingTranscriptionSessionFactory(
            foundationModelsAvailable: { true },
            capabilityProbe: { backend, _ in
                await probe.append(backend)
                return .supported(resolvedLocaleIdentifier: "en-US")
            },
            sessionBuilder: { _, _, _, _ in throw MeetingTranscriptionError.setupFailed }
        )

        do {
            _ = try await factory.make(languageTag: "en-US", purpose: .live)
            Issue.record("builder failure unexpectedly selected a fallback")
        } catch {
            #expect(error as? MeetingTranscriptionError == .setupFailed)
        }
        let backends = await probe.backends
        #expect(backends == [.speechTranscriber])
    }
}

@Suite("Meeting transcription input isolation")
struct MeetingTranscriptionInputPipelineTests {
    @Test("input overflow fails transcription without blocking capture")
    func overflowFailsOnce() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(8))
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let failures = TranscriptionFailureProbe()
        let pipeline = try MeetingTranscriptionInputPipeline(
            inputFormat: format,
            outputFormat: format,
            maximumQueuedBuffers: 1,
            consume: {
                started.signal()
                release.wait()
                return stream.continuation.yield($0)
            },
            failed: { _ in failures.record() }
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024
        pipeline.enqueue(buffer)
        #expect(started.wait(timeout: .now() + 2) == .success)
        pipeline.enqueue(buffer)
        release.signal()
        do {
            try await pipeline.finish()
            Issue.record("overflow must be surfaced to the transcription owner")
        } catch {
            #expect(error as? MeetingTranscriptionError == .runtimeFailed)
        }
        #expect(failures.count == 1)
        stream.continuation.finish()
    }
}

private final class TranscriptionFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    func record() {
        lock.lock(); failures += 1; lock.unlock()
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return failures
    }
}

private actor SelectionRecorder {
    private(set) var calls = [String]()

    func append(backend: MeetingTranscriptionBackend, locale: String) {
        calls.append("\(backend.rawValue):\(locale)")
    }
}

private actor SelectionProbe {
    private(set) var backends = [MeetingTranscriptionBackend]()

    func append(_ backend: MeetingTranscriptionBackend) {
        backends.append(backend)
    }
}

private final class FakeMeetingTranscriptionSession: MeetingTranscriptionSession, @unchecked Sendable {
    let backend: MeetingTranscriptionBackend
    let inputFormat: AVAudioFormat
    let results: AsyncThrowingStream<MeetingTranscriptionResult, Error>

    init(backend: MeetingTranscriptionBackend) {
        self.backend = backend
        self.inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        self.results = AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func analyze(_ input: AsyncStream<AnalyzerInput>) async throws {}
    func cancel() async {}
}
