import AVFoundation
import Foundation
import Testing
@testable import todo

private final class CanonicalSampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = [Int16]()

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.int16ChannelData?[0] else { return }
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    var snapshot: [Int16] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}

private final class CanonicalPipelineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var errors = [Error]()
    private var processedCount = 0

    func record(error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    func recordProcessedBuffer() {
        lock.lock()
        processedCount += 1
        lock.unlock()
    }

    var errorCount: Int {
        lock.lock(); defer { lock.unlock() }
        return errors.count
    }

    var processed: Int {
        lock.lock(); defer { lock.unlock() }
        return processedCount
    }
}

private func makeTapBuffer(format: AVAudioFormat, frameCount: Int = 1_024, sample: Int16 = 1) throws -> AVAudioPCMBuffer {
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
    buffer.frameLength = AVAudioFrameCount(frameCount)
    let channel = try #require(buffer.int16ChannelData?[0])
    for index in 0..<frameCount { channel[index] = sample }
    return buffer
}

private func expectSemaphore(_ semaphore: DispatchSemaphore, timeout: TimeInterval = 2) throws {
    #expect(semaphore.wait(timeout: .now() + timeout) == .success)
}

private func isQueueOverflow(_ error: Error) -> Bool {
    guard case MeetingCanonicalAudioPipeline.PipelineError.queueOverflow = error else { return false }
    return true
}


@Suite("Canonical meeting audio")
struct MeetingCanonicalAudioPipelineTests {
    @Test("48 kHz irregular chunks drain to exact 16 kHz one-second PCM")
    func resamplesAndDrainsTail() async throws {
        let inputFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
        let collector = CanonicalSampleCollector()
        let pipeline = try MeetingCanonicalAudioPipeline(
            inputFormat: inputFormat,
            maximumQueuedBuffers: 64,
            consume: { collector.append($0) },
            dropped: { error in Issue.record("unexpected capture drop: \(error)") }
        )
        let chunks = [127, 1_021, 511, 4_096, 255, 8_192, 33_798]
        var value: Int16 = -12_000
        for size in chunks {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(size)))
            buffer.frameLength = AVAudioFrameCount(size)
            let channel = try #require(buffer.int16ChannelData?[0])
            for index in 0..<size {
                channel[index] = value
                value &+= 1
            }
            pipeline.enqueueTapBuffer(buffer)
        }
        try await pipeline.finish()
        #expect(collector.count == 16_000)
    }

    @Test("five seconds of tap backlog is absorbed before recording fails")
    func absorbsFiveSecondsOfTapBacklog() async throws {
        let inputFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let probe = CanonicalPipelineProbe()
        let pipeline = try MeetingCanonicalAudioPipeline(
            inputFormat: inputFormat,
            consume: { _ in
                probe.recordProcessedBuffer()
                if probe.processed == 1 {
                    started.signal()
                    release.wait()
                }
            },
            dropped: { probe.record(error: $0) }
        )

        pipeline.enqueueTapBuffer(try makeTapBuffer(format: inputFormat))
        try expectSemaphore(started)
        for _ in 1..<235 {
            pipeline.enqueueTapBuffer(try makeTapBuffer(format: inputFormat))
        }
        release.signal()

        try await pipeline.finish()
        #expect(probe.errorCount == 0)
        #expect(probe.processed == 236)
        #expect(pipeline.metrics().highWaterMark >= 235)
    }

    @Test("overflow reports once and drains the accepted prefix")
    func overflowReportsOnceAndDrainsAcceptedPrefix() async throws {
        let inputFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let probe = CanonicalPipelineProbe()
        let pipeline = try MeetingCanonicalAudioPipeline(
            inputFormat: inputFormat,
            maximumQueuedBuffers: 1,
            consume: { _ in
                probe.recordProcessedBuffer()
                if probe.processed == 1 {
                    started.signal()
                    release.wait()
                }
            },
            dropped: { probe.record(error: $0) }
        )

        pipeline.enqueueTapBuffer(try makeTapBuffer(format: inputFormat))
        try expectSemaphore(started)
        for _ in 0..<4 {
            pipeline.enqueueTapBuffer(try makeTapBuffer(format: inputFormat))
        }
        release.signal()

        do {
            try await pipeline.finish()
            Issue.record("finish must report the terminal queue overflow")
        } catch {
            #expect(isQueueOverflow(error))
        }
        #expect(probe.errorCount == 1)
        #expect(probe.processed == 2)
    }

    @Test("the tap buffer is copied before the realtime callback returns")
    func ownsTapBufferBeforeDeferredConsumption() async throws {
        let inputFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let collector = CanonicalSampleCollector()
        let pipeline = try MeetingCanonicalAudioPipeline(
            inputFormat: inputFormat,
            consume: {
                started.signal()
                release.wait()
                collector.append($0)
            },
            dropped: { Issue.record("unexpected capture drop: \($0)") }
        )
        let reused = try makeTapBuffer(format: inputFormat, sample: 37)
        pipeline.enqueueTapBuffer(reused)
        try expectSemaphore(started)
        let channel = try #require(reused.int16ChannelData?[0])
        for index in 0..<Int(reused.frameLength) { channel[index] = -123 }
        release.signal()
        try await pipeline.finish()
        #expect(collector.snapshot == Array(repeating: 37, count: Int(reused.frameLength)))
    }
}
