@preconcurrency import AVFoundation
import Combine
import CoreML
@preconcurrency import FluidAudio
import Foundation
import os

nonisolated enum MeetingDiarizationPreset: String, Codable, Sendable {
    case live
    case finalPass

    /// FluidAudio v0.17.4 preset names; the model card's "s32" is only a file name.
    var sdkPresetName: String {
        switch self {
        case .live: "fast32-split-w8a8"
        case .finalPass: "c128-split-w8a8"
        }
    }
}

/// Incremental speaker evidence. Closed intervals are never repeated; open
/// intervals may still grow and are replaced by the next update.
nonisolated struct MeetingDiarizationUpdate: Sendable, Equatable {
    let sessionID: UUID
    let closedIntervals: [MeetingSpeakerInterval]
    let openIntervals: [MeetingSpeakerInterval]
    let coveredThroughSample: Int64
}

/// Converts 10 ms per-slot activity frames into half-open 16 kHz sample
/// intervals. Runs shorter than 200 ms are dropped, judged on their full length
/// even when a chunk boundary splits them. Overlapping slots stay overlapping.
nonisolated struct MeetingSpeakerActivityTracker: Sendable {
    static let samplesPerFrame: Int64 = 160
    static let minimumFrames: Int64 = 20
    static let liveMaximumGapFrames: Int64 = 5
    static let threshold: Float = 0.5

    let speakerCount: Int
    let maximumGapFrames: Int64
    var baseSample: Int64
    private(set) var frameCount: Int64 = 0
    private var runStarts: [Int64?]
    private var gapCounts: [Int64]
    private var slotIDs: [String?]

    init(speakerCount: Int, maximumGapFrames: Int64 = 0, baseSample: Int64 = 0) {
        self.speakerCount = speakerCount
        self.maximumGapFrames = max(0, maximumGapFrames)
        self.baseSample = max(0, baseSample)
        runStarts = Array(repeating: nil, count: speakerCount)
        gapCounts = Array(repeating: 0, count: speakerCount)
        slotIDs = Array(repeating: nil, count: speakerCount)
    }

    mutating func consume(
        probabilities: [Float],
        frames: Int,
        receivedSamples: Int64,
        into closed: inout [MeetingSpeakerInterval]
    ) {
        guard frames > 0, probabilities.count >= frames * speakerCount else { return }
        for frame in 0..<frames {
            let index = frameCount + Int64(frame)
            for speaker in 0..<speakerCount {
                if probabilities[frame * speakerCount + speaker] > Self.threshold {
                    if runStarts[speaker] == nil { runStarts[speaker] = index }
                    gapCounts[speaker] = 0
                } else if let start = runStarts[speaker] {
                    gapCounts[speaker] += 1
                    if gapCounts[speaker] > maximumGapFrames {
                        let activeEnd = index - gapCounts[speaker] + 1
                        close(speaker: speaker, start: start, end: activeEnd, receivedSamples: receivedSamples, into: &closed)
                        runStarts[speaker] = nil
                        gapCounts[speaker] = 0
                    }
                }
            }
        }
        frameCount += Int64(frames)
    }

    mutating func finish(receivedSamples: Int64, into closed: inout [MeetingSpeakerInterval]) {
        for speaker in 0..<speakerCount {
            guard let start = runStarts[speaker] else { continue }
            let activeEnd = frameCount - gapCounts[speaker]
            close(speaker: speaker, start: start, end: activeEnd, receivedSamples: receivedSamples, into: &closed)
            runStarts[speaker] = nil
            gapCounts[speaker] = 0
        }
    }

    /// Only runs that already passed the minimum length; they cannot be dropped later.
    mutating func openIntervals(receivedSamples: Int64) -> [MeetingSpeakerInterval] {
        var open: [MeetingSpeakerInterval] = []
        for speaker in 0..<speakerCount {
            guard let start = runStarts[speaker] else { continue }
            let activeEnd = frameCount - gapCounts[speaker]
            guard activeEnd - start >= Self.minimumFrames else { continue }
            let startSample = baseSample + start * Self.samplesPerFrame
            let endSample = min(baseSample + activeEnd * Self.samplesPerFrame, receivedSamples)
            if startSample < endSample {
                open.append(MeetingSpeakerInterval(speakerID: identifier(for: speaker), startSample: startSample, endSample: endSample))
            }
        }
        return open
    }

    /// Activity before this sample is settled. A pending sub-200 ms run may still
    /// be kept or dropped, so coverage stops at its start.
    func coveredThroughSample(receivedSamples: Int64) -> Int64 {
        var covered = min(baseSample + frameCount * Self.samplesPerFrame, receivedSamples)
        for speaker in 0..<speakerCount {
            guard let start = runStarts[speaker] else { continue }
            let activeEnd = frameCount - gapCounts[speaker]
            if activeEnd - start < Self.minimumFrames {
                covered = min(covered, baseSample + start * Self.samplesPerFrame)
            } else if gapCounts[speaker] > 0 {
                covered = min(covered, baseSample + activeEnd * Self.samplesPerFrame)
            }
        }
        return covered
    }

    private mutating func close(
        speaker: Int,
        start: Int64,
        end: Int64,
        receivedSamples: Int64,
        into closed: inout [MeetingSpeakerInterval]
    ) {
        guard end - start >= Self.minimumFrames else { return }
        // Padding frames past the real input end are trimmed.
        let startSample = baseSample + start * Self.samplesPerFrame
        let endSample = min(baseSample + end * Self.samplesPerFrame, receivedSamples)
        guard startSample < endSample else { return }
        closed.append(MeetingSpeakerInterval(speakerID: identifier(for: speaker), startSample: startSample, endSample: endSample))
    }

    private mutating func identifier(for speaker: Int) -> String {
        if let id = slotIDs[speaker] { return id }
        let id = UUID().uuidString.lowercased()
        slotIDs[speaker] = id
        return id
    }
}

nonisolated protocol MeetingDiarizationProcessing: Actor {
    nonisolated var sessionID: UUID { get }
    func prepare() async throws
    func process(samples: [Float], startSample: Int64) async throws -> MeetingDiarizationUpdate
    func finish(totalSamples: Int64) async throws -> MeetingDiarizationUpdate
    func cancel() async
}

/// Each worker owns its non-thread-safe diarizer, frontend, cache and speaker IDs.
/// Same-preset workers lease shared immutable weights, never SDK scratch arrays.
actor MeetingDiarizationWorker: MeetingDiarizationProcessing {
    private static let modelPool = MeetingDiarizationModelPool<MeetingDiarizationModelKey, MeetingDiarizationModelWeights>()
    nonisolated let sessionID: UUID
    private let preset: MeetingDiarizationPreset
    private let store: MeetingDiarizationModelStore
    private var diarizer: Nemotron3Diarizer?
    private var modelLease: MeetingDiarizationModelPool<MeetingDiarizationModelKey, MeetingDiarizationModelWeights>.Lease?
    private var tracker = MeetingSpeakerActivityTracker(speakerCount: 8)
    private var receivedSamples: Int64 = 0
    private var hasProcessedAudio = false
    private var weights: MeetingDiarizationModelWeights? { modelLease?.value }
    private var closed = false
    private let logger = Logger(subsystem: "pieroot.todo", category: "MeetingDiarization")
    private var predictedFirstChunk = false
    private var prepareTask: Task<Void, Error>?

    init(preset: MeetingDiarizationPreset, sessionID: UUID, store: MeetingDiarizationModelStore = .shared) {
        self.preset = preset
        self.sessionID = sessionID
        self.store = store
    }

    func prepare() async throws {
        guard !closed else { throw CancellationError() }
        if diarizer != nil { return }
        if prepareTask == nil {
            prepareTask = Task { try await self.loadModels() }
        }
        try await prepareTask!.value
        guard !closed else { throw CancellationError() }
    }

    private func loadModels() async throws {
        guard !closed else { throw CancellationError() }
        guard let config = Nemotron3Config.preset(named: preset.sdkPresetName) else {
            throw MeetingDiarizationFailure.modelUnavailable
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        logger.info("Model loading preset=\(self.preset.rawValue, privacy: .public) session=\(self.sessionID.uuidString, privacy: .public)")
        do {
            let key = MeetingDiarizationModelKey(storeID: ObjectIdentifier(store), preset: preset)
            let store = self.store
            modelLease = try await Self.modelPool.acquire(key: key, load: {
                let directory = try await store.acquire()
                do {
                    return try MeetingDiarizationModelWeights(config: config, directory: directory)
                } catch {
                    await store.release()
                    throw error
                }
            }, release: { await store.release() })
            let models = try modelLease!.value.makeModels(config: config)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            diarizer = Nemotron3Diarizer(config: config, models: models)
            let gapFrames = preset == .live ? MeetingSpeakerActivityTracker.liveMaximumGapFrames : 0
            tracker = MeetingSpeakerActivityTracker(speakerCount: config.numSpeakers, maximumGapFrames: gapFrames)
            logger.info("Model ready preset=\(self.preset.rawValue, privacy: .public) session=\(self.sessionID.uuidString, privacy: .public) seconds=\(ProcessInfo.processInfo.systemUptime - startedAt)")
        } catch is CancellationError {
            await releaseLease()
            throw CancellationError()
        } catch {
            await releaseLease()
            throw MeetingDiarizationFailure.modelUnavailable
        }
    }

    func process(samples: [Float], startSample: Int64) throws -> MeetingDiarizationUpdate {
        guard !closed, let diarizer, let weights else { throw MeetingDiarizationFailure.modelUnavailable }
        if !hasProcessedAudio {
            guard startSample >= 0 else { throw MeetingDiarizationFailure.timelineMismatch }
            hasProcessedAudio = true
            receivedSamples = startSample
            tracker.baseSample = startSample
        }
        guard startSample == receivedSamples else { throw MeetingDiarizationFailure.timelineMismatch }
        var closedIntervals: [MeetingSpeakerInterval] = []
        receivedSamples += Int64(samples.count)
        // Bounded appends keep the SDK frontend from holding a large caller batch.
        let block = 16_384
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let end = min(offset + block, samples.count)
            diarizer.appendAudio(offset == 0 && end == samples.count ? samples : Array(samples[offset..<end]))
            do {
                for chunk in try weights.withPredictionLock({ try diarizer.processBufferedAudio() }) {
                    if !predictedFirstChunk {
                        predictedFirstChunk = true
                        logger.info("First prediction preset=\(self.preset.rawValue, privacy: .public) session=\(self.sessionID.uuidString, privacy: .public) startSample=\(startSample) received=\(self.receivedSamples)")
                    }
                    tracker.consume(probabilities: chunk.probabilities, frames: chunk.frameCount,
                                    receivedSamples: receivedSamples, into: &closedIntervals)
                }
            } catch {
                throw MeetingDiarizationFailure.inferenceFailed
            }
            offset = end
        }
        return MeetingDiarizationUpdate(
            sessionID: sessionID,
            closedIntervals: closedIntervals,
            openIntervals: tracker.openIntervals(receivedSamples: receivedSamples),
            coveredThroughSample: tracker.coveredThroughSample(receivedSamples: receivedSamples)
        )
    }

    /// Flushes the short tail exactly once (SDK padding is trimmed to the input).
    func finish(totalSamples: Int64) async throws -> MeetingDiarizationUpdate {
        guard !closed, let diarizer, let weights else { throw MeetingDiarizationFailure.modelUnavailable }
        if !hasProcessedAudio, totalSamples >= 0 {
            hasProcessedAudio = true
            receivedSamples = totalSamples
            tracker.baseSample = totalSamples
        }
        guard totalSamples == receivedSamples else { throw MeetingDiarizationFailure.timelineMismatch }
        closed = true
        defer { self.diarizer = nil }
        var closedIntervals: [MeetingSpeakerInterval] = []
        do {
            for chunk in try weights.withPredictionLock({ try diarizer.finishStream() }) {
                tracker.consume(probabilities: chunk.probabilities, frames: chunk.frameCount,
                                receivedSamples: receivedSamples, into: &closedIntervals)
            }
        } catch {
            await releaseLease()
            throw MeetingDiarizationFailure.inferenceFailed
        }
        tracker.finish(receivedSamples: receivedSamples, into: &closedIntervals)
        await releaseLease()
        return MeetingDiarizationUpdate(
            sessionID: sessionID,
            closedIntervals: closedIntervals,
            openIntervals: [],
            coveredThroughSample: receivedSamples
        )
    }

    func cancel() async {
        closed = true
        prepareTask?.cancel()
        _ = await prepareTask?.result
        diarizer = nil
        await releaseLease()
    }

    private func releaseLease() async {
        guard let lease = modelLease else { return }
        modelLease = nil
        diarizer = nil
        await Self.modelPool.release(key: lease.key, id: lease.id)
    }
}

/// Isolates live diarization from the canonical recording path: admission never
/// blocks, the Int16 -> Float32 conversion happens on the single drain task,
/// and at most `maximumQueuedSamples` (10 s) may wait for inference. Overflow
/// stops admission and is reported only to the speaker path; time is never
/// shifted to close a gap.
nonisolated final class MeetingDiarizationInputPipeline: @unchecked Sendable {
    typealias Deliver = @Sendable (MeetingDiarizationUpdate) async -> Void
    typealias Failed = @Sendable (MeetingDiarizationFailure) -> Void
    typealias Prepared = @Sendable () -> Void

    private enum Terminal { case finish, cancel }
    private enum Step {
        case batch([(Int64, AVAudioPCMBuffer)])
        case finish(Int64)
        case wait
        case stop
    }

    private let worker: any MeetingDiarizationProcessing
    private let maximumQueuedSamples: Int64
    private let deliver: Deliver
    private let preparedCallback: Prepared
    private let failed: Failed
    private let logger = Logger(subsystem: "pieroot.todo", category: "MeetingDiarizationQueue")
    private let lock = NSLock()
    private var pending: [(Int64, AVAudioPCMBuffer)] = []
    private var unprocessedSamples: Int64 = 0
    private var firstInputLogged = false
    private var queueHighWaterSamples: Int64 = 0
    private var evictedSamples: Int64 = 0
    private var acceptedEnd: Int64 = 0
    private var accepting = true
    private var prepared = false
    private var processing = true
    private var terminal: Terminal?
    private var failure: MeetingDiarizationFailure?
    private var wake: CheckedContinuation<Void, Never>?
    private var drainTask: Task<Void, Never>?

    init(
        worker: any MeetingDiarizationProcessing,
        maximumQueuedSamples: Int64 = 160_000,
        prepared: @escaping Prepared = {},
        deliver: @escaping Deliver,
        failed: @escaping Failed
    ) {
        self.worker = worker
        self.maximumQueuedSamples = maximumQueuedSamples
        self.deliver = deliver
        self.preparedCallback = prepared
        self.failed = failed
        drainTask = Task.detached(priority: .userInitiated) { [self] in await drain() }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer, startSample: Int64) {
        let frames = Int64(buffer.frameLength)
        guard frames > 0, lock.withLock({ accepting }) else { return }
        let owned = buffer.copy() as? AVAudioPCMBuffer
        var report: MeetingDiarizationFailure?
        var firstInputSample: Int64?
        var failureMetrics: (highWater: Int64, evicted: Int64)?
        var resume: CheckedContinuation<Void, Never>?
        lock.withLock {
            guard accepting else { return }
            if let owned, owned.format.commonFormat == .pcmFormatInt16, owned.format.channelCount == 1,
               owned.int16ChannelData != nil {
                if startSample != acceptedEnd {
                    report = failLocked(.timelineMismatch)
                } else if unprocessedSamples + frames > maximumQueuedSamples {
                    if !prepared, frames <= maximumQueuedSamples {
                        let retainedLimit = max(frames, maximumQueuedSamples / 2)
                        while !pending.isEmpty, unprocessedSamples + frames > retainedLimit {
                            let dropped = pending.removeFirst()
                            evictedSamples += Int64(dropped.1.frameLength)
                            unprocessedSamples -= Int64(dropped.1.frameLength)
                        }
                        pending.append((startSample, owned))
                        unprocessedSamples += frames
                        queueHighWaterSamples = max(queueHighWaterSamples, unprocessedSamples)
                        acceptedEnd += frames
                        resume = wake
                        wake = nil
                    } else {
                        report = failLocked(.inputOverflow)
                    }
                } else {
                    pending.append((startSample, owned))
                    unprocessedSamples += frames
                    queueHighWaterSamples = max(queueHighWaterSamples, unprocessedSamples)
                    acceptedEnd += frames
                    resume = wake
                    wake = nil
                }
            } else {
                report = failLocked(.audioUnavailable)
            }
            if report == nil && !firstInputLogged {
                firstInputLogged = true
                firstInputSample = startSample
            }
            if report != nil { failureMetrics = (queueHighWaterSamples, evictedSamples) }
        }
        resume?.resume()
        if let firstInputSample {
            logger.info("Live speaker first input session=\(self.worker.sessionID.uuidString, privacy: .public) sample=\(firstInputSample)")
        }
        if let report, let failureMetrics {
            logger.error("Live speaker admission stopped session=\(self.worker.sessionID.uuidString, privacy: .public) reason=\(report.rawValue, privacy: .public) highWater=\(failureMetrics.highWater) evicted=\(failureMetrics.evicted)")
        }
        if let report { failed(report) }
    }

    /// Processes the accepted prefix, then flushes the model tail once.
    func finish() async throws {
        begin(.finish)
        await drainTask?.value
        if let failure = lock.withLock({ failure }) { throw failure }
    }

    /// Discards queued input; no update is delivered after this returns.
    func cancel() async {
        begin(.cancel)
        drainTask?.cancel()
        await drainTask?.value
    }

    var isCancellationRequested: Bool { lock.withLock { terminal == .cancel } }

    private func begin(_ request: Terminal) {
        let resume: CheckedContinuation<Void, Never>? = lock.withLock {
            if terminal == nil || request == .cancel { terminal = request }
            accepting = false
            if request == .cancel { pending.removeAll() }
            defer { wake = nil }
            return wake
        }
        resume?.resume()
    }

    /// Caller holds `lock`. Returns the failure to report once, if any.
    private func failLocked(_ code: MeetingDiarizationFailure) -> MeetingDiarizationFailure? {
        accepting = false
        guard failure == nil else { return nil }
        failure = code
        return code
    }

    private func stopProcessing(_ code: MeetingDiarizationFailure) {
        let report: MeetingDiarizationFailure? = lock.withLock {
            processing = false
            pending.removeAll()
            return failLocked(code)
        }
        if let report { failed(report) }
    }

    private func drain() async {
        do {
            try await worker.prepare()
        } catch {
            if !(error is CancellationError) {
                stopProcessing(error as? MeetingDiarizationFailure ?? .modelUnavailable)
            }
            await worker.cancel()
            return
        }
        var readyMetrics: (queued: Int64, highWater: Int64, evicted: Int64)?
        let shouldNotify = lock.withLock { () -> Bool in
            guard terminal != .cancel, processing, !Task.isCancelled else { return false }
            let retainedLimit = max(Int64(1), maximumQueuedSamples / 2)
            while pending.count > 1, unprocessedSamples > retainedLimit {
                let dropped = pending.removeFirst()
                evictedSamples += Int64(dropped.1.frameLength)
                unprocessedSamples -= Int64(dropped.1.frameLength)
            }
            readyMetrics = (unprocessedSamples, queueHighWaterSamples, evictedSamples)
            prepared = true
            return true
        }
        guard shouldNotify else {
            await worker.cancel()
            return
        }
        if let readyMetrics {
            logger.info("Live speaker prepared session=\(self.worker.sessionID.uuidString, privacy: .public) queued=\(readyMetrics.queued) highWater=\(readyMetrics.highWater) evicted=\(readyMetrics.evicted)")
        }
        preparedCallback()
        var lastOpen: [MeetingSpeakerInterval] = []
        var lastCoverage: Int64 = 0
        while true {
            switch nextStep() {
            case .stop:
                await worker.cancel()
                return
            case .wait:
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let resumeNow = lock.withLock { () -> Bool in
                        guard pending.isEmpty, terminal == nil, processing else { return true }
                        wake = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            case let .batch(batch):
                let samples = Self.floats(batch)
                do {
                    let update = try await worker.process(samples: samples, startSample: batch[0].0)
                    lock.withLock { unprocessedSamples -= Int64(samples.count) }
                    if !update.closedIntervals.isEmpty || update.openIntervals != lastOpen ||
                        update.coveredThroughSample != lastCoverage {
                        lastOpen = update.openIntervals
                        lastCoverage = update.coveredThroughSample
                        await deliver(update)
                    }
                } catch {
                    if !(error is CancellationError) {
                        stopProcessing(error as? MeetingDiarizationFailure ?? .inferenceFailed)
                    }
                    await worker.cancel()
                    return
                }
            case let .finish(total):
                do {
                    await deliver(try await worker.finish(totalSamples: total))
                } catch {
                    if !(error is CancellationError) {
                        stopProcessing(error as? MeetingDiarizationFailure ?? .inferenceFailed)
                    }
                    await worker.cancel()
                }
                return
            }
        }
    }

    private func nextStep() -> Step {
        lock.withLock {
            if terminal == .cancel || !processing || Task.isCancelled { return .stop }
            if !pending.isEmpty {
                let batch = pending
                pending.removeAll(keepingCapacity: true)
                return .batch(batch)
            }
            if terminal == .finish { return .finish(acceptedEnd) }
            return .wait
        }
    }

    private static func floats(_ batch: [(Int64, AVAudioPCMBuffer)]) -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(batch.reduce(0) { $0 + Int($1.1.frameLength) })
        for (_, buffer) in batch {
            guard let channel = buffer.int16ChannelData?[0] else { continue }
            for index in 0..<Int(buffer.frameLength) { samples.append(Float(channel[index]) / 32_768) }
        }
        return samples
    }
}

/// Final pass over the saved recording: the overlap-trimmed logical FLAC
/// timeline is streamed once through the same streaming API. Never uses
/// `processComplete`, which would hold the whole recording's PCM and mel.
nonisolated enum MeetingDiarizationReplay {
    struct Evidence: Sendable {
        let intervals: [MeetingSpeakerInterval]
        let coveredThroughSample: Int64
        let voiceEvidence: MeetingSpeakerVoiceEvidence?
    }

    static func run(
        manifest: MeetingAudioManifest,
        referenceIntervals: [MeetingSpeakerInterval],
        store: MeetingDiarizationModelStore = .shared,
        rootURL: URL = AppDataContainer.meetingDirectory(),
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> Evidence {
        guard manifest.sampleRate == 16_000,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { throw MeetingDiarizationFailure.timelineMismatch }
        let cursor: MeetingLogicalAudioCursor
        do {
            cursor = try MeetingLogicalAudioCursor(manifest: manifest, rootURL: rootURL)
        } catch {
            throw MeetingDiarizationFailure.audioUnavailable
        }
        // Keep the whole verified pack leased across the handoff between models.
        _ = try await store.acquire()
        let worker = MeetingDiarizationWorker(preset: .finalPass, sessionID: UUID(), store: store)
        do {
            try await worker.prepare()
            var intervals: [MeetingSpeakerInterval] = []
            var position: Int64 = 0
            while true {
                try Task.checkCancellation()
                let buffer: AVAudioPCMBuffer?
                do {
                    buffer = try cursor.nextPCMBuffer(maxFrames: 160_000, outputFormat: format)
                } catch {
                    throw MeetingDiarizationFailure.audioUnavailable
                }
                guard let buffer else { break }
                guard let channel = buffer.floatChannelData?[0] else { throw MeetingDiarizationFailure.audioUnavailable }
                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                let update = try await worker.process(samples: samples, startSample: position)
                intervals.append(contentsOf: update.closedIntervals)
                position += Int64(samples.count)
                if manifest.totalSamples > 0 { progress(0.8 * min(1, Double(position) / Double(manifest.totalSamples))) }
            }
            guard position == manifest.totalSamples else { throw MeetingDiarizationFailure.timelineMismatch }
            let tail = try await worker.finish(totalSamples: position)
            intervals.append(contentsOf: tail.closedIntervals)
            // finish releases Nemotron before either speaker-embedding graph loads.
            try Task.checkCancellation()
            let voiceEvidence = try await MeetingSpeakerEmbeddingService.run(
                manifest: manifest, detected: intervals, reference: referenceIntervals,
                store: store, rootURL: rootURL, progress: { progress(0.8 + 0.2 * $0) }
            )
            await store.release()
            return Evidence(intervals: intervals, coveredThroughSample: tail.coveredThroughSample, voiceEvidence: voiceEvidence)
        } catch {
            await worker.cancel()
            await store.release()
            throw error
        }
    }
}

/// One recording group or one final replay owns execution. Final requests queue
/// fairly; no replay starts until every admitted track has released ownership.
@MainActor
final class MeetingDiarizationExecutionGate {
    static let shared = MeetingDiarizationExecutionGate()

    private var liveGroupID: String?
    private var liveSessions: Set<UUID> = []
    private var finalRunning = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    var queuedFinalCount: Int { waiters.count }

    func beginLive(_ sessionID: UUID, groupID: String) -> Bool {
        guard !finalRunning, !liveSessions.contains(sessionID) else { return false }
        if let liveGroupID {
            guard liveGroupID == groupID else { return false }
        } else {
            guard waiters.isEmpty else { return false }
            liveGroupID = groupID
        }
        liveSessions.insert(sessionID)
        return true
    }

    /// Reassigns an idle prewarm reservation without releasing its execution slot.
    fileprivate func transferLive(_ sessionID: UUID, to groupID: String) -> Bool {
        guard liveSessions == [sessionID], !finalRunning else { return false }
        liveGroupID = groupID
        return true
    }

    func endLive(_ sessionID: UUID) {
        guard liveSessions.remove(sessionID) != nil else { return }
        if liveSessions.isEmpty { liveGroupID = nil }
        resumeNext()
    }

    /// Waits for all live tracks and earlier replays, with cancellation cleanup.
    func beginFinal() async -> Bool {
        guard !Task.isCancelled else { return false }
        if !finalRunning, liveSessions.isEmpty, waiters.isEmpty {
            finalRunning = true
            return true
        }
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
        // Ownership may have been handed off just before cancellation arrived.
        if acquired, Task.isCancelled {
            endFinal()
            return false
        }
        return acquired
    }

    func endFinal() {
        finalRunning = false
        resumeNext()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func resumeNext() {
        guard liveSessions.isEmpty, !finalRunning, !waiters.isEmpty else { return }
        // Transfer ownership before waking the next task; a live session or a
        // new final pass must not steal the slot while that task is resuming.
        finalRunning = true
        waiters.removeFirst().continuation.resume(returning: true)
    }
}

/// Holds a verified live worker briefly while the meeting screen is visible.
/// The same worker can be handed off during loading; its prepare call is single-flight.
@MainActor
final class MeetingLiveSpeakerPrewarmer: ObservableObject {
    static let shared = MeetingLiveSpeakerPrewarmer()

    enum Phase: Equatable { case inactive, preparing, ready }
    @Published private(set) var phase: Phase = .inactive
    private var worker: (any MeetingDiarizationProcessing)?
    private var preparation: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var releasing: Task<Void, Never>?
    private var releasingSessionID: UUID?
    private var generation = 0
    private let gate: MeetingDiarizationExecutionGate
    private let enabled: @MainActor () -> Bool
    private let installed: () async -> Bool
    private let createWorker: @MainActor (UUID) -> any MeetingDiarizationProcessing

    init(
        gate: MeetingDiarizationExecutionGate? = nil,
        enabled: (@MainActor () -> Bool)? = nil,
        installed: (() async -> Bool)? = nil,
        createWorker: (@MainActor (UUID) -> any MeetingDiarizationProcessing)? = nil
    ) {
        self.gate = gate ?? .shared
        self.enabled = enabled ?? { SettingsStore.shared.effectiveMeetingDiarizationEnabled }
        self.installed = installed ?? { await MeetingDiarizationModelStore.shared.isInstalled() }
        self.createWorker = createWorker ?? { MeetingDiarizationWorker(preset: .live, sessionID: $0) }
    }

    func prepareIfAvailable() async {
        if let releasing { await releasing.value }
        guard worker == nil, enabled(), !Task.isCancelled else { return }
        let requestGeneration = generation
        guard await installed(), worker == nil, !Task.isCancelled, enabled(),
              generation == requestGeneration else { return }
        let sessionID = UUID()
        guard gate.beginLive(sessionID, groupID: "prewarm-\(sessionID.uuidString)") else { return }
        let candidate = createWorker(sessionID)
        worker = candidate
        phase = .preparing
        preparation = Task { [weak self] in
            do {
                try await candidate.prepare()
                guard self?.worker === candidate else { return }
                self?.phase = .ready
                // A cold load can take minutes; never expire before it becomes ready.
                self?.expiry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(90))
                    guard !Task.isCancelled else { return }
                    await self?.releaseUnused(if: sessionID)
                }
            } catch {
                await self?.releaseUnused(if: sessionID)
            }
        }
    }

    /// Transfers gate ownership with the worker; the recording releases it
    /// only after its pipeline has finished or cancelled the worker.
    func take(groupID: String) -> (any MeetingDiarizationProcessing)? {
        guard let worker, gate.transferLive(worker.sessionID, to: groupID) else { return nil }
        self.worker = nil
        preparation = nil
        expiry?.cancel()
        expiry = nil
        phase = .inactive
        return worker
    }

    func releaseUnused(if sessionID: UUID? = nil) async {
        if sessionID == nil { generation += 1 }
        guard let candidate = worker else {
            if let releasing { await releasing.value }
            return
        }
        guard sessionID == nil || candidate.sessionID == sessionID else { return }
        worker = nil
        preparation?.cancel()
        preparation = nil
        expiry?.cancel()
        expiry = nil
        phase = .inactive
        // Never free the gate before a synchronous Core ML load and the
        // worker's verified-artifact lease have actually been released.
        let cleanup = Task { [gate] in
            await candidate.cancel()
            gate.endLive(candidate.sessionID)
        }
        releasing = cleanup
        releasingSessionID = candidate.sessionID
        await cleanup.value
        if releasingSessionID == candidate.sessionID {
            releasing = nil
            releasingSessionID = nil
        }
    }
}

/// Provisional, in-memory speaker evidence of the active recording. Only a
/// completed saved-audio pass persists labels.
nonisolated struct MeetingLiveSpeakerTimeline: Sendable, Equatable {
    let sessionID: UUID
    private(set) var intervals: [MeetingSpeakerInterval] = []
    private(set) var openIntervals: [MeetingSpeakerInterval] = []
    private(set) var coveredThroughSample: Int64 = 0
    private(set) var ordinals: [String: Int] = [:]

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    var activeIntervals: [MeetingSpeakerInterval] { intervals + openIntervals }

    /// Late updates from another session are rejected.
    mutating func apply(_ update: MeetingDiarizationUpdate) -> Bool {
        guard update.sessionID == sessionID else { return false }
        intervals.append(contentsOf: update.closedIntervals)
        openIntervals = update.openIntervals
        coveredThroughSample = max(coveredThroughSample, update.coveredThroughSample)
        for id in MeetingSpeakerIdentityMatcher.firstAppearanceOrder(update.closedIntervals + update.openIntervals)
        where ordinals[id] == nil && ordinals.count < 8 {
            ordinals[id] = ordinals.count + 1
        }
        return true
    }
}
