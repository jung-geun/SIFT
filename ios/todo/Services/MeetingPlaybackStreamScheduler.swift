import AVFoundation
import Foundation

/// Streams the logical meeting timeline into an AVAudioPlayerNode while keeping
/// at most `maxInFlightBuffers` decoded chunks alive, so a multi-hour meeting
/// plays with constant memory instead of a full-timeline PCM preload.
final class MeetingPlaybackStreamScheduler: @unchecked Sendable {
    /// ≈4.1 s per chunk at 16 kHz; 3 chunks keep >8 s of audio scheduled ahead.
    static let chunkFrames: Int64 = 65_536
    static let maxInFlightBuffers = 3

    /// Events carry the epoch they were emitted at so the controller can
    /// discard a `.finished`/`.failed` that a later seek has superseded.
    enum Event {
        case finished(epoch: Int)
        case failed(Error, epoch: Int)
    }

    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "pieroot.todo.meeting.playback-stream", qos: .userInitiated)
    private let cursor: MeetingLogicalAudioCursor
    private let node: AVAudioPlayerNode
    private let format: AVAudioFormat
    private var inFlight = 0
    private var reachedEnd = false
    private var cancelled = false
    /// Bumped on every seek. Completion callbacks and events tagged with an
    /// older epoch are stale (their audio was flushed by node.stop()) and must
    /// be ignored. Kept behind a lightweight lock rather than the serial queue
    /// so the completion callback and the controller can read it without
    /// risking a deadlock against a queue.sync in progress.
    private let epochLock = NSLock()
    private var _epoch = 0

    func currentEpoch() -> Int {
        epochLock.lock(); defer { epochLock.unlock() }
        return _epoch
    }

    private func bumpEpoch() {
        epochLock.lock(); defer { epochLock.unlock() }
        _epoch += 1
    }

    init(cursor: MeetingLogicalAudioCursor, node: AVAudioPlayerNode, format: AVAudioFormat) {
        self.cursor = cursor
        self.node = node
        self.format = format
    }

    /// Decodes and schedules the first chunk synchronously so the caller can
    /// throw immediate decode failures, then keeps refilling in the background.
    func start() throws {
        var startError: Error?
        queue.sync {
            do {
                if let first = try cursor.nextPCMBuffer(maxFrames: Self.chunkFrames, outputFormat: format) {
                    schedule(first)
                } else {
                    reachedEnd = true
                }
            } catch {
                startError = error
            }
        }
        if let startError { throw startError }
        queue.async { self.fill() }
    }

    /// After this returns no further buffers are scheduled and no events fire.
    func cancel() {
        queue.sync { cancelled = true }
    }

    /// Repositions playback to `sample` in the logical timeline. Flushes the
    /// scheduled buffers (node.stop resets render time to 0), reschedules from
    /// the new position, and — if `resumePlaying` — restarts the node. All
    /// cursor access stays on the serial queue; stale completions and events
    /// are ignored via the epoch guard.
    func seek(toLogicalSample sample: Int64, resumePlaying: Bool) throws {
        var seekError: Error?
        queue.sync {
            bumpEpoch()
            node.stop()
            inFlight = 0
            reachedEnd = false
            cancelled = false
            do {
                try cursor.seek(toLogicalSample: sample)
                if let first = try cursor.nextPCMBuffer(maxFrames: Self.chunkFrames, outputFormat: format) {
                    schedule(first)
                } else {
                    reachedEnd = true
                }
            } catch {
                seekError = error
            }
        }
        if let seekError { throw seekError }
        if resumePlaying { node.play() }
        queue.async { self.fill() }
    }

    /// `.dataConsumed` fires when the render thread finishes pulling a buffer.
    /// It is used rather than `.dataPlayedBack` because it also fires under
    /// `engine.renderOffline` — `.dataPlayedBack` never fires without a live
    /// output, which hangs offline tests. The end-of-playback gap it leaves is
    /// only the output latency (tens of ms), not a chunk duration, since
    /// consumption completes near the end of each buffer's playout.
    private func schedule(_ buffer: AVAudioPCMBuffer) {
        inFlight += 1
        let scheduledEpoch = currentEpoch()
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard scheduledEpoch == self.currentEpoch() else { return }
                self.inFlight -= 1
                self.fill()
            }
        }
    }

    private func fill() {
        while !cancelled, !reachedEnd, inFlight < Self.maxInFlightBuffers {
            do {
                guard let buffer = try cursor.nextPCMBuffer(maxFrames: Self.chunkFrames, outputFormat: format) else {
                    reachedEnd = true
                    break
                }
                schedule(buffer)
            } catch {
                cancelled = true
                onEvent?(.failed(error, epoch: currentEpoch()))
                return
            }
        }
        if reachedEnd, inFlight == 0, !cancelled {
            cancelled = true
            onEvent?(.finished(epoch: currentEpoch()))
        }
    }
}
