@preconcurrency import AVFoundation
import Foundation

/// Queue-confined, bounded PCM projection on the parent's media clock. Only one
/// output chunk and one source chunk are decoded at a time, regardless of duration.
nonisolated final class MeetingGroupAudioCursor: MeetingPCMStreamCursor {
    static let chunkFrames: Int64 = 65_536
    let plan: MeetingGroupAudioPlaybackPlan
    private let rootURL: URL
    private var cursors: [MeetingLogicalAudioCursor?]
    private var position: Int64 = 0

    init(plan: MeetingGroupAudioPlaybackPlan, rootURL: URL = AppDataContainer.meetingDirectory()) throws {
        self.plan = plan
        self.rootURL = rootURL
        self.cursors = Array(repeating: nil, count: plan.sources.count)
    }

    func seek(toLogicalSample logicalSample: Int64) throws {
        position = min(max(logicalSample, 0), plan.totalSamples)
        // Drop decoder/file state. Late sources remain unopened until their onset,
        // and every active source gets its exact source-local seek on the next read.
        for index in cursors.indices { cursors[index] = nil }
    }

    func nextPCMBuffer(maxFrames: Int64, outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        guard maxFrames > 0, position < plan.totalSamples else { return nil }
        guard outputFormat.commonFormat == .pcmFormatFloat32,
              outputFormat.channelCount == 1, !outputFormat.isInterleaved,
              outputFormat.sampleRate == Double(plan.sampleRate) else {
            throw MeetingLogicalAudioCursor.CursorError.conversion
        }
        let frames = min(maxFrames, Self.chunkFrames, plan.totalSamples - position)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = output.floatChannelData?[0] else {
            throw MeetingLogicalAudioCursor.CursorError.bufferAllocation
        }
        output.frameLength = AVAudioFrameCount(frames)
        channel.initialize(repeating: 0, count: Int(frames))
        let end = position + frames
        for (index, source) in plan.sources.enumerated() {
            let sourceEnd = source.startSample + source.manifest.totalSamples
            let begin = max(position, source.startSample)
            let intersectionEnd = min(end, sourceEnd)
            guard begin < intersectionEnd else { continue }
            let cursor: MeetingLogicalAudioCursor
            if let existing = cursors[index] {
                cursor = existing
            } else {
                cursor = try MeetingLogicalAudioCursor(manifest: source.manifest, rootURL: rootURL)
                if begin > source.startSample {
                    try cursor.seek(toLogicalSample: begin - source.startSample)
                }
                cursors[index] = cursor
            }
            var written: Int64 = 0
            let count = intersectionEnd - begin
            while written < count {
                guard let input = try cursor.nextPCMBuffer(maxFrames: count - written, outputFormat: outputFormat),
                      input.frameLength > 0, Int64(input.frameLength) <= count - written,
                      let samples = input.floatChannelData?[0] else {
                    throw MeetingLogicalAudioCursor.CursorError.shortRead(-1)
                }
                let destination = Int(begin - position + written)
                for frame in 0..<Int(input.frameLength) {
                    guard samples[frame].isFinite else { throw MeetingLogicalAudioCursor.CursorError.conversion }
                    channel[destination + frame] += samples[frame]
                }
                written += Int64(input.frameLength)
            }
            if intersectionEnd == sourceEnd { cursors[index] = nil }
        }
        // Saturate only after summing all sources: opposite-phase audio can cancel
        // naturally, and a source playing alone retains its original amplitude.
        for frame in 0..<Int(frames) {
            guard channel[frame].isFinite else { throw MeetingLogicalAudioCursor.CursorError.conversion }
            channel[frame] = min(1, max(-1, channel[frame]))
        }
        position = end
        return output
    }
}
