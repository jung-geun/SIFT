import AVFoundation
import Foundation
import Testing
@testable import todo

private nonisolated final class RecordingMeterClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 100.0
    func now() -> Double { lock.withLock { time } }
    func set(_ time: Double) { lock.withLock { self.time = time } }
}

private func recordingMeterPCM(_ value: Int16) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
    buffer.frameLength = 320
    let samples = try #require(buffer.int16ChannelData?[0])
    samples.initialize(repeating: value, count: 320)
    return buffer
}

@Suite("Recording activity measured source histories")
struct MeetingRecordingMeterTests {
    @Test("all five lanes retain independent meters, silence and privacy gates")
    func independentSources() async throws {
        let clock = RecordingMeterClock()
        let router = try MeetingAudioSourceRouter(automaticallyRenders: false, clock: clock.now,
            consume: { _, _ in }, failed: { _, _ in })
        let sources: [MeetingAudioSourceRouter.Source] = [.microphone, .appAudio,
            .application("one"), .application("two"), .application("silent")]
        let samples: [Int16] = [16_384, 8_192, 4_096, 2_048, 0]
        router.start(hostTime: 100, microphoneEnabled: true)
        for (source, sample) in zip(sources, samples) {
            router.setEnabled(true, source: source, hostTime: 100)
            router.enqueue(try recordingMeterPCM(sample), source: source, hostTime: 100)
        }
        await router.render(hostTime: 100.1)
        let meter = router.meterSnapshot()
        #expect(meter.levels.count == 5)
        for (source, sample) in zip(sources, samples) {
            #expect(meter.levels[source] == Double(sample) / 32_768)
        }
        router.setEnabled(false, source: .application("one"), hostTime: 100.01)
        #expect(router.meterSnapshot().levels[.application("one")] == 0)
        #expect(router.meterSnapshot().levels[.application("two")] == 0.0625)
        router.close(source: .appAudio, hostTime: 100.01)
        #expect(router.meterSnapshot().levels[.appAudio] == 0)
        clock.set(100.6)
        #expect(router.meterSnapshot().levels.values.allSatisfy { $0 == 0 })
        await router.cancel()
    }

    @Test("queued old input cannot become a fresh activity measurement")
    func oldInputIsStale() async throws {
        let clock = RecordingMeterClock()
        clock.set(100.6)
        let router = try MeetingAudioSourceRouter(automaticallyRenders: false, clock: clock.now,
            consume: { _, _ in }, failed: { _, _ in })
        router.start(hostTime: 100, microphoneEnabled: true)
        router.enqueue(try recordingMeterPCM(16_384), source: .microphone, hostTime: 100)
        await router.render(hostTime: 100.6)
        #expect(router.meterSnapshot().levels[.microphone] == 0)
        await router.cancel()
    }

    @Test("pause freezes the canonical clock and terminal input never resurrects levels")
    func pauseAndTerminalFences() async throws {
        let clock = RecordingMeterClock()
        let router = try MeetingAudioSourceRouter(automaticallyRenders: false, clock: clock.now,
            consume: { _, _ in }, failed: { _, _ in })
        router.start(hostTime: 100, microphoneEnabled: true)
        router.enqueue(try recordingMeterPCM(16_384), source: .microphone, hostTime: 100)
        await router.render(hostTime: 100.1)
        clock.set(100.2)
        router.pause(hostTime: clock.now())
        let paused = router.meterSnapshot()
        #expect(paused.elapsedSamples == 3_200)
        #expect(paused.levels[.microphone] == 0)
        clock.set(110)
        router.enqueue(try recordingMeterPCM(16_384), source: .microphone, hostTime: 110)
        await router.render(hostTime: 110)
        #expect(router.meterSnapshot().elapsedSamples == paused.elapsedSamples)
        #expect(router.meterSnapshot().levels[.microphone] == 0)
        router.resume(hostTime: 110)
        clock.set(110.1)
        #expect(router.meterSnapshot().elapsedSamples == 4_800)
        #expect(router.meterSnapshot().levels[.microphone] == 0)
        try await router.finish(hostTime: 110.1)
        router.enqueue(try recordingMeterPCM(16_384), source: .microphone, hostTime: 110.1)
        await router.render(hostTime: 110.1)
        #expect(router.meterSnapshot().levels[.microphone] == 0)
    }

    @Test("quantization stays bounded, logarithmic, chronological and exactly flat for silence")
    func historyBoundaries() {
        var history = MeetingRecordingMeterHistory()
        for _ in 0..<40 { history.append(rms: 0) }
        #expect(history.levels == Array(repeating: 0, count: 32))
        history.append(rms: 0.001)
        history.append(rms: 0.01)
        history.append(rms: 0.1)
        history.append(rms: 1)
        #expect(Array(history.levels.suffix(4)) == [0, 85, 170, 255])
        history.append(rms: .nan)
        history.append(rms: .infinity)
        history.append(rms: -1)
        #expect(Array(history.levels.suffix(3)) == [0, 0, 0])
        #expect(history.levels.count == 32)
        history.clear()
        #expect(history.levels == Array(repeating: 0, count: 32))
        history.append(rms: 1)
        #expect(history.levels.last == 255)
        #expect(history.levels.dropLast().allSatisfy { $0 == 0 })
    }
}
