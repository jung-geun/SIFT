import AVFoundation
import Foundation
import Testing
@testable import todo

@Suite("Meeting waveform resolution and viewport seeking")
@MainActor
struct MeetingWaveformTests {
    @Test("78-minute and longer recordings retain ten time bins per second")
    func timeResolution() {
        let rate = MeetingMediaTimeline.sampleRate
        #expect(MeetingWaveformGenerator.recommendedBucketCount(totalSamples: 2 * rate, sampleRate: rate) == 180)
        #expect(MeetingWaveformGenerator.recommendedBucketCount(totalSamples: 60 * rate, sampleRate: rate) == 600)
        #expect(MeetingWaveformGenerator.recommendedBucketCount(totalSamples: 4_688 * rate, sampleRate: rate) == 46_880)
        #expect(MeetingWaveformGenerator.recommendedBucketCount(totalSamples: 21_600 * rate, sampleRate: rate) == 216_000)
        #expect(MeetingWaveformGenerator.recommendedBucketCount(totalSamples: 60 * 44_100, sampleRate: 44_100) == 600)
    }

    @Test("generation uses duration-aware defaults and reuses deterministic cached data")
    func adaptiveGeneration() throws {
        let fixture = try makeFixture(totalSamples: 320_000) { $0 % 1_600 == 0 ? 16_000 : 0 }
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        let first = try MeetingWaveformGenerator.generate(manifest: fixture.manifest)
        let second = try MeetingWaveformGenerator.generate(manifest: fixture.manifest)
        #expect(first.buckets.count == 200)
        #expect(first.totalSamples == 320_000)
        #expect(first == second)
        #expect(first.buckets.allSatisfy { $0 == 1 })
    }

    @Test("nondivisible sample counts span the whole timeline without a padded silent tail")
    func uniformTimelineBins() throws {
        let fixture = try makeFixture(totalSamples: 16_201) { index in
            index == 0 || index == 16_200 ? 16_000 : 0
        }
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        let waveform = try MeetingWaveformGenerator.generate(manifest: fixture.manifest, bucketCount: 180)
        #expect(waveform.totalSamples == 16_201)
        #expect(waveform.buckets.count == 180)
        #expect(waveform.buckets.first == 1)
        #expect(waveform.buckets.last == 1)
        #expect(waveform.buckets.filter { $0 > 0 }.count == 2)
    }

    @Test("silence and subthreshold noise stay empty instead of becoming minimum-height bars")
    func silence() throws {
        for amplitude in [Int16(0), Int16(16)] {
            let fixture = try makeFixture(totalSamples: 32_000) { _ in amplitude }
            defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
            let waveform = try MeetingWaveformGenerator.generate(manifest: fixture.manifest)
            #expect(waveform.totalSamples == 32_000)
            #expect(waveform.buckets.count == 180)
            #expect(waveform.buckets.allSatisfy { $0 == 0 })
        }
    }

    @Test("cancellation is honored even when the waveform is already cached")
    func cancelledCacheRead() async throws {
        let fixture = try makeFixture(totalSamples: 32_000) { _ in 0 }
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        _ = try MeetingWaveformGenerator.generate(manifest: fixture.manifest)
        let task = Task { try MeetingWaveformGenerator.generate(manifest: fixture.manifest) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("render work stays viewport-sized at the start, middle, and end of long recordings")
    func boundedVisibleBins() {
        for seconds in [Int64(4_688), Int64(21_600)] {
            let count = MeetingWaveformGenerator.recommendedBucketCount(
                totalSamples: seconds * MeetingMediaTimeline.sampleRate,
                sampleRate: MeetingMediaTimeline.sampleRate
            )
            for width in [CGFloat(320), CGFloat(1_024)] {
                for progress in [0.0, 0.12345, 0.5, 0.99999, 1.0] {
                    let layout = MeetingWaveformViewport(width: width, totalMs: seconds * 1_000, bucketCount: count, progress: progress)
                    #expect(layout.contentWidth == CGFloat(seconds) * 40)
                    #expect(layout.bucketSpan == 4)
                    #expect(layout.visibleBuckets.count <= Int(ceil(width / 4)) + 3)
                    #expect(layout.visibleBuckets.lowerBound >= 0)
                    #expect(layout.visibleBuckets.upperBound <= count)
                    #expect(!layout.visibleBuckets.isEmpty)
                    if progress == 0 { #expect(layout.visibleBuckets.lowerBound == 0) }
                    if progress == 1 { #expect(layout.visibleBuckets.upperBound == count) }
                }
            }
        }
    }

    @Test("short and empty waveforms have safe bounded geometry")
    func shortViewport() {
        let layout = MeetingWaveformViewport(width: 320, totalMs: 2_000, bucketCount: 180, progress: 0.5)
        #expect(layout.contentWidth == 320)
        #expect(layout.visibleBuckets == 0..<180)
        #expect(layout.seekProgress(from: 0.5, translation: 80) == 0.25)
        #expect(layout.seekProgress(from: 0.5, translation: -160) == 1)
        #expect(layout.seekProgress(from: 0.5, translation: 160) == 0)
        #expect(MeetingWaveformViewport(width: 320, totalMs: 0, bucketCount: 0, progress: 0).visibleBuckets.isEmpty)
        #expect(MeetingWaveformViewport(width: 0, totalMs: 2_000, bucketCount: 180, progress: 0).visibleBuckets.isEmpty)
    }

    @Test("fine seeking uses elapsed time independent of the bucket count and clamps at both ends")
    func accurateFineSeeking() {
        let totalMs: Int64 = 4_688_000
        for count in [180, 46_880] {
            let layout = MeetingWaveformViewport(width: 320, totalMs: totalMs, bucketCount: count, progress: 0.5)
            let earlier = layout.seekProgress(from: 0.5, translation: 200)
            let later = layout.seekProgress(from: 0.5, translation: -200)
            #expect(abs((0.5 - earlier) * Double(totalMs) - 5_000) < 0.0001)
            #expect(abs((later - 0.5) * Double(totalMs) - 5_000) < 0.0001)
            #expect(layout.seekProgress(from: 0, translation: 200) == 0)
            #expect(layout.seekProgress(from: 1, translation: -200) == 1)
            #expect(layout.seekProgress(from: 0.5, translation: layout.contentWidth) == 0)
            #expect(layout.seekProgress(from: 0.5, translation: -layout.contentWidth) == 1)
        }
    }

    @Test("visible bars and the center playhead share the same fraction scale")
    func truthfulTimeAlignment() {
        let count = 46_880
        for index in [0, 1, count / 2, count - 1] {
            let fraction = (Double(index) + 0.5) / Double(count)
            let layout = MeetingWaveformViewport(width: 320, totalMs: 4_688_000, bucketCount: count, progress: fraction)
            #expect(abs(layout.x(for: index) - 160) < 0.0001)
            #expect(layout.visibleBuckets.contains(index))
            let oneSecondEarlier = max(0, fraction - 1 / 4_688.0)
            #expect(abs(layout.seekProgress(from: fraction, translation: 40) - oneSecondEarlier) < 0.0001)
        }
        #expect(MeetingWaveformView.adjustedProgress(0.5, totalMs: 4_688_000, increment: true) > 0.5)
        #expect(MeetingWaveformView.adjustedProgress(1, totalMs: 4_688_000, increment: true) == 1)
        #expect(MeetingWaveformView.adjustedProgress(0, totalMs: 4_688_000, increment: false) == 0)
    }

    private func makeFixture(totalSamples: Int, sample: (Int) -> Int16) throws -> (manifest: MeetingAudioManifest, cleanup: URL) {
        let name = "waveform-test-\(UUID().uuidString.lowercased())"
        let root = AppDataContainer.meetingDirectory().appendingPathComponent(name, isDirectory: true)
        let audioDirectory = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        do {
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
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
                buffer.frameLength = AVAudioFrameCount(frames)
                let channel = try #require(buffer.int16ChannelData?[0])
                for index in 0..<frames { channel[index] = sample(written + index) }
                try writer.append(buffer)
                written += frames
            }
            _ = try writer.finish()
            return (writer.manifest(relativeDirectory: "\(name)/audio"), root)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
