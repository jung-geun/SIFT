import AVFoundation
import Foundation
import Testing
@testable import todo

@Suite("Meeting playback streaming and waveform cache")
struct MeetingPlaybackStreamTests {
    /// Writes a synthesized recording under the real meeting directory so the
    /// logical cursor can resolve it, and returns its manifest.
    private func makeFixture(totalSamples: Int) throws -> (manifest: MeetingAudioManifest, cleanup: URL) {
        let name = "test-\(UUID().uuidString.lowercased())"
        let root = AppDataContainer.meetingDirectory().appendingPathComponent(name, isDirectory: true)
        let audioDirectory = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        let writer = try MeetingFLACPartWriter(directory: audioDirectory)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(MeetingMediaTimeline.sampleRate),
            channels: 1,
            interleaved: true
        ))
        var written = 0
        while written < totalSamples {
            let frames = min(8_000, totalSamples - written)
            let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            input.frameLength = AVAudioFrameCount(frames)
            let samples = try #require(input.int16ChannelData?[0])
            for index in 0..<frames {
                samples[index] = Int16(truncatingIfNeeded: (written + index) % 8_000)
            }
            try writer.append(input)
            written += frames
        }
        _ = try writer.finish()
        return (writer.manifest(relativeDirectory: "\(name)/audio"), root)
    }

    @Test("bounded scheduler streams the whole timeline to completion")
    func schedulerStreamsToCompletion() async throws {
        let fixture = try makeFixture(totalSamples: 48_000)
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(fixture.manifest.sampleRate),
            channels: 1,
            interleaved: false
        ))
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        try engine.start()
        node.play()

        final class EventBox: @unchecked Sendable {
            private let lock = NSLock()
            private var finishedFlag = false
            private var failure: Error?
            func record(_ event: MeetingPlaybackStreamScheduler.Event) {
                lock.lock()
                defer { lock.unlock() }
                switch event {
                case .finished: finishedFlag = true
                case .failed(let error, _): failure = error
                }
            }
            var finished: Bool { lock.lock(); defer { lock.unlock() }; return finishedFlag }
            var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
        }
        let events = EventBox()

        let cursor = try MeetingLogicalAudioCursor(manifest: fixture.manifest)
        let scheduler = MeetingPlaybackStreamScheduler(cursor: cursor, node: node, format: format)
        scheduler.onEvent = { events.record($0) }
        try scheduler.start()

        let render = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
        var iterations = 0
        while !events.finished, events.error == nil, iterations < 400 {
            let status = try engine.renderOffline(4_096, to: render)
            #expect(status == .success)
            iterations += 1
            // Refills hop through the scheduler queue; give them a beat.
            try await Task.sleep(for: .milliseconds(2))
        }
        node.stop()
        engine.stop()
        #expect(events.error == nil)
        #expect(events.finished)
    }

    @Test("waveform generation caches by manifest and stays deterministic")
    func waveformCache() throws {
        let fixture = try makeFixture(totalSamples: 32_000)
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }

        let first = try MeetingWaveformGenerator.generate(manifest: fixture.manifest, bucketCount: 90)
        let second = try MeetingWaveformGenerator.generate(manifest: fixture.manifest, bucketCount: 90)
        #expect(first == second)
        #expect(first.buckets.count == 90)
        #expect(first.totalSamples == 32_000)
        #expect(first.buckets.contains { $0 > 0 })

        let differentBuckets = try MeetingWaveformGenerator.generate(manifest: fixture.manifest, bucketCount: 45)
        #expect(differentBuckets.buckets.count == 45)
    }
    @Test("logical samples convert to floored milliseconds")
    func playbackMilliseconds() {
        #expect(MeetingAudioPlaybackController.milliseconds(forLogicalSample: 47, sampleRate: 48_000) == 0)
        #expect(MeetingAudioPlaybackController.milliseconds(forLogicalSample: 48, sampleRate: 48_000) == 1)
        #expect(MeetingAudioPlaybackController.milliseconds(forLogicalSample: 95, sampleRate: 48_000) == 1)
        #expect(MeetingAudioPlaybackController.milliseconds(forLogicalSample: 96, sampleRate: 48_000) == 2)
        #expect(MeetingAudioPlaybackController.milliseconds(forLogicalSample: 44, sampleRate: 44_100) == 0)
        #expect(MeetingAudioPlaybackController.milliseconds(forLogicalSample: 45, sampleRate: 44_100) == 1)
        #expect(MeetingAudioPlaybackController.milliseconds(forLogicalSample: 44_100, sampleRate: 44_100) == 1_000)
        #expect(MeetingAudioPlaybackController.milliseconds(forLogicalSample: -1, sampleRate: 48_000) == 0)
        #expect(MeetingAudioPlaybackController.milliseconds(forLogicalSample: 1, sampleRate: 0) == 0)
    }

    @Test("output percentage maps around unity without stale gain")
    func outputMix() {
        let muted = MeetingAudioPlaybackController.outputMix(for: 0)
        #expect(muted.volume == 0)
        #expect(muted.gainDB == 0)

        let half = MeetingAudioPlaybackController.outputMix(for: 50)
        #expect(abs(half.volume - 0.5) < 0.0001)
        #expect(half.gainDB == 0)

        let unity = MeetingAudioPlaybackController.outputMix(for: 100)
        #expect(unity.volume == 1)
        #expect(unity.gainDB == 0)

        let doubled = MeetingAudioPlaybackController.outputMix(for: 200)
        #expect(doubled.volume == 1)
        #expect(abs(doubled.gainDB - 6.0206) < 0.001)

        let maximum = MeetingAudioPlaybackController.outputMix(for: 400)
        #expect(maximum.volume == 1)
        #expect(abs(maximum.gainDB - 12) < 0.0001)
        #expect(MeetingAudioPlaybackController.outputMix(for: 999).gainDB == 12)
        #expect(MeetingAudioPlaybackController.outputMix(for: -1).volume == 0)
    }

    @Test("waveform accessibility seeks five seconds and clamps")
    func waveformAccessibilitySeek() {
        #expect(MeetingWaveformView.adjustedProgress(0.5, totalMs: 20_000, increment: true) == 0.75)
        #expect(MeetingWaveformView.adjustedProgress(0.5, totalMs: 20_000, increment: false) == 0.25)
        #expect(MeetingWaveformView.adjustedProgress(0.95, totalMs: 20_000, increment: true) == 1)
        #expect(MeetingWaveformView.adjustedProgress(0.05, totalMs: 20_000, increment: false) == 0)
        #expect(MeetingWaveformView.adjustedProgress(0.3, totalMs: 0, increment: true) == 0.3)
    }

    @Test("completion preserves final clock and explicit stop resets it")
    @MainActor
    func outputClampAndStop() {
        let controller = MeetingAudioPlaybackController()
        controller.outputLevelPercent = -10
        #expect(controller.outputLevelPercent == 0)
        controller.outputLevelPercent = 500
        #expect(controller.outputLevelPercent == 400)

        controller.completePlayback(totalSamples: 48_000, sampleRate: 48_000)
        #expect(controller.playbackProgress == 1)
        #expect(controller.playbackMilliseconds == 1_000)

        controller.stop(resetProgress: true)
        #expect(controller.playbackProgress == 0)
        #expect(controller.playbackMilliseconds == 0)

        controller.completePlayback(totalSamples: 96_000, sampleRate: 48_000)
        controller.stop()
        #expect(controller.playbackProgress == 0)
        #expect(controller.playbackMilliseconds == 0)
    }
}
