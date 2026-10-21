import AVFoundation
import Foundation

struct MeetingWaveform: Equatable, Sendable {
    /// Uniform time bins spanning the entire source or mixed parent timeline.
    let buckets: [Float]
    let totalSamples: Int64
}

enum MeetingWaveformGenerator {
    /// A regenerated manifest for the same directory (e.g. after recovery)
    /// compares unequal, so stale waveforms are never served.
    nonisolated private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache = [String: (manifest: MeetingAudioManifest, bucketCount: Int, waveform: MeetingWaveform)]()
    /// Full plan equality includes source manifests, parent offsets, and duration.
    /// Keep this separate so single-source directory replacement stays unchanged.
    nonisolated(unsafe) private static var groupCache: [(plan: MeetingGroupAudioPlaybackPlan, bucketCount: Int, waveform: MeetingWaveform)] = []
    nonisolated private static let cacheLimit = 8

    /// Ten peaks per second gives a four-point bar spacing at the view's 40pt/s.
    /// Keep a useful minimum for short clips; do not cap long recordings at an
    /// overview-sized count, which would stretch seconds of audio into one bar.
    nonisolated static func recommendedBucketCount(totalSamples: Int64, sampleRate: Int64) -> Int {
        guard totalSamples > 0, sampleRate > 0 else { return 180 }
        let samplesPerBucket = max(1, sampleRate / 10)
        let count = totalSamples / samplesPerBucket + (totalSamples % samplesPerBucket == 0 ? 0 : 1)
        return max(180, Int(count))
    }

    /// Uses an independent overlap-trimmed cursor, never the playback cursor.
    /// An explicit count is useful for exports/tests; playback uses time resolution.
    nonisolated static func generate(manifest: MeetingAudioManifest, bucketCount requestedCount: Int? = nil) throws -> MeetingWaveform {
        let bucketCount = requestedCount ?? recommendedBucketCount(totalSamples: manifest.totalSamples, sampleRate: manifest.sampleRate)
        guard bucketCount > 0 else { throw WaveformError.format }
        try Task.checkCancellation()
        cacheLock.lock()
        let cached = cache[manifest.relativeDirectory]
        cacheLock.unlock()
        if let cached, cached.manifest == manifest, cached.bucketCount == bucketCount {
            return cached.waveform
        }
        let cursor = try MeetingLogicalAudioCursor(manifest: manifest)
        let waveform = try generate(
            totalSamples: manifest.totalSamples,
            sampleRate: manifest.sampleRate,
            bucketCount: bucketCount,
            nextPCMBuffer: cursor.nextPCMBuffer
        )
        try Task.checkCancellation()
        cacheLock.lock()
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[manifest.relativeDirectory] = (manifest, bucketCount, waveform)
        cacheLock.unlock()
        return waveform
    }

    /// Reads the actual mixed PCM from parent sample zero through the last source,
    /// including leading/inter-source silence, without touching playback state.
    nonisolated static func generate(plan: MeetingGroupAudioPlaybackPlan, bucketCount requestedCount: Int? = nil) throws -> MeetingWaveform {
        let bucketCount = requestedCount ?? recommendedBucketCount(totalSamples: plan.totalSamples, sampleRate: plan.sampleRate)
        guard bucketCount > 0 else { throw WaveformError.format }
        try Task.checkCancellation()
        cacheLock.lock()
        let cached = groupCache.first { $0.plan == plan && $0.bucketCount == bucketCount }
        cacheLock.unlock()
        if let cached {
            try Task.checkCancellation()
            return cached.waveform
        }
        let cursor = try MeetingGroupAudioCursor(plan: plan)
        let waveform = try generate(
            totalSamples: plan.totalSamples,
            sampleRate: plan.sampleRate,
            bucketCount: bucketCount,
            nextPCMBuffer: cursor.nextPCMBuffer
        )
        try Task.checkCancellation()
        cacheLock.lock()
        if groupCache.count >= cacheLimit { groupCache.removeAll() }
        groupCache.append((plan, bucketCount, waveform))
        cacheLock.unlock()
        return waveform
    }

    /// Both source cursors feed the same bounded peak bins and normalization.
    nonisolated private static func generate(
        totalSamples: Int64,
        sampleRate: Int64,
        bucketCount: Int,
        nextPCMBuffer: (Int64, AVAudioFormat) throws -> AVAudioPCMBuffer?
    ) throws -> MeetingWaveform {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else { throw WaveformError.format }
        var peaks = Array(repeating: Float(0), count: bucketCount)
        var bucket = 0
        // Ceil each boundary instead of rounding a fixed samples-per-bucket up:
        // fixed rounding pads the tail and misaligns bars with seeking fractions.
        func endSample(for bucket: Int) -> Int64 {
            Int64(ceil(Double(totalSamples) * Double(bucket + 1) / Double(bucketCount)))
        }
        var bucketEnd = endSample(for: bucket)
        var sampleOffset: Int64 = 0
        while let buffer = try nextPCMBuffer(8_192, format) {
            try Task.checkCancellation()
            guard let channel = buffer.floatChannelData?[0] else { throw WaveformError.format }
            var index = 0
            let frameCount = Int(buffer.frameLength)
            while index < frameCount {
                let logicalSample = sampleOffset + Int64(index)
                while bucket < bucketCount - 1, logicalSample >= bucketEnd {
                    bucket += 1
                    bucketEnd = endSample(for: bucket)
                }
                let frames = min(frameCount - index, Int(max(1, bucketEnd - logicalSample)))
                let end = index + frames
                var peak = peaks[bucket]
                for frame in index..<end {
                    peak = max(peak, abs(channel[frame]))
                }
                peaks[bucket] = peak
                index = end
            }
            sampleOffset += Int64(buffer.frameLength)
        }
        try Task.checkCancellation()
        let nonSilent = peaks.filter { $0 >= 0.001 }.sorted()
        let scale = nonSilent.isEmpty ? Float(0.01) : max(nonSilent[min(nonSilent.count - 1, Int(Double(nonSilent.count - 1) * 0.95))], 0.01)
        let normalized = peaks.map { peak -> Float in
            guard peak >= 0.001 else { return 0 }
            return sqrt(min(1, peak / scale))
        }
        let waveform = MeetingWaveform(buckets: normalized, totalSamples: sampleOffset)
        try Task.checkCancellation()
        return waveform
    }

    enum WaveformError: LocalizedError {
        case format

        var errorDescription: String? {
            AppLanguage.localized("meeting.waveform.error.format", defaultValue: "The recording waveform could not be prepared.",
                                  language: .current, comment: "Waveform generation failed without exposing audio diagnostics.")
        }
    }
}
