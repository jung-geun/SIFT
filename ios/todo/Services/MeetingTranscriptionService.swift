@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech


nonisolated private func recordTranscriptionDiagnostic(
    _ error: Error,
    operation: String,
    file: String = #fileID,
    line: Int = #line,
    function: String = #function
) {
    DiagnosticRecorder.shared.record(
        error: error,
        component: "meeting.transcription",
        operation: operation,
        file: file,
        line: line,
        function: function
    )
}
enum MeetingTranscriptionPurpose: Sendable {
    case live
    case retry
}

enum MeetingTranscriptionBackend: String, Sendable {
    case speechTranscriber
    case dictationTranscriber
}

struct MeetingTranscriptionResult: Sendable {
    let range: CMTimeRange
    /// The SDK's primary hypothesis. Alternatives are retained for correction UI,
    /// never substituted using an incomparable per-run confidence average.
    let text: AttributedString
    let alternatives: [AttributedString]
    let isFinal: Bool
    let confidence: Double?
}

protocol MeetingTranscriptionSession: AnyObject, Sendable {
    var backend: MeetingTranscriptionBackend { get }
    var inputFormat: AVAudioFormat { get }
    var results: AsyncThrowingStream<MeetingTranscriptionResult, Error> { get }

    func analyze(_ input: AsyncStream<AnalyzerInput>) async throws
    func cancel() async
}

protocol MeetingTranscriptionSessionFactory: Sendable {
    func make(languageTag: String, purpose: MeetingTranscriptionPurpose) async throws -> any MeetingTranscriptionSession
}

enum MeetingTranscriptionCapability: Sendable, Equatable {
    case supported(resolvedLocaleIdentifier: String)
    case unavailable
    case unsupportedLocale
    case unsupportedAsset
}

enum MeetingTranscriptionError: LocalizedError, Sendable, Equatable {
    case unsupportedLocale(String)
    case backendUnavailable
    case staticAssetUnavailable(String)
    case assetInstallationFailed
    case incompatibleAudioFormat
    case setupFailed
    case runtimeFailed

    var errorDescription: String? {
        errorDescription(language: .current)
    }

    func errorDescription(language: AppLanguage) -> String {
        switch self {
        case .unsupportedLocale, .backendUnavailable:
            return AppLanguage.localized(
                "error.meeting.transcription.unsupported",
                defaultValue: language == .english
                    ? "Offline transcription is not supported for this language."
                    : "이 언어의 오프라인 전사를 지원하지 않습니다.",
                language: language,
                comment: "Meeting transcription error shown when offline transcription does not support the selected language."
            )
        case .staticAssetUnavailable:
            return AppLanguage.localized(
                "error.meeting.transcription.staticAssetUnavailable",
                defaultValue: language == .english
                    ? "A transcription model for this language is not available on this device."
                    : "이 기기에서 이 언어의 전사 모델을 사용할 수 없습니다.",
                language: language,
                comment: "Meeting transcription error shown when the required on-device model is unavailable."
            )
        case .assetInstallationFailed:
            return AppLanguage.localized(
                "error.meeting.transcription.assetInstallationFailed",
                defaultValue: language == .english
                    ? "The transcription model could not be prepared. Check your network connection and available storage, then try again."
                    : "전사 모델을 준비하지 못했습니다. 네트워크와 저장 공간을 확인한 뒤 다시 시도하세요.",
                language: language,
                comment: "Meeting transcription error shown when the transcription model cannot be installed."
            )
        case .incompatibleAudioFormat, .setupFailed:
            return AppLanguage.localized(
                "error.meeting.transcription.setupFailed",
                defaultValue: language == .english
                    ? "Transcription could not be started. Please try again later."
                    : "전사를 시작하지 못했습니다. 잠시 후 다시 시도하세요.",
                language: language,
                comment: "Meeting transcription error shown when transcription setup cannot start."
            )
        case .runtimeFailed:
            return AppLanguage.localized(
                "error.meeting.transcription.runtimeFailed",
                defaultValue: language == .english
                    ? "Transcription could not be completed. The recording was saved, so you can retry with accuracy prioritized."
                    : "전사를 완료하지 못했습니다. 녹음은 저장되었으니 정확도 우선 재전사를 시도하세요.",
                language: language,
                comment: "Meeting transcription error shown when transcription fails after setup."
            )
        }
    }
}

typealias MeetingTranscriptionCapabilityProbe = @Sendable (MeetingTranscriptionBackend, Locale) async -> MeetingTranscriptionCapability
typealias MeetingTranscriptionSessionBuilder = @Sendable (MeetingTranscriptionBackend, Locale, MeetingTranscriptionPurpose, UserVocabularySnapshot) async throws -> any MeetingTranscriptionSession

struct DefaultMeetingTranscriptionSessionFactory: MeetingTranscriptionSessionFactory {
    private let foundationModelsAvailable: @Sendable () async -> Bool
    private let capabilityProbe: MeetingTranscriptionCapabilityProbe
    private let sessionBuilder: MeetingTranscriptionSessionBuilder
    private let snapshotProvider: @Sendable () async -> UserVocabularySnapshot
    private let forcedBackend: MeetingTranscriptionBackend?

    init(
        foundationModelsAvailable: @escaping @Sendable () async -> Bool = {
            await MainActor.run { FoundationModelsAvailability.isAvailable }
        },
        capabilityProbe: @escaping MeetingTranscriptionCapabilityProbe = Self.liveCapabilityProbe,
        sessionBuilder: @escaping MeetingTranscriptionSessionBuilder = Self.liveSessionBuilder,
        snapshotProvider: @escaping @Sendable () async -> UserVocabularySnapshot = { .empty },
        forcedBackend: MeetingTranscriptionBackend? = Self.debugForcedBackend
    ) {
        self.foundationModelsAvailable = foundationModelsAvailable
        self.capabilityProbe = capabilityProbe
        self.sessionBuilder = sessionBuilder
        self.snapshotProvider = snapshotProvider
        self.forcedBackend = forcedBackend
    }

    func make(languageTag: String, purpose: MeetingTranscriptionPurpose) async throws -> any MeetingTranscriptionSession {
        let requestedLocale = Locale(identifier: languageTag)
        if let forcedBackend {
            return try await make(
                backend: forcedBackend,
                requestedLocale: requestedLocale,
                languageTag: languageTag,
                purpose: purpose,
                forced: true
            )
        }

        let primary: MeetingTranscriptionBackend = await foundationModelsAvailable() ? .speechTranscriber : .dictationTranscriber
        let secondary: MeetingTranscriptionBackend = primary == .speechTranscriber ? .dictationTranscriber : .speechTranscriber
        let primaryCapability = await capabilityProbe(primary, requestedLocale)
        if case .supported(let identifier) = primaryCapability {
            return try await build(primary, locale: Locale(identifier: identifier), purpose: purpose, forced: false)
        }

        let secondaryCapability = await capabilityProbe(secondary, requestedLocale)
        if case .supported(let identifier) = secondaryCapability {
            return try await build(secondary, locale: Locale(identifier: identifier), purpose: purpose, forced: false)
        }
        throw selectionError(
            languageTag: languageTag,
            capabilities: [primaryCapability, secondaryCapability]
        )
    }

    private func make(
        backend: MeetingTranscriptionBackend,
        requestedLocale: Locale,
        languageTag: String,
        purpose: MeetingTranscriptionPurpose,
        forced: Bool
    ) async throws -> any MeetingTranscriptionSession {
        let capability = await capabilityProbe(backend, requestedLocale)
        guard case .supported(let identifier) = capability else {
            throw selectionError(languageTag: languageTag, capabilities: [capability])
        }
        return try await build(backend, locale: Locale(identifier: identifier), purpose: purpose, forced: forced)
    }

    private func build(
        _ backend: MeetingTranscriptionBackend,
        locale: Locale,
        purpose: MeetingTranscriptionPurpose,
        forced: Bool
    ) async throws -> any MeetingTranscriptionSession {
        // Builder failures are operational. Do not conceal them by silently
        // switching an already-selected transcription backend.
        let session = try await sessionBuilder(backend, locale, purpose, await snapshotProvider())
        let logger = Logger(subsystem: "pieroot.todo", category: "MeetingTranscription")
        if forced {
            logger.notice("backend=\(backend.rawValue, privacy: .public), locale=\(locale.identifier, privacy: .public), forced=true")
            #if DEBUG
            print("SIFT_MEETING_SELECTOR backend=\(backend.rawValue) locale=\(locale.identifier) forced=true")
            #endif
        } else {
            let afmAvailable = await foundationModelsAvailable()
            logger.notice("afmAvailable=\(afmAvailable, privacy: .public), backend=\(backend.rawValue, privacy: .public), locale=\(locale.identifier, privacy: .public), forced=false")
            #if DEBUG
            print("SIFT_MEETING_SELECTOR afmAvailable=\(afmAvailable) backend=\(backend.rawValue) locale=\(locale.identifier) forced=false")
            #endif
        }
        return session
    }

    private func selectionError(
        languageTag: String,
        capabilities: [MeetingTranscriptionCapability]
    ) -> MeetingTranscriptionError {
        if capabilities.contains(.unsupportedAsset) {
            return .staticAssetUnavailable(languageTag)
        }
        if capabilities.contains(.unsupportedLocale) {
            return .unsupportedLocale(languageTag)
        }
        return .backendUnavailable
    }

    private static let liveCapabilityProbe: MeetingTranscriptionCapabilityProbe = { backend, requestedLocale in
        if backend == .speechTranscriber, !SpeechTranscriber.isAvailable {
            return .unavailable
        }
        let locale: Locale?
        switch backend {
        case .speechTranscriber:
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        case .dictationTranscriber:
            locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale)
        }
        guard let locale else { return .unsupportedLocale }
        let module: any SpeechModule
        switch backend {
        case .speechTranscriber:
            module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        case .dictationTranscriber:
            module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        }
        guard await AssetInventory.status(forModules: [module]) != .unsupported else {
            return .unsupportedAsset
        }
        return .supported(resolvedLocaleIdentifier: locale.identifier)
    }

    private static let liveSessionBuilder: MeetingTranscriptionSessionBuilder = { backend, locale, purpose, snapshot in
        do {
            switch backend {
            case .speechTranscriber:
                let transcriber: SpeechTranscriber
                switch purpose {
                case .live:
                    transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
                case .retry:
                    transcriber = SpeechTranscriber(
                        locale: locale,
                        transcriptionOptions: [],
                        reportingOptions: [.alternativeTranscriptions],
                        attributeOptions: [.audioTimeRange, .transcriptionConfidence]
                    )
                }
                return try await SpeechMeetingTranscriptionSession(transcriber: transcriber, snapshot: snapshot)
            case .dictationTranscriber:
                let transcriber: DictationTranscriber
                switch purpose {
                case .live:
                    var preset = DictationTranscriber.Preset.progressiveLongDictation
                    preset.reportingOptions.insert(.volatileResults)
                    preset.attributeOptions.formUnion([.audioTimeRange, .transcriptionConfidence])
                    transcriber = DictationTranscriber(locale: locale, preset: preset)
                case .retry:
                    var preset = DictationTranscriber.Preset.timeIndexedLongDictation
                    preset.reportingOptions.insert(.alternativeTranscriptions)
                    preset.attributeOptions.formUnion([.audioTimeRange, .transcriptionConfidence])
                    transcriber = DictationTranscriber(locale: locale, preset: preset)
                }
                return try await DictationMeetingTranscriptionSession(transcriber: transcriber, snapshot: snapshot)
            }
        } catch let error as MeetingTranscriptionError {
            throw error
        } catch {
            recordTranscriptionDiagnostic(error, operation: "sessionSetup")
            throw MeetingTranscriptionError.setupFailed
        }
    }

    private static var debugForcedBackend: MeetingTranscriptionBackend? {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-SIFTMeetingTranscriptionBackend"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return switch arguments[index + 1].lowercased() {
        case "speech": .speechTranscriber
        case "dictation": .dictationTranscriber
        default: nil
        }
        #else
        return nil
        #endif
    }
}

private protocol AppleMeetingTranscriptionSession: MeetingTranscriptionSession {
    var analyzer: SpeechAnalyzer { get }
    var collectorTask: Task<Void, Never>? { get }
    var resultContinuation: AsyncThrowingStream<MeetingTranscriptionResult, Error>.Continuation { get }
}

private extension AppleMeetingTranscriptionSession {
    func analyze(_ input: AsyncStream<AnalyzerInput>) async throws {
        do {
            let last = try await analyzer.analyzeSequence(input)
            if let last {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            await collectorTask?.value
        } catch is CancellationError {
            resultContinuation.finish()
            throw CancellationError()
        } catch {
            recordTranscriptionDiagnostic(error, operation: "analyze")
            resultContinuation.finish(throwing: MeetingTranscriptionError.runtimeFailed)
            throw MeetingTranscriptionError.runtimeFailed
        }
    }

    func cancel() async {
        await analyzer.cancelAndFinishNow()
        collectorTask?.cancel()
        resultContinuation.finish()
    }
}

private final class SpeechMeetingTranscriptionSession: AppleMeetingTranscriptionSession, @unchecked Sendable {
    let backend: MeetingTranscriptionBackend = .speechTranscriber
    let inputFormat: AVAudioFormat
    let analyzer: SpeechAnalyzer
    let results: AsyncThrowingStream<MeetingTranscriptionResult, Error>
    let resultContinuation: AsyncThrowingStream<MeetingTranscriptionResult, Error>.Continuation
    private(set) var collectorTask: Task<Void, Never>?
    private let transcriber: SpeechTranscriber

    init(transcriber: SpeechTranscriber, snapshot: UserVocabularySnapshot) async throws {
        self.transcriber = transcriber
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            recordTranscriptionDiagnostic(error, operation: "assetInstallation")
            throw MeetingTranscriptionError.assetInstallationFailed
        }
        guard let inputFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MeetingTranscriptionError.incompatibleAudioFormat
        }
        self.inputFormat = inputFormat
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        let stream = AsyncThrowingStream<MeetingTranscriptionResult, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.results = stream.stream
        self.resultContinuation = stream.continuation
        do {
            try await UserVocabularyBiasing.prepare(analyzer: analyzer, inputFormat: inputFormat, snapshot: snapshot)
        } catch {
            recordTranscriptionDiagnostic(error, operation: "vocabularyPreparation")
            throw MeetingTranscriptionError.setupFailed
        }
        collectorTask = Task { [transcriber, resultContinuation] in
            do {
                for try await result in transcriber.results {
                    switch resultContinuation.yield(Self.map(result)) {
                    case .enqueued:
                        continue
                    case .dropped:
                        resultContinuation.finish(throwing: MeetingTranscriptionError.runtimeFailed)
                        return
                    case .terminated:
                        return
                    @unknown default:
                        resultContinuation.finish(throwing: MeetingTranscriptionError.runtimeFailed)
                        return
                    }
                }
                resultContinuation.finish()
            } catch {
                recordTranscriptionDiagnostic(error, operation: "resultCollection")
                resultContinuation.finish(throwing: MeetingTranscriptionError.runtimeFailed)
            }
        }
    }

    private static func map(_ result: SpeechTranscriber.Result) -> MeetingTranscriptionResult {
        MeetingTranscriptionResult(
            range: result.range,
            text: result.text,
            alternatives: result.alternatives,
            isFinal: result.isFinal,
            confidence: averageConfidence(of: result.text)
        )
    }
}

private final class DictationMeetingTranscriptionSession: AppleMeetingTranscriptionSession, @unchecked Sendable {
    let backend: MeetingTranscriptionBackend = .dictationTranscriber
    let inputFormat: AVAudioFormat
    let analyzer: SpeechAnalyzer
    let results: AsyncThrowingStream<MeetingTranscriptionResult, Error>
    let resultContinuation: AsyncThrowingStream<MeetingTranscriptionResult, Error>.Continuation
    private(set) var collectorTask: Task<Void, Never>?
    private let transcriber: DictationTranscriber

    init(transcriber: DictationTranscriber, snapshot: UserVocabularySnapshot) async throws {
        self.transcriber = transcriber
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            recordTranscriptionDiagnostic(error, operation: "assetInstallation")
            throw MeetingTranscriptionError.assetInstallationFailed
        }
        guard let inputFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MeetingTranscriptionError.incompatibleAudioFormat
        }
        self.inputFormat = inputFormat
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        let stream = AsyncThrowingStream<MeetingTranscriptionResult, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.results = stream.stream
        self.resultContinuation = stream.continuation
        do {
            try await UserVocabularyBiasing.prepare(analyzer: analyzer, inputFormat: inputFormat, snapshot: snapshot)
        } catch {
            recordTranscriptionDiagnostic(error, operation: "vocabularyPreparation")
            throw MeetingTranscriptionError.setupFailed
        }
        collectorTask = Task { [transcriber, resultContinuation] in
            do {
                for try await result in transcriber.results {
                    switch resultContinuation.yield(Self.map(result)) {
                    case .enqueued:
                        continue
                    case .dropped:
                        resultContinuation.finish(throwing: MeetingTranscriptionError.runtimeFailed)
                        return
                    case .terminated:
                        return
                    @unknown default:
                        resultContinuation.finish(throwing: MeetingTranscriptionError.runtimeFailed)
                        return
                    }
                }
                resultContinuation.finish()
            } catch {
                recordTranscriptionDiagnostic(error, operation: "resultCollection")
                resultContinuation.finish(throwing: MeetingTranscriptionError.runtimeFailed)
            }
        }
    }

    private static func map(_ result: DictationTranscriber.Result) -> MeetingTranscriptionResult {
        MeetingTranscriptionResult(
            range: result.range,
            text: result.text,
            alternatives: result.alternatives,
            isFinal: result.isFinal,
            confidence: averageConfidence(of: result.text)
        )
    }
}

private func averageConfidence(of text: AttributedString) -> Double? {
    var total = 0.0
    var count = 0
    for run in text.runs {
        guard let confidence = run.transcriptionConfidence else { continue }
        total += confidence
        count += 1
    }
    return count == 0 ? nil : total / Double(count)
}

/// Converts canonical PCM to the analyzer's selected input format while preserving
/// resampler tail frames at end of stream.
nonisolated final class MeetingPCMConverter: @unchecked Sendable {
    enum ConversionError: Error {
        case unsupportedFormat
        case conversionFailed
    }

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ConversionError.unsupportedFormat
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 8
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw ConversionError.conversionFailed
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil else {
            throw conversionError ?? ConversionError.conversionFailed
        }
        return output.frameLength > 0 ? [output] : []
    }

    func finish() throws -> [AVAudioPCMBuffer] {
        var buffers = [AVAudioPCMBuffer]()
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else {
                throw ConversionError.conversionFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if output.frameLength > 0 { buffers.append(output) }
            if let conversionError { throw conversionError }
            switch status {
            case .endOfStream, .inputRanDry:
                return buffers
            case .haveData:
                continue
            case .error:
                throw ConversionError.conversionFailed
            @unknown default:
                throw ConversionError.conversionFailed
            }
        }
    }
}

/// Keeps best-effort live transcription isolated from the canonical recording
/// path. A bounded queue preserves the chronological prefix and reports any
/// saturation without ever stopping FLAC persistence.
nonisolated final class MeetingTranscriptionInputPipeline: @unchecked Sendable {
    typealias Consume = @Sendable (AnalyzerInput) -> AsyncStream<AnalyzerInput>.Continuation.YieldResult

    private enum TerminalRequest {
        case finish
        case cancel
    }

    private enum TerminalState: Equatable {
        case open
        case finishing
        case cancelling
        case completed
    }

    private let queue = DispatchQueue(label: "pieroot.todo.meeting.transcription-input", qos: .userInitiated)
    private let maximumQueuedBuffers: Int
    private let converter: MeetingPCMConverter
    private let consume: Consume
    private let failed: @Sendable (Error) -> Void
    private let lock = NSLock()
    private var accepting = true
    private var processAcceptedPrefix = true
    private var terminalRequest: TerminalRequest?
    private var terminalState: TerminalState = .open
    private var failure: Error?
    private var queuedBufferCount = 0
    private var waiters = [CheckedContinuation<Void, Never>]()

    init(
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        maximumQueuedBuffers: Int = 256,
        consume: @escaping Consume,
        failed: @escaping @Sendable (Error) -> Void
    ) throws {
        guard maximumQueuedBuffers > 0 else { throw MeetingTranscriptionError.runtimeFailed }
        self.maximumQueuedBuffers = maximumQueuedBuffers
        converter = try MeetingPCMConverter(inputFormat: inputFormat, outputFormat: outputFormat)
        self.consume = consume
        self.failed = failed
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        // Copy outside synchronization. Then reserve and schedule while holding
        // the terminal lock so a finish fence cannot overtake accepted work.
        guard let copied = buffer.copy() as? AVAudioPCMBuffer else {
            if recordFailure(MeetingTranscriptionError.runtimeFailed, stopProcessing: false) {
                failed(MeetingTranscriptionError.runtimeFailed)
            }
            return
        }

        lock.lock()
        guard accepting, queuedBufferCount < maximumQueuedBuffers else {
            let shouldReport = accepting
                ? recordFailureLocked(MeetingTranscriptionError.runtimeFailed, stopProcessing: false)
                : false
            lock.unlock()
            if shouldReport { failed(MeetingTranscriptionError.runtimeFailed) }
            return
        }
        queuedBufferCount += 1
        queue.async { [self, copied] in
            var processingError: Error?
            lock.lock()
            let shouldProcess = processAcceptedPrefix
            lock.unlock()
            if shouldProcess {
                do {
                    for converted in try converter.convert(copied) {
                        guard try yield(AnalyzerInput(buffer: converted)) else { break }
                    }
                } catch {
                    processingError = error
                }
            }
            lock.lock()
            queuedBufferCount -= 1
            lock.unlock()
            if let processingError, recordFailure(processingError, stopProcessing: true) {
                failed(processingError)
            }
        }
        lock.unlock()
    }

    func finish() async throws {
        beginTerminal(.finish)
        await waitForTerminal()
        let terminalResult = lock.withLock {
            (error: failure, request: terminalRequest)
        }
        let cancelled: Bool
        if case .cancel = terminalResult.request {
            cancelled = true
        } else {
            cancelled = false
        }
        if cancelled { throw CancellationError() }
        if let error = terminalResult.error { throw error }
    }

    func cancel() async {
        beginTerminal(.cancel)
        await waitForTerminal()
    }

    private func beginTerminal(_ request: TerminalRequest) {
        var scheduleFence = false
        lock.lock()
        if terminalState == .open {
            terminalRequest = request
            switch request {
            case .finish:
                terminalState = .finishing
            case .cancel:
                terminalState = .cancelling
                processAcceptedPrefix = false
            }
            accepting = false
            scheduleFence = true
        }
        lock.unlock()
        guard scheduleFence else { return }
        queue.async { [self] in
            var tailError: Error?
            lock.lock()
            let shouldDrain: Bool
            if case .finish = terminalRequest {
                shouldDrain = processAcceptedPrefix
            } else {
                shouldDrain = false
            }
            lock.unlock()
            if shouldDrain {
                do {
                    for converted in try converter.finish() {
                        guard try yield(AnalyzerInput(buffer: converted)) else { break }
                    }
                } catch {
                    tailError = error
                }
            }
            if let tailError, recordFailure(tailError, stopProcessing: true) {
                failed(tailError)
            }
            completeTerminal()
        }
    }

    /// Returns false when the consumer already finished. A closed live stream
    /// is not a recording failure; only dropping a bounded buffer is.
    private func yield(_ input: AnalyzerInput) throws -> Bool {
        switch consume(input) {
        case .enqueued:
            return true
        case .terminated:
            return false
        case .dropped:
            throw MeetingTranscriptionError.runtimeFailed
        @unknown default:
            throw MeetingTranscriptionError.runtimeFailed
        }
    }

    private func recordFailureLocked(_ error: Error, stopProcessing: Bool) -> Bool {
        accepting = false
        if stopProcessing { processAcceptedPrefix = false }
        guard failure == nil else { return false }
        failure = error
        return true
    }

    private func recordFailure(_ error: Error, stopProcessing: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordFailureLocked(error, stopProcessing: stopProcessing)
    }

    private func waitForTerminal() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if terminalState == .completed {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func completeTerminal() {
        lock.lock()
        terminalState = .completed
        let completions = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        for completion in completions { completion.resume() }
    }
}
