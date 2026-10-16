import AVFoundation
import AudioToolbox
import Foundation

/// Owns lossless FLAC part rotation after canonical 16-kHz mono PCM conversion.
/// Part ownership is fixed; overlap is encoded only in later physical files.
nonisolated final class MeetingFLACPartWriter {
    private let directory: URL
    private var currentFile: AVAudioFile?
    private var currentURL: URL?
    private var currentIndex = 0
    private var ownedStart: Int64 = 0
    private(set) var totalSamples: Int64 = 0
    private var overlapRing = [Int16](repeating: 0, count: Int(MeetingMediaTimeline.overlapSamples))
    private var overlapCount = 0
    private var overlapWriteIndex = 0
    private(set) var completedParts = [MeetingMediaPart]()
    private var finished = false

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try openPart(index: 0, ownedStart: 0)
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard !finished else { throw MeetingFLACPartWriterError.alreadyFinished }
        guard totalSamples <= MeetingMediaTimeline.maximumSamples - Int64(buffer.frameLength) else {
            throw MeetingFLACPartWriterError.durationLimit
        }
        do {
            try appendWriting(buffer)
        } catch {
            finished = true
            currentFile = nil
            throw error
        }
    }

    private func appendWriting(_ buffer: AVAudioPCMBuffer) throws {
        guard let source = buffer.int16ChannelData?[0] else { throw MeetingFLACPartWriterError.nonCanonicalBuffer }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // The canonical pipeline creates a fresh buffer for every input. The
        // writer completes this synchronous read before ownership transfers to
        // the transcription queue; neither side mutates it afterward.
        let ownedUsed = totalSamples - ownedStart
        let available = MeetingMediaTimeline.ownedSamplesPerPart - ownedUsed
        if let currentFile,
           Int64(frameCount) <= available,
           totalSamples <= MeetingMediaTimeline.maximumSamples - Int64(frameCount),
           buffer.format.commonFormat == .pcmFormatInt16,
           buffer.format.sampleRate == currentFile.processingFormat.sampleRate,
           buffer.format.channelCount == currentFile.processingFormat.channelCount,
           buffer.format.isInterleaved == currentFile.processingFormat.isInterleaved {
            try currentFile.write(from: buffer)
            appendOverlap(source, count: frameCount)
            totalSamples += Int64(frameCount)
            return
        }

        var offset = 0
        while offset < frameCount {
            let ownedUsed = totalSamples - ownedStart
            if ownedUsed == MeetingMediaTimeline.ownedSamplesPerPart {
                try closeCurrentPart(ownedEnd: totalSamples)
                currentIndex += 1
                ownedStart = totalSamples
                try openPart(index: currentIndex, ownedStart: ownedStart)
            }
            let available = Int(MeetingMediaTimeline.ownedSamplesPerPart - (totalSamples - ownedStart))
            let count = min(available, frameCount - offset)
            try write(samples: source.advanced(by: offset), count: count)
            appendOverlap(source.advanced(by: offset), count: count)
            totalSamples += Int64(count)
            offset += count
        }
    }

    func finish() throws -> [MeetingMediaPart] {
        guard !finished else { return completedParts }
        finished = true
        if totalSamples > ownedStart {
            try closeCurrentPart(ownedEnd: totalSamples)
        } else if totalSamples == 0, let currentURL {
            currentFile = nil
            try? FileManager.default.removeItem(at: currentURL)
        }
        currentFile = nil
        if totalSamples > 0, let currentURL { AppDataContainer.finalizeMeetingAudio(at: currentURL) }
        return completedParts
    }

    private func openPart(index: Int, ownedStart: Int64) throws {
        let url = directory.appendingPathComponent(String(format: "part-%02d.flac", index))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: MeetingMediaTimeline.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        currentFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        currentURL = url
        if index > 0, overlapCount > 0 {
            try writeOverlapRing()
        }
    }

    private func closeCurrentPart(ownedEnd: Int64) throws {
        let partStart = max(0, ownedStart - MeetingMediaTimeline.overlapSamples)
        completedParts.append(MeetingMediaPart(index: currentIndex, partStartSample: partStart, ownedStartSample: ownedStart, ownedEndSample: ownedEnd))
        currentFile = nil
        if let currentURL { AppDataContainer.finalizeMeetingAudio(at: currentURL) }
    }

    private func write(samples: UnsafePointer<Int16>, count: Int) throws {
        guard let file = currentFile else { throw MeetingFLACPartWriterError.writerUnavailable }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(MeetingMediaTimeline.sampleRate), channels: 1, interleaved: true)!,
            frameCapacity: AVAudioFrameCount(count)
        ), let target = output.int16ChannelData?[0] else { throw MeetingFLACPartWriterError.nonCanonicalBuffer }
        target.update(from: samples, count: count)
        output.frameLength = AVAudioFrameCount(count)
        try file.write(from: output)
    }

    private func appendOverlap(_ samples: UnsafePointer<Int16>, count: Int) {
        let keep = overlapRing.count
        guard keep > 0, count > 0 else { return }
        var source = samples
        var remaining = count
        while remaining > 0 {
            let writable = min(remaining, keep - overlapWriteIndex)
            overlapRing.withUnsafeMutableBufferPointer { target in
                target.baseAddress!.advanced(by: overlapWriteIndex).update(from: source, count: writable)
            }
            source = source.advanced(by: writable)
            remaining -= writable
            overlapWriteIndex = (overlapWriteIndex + writable) % keep
            overlapCount = min(keep, overlapCount + writable)
        }
    }

    private func writeOverlapRing() throws {
        guard overlapCount > 0 else { return }
        let keep = overlapRing.count
        let firstStart = overlapCount == keep ? overlapWriteIndex : 0
        let firstCount = min(overlapCount, keep - firstStart)
        try overlapRing.withUnsafeBufferPointer { ring in
            try write(samples: ring.baseAddress!.advanced(by: firstStart), count: firstCount)
            let remaining = overlapCount - firstCount
            if remaining > 0 {
                try write(samples: ring.baseAddress!, count: remaining)
            }
        }
    }
}

enum MeetingFLACPartWriterError: Error {
    case nonCanonicalBuffer
    case durationLimit
    case alreadyFinished
    case writerUnavailable
}
