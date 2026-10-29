import AVFoundation
import Speech
import Testing
@testable import todo

@Suite("Meeting transcription backend selection")
struct MeetingTranscriptionServiceTests {
    @Test("installed assets without a compatible format cannot select a backend") @MainActor
    func installedWithoutFormatSelectsRunnableBackend() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 16_000, channels: 1, interleaved: true))
        let factory = DefaultMeetingTranscriptionSessionFactory(
            foundationModelsAvailable: { false },
            capabilityProbe: { backend, locale in
                DefaultMeetingTranscriptionSessionFactory.assetCapability(status: .installed,
                    audioFormat: backend == .dictationTranscriber ? nil : format,
                    localeIdentifier: locale.identifier, checkingInputFormat: true)
            },
            sessionBuilder: { backend, _, _, _ in FakeMeetingTranscriptionSession(backend: backend) },
            forcedBackend: nil
        )
        let session = try await factory.make(languageTag: "en-US", purpose: .live)
        #expect(session.backend == .speechTranscriber)
    }

    @Test("no runnable Apple format is unavailable rather than a late setup failure") @MainActor
    func noAvailableFormatsCannotBuild() async {
        let probe: MeetingTranscriptionCapabilityProbe = { _, locale in
            DefaultMeetingTranscriptionSessionFactory.assetCapability(status: .installed,
                audioFormat: nil, localeIdentifier: locale.identifier, checkingInputFormat: true)
        }
        let factory = DefaultMeetingTranscriptionSessionFactory(
            foundationModelsAvailable: { false }, capabilityProbe: probe,
            sessionBuilder: { _, _, _, _ in
                Issue.record("An unavailable format must not start an analyzer")
                throw MeetingTranscriptionError.setupFailed
            }, forcedBackend: nil
        )
        #expect(await MeetingTranscriptionLanguages.supportsApple("en-US", capabilityProbe: probe) == false)
        do {
            _ = try await factory.make(languageTag: "en-US", purpose: .live)
            Issue.record("A device without usable Apple input must use explicit local transcription")
        } catch {
            #expect(error as? MeetingTranscriptionError == .backendUnavailable)
        }
    }

    @Test("downloadable Apple assets retain normal installation rather than switching engines") @MainActor
    func downloadableLanguageReadiness() {
        for status in [AssetInventory.Status.supported, .downloading] {
            #expect(DefaultMeetingTranscriptionSessionFactory.assetCapability(status: status,
                audioFormat: nil, localeIdentifier: "ko-KR", checkingInputFormat: true)
                == .supported(resolvedLocaleIdentifier: "ko-KR"))
        }
        #expect(DefaultMeetingTranscriptionSessionFactory.assetCapability(status: .unsupported,
            audioFormat: nil, localeIdentifier: "ko-KR", checkingInputFormat: true) == .unsupportedAsset)
    }

    @Test("missing live formats do not remove supported recording languages or require Whisper") @MainActor
    func languageEligibilitySurvivesMissingLiveFormat() async {
        let languageProbe: MeetingTranscriptionCapabilityProbe = { _, locale in
            DefaultMeetingTranscriptionSessionFactory.assetCapability(status: .installed,
                audioFormat: nil, localeIdentifier: locale.identifier, checkingInputFormat: false)
        }
        let languages = await MeetingLanguageCatalog.appleLanguages(
            localeProvider: { _ in [Locale(identifier: "en-US")] }, capabilityProbe: languageProbe)
        #expect(languages.map(\.languageTag) == ["en-US"])
        #expect(await MeetingTranscriptionLanguages.supportsApple("en-US", capabilityProbe: languageProbe))
        #expect(MeetingTranscriptionLanguages.options(apple: [MeetingLanguageOption(id: "en-US")],
            whisperAvailable: false).map(\.id) == ["en-US"])
        #expect(DefaultMeetingTranscriptionSessionFactory.assetCapability(status: .installed,
            audioFormat: nil, localeIdentifier: "en-US", checkingInputFormat: true) == .unavailable)
    }

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

    @Test("runtime-supported languages and script/region variants bypass app UI language restrictions") @MainActor
    func runtimeLanguageRequests() async throws {
        let recorder = SelectionRecorder()
        let factory = DefaultMeetingTranscriptionSessionFactory(
            foundationModelsAvailable: { false },
            capabilityProbe: { _, locale in .supported(resolvedLocaleIdentifier: locale.identifier) },
            sessionBuilder: { backend, locale, _, _ in
                await recorder.append(backend: backend, locale: locale.identifier(.bcp47))
                return FakeMeetingTranscriptionSession(backend: backend)
            },
            forcedBackend: nil
        )
        let tags = ["bn-BD", "hi-IN", "ar-SA", "pt-BR", "zh-Hant-TW", "sr-Latn-RS"]
        for tag in tags { _ = try await factory.make(languageTag: tag, purpose: .retry) }
        let calls = await recorder.calls
        #expect(calls == tags.map { "dictationTranscriber:\($0)" })
    }

    @Test("malformed tags fail before probing; unsupported runtime locales never build a session") @MainActor
    func unknownLanguagesNeverDefaultToEnglish() async {
        let probe = SelectionProbe()
        let recorder = SelectionRecorder()
        let factory = DefaultMeetingTranscriptionSessionFactory(
            foundationModelsAvailable: { false },
            capabilityProbe: { backend, _ in
                await probe.append(backend)
                return .unsupportedLocale
            },
            sessionBuilder: { backend, locale, _, _ in
                await recorder.append(backend: backend, locale: locale.identifier)
                return FakeMeetingTranscriptionSession(backend: backend)
            },
            forcedBackend: nil
        )
        for tag in ["", "not-a-language", "en--US", "xx-US"] {
            do {
                _ = try await factory.make(languageTag: tag, purpose: .live)
                Issue.record("Unsupported locale unexpectedly created a session")
            } catch {
                #expect(error as? MeetingTranscriptionError == .unsupportedLocale(tag))
            }
        }
        let backends = await probe.backends
        let calls = await recorder.calls
        #expect(backends == [.dictationTranscriber, .speechTranscriber])
        #expect(calls.isEmpty)
    }
}

@Suite("Meeting transcription input isolation")
@MainActor
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
        #expect(waitForSemaphore(started))
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

private func waitForSemaphore(_ semaphore: DispatchSemaphore, timeout: TimeInterval = 2) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
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
