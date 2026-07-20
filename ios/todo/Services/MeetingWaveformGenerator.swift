import AVFoundation
import Foundation

struct MeetingWaveform: Equatable, Sendable {
    let buckets: [Float]
    let totalSamples: Int64
}

enum MeetingWaveformGenerator {
    /// A regenerated manifest for the same directory (e.g. after recovery)
    /// compares unequal, so stale waveforms are never served.
    nonisolated private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache = [String: (manifest: MeetingAudioManifest, bucketCount: Int, waveform: MeetingWaveform)]()
    nonisolated private static let cacheLimit = 8

    /// Uses an independent overlap-trimmed cursor, never the playback cursor.
    nonisolated static func generate(manifest: MeetingAudioManifest, bucketCount: Int = 180) throws -> MeetingWaveform {
        guard bucketCount > 0 else { throw WaveformError.format }
        cacheLock.lock()
        let cached = cache[manifest.relativeDirectory]
        cacheLock.unlock()
        if let cached, cached.manifest == manifest, cached.bucketCount == bucketCount {
            return cached.waveform
        }
        let cursor = try MeetingLogicalAudioCursor(manifest: manifest)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(manifest.sampleRate),
            channels: 1,
            interleaved: false
        ) else { throw WaveformError.format }
        let samplesPerBucket = max(Int64(1), (manifest.totalSamples + Int64(bucketCount) - 1) / Int64(bucketCount))
        var peaks = Array(repeating: Float(0), count: bucketCount)
        var sampleOffset: Int64 = 0
        while let buffer = try cursor.nextPCMBuffer(maxFrames: 8_192, outputFormat: format) {
            try Task.checkCancellation()
            guard let channel = buffer.floatChannelData?[0] else { throw WaveformError.format }
            for index in 0..<Int(buffer.frameLength) {
                let bucket = min(bucketCount - 1, Int((sampleOffset + Int64(index)) / samplesPerBucket))
                peaks[bucket] = max(peaks[bucket], abs(channel[index]))
            }
            sampleOffset += Int64(buffer.frameLength)
        }
        let nonSilent = peaks.filter { $0 >= 0.001 }.sorted()
        let waveform: MeetingWaveform
        if nonSilent.isEmpty {
            waveform = MeetingWaveform(buckets: peaks, totalSamples: sampleOffset)
        } else {
            let p95 = nonSilent[min(nonSilent.count - 1, Int(Double(nonSilent.count - 1) * 0.95))]
            let scale = max(p95, 0.01)
            let normalized = peaks.map { peak -> Float in
                guard peak >= 0.001 else { return 0 }
                return sqrt(min(1, peak / scale))
            }
            waveform = MeetingWaveform(buckets: normalized, totalSamples: sampleOffset)
        }
        cacheLock.lock()
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[manifest.relativeDirectory] = (manifest, bucketCount, waveform)
        cacheLock.unlock()
        return waveform
    }

    enum WaveformError: Error { case format }
}
