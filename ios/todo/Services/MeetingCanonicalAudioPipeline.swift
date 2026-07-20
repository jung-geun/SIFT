import AVFoundation
import Foundation

/// Moves work out of AVAudioEngine's realtime tap and emits only canonical
/// 16-kHz, mono, interleaved PCM16 buffers. The caller owns persistence,
/// analyzer input, overlap buffering, and part rotation on this serial queue.
///
/// Each accepted tap buffer is copied before the realtime callback returns.
/// The pipeline owns that copy until `consume` returns; its converter produces
/// a fresh output buffer for each input.
struct MeetingAudioPipelineMetrics: Sendable {
    let capacity: Int
    let highWaterMark: Int
}

final class MeetingCanonicalAudioPipeline: @unchecked Sendable {
    typealias CanonicalBufferHandler = @Sendable (AVAudioPCMBuffer) throws -> Void
    typealias DropHandler = @Sendable (Error) -> Void

    enum PipelineError: Error {
        case unsupportedInputFormat
        case invalidQueueCapacity
        case conversionFailed
        case bufferCopyFailed
        case queueOverflow
    }

    private enum TerminalRequest {
        case finish
        case cancel
    }

    private enum TerminalState {
        case open
        case finishing
        case cancelling
        case completed
    }

    private let queue = DispatchQueue(label: "pieroot.todo.meeting.canonical-audio", qos: .userInitiated)
    private let permits: DispatchSemaphore
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let consume: CanonicalBufferHandler
    private let dropped: DropHandler
    private let stateLock = NSLock()
    private let capacity: Int
    private var acceptingBuffers = true
    private var processAcceptedPrefix = true
    private var terminalState: TerminalState = .open
    private var terminalRequest: TerminalRequest?
    private var terminalError: Error?
    private var queuedBuffers = 0
    private var highWaterMark = 0
    private var terminalWaiters = [CheckedContinuation<Void, Never>]()

    init(
        inputFormat: AVAudioFormat,
        maximumQueuedBuffers: Int = 256,
        consume: @escaping CanonicalBufferHandler,
        dropped: @escaping DropHandler
    ) throws {
        guard maximumQueuedBuffers > 0 else { throw PipelineError.invalidQueueCapacity }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw PipelineError.unsupportedInputFormat
        }
        self.outputFormat = outputFormat
        self.converter = converter
        self.permits = DispatchSemaphore(value: maximumQueuedBuffers)
        self.capacity = maximumQueuedBuffers
        self.consume = consume
        self.dropped = dropped
    }

    func enqueueTapBuffer(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let accepting = acceptingBuffers
        stateLock.unlock()
        guard accepting else { return }
        guard permits.wait(timeout: .now()) == .success else {
            stateLock.lock()
            let shouldReport = acceptingBuffers
                ? recordFailureLocked(PipelineError.queueOverflow, stopProcessing: false)
                : false
            stateLock.unlock()
            if shouldReport {
                dropped(PipelineError.queueOverflow)
            }
            return
        }

        stateLock.lock()
        guard acceptingBuffers else {
            stateLock.unlock()
            permits.signal()
            return
        }
        guard let copied = buffer.copy() as? AVAudioPCMBuffer else {
            let shouldReport = recordFailureLocked(PipelineError.bufferCopyFailed, stopProcessing: false)
            stateLock.unlock()
            permits.signal()
            if shouldReport {
                dropped(PipelineError.bufferCopyFailed)
            }
            return
        }
        queuedBuffers += 1
        highWaterMark = max(highWaterMark, queuedBuffers)
        queue.async { [self, copied] in
            var processingError: Error?
            stateLock.lock()
            let shouldProcess = processAcceptedPrefix
            stateLock.unlock()
            if shouldProcess {
                do {
                    try consume(convert(copied))
                } catch {
                    processingError = error
                }
            }
            releasePermit()
            if let processingError, recordFailure(processingError, stopProcessing: true) {
                dropped(processingError)
            }
        }
        stateLock.unlock()
    }

    /// Drains all buffers accepted before the first terminal condition. The
    /// converter tail is emitted once only after the queue reaches this fence.
    func finish() async throws {
        beginTerminal(.finish)
        await waitForTerminal()
        let (error, cancelled) = stateLock.withLock {
            var cancelled = false
            if case .some(.cancel) = terminalRequest { cancelled = true }
            return (terminalError, cancelled)
        }
        if cancelled { throw CancellationError() }
        if let error { throw error }
    }

    /// Makes cancellation win only if it reaches the terminal gate first.
    /// Queued work is skipped, but every permit is still released exactly once.
    func cancel() async {
        beginTerminal(.cancel)
        await waitForTerminal()
    }

    func metrics() -> MeetingAudioPipelineMetrics {
        stateLock.lock()
        defer { stateLock.unlock() }
        return MeetingAudioPipelineMetrics(capacity: capacity, highWaterMark: highWaterMark)
    }

    private func beginTerminal(_ request: TerminalRequest) {
        var scheduleFence = false
        stateLock.lock()
        switch terminalState {
        case .open:
            terminalRequest = request
            switch request {
            case .finish:
                terminalState = .finishing
            case .cancel:
                terminalState = .cancelling
                processAcceptedPrefix = false
            }
            acceptingBuffers = false
            scheduleFence = true
        case .finishing, .cancelling, .completed:
            break
        }
        stateLock.unlock()

        guard scheduleFence else { return }
        queue.async { [self] in
            var tailError: Error?
            stateLock.lock()
            var shouldDrain = false
            if case .some(.finish) = terminalRequest {
                shouldDrain = processAcceptedPrefix
            }
            stateLock.unlock()
            if shouldDrain {
                do {
                    try drainConverter()
                } catch {
                    tailError = error
                }
            }
            if let tailError, recordFailure(tailError, stopProcessing: true) {
                dropped(tailError)
            }
            completeTerminal()
        }
    }

    private func waitForTerminal() async {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            if case .completed = terminalState {
                stateLock.unlock()
                continuation.resume()
            } else {
                terminalWaiters.append(continuation)
                stateLock.unlock()
            }
        }
    }

    private func completeTerminal() {
        stateLock.lock()
        terminalState = .completed
        let waiters = terminalWaiters
        terminalWaiters.removeAll(keepingCapacity: false)
        stateLock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    /// Stores only the first terminal error while `stateLock` is already held.
    private func recordFailureLocked(_ error: Error, stopProcessing: Bool) -> Bool {
        acceptingBuffers = false
        if stopProcessing { processAcceptedPrefix = false }
        guard terminalError == nil else { return false }
        terminalError = error
        return true
    }

    /// Returns true only for the first error, which is the only error surfaced
    /// to the caller and passed to the coordinator.
    private func recordFailure(_ error: Error, stopProcessing: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        acceptingBuffers = false
        if stopProcessing { processAcceptedPrefix = false }
        guard terminalError == nil else { return false }
        terminalError = error
        return true
    }

    private func releasePermit() {
        stateLock.lock()
        queuedBuffers -= 1
        stateLock.unlock()
        permits.signal()
    }

    private func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 8
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw PipelineError.conversionFailed
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
        guard status != .error, conversionError == nil, output.frameLength > 0 else {
            throw conversionError ?? PipelineError.conversionFailed
        }
        return output
    }

    private func drainConverter() throws {
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else {
                throw PipelineError.conversionFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if output.frameLength > 0 { try consume(output) }
            if let conversionError { throw conversionError }
            switch status {
            case .endOfStream, .inputRanDry:
                return
            case .error:
                throw PipelineError.conversionFailed
            case .haveData:
                continue
            @unknown default:
                throw PipelineError.conversionFailed
            }
        }
    }
}
