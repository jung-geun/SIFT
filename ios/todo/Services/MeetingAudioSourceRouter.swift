@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Local recording metadata only. Never log selection strings.
nonisolated struct MeetingCaptureSourceMetadata: Codable, Equatable, Sendable {
    let boundaries: [MeetingCaptureSourceBoundary]
}

nonisolated struct MeetingCaptureSourceBoundary: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case microphone, appAudio }
    enum Action: String, Codable, Sendable { case enabled, disabled, paused, resumed, selection }
    let sample: Int64
    let source: Source
    let action: Action
    let selection: String?
}

/// Independently normalizes up to one microphone and four application tracks to
/// 16-kHz mono PCM16. No samples from different sources are ever combined or
/// attenuated. Each child starts at local zero; its origin is on the group's
/// monotonic clock, which excludes pauses. Missing input is real silence.
///
/// consume BORROWS one reused 20-ms output buffer on the serial queue. Copy or
/// consume it synchronously; do not retain it or wait synchronously for controls.
/// Disable revokes only that source's uncommitted PCM and converter history.
/// close/finish instead close admission first, then drain the accepted prefix.
nonisolated final class MeetingAudioSourceRouter: @unchecked Sendable {
    enum Source: Hashable, Sendable {
        case microphone, appAudio, application(String)
        var metadataSource: MeetingCaptureSourceBoundary.Source {
            self == .microphone ? .microphone : .appAudio
        }
    }
    enum RouterError: Error {
        case invalidConfiguration, unsupportedInputFormat, bufferCopyFailed
        case conversionFailed, queueOverflow, sourceLimitReached
    }
    typealias BufferHandler = @Sendable (Source, AVAudioPCMBuffer) throws -> Void
    typealias FailureHandler = @Sendable (Source, Error) -> Void

    struct DeliveryMetrics: Sendable {
        let microphoneBuffers: Int64
        let appAudioBuffers: Int64
    }
    struct SourceLevels: Sendable {
        let microphoneRMS: Double
        let appAudioRMS: Double
    }
    struct MeterSnapshot: Sendable {
        /// Group media clock, including silence and excluding every pause.
        let elapsedSamples: Int64
        let levels: [Source: Double]
    }
    private nonisolated struct Level {
        var rms = 0.0
        var updatedAt = 0.0
    }
    private nonisolated final class Epoch: @unchecked Sendable {
        let hostStart: Double
        let sampleStart: Int64
        var hostStop: Double? // admission lock
        init(_ hostStart: Double, sampleStart: Int64) {
            self.hostStart = hostStart
            self.sampleStart = sampleStart
        }
    }
    private nonisolated final class Conversion {
        var revision: UInt64 = 0
        var epoch: Epoch?
        var converter: AVAudioConverter?
        var format: AVAudioFormat?
        var output: AVAudioPCMBuffer?
        var nextSample: Int64 = 0
        var expectedHostTime: Double = 0
        var endSample: Int64 = 0
        func reset() {
            converter = nil
            format = nil
            output = nil
            epoch = nil
        }
    }
    private nonisolated final class Lane: @unchecked Sendable {
        let source: Source
        let origin: Int64
        let core: MeetingAudioSourceRouterCore
        let conversion = Conversion() // serial queue only
        // Everything below is protected by the admission/commit lock.
        var enabled: Bool
        var revision: UInt64 = 0
        var openedAt: Double
        var closingAt: Double?
        var finished = false
        var failure: Error?
        var selection: String?
        var level = Level()
        var committed: Int64
        var boundaries = [MeetingCaptureSourceBoundary]()
        init(source: Source, origin: Int64, hostTime: Double, enabled: Bool) {
            self.source = source
            self.origin = origin
            self.openedAt = hostTime
            self.enabled = enabled
            self.committed = origin
            self.core = MeetingAudioSourceRouterCore(capacity: 32_000, cursor: origin)
        }
    }
    private nonisolated enum Terminal: Equatable { case finish, cancel }
    private let queue = DispatchQueue(label: "pieroot.todo.meeting.source-router", qos: .userInitiated)
    private let lock = NSLock()
    private let format: AVAudioFormat
    private let output: AVAudioPCMBuffer
    private let consume: BufferHandler
    private let failed: FailureHandler
    private let clock: @Sendable () -> Double
    private let automaticallyRenders: Bool
    private let maximumQueuedBuffers: Int
    private let renderLatency: Double
    private var timer: DispatchSourceTimer?
    // Fixed slots bound converter, ring and output memory even across replacements.
    private var lanes = [Lane?](repeating: nil, count: 5)
    private var activeEpoch: Epoch?
    private var queueEpoch: Epoch? // serial queue only
    private var started = false
    private var terminal: Terminal?
    private var queuedBuffers = 0
    private var highWaterMark = 0
    private var microphoneBuffers: Int64 = 0
    private var appAudioBuffers: Int64 = 0
    private var committedSamples: Int64 = 0
    private var pausedSample: Int64 = 0
    private let blockFrames = 320
    private static let maximumInputBytes = 1_048_576

    init(maximumQueuedBuffers: Int = 32, automaticallyRenders: Bool = true,
         renderLatency: Double = 0.2,
         clock: @escaping @Sendable () -> Double = { CMClockGetTime(CMClockGetHostTimeClock()).seconds },
         consume: @escaping BufferHandler, failed: @escaping FailureHandler) throws {
        guard maximumQueuedBuffers > 0, maximumQueuedBuffers <= 256,
              renderLatency.isFinite, renderLatency >= 0, renderLatency <= 1,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320) else {
            throw RouterError.invalidConfiguration
        }
        self.maximumQueuedBuffers = maximumQueuedBuffers
        self.automaticallyRenders = automaticallyRenders
        self.renderLatency = renderLatency
        self.clock = clock
        self.consume = consume
        self.failed = failed
        self.format = format
        self.output = output
    }
    deinit { timer?.cancel() }

    // Helpers with Locked suffix require the admission lock.
    private func laneLocked(_ source: Source) -> Lane? {
        for lane in lanes { if lane?.source == source { return lane } }
        return nil
    }
    private func createLaneLocked(_ source: Source, hostTime: Double, enabled: Bool) -> Lane? {
        let slot: Int?
        if source == .microphone { slot = lanes[0] == nil ? 0 : nil }
        else { slot = (1..<lanes.count).first { lanes[$0] == nil } }
        guard let slot else { return nil }
        let lane = Lane(source: source, origin: max(committedSamples, mediaSampleLocked(hostTime)),
                        hostTime: hostTime, enabled: enabled)
        lanes[slot] = lane
        if started { appendBoundaryLocked(lane, sample: lane.origin, action: enabled ? .enabled : .disabled) }
        return lane
    }
    func start(hostTime: Double, microphoneEnabled: Bool) {
        guard hostTime.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !started, terminal == nil else { return }
        let epoch = Epoch(hostTime, sampleStart: 0)
        activeEpoch = epoch
        if microphoneEnabled {
            let microphone = laneLocked(.microphone) ?? createLaneLocked(.microphone, hostTime: hostTime, enabled: true)
            microphone?.enabled = true
        }
        laneLocked(.microphone)?.enabled = microphoneEnabled
        started = true
        for case let lane? in lanes {
            lane.openedAt = max(hostTime, lane.openedAt)
            appendBoundaryLocked(lane, sample: lane.origin, action: lane.enabled ? .enabled : .disabled)
            if let selection = lane.selection { appendBoundaryLocked(lane, sample: lane.origin, action: .selection, selection: selection) }
        }
        queue.async { [self] in queueEpoch = epoch }
        if automaticallyRenders {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.renderCurrent(hostTime: self.clock())
            }
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
            self.timer = timer
            timer.resume()
        }
    }
    func setEnabled(_ enabled: Bool, source: Source, hostTime: Double) {
        guard hostTime.isFinite else { return }
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        guard let lane = laneLocked(source) ?? (enabled ? createLaneLocked(source, hostTime: hostTime, enabled: true) : nil) else {
            lock.unlock()
            if enabled { failed(source, RouterError.sourceLimitReached) }
            return
        }
        guard !lane.finished, lane.failure == nil, lane.closingAt == nil else { lock.unlock(); return }
        // A newly created enabled lane already has its initial boundary.
        if lane.enabled != enabled {
            lane.enabled = enabled
            lane.revision &+= 1
            lane.openedAt = enabled ? hostTime : .infinity
            if !enabled { lane.level = Level() }
            if started {
                let sample = enabled ? max(lane.origin, mediaSampleLocked(hostTime)) : lane.committed
                if !enabled {
                    lane.boundaries.removeAll { $0.sample >= sample - lane.origin && ($0.action == .enabled || $0.action == .selection) }
                }
                appendBoundaryLocked(lane, sample: sample, action: enabled ? .enabled : .disabled)
                if enabled, let selection = lane.selection { appendBoundaryLocked(lane, sample: sample, action: .selection, selection: selection) }
            }
            queue.async { lane.core.clear(); lane.conversion.reset() }
        }
        lock.unlock()
    }
    func setSelection(_ selection: String?, source: Source, hostTime: Double) {
        guard hostTime.isFinite else { return }
        lock.withLock {
            guard terminal == nil,
                  let lane = laneLocked(source) ?? createLaneLocked(source, hostTime: hostTime, enabled: false),
                  !lane.finished, lane.selection != selection else { return }
            lane.selection = selection
            if started { appendBoundaryLocked(lane, sample: mediaSampleLocked(hostTime), action: .selection, selection: selection) }
        }
    }
    func sessionStartSample(for source: Source) -> Int64? { lock.withLock { laneLocked(source)?.origin } }

    func enqueue(_ buffer: AVAudioPCMBuffer, source: Source, hostTime: Double) {
        enqueue(buffer, source: source, hostTime: hostTime, takingOwnership: false)
    }
    /// Producer transfers ownership and must not reuse the buffer afterward.
    func enqueueOwned(_ buffer: AVAudioPCMBuffer, source: Source, hostTime: Double) {
        enqueue(buffer, source: source, hostTime: hostTime, takingOwnership: true)
    }
    private func enqueue(_ buffer: AVAudioPCMBuffer, source: Source, hostTime: Double, takingOwnership: Bool) {
        lock.lock()
        guard terminal == nil, let epoch = activeEpoch, let lane = laneLocked(source),
              lane.enabled, lane.failure == nil, lane.closingAt == nil, !lane.finished,
              hostTime.isFinite, hostTime >= max(epoch.hostStart, lane.openedAt), buffer.frameLength > 0 else {
            lock.unlock(); return
        }
        let revision = lane.revision
        let inputFormat = buffer.format
        let byteCount = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).reduce(0) { $0 + Int($1.mDataByteSize) }
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate >= 8_000, inputFormat.sampleRate <= 192_000,
              inputFormat.channelCount > 0, inputFormat.channelCount <= 8,
              Double(buffer.frameLength) / inputFormat.sampleRate <= 0.5,
              byteCount <= Self.maximumInputBytes else {
            lock.unlock(); recordFailure(RouterError.unsupportedInputFormat, lane: lane, revision: revision); return
        }
        guard queuedBuffers < maximumQueuedBuffers else {
            lock.unlock(); recordFailure(RouterError.queueOverflow, lane: lane, revision: revision); return
        }
        guard let copied = takingOwnership ? buffer : Self.copyInput(buffer) else {
            lock.unlock(); recordFailure(RouterError.bufferCopyFailed, lane: lane, revision: revision); return
        }
        queuedBuffers += 1
        highWaterMark = max(highWaterMark, queuedBuffers)
        if source == .microphone { microphoneBuffers += 1 } else { appAudioBuffers += 1 }
        queue.async { [self, copied] in
            defer { lock.withLock { queuedBuffers -= 1 } }
            do { try process(copied, lane: lane, hostTime: hostTime, epoch: epoch, revision: revision) }
            catch { recordFailure(error, lane: lane, revision: revision) }
        }
        lock.unlock()
    }

    func pause(hostTime: Double) {
        guard hostTime.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        guard terminal == nil, let epoch = activeEpoch else { return }
        epoch.hostStop = max(epoch.hostStart, hostTime)
        pausedSample = max(committedSamples, mediaSampleLocked(hostTime))
        for case let lane? in lanes where !lane.finished {
            lane.level = Level()
            appendBoundaryLocked(lane, sample: pausedSample, action: .paused)
        }
        activeEpoch = nil
        queue.async { [self] in closeEpoch(epoch) }
    }
    func resume(hostTime: Double) {
        guard hostTime.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        guard started, terminal == nil, activeEpoch == nil else { return }
        let epoch = Epoch(hostTime, sampleStart: pausedSample)
        activeEpoch = epoch
        for case let lane? in lanes where !lane.finished {
            appendBoundaryLocked(lane, sample: pausedSample, action: .resumed)
        }
        queue.async { [self] in queueEpoch = epoch }
    }
    /// Normal source stop: close admission immediately, retain accepted prefix.
    func close(source: Source, hostTime: Double) {
        guard hostTime.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        guard terminal == nil, let lane = laneLocked(source), !lane.finished, lane.closingAt == nil else { return }
        lane.closingAt = hostTime
        lane.level = Level()
        let target = max(lane.committed, mediaSampleLocked(hostTime))
        queue.async { [self] in
            do {
                try drain(lane.conversion, lane: lane)
                try emit(lane, through: target, completeBlocksOnly: false)
            } catch { recordFailure(error, lane: lane) }
            lane.conversion.reset()
            lane.core.clear()
            lock.withLock { lane.finished = true }
        }
    }
    /// Privacy/source replacement revokes own pending PCM. If normal close has
    /// already fenced admission, release queues behind its prefix-preserving
    /// drain instead. Returns finalized metadata and frees the source slot.
    func retire(source: Source, hostTime: Double) async throws -> MeetingCaptureSourceMetadata {
        guard hostTime.isFinite else { throw RouterError.invalidConfiguration }
        let lane: Lane? = lock.withLock {
            guard let lane = laneLocked(source) else { return nil }
            if lane.closingAt == nil {
                lane.enabled = false
                lane.finished = true
                lane.revision &+= 1
                lane.boundaries.removeAll { $0.sample >= lane.committed - lane.origin && ($0.action == .enabled || $0.action == .selection) }
                appendBoundaryLocked(lane, sample: lane.committed, action: .disabled)
            }
            lane.level = Level()
            return lane
        }
        guard let lane else { return MeetingCaptureSourceMetadata(boundaries: []) }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                lane.core.clear()
                lane.conversion.reset()
                let metadata = lock.withLock {
                    lane.finished = true
                    let result = metadataLocked(lane)
                    for index in lanes.indices where lanes[index] === lane { lanes[index] = nil }
                    return result
                }
                continuation.resume(returning: metadata)
            }
        }
    }
    func render(hostTime: Double) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in renderCurrent(hostTime: hostTime); continuation.resume() }
        }
    }
    func finish(hostTime: Double) async throws {
        beginTerminal(.finish, hostTime: hostTime)
        await fence()
        if lock.withLock({ terminal == .cancel }) { throw CancellationError() }
        // Source-local errors have already been delivered with their identity.
    }
    func cancel() async { beginTerminal(.cancel, hostTime: 0); await fence() }
    private func beginTerminal(_ request: Terminal, hostTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard terminal == nil else { return }
        terminal = request
        timer?.cancel()
        timer = nil
        let epoch = activeEpoch
        if let epoch { epoch.hostStop = hostTime.isFinite ? max(epoch.hostStart, hostTime) : epoch.hostStart }
        activeEpoch = nil
        for case let lane? in lanes { lane.level = Level() }
        queue.async { [self] in
            if request == .finish, let epoch { closeEpoch(epoch) }
            for index in 0..<5 {
                guard let lane = lock.withLock({ lanes[index] }) else { continue }
                lane.conversion.reset()
                lane.core.clear()
                lock.withLock { lane.finished = true }
            }
        }
    }
    func metrics() -> MeetingAudioPipelineMetrics {
        lock.withLock { MeetingAudioPipelineMetrics(capacity: maximumQueuedBuffers, highWaterMark: highWaterMark) }
    }
    func deliveryMetrics() -> DeliveryMetrics {
        lock.withLock { DeliveryMetrics(microphoneBuffers: microphoneBuffers, appAudioBuffers: appAudioBuffers) }
    }
    func sourceLevels() -> SourceLevels {
        let now = clock()
        return lock.withLock {
            var mic = 0.0, app = 0.0
            for case let lane? in lanes {
                let rms = meterLevelLocked(lane, now: now)
                if lane.source == .microphone { mic = rms } else { app = max(app, rms) }
            }
            return SourceLevels(microphoneRMS: mic, appAudioRMS: app)
        }
    }
    /// Poll off the audio callback. Only the existing RMS scalar is sampled;
    /// separate application lanes never share their aggregate UI maximum.
    func meterSnapshot() -> MeterSnapshot {
        let now = clock()
        return lock.withLock {
            var levels: [Source: Double] = [:]
            levels.reserveCapacity(5)
            for case let lane? in lanes { levels[lane.source] = meterLevelLocked(lane, now: now) }
            return MeterSnapshot(elapsedSamples: mediaSampleLocked(now), levels: levels)
        }
    }
    private func meterLevelLocked(_ lane: Lane, now: Double) -> Double {
        guard started, terminal == nil, activeEpoch != nil, lane.enabled,
              !lane.finished, lane.failure == nil, lane.closingAt == nil else { return 0 }
        let age = now - lane.level.updatedAt
        return age >= 0 && age < 0.5 ? lane.level.rms : 0
    }
    func captureSourceMetadata(for source: Source) async -> MeetingCaptureSourceMetadata {
        await fence()
        return lock.withLock { laneLocked(source).map(metadataLocked) ?? MeetingCaptureSourceMetadata(boundaries: []) }
    }
    private func metadataLocked(_ lane: Lane) -> MeetingCaptureSourceMetadata {
        let endpoint = max(0, lane.committed - lane.origin)
        let indexed = lane.boundaries.enumerated().map { index, boundary in
            (index, MeetingCaptureSourceBoundary(sample: min(boundary.sample, endpoint), source: boundary.source,
                                                 action: boundary.action, selection: boundary.selection))
        }
        return MeetingCaptureSourceMetadata(boundaries: indexed.sorted {
            $0.1.sample == $1.1.sample ? $0.0 < $1.0 : $0.1.sample < $1.1.sample
        }.map { $0.1 })
    }
    private func mediaSampleLocked(_ hostTime: Double) -> Int64 {
        guard let epoch = activeEpoch else { return pausedSample }
        return epoch.sampleStart + Self.sampleOffset(hostTime - epoch.hostStart)
    }
    private func appendBoundaryLocked(_ lane: Lane, sample: Int64, action: MeetingCaptureSourceBoundary.Action, selection: String? = nil) {
        let boundary = MeetingCaptureSourceBoundary(sample: max(0, sample - lane.origin), source: lane.source.metadataSource,
                                                    action: action, selection: selection)
        if lane.boundaries.last != boundary { lane.boundaries.append(boundary) }
    }
    private func fence() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    private func recordFailure(_ error: Error, lane: Lane, revision: UInt64? = nil) {
        let first = lock.withLock {
            guard lane.failure == nil, !lane.finished, terminal != .cancel,
                  laneLocked(lane.source) === lane,
                  revision == nil || revision == lane.revision else { return false }
            lane.failure = error
            lane.enabled = false
            lane.revision &+= 1
            lane.level = Level()
            return true
        }
        if first {
            queue.async { lane.core.clear(); lane.conversion.reset() }
            failed(lane.source, error)
        }
    }
    private func admittedLocked(_ lane: Lane, revision: UInt64) -> Bool {
        lane.failure == nil && !lane.finished && terminal != .cancel
            && (lane.enabled || lane.closingAt != nil) && lane.revision == revision
    }
    private static func copyInput(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return nil }
        copy.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let from = source[index].mData, let to = destination[index].mData,
                  source[index].mDataByteSize <= destination[index].mDataByteSize else { return nil }
            to.copyMemory(from: from, byteCount: Int(source[index].mDataByteSize))
        }
        return copy
    }
    private func process(_ input: AVAudioPCMBuffer, lane: Lane, hostTime: Double, epoch: Epoch, revision: UInt64) throws {
        let admission = lock.withLock { (admittedLocked(lane, revision: revision), epoch.hostStop, lane.closingAt) }
        guard admission.0 else { return }
        let stop = min(admission.1 ?? .infinity, admission.2 ?? .infinity)
        if stop.isFinite {
            let frames = max(0, ((stop - hostTime) * input.format.sampleRate + 0.001).rounded(.down))
            input.frameLength = AVAudioFrameCount(min(Double(input.frameLength), frames))
        }
        guard input.frameLength > 0 else { return }
        let state = lane.conversion
        let sample = epoch.sampleStart + Self.sampleOffset(hostTime - epoch.hostStart)
        let continuous = state.epoch === epoch && state.revision == revision && state.format == input.format
            && abs(hostTime - state.expectedHostTime) <= 1.5 / input.format.sampleRate
            && (input.format != format || sample == state.nextSample)
        if !continuous {
            if state.epoch === epoch, state.revision == revision { try drain(state, lane: lane) }
            state.reset()
            state.epoch = epoch
            state.revision = revision
            state.format = input.format
            state.nextSample = sample
            if input.format != format {
                guard let converter = AVAudioConverter(from: input.format, to: format),
                      let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_256) else {
                    throw RouterError.unsupportedInputFormat
                }
                converter.primeMethod = .none
                state.converter = converter
                state.output = converted
            }
        }
        state.expectedHostTime = (continuous ? state.expectedHostTime : hostTime)
            + Double(input.frameLength) / input.format.sampleRate
        state.endSample = epoch.sampleStart + Self.sampleOffset(
            max(0, hostTime - epoch.hostStart) + Double(input.frameLength) / input.format.sampleRate)
        if let converter = state.converter, let converted = state.output {
            var supplied = false
            var error: NSError?
            converted.frameLength = 0
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                if supplied { outStatus.pointee = .noDataNow; return nil }
                supplied = true
                outStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            guard status != .error else { throw RouterError.conversionFailed }
            try insert(converted, state: state, lane: lane)
        } else { try insert(input, state: state, lane: lane) }
    }
    private func insert(_ buffer: AVAudioPCMBuffer, state: Conversion, lane: Lane) throws {
        guard let samples = buffer.int16ChannelData?[0] else { throw RouterError.conversionFailed }
        let count = min(Int(buffer.frameLength), max(0, Int(state.endSample - state.nextSample)))
        lock.lock()
        defer { lock.unlock() }
        guard admittedLocked(lane, revision: state.revision) else { return }
        guard lane.core.insert(UnsafeBufferPointer(start: samples, count: count), at: state.nextSample) else {
            throw RouterError.queueOverflow
        }
        let first = min(count, max(0, Int(lane.core.cursor - state.nextSample)))
        if first < count, terminal == nil, activeEpoch === state.epoch, lane.closingAt == nil {
            var energy = 0.0
            for index in first..<count { let value = Double(samples[index]) / 32_768; energy += value * value }
            lane.level = Level(rms: min(1, sqrt(energy / Double(count - first))),
                               updatedAt: min(clock(), state.expectedHostTime))
        }
        state.nextSample += Int64(count)
    }
    private func drain(_ state: Conversion, lane: Lane) throws {
        guard lock.withLock({ admittedLocked(lane, revision: state.revision) }),
              let converter = state.converter, let output = state.output else { return }
        output.frameLength = 0
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        if let error { throw error }
        guard status != .error else { throw RouterError.conversionFailed }
        try insert(output, state: state, lane: lane)
    }
    private func closeEpoch(_ epoch: Epoch) {
        let target = lock.withLock { max(committedSamples, epoch.sampleStart + Self.sampleOffset((epoch.hostStop ?? epoch.hostStart) - epoch.hostStart)) }
        for index in 0..<5 {
            guard let lane = lock.withLock({ lanes[index] }), !lock.withLock({ lane.finished }) else { continue }
            do {
                if lane.conversion.epoch === epoch { try drain(lane.conversion, lane: lane) }
                try emit(lane, through: target, completeBlocksOnly: false)
            } catch { recordFailure(error, lane: lane) }
            lane.conversion.reset()
            lane.core.clear()
        }
        lock.withLock { committedSamples = max(committedSamples, target) }
    }
    private func renderCurrent(hostTime: Double) {
        guard hostTime.isFinite else { return }
        let epoch = lock.withLock { activeEpoch }
        guard let epoch, queueEpoch === epoch else { return }
        let requested = epoch.sampleStart + Self.sampleOffset(max(0, hostTime - epoch.hostStart - renderLatency))
        let target = lock.withLock { committedSamples + max(0, (requested - committedSamples) / Int64(blockFrames)) * Int64(blockFrames) }
        for index in 0..<5 {
            guard let lane = lock.withLock({ lanes[index] }) else { continue }
            do { try emit(lane, through: target, completeBlocksOnly: true, epoch: epoch) }
            catch { recordFailure(error, lane: lane) }
        }
        lock.withLock { if activeEpoch === epoch { committedSamples = max(committedSamples, target) } }
    }
    private func emit(_ lane: Lane, through target: Int64, completeBlocksOnly: Bool, epoch: Epoch? = nil) throws {
        let endpoint = lock.withLock {
            lane.closingAt.flatMap { closeTime in
                queueEpoch.map { min(target, $0.sampleStart + Self.sampleOffset(closeTime - $0.hostStart)) }
            } ?? target
        }
        guard endpoint - lane.core.cursor <= Int64(lane.core.capacity) else { throw RouterError.queueOverflow }
        while lane.core.cursor < endpoint {
            lock.lock()
            if lane.failure != nil || lane.finished || terminal == .cancel || (epoch != nil && activeEpoch !== epoch) {
                lock.unlock(); return
            }
            let count = min(blockFrames, Int(endpoint - lane.core.cursor))
            if completeBlocksOnly && count < blockFrames { lock.unlock(); return }
            if !admittedLocked(lane, revision: lane.conversion.revision) { lane.core.clear() }
            output.frameLength = AVAudioFrameCount(count)
            lane.core.render(into: output.int16ChannelData![0], count: count)
            lane.committed = lane.core.cursor
            committedSamples = max(committedSamples, lane.committed)
            lock.unlock()
            try consume(lane.source, output)
        }
    }
    private static func sampleOffset(_ seconds: Double) -> Int64 {
        Int64(min(max(0, (seconds * 16_000).rounded()), Double(Int64.max / 2)))
    }
}

/// One bounded unity-gain ring per track. Overlap replaces; late data is dropped.
/// Only the router's serial queue accesses a ring after construction.
nonisolated final class MeetingAudioSourceRouterCore {
    let capacity: Int
    private(set) var cursor: Int64
    private var samples: [Int16]
    private var populated = false
    init(capacity: Int, cursor: Int64 = 0) {
        precondition(capacity > 0 && cursor >= 0)
        self.capacity = capacity
        self.cursor = cursor
        samples = Array(repeating: 0, count: capacity)
    }
    @discardableResult
    func insert(_ input: UnsafeBufferPointer<Int16>, at start: Int64) -> Bool {
        let (end, overflow) = start.addingReportingOverflow(Int64(input.count))
        guard !overflow, end <= cursor + Int64(capacity) else { return false }
        let lower = max(start, cursor)
        guard lower < end else { return true }
        populated = true
        for position in lower..<end { samples[Int(position % Int64(capacity))] = input[Int(position - start)] }
        return true
    }
    func clear() {
        guard populated else { return }
        populated = false
        samples.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
    }
    func render(into output: UnsafeMutablePointer<Int16>, count: Int) {
        precondition(count >= 0 && count <= capacity)
        for offset in 0..<count {
            let index = Int((cursor + Int64(offset)) % Int64(capacity))
            output[offset] = samples[index]
            samples[index] = 0
        }
        cursor += Int64(count)
    }
}
