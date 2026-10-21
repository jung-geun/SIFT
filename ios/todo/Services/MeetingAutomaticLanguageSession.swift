@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Nil means no usable speech, never a request to substitute a locale.
typealias MeetingLiveLanguageDetector = @Sendable ([Float]) async throws -> String?

/// A source-local, bounded FIFO spans detection, Apple preparation and replay.
/// The audio writer only copies PCM. Detection and conversion run on the generic
/// executor; Apple pulls the FIFO with backpressure instead of a lossy replay burst.
nonisolated final class MeetingAutomaticLanguageSession: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case noSpeech, invalidLanguage, bufferLimit
    }

    static let detectionSampleLimit = 160_000
    static let maximumBufferedSamples = 16_000 * 120
    private static let maximumBuffers = 1_024
    static let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    let results: AsyncThrowingStream<MeetingTranscriptionResult, Error>
    private let output: AsyncThrowingStream<MeetingTranscriptionResult, Error>.Continuation
    private let detector: MeetingLiveLanguageDetector
    private let factory: any MeetingTranscriptionSessionFactory
    private let detected: @Sendable (String) -> Void
    private let lock = NSLock()
    private var buffers = [AVAudioPCMBuffer?](repeating: nil, count: maximumBuffers)
    private var head = 0
    private var count = 0
    private var bufferedSamples = 0
    private var ended = false
    private var cancelled = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Void, Never>?
    private var apple: (any MeetingTranscriptionSession)?

    init(factory: any MeetingTranscriptionSessionFactory, detector: @escaping MeetingLiveLanguageDetector,
         detected: @escaping @Sendable (String) -> Void) {
        self.factory = factory
        self.detector = detector
        self.detected = detected
        let stream = AsyncThrowingStream<MeetingTranscriptionResult, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        results = stream.stream
        output = stream.continuation
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let wake: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !ended, !cancelled, failure == nil else { return nil }
            guard buffer.format == Self.canonicalFormat,
                  count < Self.maximumBuffers,
                  frames <= Self.maximumBufferedSamples - bufferedSamples,
                  let copy = buffer.copy() as? AVAudioPCMBuffer else {
                failure = Failure.bufferLimit
                let wake = waiter; waiter = nil
                return wake
            }
            buffers[(head + count) % Self.maximumBuffers] = copy
            count += 1
            bufferedSamples += frames
            let wake = waiter; waiter = nil
            return wake
        }
        wake?.resume()
    }

    func finishInput() {
        let wake = lock.withLock {
            ended = true
            let wake = waiter; waiter = nil
            return wake
        }
        wake?.resume()
    }

    private func requestCancellation() -> (any MeetingTranscriptionSession)? {
        let state = lock.withLock {
            cancelled = true
            ended = true
            for index in 0..<count { buffers[(head + index) % Self.maximumBuffers] = nil }
            count = 0
            bufferedSamples = 0
            let wake = waiter; waiter = nil
            return (wake, apple)
        }
        state.0?.resume()
        output.finish()
        return state.1
    }

    func cancel() async { await requestCancellation()?.cancel() }

    @concurrent
    func run() async throws {
        try await withTaskCancellationHandler {
            try await performRun()
        } onCancel: {
            let session = self.requestCancellation()
            Task { await session?.cancel() }
        }
    }

    @concurrent
    private func performRun() async throws {
        defer { lock.withLock { apple = nil } }
        do {
            var estimatedSamples = 0
            var language: String?
            repeat {
                let prefix = try await detectionPrefix(after: estimatedSamples)
                try Task.checkCancellation()
                guard !prefix.isEmpty else { throw Failure.noSpeech }
                language = try await detector(prefix)
                estimatedSamples += prefix.count
                // No evidence in the opening window is not evidence that this
                // source will never speak. Wait for the next source-local window;
                // keep ALL buffered audio for the eventual Apple handoff.
            } while language == nil
            guard let language else { throw Failure.noSpeech }
            try checkState()
            guard let code = MeetingLanguageCatalog.whisperLanguageCode(for: language) else {
                throw Failure.invalidLanguage
            }
            detected(code)
            // Factory capability resolution is authoritative: no English/system
            // locale substitution, and no artificial transcription backend case.
            let session = try await factory.make(languageTag: code, purpose: .live)
            let admitted = lock.withLock {
                guard !cancelled, failure == nil else { return false }
                apple = session
                return true
            }
            guard admitted, !Task.isCancelled else {
                await session.cancel()
                throw CancellationError()
            }
            let inputFormat = await session.inputFormat
            let results = await session.results
            let reader = try Reader(owner: self, outputFormat: inputFormat)
            let stream = AsyncStream<AnalyzerInput>(unfolding: { await reader.next() })
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await session.analyze(stream) }
                group.addTask { [output, results] in
                    for try await result in results {
                        try Task.checkCancellation()
                        switch output.yield(result) {
                        case .enqueued: break
                        case .terminated: return
                        case .dropped: throw MeetingTranscriptionError.runtimeFailed
                        @unknown default: throw MeetingTranscriptionError.runtimeFailed
                        }
                    }
                }
                do { while let _ = try await group.next() {} }
                catch {
                    // Child-task cancellation cannot wake a continuation that
                    // is waiting for the next audio buffer on its own.
                    finishInput()
                    group.cancelAll()
                    await session.cancel()
                    throw error
                }
            }
            try checkState()
            output.finish()
        } catch {
            let session = lock.withLock {
                failure = failure ?? error
                ended = true
                for index in 0..<count { buffers[(head + index) % Self.maximumBuffers] = nil }
                count = 0
                bufferedSamples = 0
                let wake = waiter; waiter = nil
                wake?.resume()
                return apple
            }
            await session?.cancel()
            output.finish(throwing: error)
            throw error
        }
    }

    private func checkState() throws {
        try Task.checkCancellation()
        try lock.withLock {
            if cancelled { throw CancellationError() }
            if let failure { throw failure }
        }
    }

    private func waitForChange(minimumSamples: Int) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if ended || cancelled || failure != nil || bufferedSamples >= minimumSamples { return true }
                waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    @concurrent
    private func detectionPrefix(after estimatedSamples: Int) async throws -> [Float] {
        while true {
            try checkState()
            let prefix: [(buffer: AVAudioPCMBuffer, firstFrame: Int)]? = lock.withLock {
                guard ended || bufferedSamples - estimatedSamples >= Self.detectionSampleLimit else { return nil }
                var prefix: [(buffer: AVAudioPCMBuffer, firstFrame: Int)] = []
                var skipped = estimatedSamples
                var samples = 0
                for index in 0..<count {
                    guard let buffer = buffers[(head + index) % Self.maximumBuffers] else { break }
                    let frames = Int(buffer.frameLength)
                    if skipped >= frames { skipped -= frames; continue }
                    prefix.append((buffer, skipped))
                    samples += frames - skipped
                    skipped = 0
                    if samples >= Self.detectionSampleLimit { break }
                }
                return prefix
            }
            if let prefix {
                var samples: [Float] = []
                samples.reserveCapacity(Self.detectionSampleLimit)
                for (buffer, firstFrame) in prefix {
                    guard let channel = buffer.int16ChannelData?[0] else { throw Failure.bufferLimit }
                    let end = min(Int(buffer.frameLength), firstFrame + Self.detectionSampleLimit - samples.count)
                    for index in firstFrame..<end {
                        samples.append(Float(channel[index]) / 32_768)
                    }
                }
                return samples
            }
            await waitForChange(minimumSamples: estimatedSamples + Self.detectionSampleLimit)
        }
    }

    private func nextBuffer() async throws -> AVAudioPCMBuffer? {
        while true {
            try checkState()
            let state = lock.withLock { () -> (AVAudioPCMBuffer?, Bool) in
                guard count > 0 else { return (nil, ended) }
                let buffer = buffers[head]
                buffers[head] = nil
                head = (head + 1) % Self.maximumBuffers
                count -= 1
                bufferedSamples -= Int(buffer?.frameLength ?? 0)
                return (buffer, false)
            }
            if let buffer = state.0 { return buffer }
            if state.1 { return nil }
            await waitForChange(minimumSamples: 1)
        }
    }

    /// One unfolding stream consumer owns the converter and its bounded tail.
    private nonisolated final class Reader: @unchecked Sendable {
        let owner: MeetingAutomaticLanguageSession
        let converter: MeetingPCMConverter?
        var outputSamples: Int64 = 0
        var pending: [AVAudioPCMBuffer] = []
        var finished = false

        init(owner: MeetingAutomaticLanguageSession, outputFormat: AVAudioFormat) throws {
            self.owner = owner
            converter = outputFormat == MeetingAutomaticLanguageSession.canonicalFormat ? nil : try MeetingPCMConverter(
                inputFormat: MeetingAutomaticLanguageSession.canonicalFormat, outputFormat: outputFormat)
        }

        @concurrent
        func next() async -> AnalyzerInput? {
            do {
                while pending.isEmpty && !finished {
                    if let buffer = try await owner.nextBuffer() {
                        pending = try converter?.convert(buffer) ?? [buffer]
                    } else {
                        finished = true
                        pending = try converter?.finish() ?? []
                    }
                }
                guard !pending.isEmpty else { return nil }
                let buffer = pending.removeFirst()
                let start = CMTime(value: outputSamples, timescale: CMTimeScale(buffer.format.sampleRate))
                outputSamples += Int64(buffer.frameLength)
                return AnalyzerInput(buffer: buffer, bufferStartTime: start)
            } catch {
                owner.lock.withLock { owner.failure = owner.failure ?? error }
                return nil
            }
        }
    }
}
