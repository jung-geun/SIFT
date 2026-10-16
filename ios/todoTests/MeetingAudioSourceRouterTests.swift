import AVFoundation
import Foundation
import Testing
@testable import todo

private typealias Router = MeetingAudioSourceRouter
private final class RouterSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [Router.Source: [Int16]]()
    private var failures = [Router.Source]()
    private var blockSizes = [Int]()
    func append(_ source: Router.Source, _ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            storage[source, default: []].append(contentsOf: UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
            blockSizes.append(Int(buffer.frameLength))
        }
    }
    func record(_ source: Router.Source, _ error: Error) { lock.withLock { failures.append(source) } }
    func samples(_ source: Router.Source = .microphone) -> [Int16] { lock.withLock { storage[source] ?? [] } }
    var failedSources: [Router.Source] { lock.withLock { failures } }
    var sizes: [Int] { lock.withLock { blockSizes } }
}
private final class RouterClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 100.0
    func now() -> Double { lock.withLock { value } }
    func set(_ value: Double) { lock.withLock { self.value = value } }
}
private func routerPCM(_ samples: [Int16], rate: Double = 16_000) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let channel = try #require(buffer.int16ChannelData?[0])
    for index in samples.indices { channel[index] = samples[index] }
    return buffer
}
private func routerPCM(_ sample: Int16, count: Int, rate: Double = 16_000) throws -> AVAudioPCMBuffer {
    try routerPCM(Array(repeating: sample, count: count), rate: rate)
}
private func insert(_ samples: [Int16], at start: Int64, into core: MeetingAudioSourceRouterCore) -> Bool {
    samples.withUnsafeBufferPointer { core.insert($0, at: start) }
}
private func render(_ count: Int, from core: MeetingAudioSourceRouterCore) -> [Int16] {
    var result = Array(repeating: Int16(0), count: count)
    result.withUnsafeMutableBufferPointer { core.render(into: $0.baseAddress!, count: count) }
    return result
}

@Suite("Independent host-aligned meeting source router")
struct MeetingAudioSourceRouterTests {
    @Test("simultaneous core rings preserve full-scale samples independently")
    func isolatedUnityGainRings() {
        let mic = MeetingAudioSourceRouterCore(capacity: 16)
        let app = MeetingAudioSourceRouterCore(capacity: 16)
        #expect(insert([100, .max, .min, 300], at: 2, into: mic))
        #expect(insert([.max, .min, -500], at: 3, into: app))
        #expect(render(8, from: mic) == [0, 0, 100, .max, .min, 300, 0, 0])
        #expect(render(8, from: app) == [0, 0, 0, .max, .min, -500, 0, 0])
    }
    @Test("bounded ring wraps, drops late data, rejects future and integer overflow")
    func ringBounds() {
        let core = MeetingAudioSourceRouterCore(capacity: 8)
        #expect(insert([1, 2, 3, 4], at: 4, into: core))
        #expect(render(6, from: core) == [0, 0, 0, 0, 1, 2])
        #expect(insert([70, 80, 90, 100], at: 7, into: core))
        #expect(insert([99, 99, 99], at: 1, into: core))
        #expect(!insert([7, 8], at: 13, into: core))
        #expect(!insert([7, 8], at: Int64.max, into: core))
        #expect(render(8, from: core) == [3, 70, 80, 90, 100, 0, 0, 0])
        #expect(render(8, from: core) == Array(repeating: 0, count: 8))
    }
    @Test("same-track overlap replaces rather than amplifying and clear revokes all pending PCM")
    func overlapAndClear() {
        let core = MeetingAudioSourceRouterCore(capacity: 8)
        #expect(insert([10, 20, 30], at: 0, into: core))
        #expect(insert([40, 50], at: 1, into: core))
        #expect(render(4, from: core) == [10, 40, 50, 0])
        #expect(insert([99, 99], at: 4, into: core))
        core.clear()
        #expect(render(4, from: core) == [0, 0, 0, 0])
    }
    @Test("mic plus four simultaneous applications remain separate at unity gain")
    func allSourcesIndependent() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        let apps: [Router.Source] = [.appAudio, .application("a"), .application("b"), .application("c")]
        for (index, source) in apps.enumerated() {
            router.setEnabled(true, source: source, hostTime: 100)
            router.enqueue(try routerPCM(Int16(10_000 + index * 5_000), count: 320), source: source, hostTime: 100)
        }
        router.enqueue(try routerPCM(.max, count: 320), source: .microphone, hostTime: 100)
        try await router.finish(hostTime: 100.02)
        #expect(sink.samples() == Array(repeating: .max, count: 320))
        for (index, source) in apps.enumerated() {
            #expect(sink.samples(source) == Array(repeating: Int16(10_000 + index * 5_000), count: 320))
        }
        #expect(sink.failedSources.isEmpty)
        #expect(sink.sizes.allSatisfy { $0 <= 320 })
    }
    @Test("late child starts at local zero with group offset and its own metadata")
    func childOffsetsAndMetadata() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.setSelection("microphone-route", source: .microphone, hostTime: 99)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.setEnabled(true, source: .appAudio, hostTime: 100.01)
        router.setSelection("approved-window", source: .appAudio, hostTime: 100.01)
        router.enqueue(try routerPCM(10, count: 320), source: .microphone, hostTime: 100)
        router.enqueue(try routerPCM(20, count: 160), source: .appAudio, hostTime: 100.01)
        try await router.finish(hostTime: 100.03)
        #expect(router.sessionStartSample(for: .microphone) == 0)
        #expect(router.sessionStartSample(for: .appAudio) == 160)
        #expect(sink.samples() == Array(repeating: Int16(10), count: 320) + Array(repeating: 0, count: 160))
        #expect(sink.samples(.appAudio) == Array(repeating: Int16(20), count: 160) + Array(repeating: 0, count: 160))
        let mic = await router.captureSourceMetadata(for: .microphone).boundaries
        let app = await router.captureSourceMetadata(for: .appAudio).boundaries
        #expect(mic.allSatisfy { $0.source == .microphone && $0.selection != "approved-window" })
        #expect(app.allSatisfy { $0.source == .appAudio && $0.selection != "microphone-route" })
        #expect(app.filter { $0.action == .enabled || $0.action == .selection }.allSatisfy { $0.sample == 0 })
    }
    @Test("approved silence and input gaps produce real samples without creating unapproved tracks")
    func silenceCadence() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: false)
        router.enqueue(try routerPCM(100, count: 16_000), source: .microphone, hostTime: 100)
        router.setEnabled(true, source: .appAudio, hostTime: 100)
        await router.render(hostTime: 100.219)
        #expect(sink.samples(.appAudio).isEmpty)
        await router.render(hostTime: 100.22)
        #expect(sink.samples(.appAudio) == Array(repeating: 0, count: 320))
        try await router.finish(hostTime: 100.04)
        #expect(sink.samples(.appAudio) == Array(repeating: 0, count: 640))
        #expect(sink.samples().isEmpty)
        #expect(router.sessionStartSample(for: .microphone) == nil)
        #expect(router.metrics().highWaterMark == 0)
        #expect(sink.failedSources.isEmpty)
    }
    @Test("off/on revokes only own converted PCM and rejects stale spanning callbacks")
    func sourceEpochRevocation() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.setEnabled(true, source: .appAudio, hostTime: 100)
        router.enqueue(try routerPCM(5, count: 640), source: .appAudio, hostTime: 100)
        router.enqueue(try routerPCM(100, count: 320), source: .microphone, hostTime: 100)
        await router.render(hostTime: 100.1)
        router.setEnabled(false, source: .microphone, hostTime: 100.01)
        router.enqueue(try routerPCM(900, count: 320), source: .microphone, hostTime: 100.01)
        router.setEnabled(true, source: .microphone, hostTime: 100.02)
        router.enqueue(try routerPCM(800, count: 320), source: .microphone, hostTime: 100.015)
        router.enqueue(try routerPCM(7, count: 320), source: .microphone, hostTime: 100.02)
        try await router.finish(hostTime: 100.04)
        #expect(sink.samples() == Array(repeating: Int16(0), count: 320) + Array(repeating: Int16(7), count: 320))
        #expect(sink.samples(.appAudio) == Array(repeating: 5, count: 640))
        #expect(router.deliveryMetrics().microphoneBuffers == 2)
        #expect(router.deliveryMetrics().appAudioBuffers == 1)
        #expect(sink.failedSources.isEmpty)
    }
    @Test("pause clips accepted prefixes for every track and finish keeps paused endpoint")
    func pauseThenFinish() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.setEnabled(true, source: .appAudio, hostTime: 100.025)
        router.enqueue(try routerPCM(17, count: 1_600), source: .microphone, hostTime: 100)
        router.enqueue(try routerPCM(31, count: 1_600), source: .appAudio, hostTime: 100.025)
        router.pause(hostTime: 100.075)
        router.enqueue(try routerPCM(99, count: 160), source: .microphone, hostTime: 100.075)
        await router.render(hostTime: 200)
        try await router.finish(hostTime: 200)
        #expect(sink.samples() == Array(repeating: 17, count: 1_200))
        #expect(sink.samples(.appAudio) == Array(repeating: 31, count: 800))
        #expect(sink.failedSources.isEmpty)
    }
    @Test("group pause clock excludes wall time and preserves source configuration changed while paused")
    func groupedPauseResume() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.pause(hostTime: 100.01)
        router.setEnabled(true, source: .appAudio, hostTime: 101)
        router.resume(hostTime: 102)
        router.enqueue(try routerPCM(99, count: 320), source: .microphone, hostTime: 101.999)
        router.enqueue(try routerPCM(7, count: 160), source: .microphone, hostTime: 102)
        router.enqueue(try routerPCM(9, count: 160), source: .appAudio, hostTime: 102)
        try await router.finish(hostTime: 102.01)
        #expect(sink.samples() == Array(repeating: Int16(0), count: 160) + Array(repeating: Int16(7), count: 160))
        #expect(sink.samples(.appAudio) == Array(repeating: 9, count: 160))
        #expect(router.sessionStartSample(for: .appAudio) == 160)
        let mic = await router.captureSourceMetadata(for: .microphone).boundaries
        let app = await router.captureSourceMetadata(for: .appAudio).boundaries
        #expect(mic.filter { $0.action == .resumed }.map(\.sample) == [160])
        #expect(app.filter { $0.action == .resumed }.map(\.sample) == [0])
        #expect(sink.failedSources.isEmpty)
    }
    @Test("source close preserves valid pending tail without stopping another source")
    func independentClose() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.setEnabled(true, source: .appAudio, hostTime: 100)
        router.enqueue(try routerPCM(17, count: 1_600), source: .microphone, hostTime: 100)
        router.enqueue(try routerPCM(29, count: 1_600), source: .appAudio, hostTime: 100)
        router.close(source: .microphone, hostTime: 100.06)
        router.enqueue(try routerPCM(99, count: 160), source: .microphone, hostTime: 100.06)
        try await router.finish(hostTime: 100.1)
        #expect(sink.samples() == Array(repeating: 17, count: 960))
        #expect(sink.samples(.appAudio) == Array(repeating: 29, count: 1_600))
        #expect(sink.failedSources.isEmpty)
    }
    @Test("close followed by retirement drains queued valid prefix before release and retired disable cannot recreate it")
    func closeThenRetirePreservesPrefix() async throws {
        let sink = RouterSamples()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let router = try Router(automaticallyRenders: false, consume: { source, buffer in
            sink.append(source, buffer)
            if source == .microphone && sink.samples().count == 320 { entered.signal(); release.wait() }
        }, failed: sink.record)
        defer { release.signal() }
        router.start(hostTime: 100, microphoneEnabled: true)
        let rendering = Task.detached { await router.render(hostTime: 100.22) }
        let enteredInTime = await Task.detached { entered.wait(timeout: .now() + 2) == .success }.value
        try #require(enteredInTime)
        // This source's conversion and close both wait behind microphone consume.
        router.setEnabled(true, source: .appAudio, hostTime: 100.02)
        router.setSelection("old-window", source: .appAudio, hostTime: 100.02)
        router.enqueue(try routerPCM(29, count: 1_600), source: .appAudio, hostTime: 100.02)
        router.close(source: .appAudio, hostTime: 100.06)
        router.enqueue(try routerPCM(99, count: 160), source: .appAudio, hostTime: 100.06)
        // Allow the retirement call to overlap the still-blocked conversion queue.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { release.signal() }
        let metadata = try await router.retire(source: .appAudio, hostTime: 100.06)
        await rendering.value
        #expect(sink.samples(.appAudio) == Array(repeating: 29, count: 640))
        #expect(metadata.boundaries.filter { $0.action == .disabled }.isEmpty)
        #expect(router.sessionStartSample(for: .appAudio) == nil)
        router.setEnabled(false, source: .appAudio, hostTime: 100.07)
        #expect(router.sessionStartSample(for: .appAudio) == nil)
        router.setEnabled(true, source: .appAudio, hostTime: 100.08)
        router.setSelection("new-window", source: .appAudio, hostTime: 100.08)
        router.enqueue(try routerPCM(7, count: 320), source: .appAudio, hostTime: 100.08)
        try await router.finish(hostTime: 100.1)
        #expect(router.sessionStartSample(for: .appAudio) == 1_280)
        #expect(sink.samples(.appAudio) == Array(repeating: Int16(29), count: 640) + Array(repeating: Int16(7), count: 320))
        let fresh = await router.captureSourceMetadata(for: .appAudio).boundaries
        #expect(fresh.filter { $0.action == .enabled }.map(\.sample) == [0])
        #expect(fresh.contains { $0.selection == "new-window" && $0.sample == 0 })
        #expect(!fresh.contains { $0.selection == "old-window" })
        #expect(sink.failedSources.isEmpty)
    }
    @Test("stopping microphone delivery after admission closes preserves the valid source prefix")
    func stoppingCapturePreservesMicrophoneTail() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        let input = MeetingAppAudioInputSink()
        input.attach(router)
        let ticket = input.microphoneConsent.beginApproval()
        #expect(input.microphoneConsent.approve(ticket, enabled: true))
        router.start(hostTime: 100, microphoneEnabled: true)
        input.enqueue(try routerPCM(17, count: 1_600), hostTime: 100, source: .microphone)
        router.pause(hostTime: 100.06)
        input.stopMicrophoneDelivery()
        input.enqueue(try routerPCM(99, count: 160), hostTime: 100.06, source: .microphone)
        try await router.finish(hostTime: 100.06)
        #expect(sink.samples() == Array(repeating: 17, count: 960))
        #expect(sink.failedSources.isEmpty)
        let boundaries = await router.captureSourceMetadata(for: .microphone).boundaries
        #expect(boundaries.filter { $0.action == .disabled }.isEmpty)
        #expect(boundaries.filter { $0.action == .paused }.map(\.sample) == [960])
    }
    @Test("pause during one source callback shares the committed group endpoint with every track")
    func pauseDuringDelivery() async throws {
        let sink = RouterSamples()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let router = try Router(automaticallyRenders: false, consume: { source, buffer in
            sink.append(source, buffer)
            if source == .microphone && sink.samples().count == 320 { entered.signal(); release.wait() }
        }, failed: sink.record)
        defer { release.signal() }
        router.start(hostTime: 100, microphoneEnabled: true)
        router.setEnabled(true, source: .appAudio, hostTime: 100)
        router.enqueue(try routerPCM(13, count: 640), source: .microphone, hostTime: 100)
        router.enqueue(try routerPCM(29, count: 640), source: .appAudio, hostTime: 100)
        let rendering = Task.detached { await router.render(hostTime: 100.24) }
        let enteredInTime = await Task.detached { entered.wait(timeout: .now() + 2) == .success }.value
        try #require(enteredInTime)
        router.pause(hostTime: 100.01)
        release.signal()
        await rendering.value
        try await router.finish(hostTime: 200)
        #expect(sink.samples() == Array(repeating: 13, count: 320))
        #expect(sink.samples(.appAudio) == Array(repeating: 29, count: 320))
        for source in [Router.Source.microphone, .appAudio] {
            let events = await router.captureSourceMetadata(for: source).boundaries
            #expect(events.filter { $0.action == .paused }.map(\.sample) == [320])
        }
    }
    @Test("retirement revokes pending data, frees slot and re-enable creates a new local zero")
    func retirementAndReuse() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.enqueue(try routerPCM(11, count: 640), source: .microphone, hostTime: 100)
        await router.render(hostTime: 100.22)
        let metadata = try await router.retire(source: .microphone, hostTime: 100.03)
        #expect(sink.samples() == Array(repeating: 11, count: 320))
        #expect(metadata.boundaries.last?.sample == 320)
        #expect(router.sessionStartSample(for: .microphone) == nil)
        router.setEnabled(true, source: .microphone, hostTime: 100.04)
        router.enqueue(try routerPCM(99, count: 320), source: .microphone, hostTime: 100.03)
        router.enqueue(try routerPCM(7, count: 320), source: .microphone, hostTime: 100.04)
        try await router.finish(hostTime: 100.06)
        #expect(router.sessionStartSample(for: .microphone) == 640)
        #expect(sink.samples() == Array(repeating: Int16(11), count: 320) + Array(repeating: Int16(7), count: 320))
        let fresh = await router.captureSourceMetadata(for: .microphone).boundaries
        #expect(fresh.filter { $0.action == .enabled }.map(\.sample) == [0])
    }
    @Test("four application limit includes primary slot; retirement permits a replacement")
    func sourceCountBound() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        let apps: [Router.Source] = [.appAudio, .application("a"), .application("b"), .application("c")]
        for source in apps { router.setEnabled(true, source: source, hostTime: 100) }
        let extra = Router.Source.application("extra")
        router.setEnabled(true, source: extra, hostTime: 100)
        #expect(router.sessionStartSample(for: extra) == nil)
        #expect(sink.failedSources == [extra])
        _ = try await router.retire(source: .application("a"), hostTime: 100)
        router.setEnabled(true, source: extra, hostTime: 100)
        router.enqueue(try routerPCM(23, count: 320), source: extra, hostTime: 100)
        try await router.finish(hostTime: 100.02)
        #expect(sink.samples(extra) == Array(repeating: 23, count: 320))
    }
    @Test("unsupported source fails once without poisoning healthy sources or finish")
    func independentInputFailure() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.setEnabled(true, source: .appAudio, hostTime: 100)
        router.enqueue(try routerPCM(1, count: 16_000), source: .microphone, hostTime: 100)
        router.enqueue(try routerPCM(1, count: 16_000), source: .microphone, hostTime: 100)
        router.enqueue(try routerPCM(29, count: 320), source: .appAudio, hostTime: 100)
        try await router.finish(hostTime: 100.02)
        #expect(sink.failedSources == [.microphone])
        #expect(sink.samples().isEmpty)
        #expect(sink.samples(.appAudio) == Array(repeating: 29, count: 320))
    }
    @Test("consumer failure is scoped to its source")
    func independentConsumerFailure() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: { source, buffer in
            if source == .microphone { throw Router.RouterError.conversionFailed }
            sink.append(source, buffer)
        }, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.setEnabled(true, source: .appAudio, hostTime: 100)
        router.enqueue(try routerPCM(29, count: 640), source: .appAudio, hostTime: 100)
        try await router.finish(hostTime: 100.04)
        #expect(sink.failedSources == [.microphone])
        #expect(sink.samples(.appAudio) == Array(repeating: 29, count: 640))
    }
    @Test("distinct source rates normalize independently, not to a summed waveform")
    func independentConverters() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.setEnabled(true, source: .appAudio, hostTime: 100)
        router.enqueue(try routerPCM(2_000, count: 1_920, rate: 48_000), source: .microphone, hostTime: 100)
        router.enqueue(try routerPCM(4_000, count: 1_764, rate: 44_100), source: .appAudio, hostTime: 100)
        try await router.finish(hostTime: 100.04)
        for (source, level) in [(Router.Source.microphone, 2_000), (.appAudio, 4_000)] {
            let samples = sink.samples(source)
            #expect(samples.count == 640)
            #expect(samples.dropFirst(64).dropLast(64).allSatisfy { abs(Int($0) - level) <= 2 })
        }
        #expect(sink.failedSources.isEmpty)
    }
    @Test("odd-sized callbacks retain resampler phase and history", arguments: [44_100.0, 48_000.0])
    func continuousResamplerHistory(rate: Double) async throws {
        let lengths = [127, 511, 113, 997, 251, 733, 59, 887]
        let count = lengths.reduce(0, +)
        let waveform = (0..<count).map { index in
            let time = Double(index) / rate
            return Int16((6_000 * sin(2 * Double.pi * 701 * time) + 3_000 * sin(2 * Double.pi * 2_713 * time)).rounded())
        }
        let reference = RouterSamples()
        let whole = try Router(automaticallyRenders: false, consume: reference.append, failed: reference.record)
        whole.start(hostTime: 100, microphoneEnabled: true)
        whole.enqueue(try routerPCM(waveform, rate: rate), source: .microphone, hostTime: 100)
        try await whole.finish(hostTime: 100 + Double(count) / rate)
        let split = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: split.append, failed: split.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        var offset = 0
        for length in lengths {
            router.enqueue(try routerPCM(Array(waveform[offset..<(offset + length)]), rate: rate),
                           source: .microphone, hostTime: 100 + Double(offset) / rate)
            offset += length
        }
        try await router.finish(hostTime: 100 + Double(count) / rate)
        let expected = reference.samples(), actual = split.samples()
        #expect(expected.count == Int((Double(count) * 16_000 / rate).rounded()))
        try #require(actual.count == expected.count)
        #expect((16..<(actual.count - 32)).allSatisfy { abs(Int(actual[$0]) - Int(expected[$0])) <= 2 })
        #expect(reference.failedSources.isEmpty && split.failedSources.isEmpty)
    }
    @Test("one-frame timestamp gaps remain silence and do not accumulate concatenation drift")
    func timestampGaps() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        for index in 0..<10 {
            router.enqueue(try routerPCM(777, count: 320), source: .microphone, hostTime: 100 + Double(index * 321) / 16_000)
        }
        try await router.finish(hostTime: 100 + Double(3_210) / 16_000)
        let samples = sink.samples()
        try #require(samples.count == 3_210)
        #expect(samples.filter { $0 == 0 }.count == 10)
        for index in 0..<10 { #expect(samples[index * 321 + 319] == 777); #expect(samples[index * 321 + 320] == 0) }
    }
    @Test("planar float stereo is normalized within its own track")
    func stereoFloatConversion() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_920))
        input.frameLength = 1_920
        let channels = try #require(input.floatChannelData)
        for frame in 0..<1_920 { channels[0][frame] = 0.25; channels[1][frame] = 0.25 }
        router.start(hostTime: 100, microphoneEnabled: true)
        router.enqueue(input, source: .microphone, hostTime: 100)
        try await router.finish(hostTime: 100.04)
        #expect(sink.samples().count == 640)
        #expect(sink.samples().dropFirst(64).dropLast(64).allSatisfy { abs(Int($0) - 8_192) <= 2 })
    }
    @Test("resampled gaps remain silence")
    func resampledGap() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.enqueue(try routerPCM(3_000, count: 960, rate: 48_000), source: .microphone, hostTime: 100)
        router.enqueue(try routerPCM(-3_000, count: 960, rate: 48_000), source: .microphone, hostTime: 100.04)
        try await router.finish(hostTime: 100.06)
        let samples = sink.samples()
        try #require(samples.count == 960)
        #expect(samples[64..<256].allSatisfy { abs(Int($0) - 3_000) <= 2 })
        #expect(samples[320..<640].allSatisfy { $0 == 0 })
        #expect(samples[704..<896].allSatisfy { abs(Int($0) + 3_000) <= 2 })
    }
    @Test("converter history is discarded across off/on and pause/resume")
    func converterHistoryRevocation() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.enqueue(try routerPCM(24_000, count: 960, rate: 48_000), source: .microphone, hostTime: 100)
        await router.render(hostTime: 100.1)
        router.setEnabled(false, source: .microphone, hostTime: 100.02)
        router.setEnabled(true, source: .microphone, hostTime: 100.03)
        router.enqueue(try routerPCM(0, count: 960, rate: 48_000), source: .microphone, hostTime: 100.03)
        router.pause(hostTime: 100.05)
        await router.render(hostTime: 100.5)
        #expect(sink.samples() == Array(repeating: 0, count: 800))
        router.resume(hostTime: 101)
        router.enqueue(try routerPCM(24_000, count: 960, rate: 48_000), source: .microphone, hostTime: 101)
        router.pause(hostTime: 101.02)
        await router.render(hostTime: 102)
        router.resume(hostTime: 103)
        router.enqueue(try routerPCM(0, count: 960, rate: 48_000), source: .microphone, hostTime: 103)
        try await router.finish(hostTime: 103.02)
        let samples = sink.samples()
        try #require(samples.count == 1_440)
        #expect(samples[864..<1_056].allSatisfy { abs(Int($0) - 24_000) <= 2 })
        #expect(samples[1_120..<1_440].allSatisfy { $0 == 0 })
    }
    @Test("capture buffer is copied before producer reuse")
    func ownsRawInput() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        let input = try routerPCM(37, count: 320)
        router.enqueue(input, source: .microphone, hostTime: 100)
        for index in 0..<320 { input.int16ChannelData![0][index] = -37 }
        try await router.finish(hostTime: 100.02)
        #expect(sink.samples() == Array(repeating: 37, count: 320))
    }
    @Test("raw work waiting behind consumption is revoked without affecting another source")
    func queuedRawRevocation() async throws {
        let sink = RouterSamples()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let router = try Router(automaticallyRenders: false, consume: { source, buffer in
            sink.append(source, buffer)
            if source == .microphone && sink.samples().count == 320 { entered.signal(); release.wait() }
        }, failed: sink.record)
        defer { release.signal() }
        router.start(hostTime: 100, microphoneEnabled: true)
        router.setEnabled(true, source: .appAudio, hostTime: 100)
        let rendering = Task.detached { await router.render(hostTime: 100.22) }
        let enteredInTime = await Task.detached { entered.wait(timeout: .now() + 2) == .success }.value
        try #require(enteredInTime)
        router.enqueue(try routerPCM(37, count: 320), source: .microphone, hostTime: 100.02)
        router.enqueue(try routerPCM(8, count: 320), source: .appAudio, hostTime: 100.02)
        router.setEnabled(false, source: .microphone, hostTime: 100.03)
        router.setEnabled(true, source: .microphone, hostTime: 100.04)
        router.enqueue(try routerPCM(88, count: 320), source: .microphone, hostTime: 100.035)
        router.enqueue(try routerPCM(9, count: 320), source: .microphone, hostTime: 100.04)
        release.signal()
        await rendering.value
        try await router.finish(hostTime: 100.06)
        #expect(sink.samples() == Array(repeating: Int16(0), count: 640) + Array(repeating: Int16(9), count: 320))
        #expect(sink.samples(.appAudio) == Array(repeating: Int16(0), count: 320) + Array(repeating: Int16(8), count: 320) + Array(repeating: Int16(0), count: 320))
        #expect(sink.failedSources.isEmpty)
    }
    @Test("raw backlog has a hard capacity and source-local overflow fails once")
    func boundedRawBacklog() async throws {
        let sink = RouterSamples()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let router = try Router(maximumQueuedBuffers: 1, automaticallyRenders: false, consume: { source, buffer in
            sink.append(source, buffer)
            if source == .microphone && sink.samples().count == 320 { entered.signal(); release.wait() }
        }, failed: sink.record)
        defer { release.signal() }
        router.start(hostTime: 100, microphoneEnabled: true)
        let rendering = Task.detached { await router.render(hostTime: 100.22) }
        let enteredInTime = await Task.detached { entered.wait(timeout: .now() + 2) == .success }.value
        try #require(enteredInTime)
        router.enqueue(try routerPCM(37, count: 320), source: .microphone, hostTime: 100.02)
        router.enqueue(try routerPCM(38, count: 320), source: .microphone, hostTime: 100.04)
        router.enqueue(try routerPCM(39, count: 320), source: .microphone, hostTime: 100.06)
        release.signal()
        await rendering.value
        try await router.finish(hostTime: 100.08)
        #expect(sink.failedSources == [.microphone])
        #expect(router.metrics().highWaterMark == 1)
        #expect(sink.samples() == Array(repeating: 0, count: 320))
    }
    @Test("future PCM and long output catch-up remain bounded")
    func boundedTimeline() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.enqueue(try routerPCM(1, count: 320), source: .microphone, hostTime: 103)
        await router.render(hostTime: 100.1)
        #expect(sink.failedSources == [.microphone])
        #expect(sink.samples().isEmpty)
        router.setEnabled(true, source: .appAudio, hostTime: 100)
        await router.render(hostTime: 200)
        #expect(sink.failedSources == [.microphone, .appAudio])
        #expect(sink.samples(.appAudio).isEmpty)
        await router.cancel()
    }
    @Test("local levels age out and reset independently at privacy gates")
    func sourceLevels() async throws {
        let sink = RouterSamples(), clock = RouterClock()
        let router = try Router(automaticallyRenders: false, clock: clock.now, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.setEnabled(true, source: .appAudio, hostTime: 100)
        router.enqueue(try routerPCM(16_384, count: 320), source: .microphone, hostTime: 100)
        router.enqueue(try routerPCM(8_192, count: 320), source: .appAudio, hostTime: 100)
        await router.render(hostTime: 100.1)
        #expect(router.sourceLevels().microphoneRMS == 0.5)
        #expect(router.sourceLevels().appAudioRMS == 0.25)
        router.setEnabled(false, source: .microphone, hostTime: 100.01)
        #expect(router.sourceLevels().microphoneRMS == 0)
        #expect(router.sourceLevels().appAudioRMS == 0.25)
        clock.set(100.51)
        #expect(router.sourceLevels().appAudioRMS == 0)
        await router.cancel()
        #expect(router.sourceLevels().microphoneRMS == 0 && router.sourceLevels().appAudioRMS == 0)
    }
    @Test("source metadata prunes revoked future selection and clamps local endpoints")
    func metadataRedaction() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.setEnabled(true, source: .appAudio, hostTime: 100.01)
        router.setSelection("window", source: .appAudio, hostTime: 100.015)
        router.setEnabled(false, source: .appAudio, hostTime: 100.019)
        try await router.finish(hostTime: 100.04)
        let events = await router.captureSourceMetadata(for: .appAudio).boundaries
        #expect(events.filter { $0.action == .enabled || $0.action == .selection }.isEmpty)
        #expect(events.map(\.sample) == events.map(\.sample).sorted())
        #expect(events.allSatisfy { $0.sample <= 480 })
        #expect(sink.samples(.appAudio) == Array(repeating: 0, count: 480))
    }
    @Test("cancel discards pending source data and converter history; finish remains cancelled")
    func cancelCleanup() async throws {
        let sink = RouterSamples()
        let router = try Router(automaticallyRenders: false, consume: sink.append, failed: sink.record)
        router.start(hostTime: 100, microphoneEnabled: true)
        router.setEnabled(true, source: .appAudio, hostTime: 100)
        router.enqueue(try routerPCM(37, count: 960, rate: 48_000), source: .microphone, hostTime: 100)
        router.enqueue(try routerPCM(49, count: 320), source: .appAudio, hostTime: 100)
        await router.cancel()
        await #expect(throws: CancellationError.self) { try await router.finish(hostTime: 100.02) }
        #expect(sink.samples().isEmpty && sink.samples(.appAudio).isEmpty)
        #expect(sink.failedSources.isEmpty)
    }
}
