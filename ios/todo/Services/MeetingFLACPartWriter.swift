import AVFoundation
import AudioToolbox
import Foundation

/// Owns lossless FLAC part rotation after canonical 16-kHz mono PCM conversion.
/// Part ownership is fixed; overlap is encoded only in later physical files.
nonisolated final class MeetingFLACPartWriter {
    // Native 16-kHz FLAC's initial packet size (AudioFormatGetProperty FormatInfo).
    private static let nativeFLACBlockSamples = 4_608
    // Process-local ownership only: a relaunch must still recover abandoned files.
    // Recovery holds the same reservation while reading, never the lock during I/O.
    private static let directoryLock = NSLock()
    // URL directory hints change after creation; physical path identity must not.
    nonisolated(unsafe) private static var reservedDirectories = Set<String>()
    private let directory: URL
    private var ownsDirectory = false
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
    private var terminalError: (any Error)?

    init(directory: URL) throws {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.reserveDirectory(self.directory) else { throw MeetingFLACPartWriterError.writerUnavailable }
        ownsDirectory = true
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            try openPart(index: 0, ownedStart: 0)
        } catch {
            currentFile?.close()
            currentFile = nil
            releaseDirectory()
            throw error
        }
    }

    deinit {
        currentFile?.close()
        releaseDirectory()
    }

    /// An active native FLAC is not a recovery candidate, even if its current
    /// header happens to open. Its sample count and final frame are still mutable.
    static func withRecoveryAccess<Result>(to directory: URL, _ recover: () throws -> Result) rethrows -> Result? {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard reserveDirectory(directory) else { return nil }
        defer { directoryLock.withLock { _ = reservedDirectories.remove(directory.path) } }
        return try recover()
    }

    private static func reserveDirectory(_ directory: URL) -> Bool {
        directoryLock.withLock { reservedDirectories.insert(directory.path).inserted }
    }

    private func releaseDirectory() {
        guard ownsDirectory else { return }
        Self.directoryLock.withLock { _ = Self.reservedDirectories.remove(directory.path) }
        ownsDirectory = false
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        if let terminalError { throw terminalError }
        guard !finished else { throw MeetingFLACPartWriterError.alreadyFinished }
        guard totalSamples <= MeetingMediaTimeline.maximumSamples - Int64(buffer.frameLength) else {
            throw MeetingFLACPartWriterError.durationLimit
        }
        do {
            try appendWriting(buffer)
        } catch {
            finished = true
            terminalError = error
            currentFile?.close()
            currentFile = nil
            releaseDirectory()
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
        if let terminalError { throw terminalError }
        guard !finished else { return completedParts }
        defer { releaseDirectory() }
        finished = true
        do {
            if totalSamples > ownedStart {
                try closeCurrentPart(ownedEnd: totalSamples)
            } else if totalSamples == 0, let currentURL {
                currentFile?.close()
                currentFile = nil
                try? FileManager.default.removeItem(at: currentURL)
            }
            currentFile = nil
            return completedParts
        } catch {
            terminalError = error
            currentFile?.close()
            currentFile = nil
            throw error
        }
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
        guard currentFile != nil, let currentURL else { throw MeetingFLACPartWriterError.writerUnavailable }
        currentFile?.close()
        currentFile = nil
        // The native codec emits no initial partial block, even with documented
        // AudioConverter EOF/draining. Encode that bounded case as genuine FLAC
        // (RFC 9639 §§8.2, 9.1, 9.2.4, 9.3), not padded PCM. The overlap ring
        // already retains every sample here. Rotated files start with 32,000
        // overlap samples, so they and all longer files keep native streaming.
        if ownedStart == 0, ownedEnd < Int64(Self.nativeFLACBlockSamples) {
            let encoded = overlapRing.withUnsafeBufferPointer { ring in
                Self.shortFLAC(samples: UnsafeBufferPointer(start: ring.baseAddress, count: Int(ownedEnd)))
            }
            try encoded.write(to: currentURL, options: .atomic)
        }
        AppDataContainer.finalizeMeetingAudio(at: currentURL)
        let partStart = max(0, ownedStart - MeetingMediaTimeline.overlapSamples)
        completedParts.append(MeetingMediaPart(index: currentIndex, partStartSample: partStart, ownedStartSample: ownedStart, ownedEndSample: ownedEnd))
    }

    /// One final verbatim subframe: signed big-endian samples, no extra samples.
    /// RFC 9639 permits the last block to be shorter than the nominal block size,
    /// including fewer than 16 samples, and a zero MD5 to mean "not provided".
    private static func shortFLAC(samples: UnsafeBufferPointer<Int16>) -> Data {
        let frameByteCount = 11 + samples.count * MemoryLayout<Int16>.size
        let streamInfoByteCount = 34
        var encoded = Data(capacity: 8 + streamInfoByteCount + frameByteCount)
        // fLaC signature; last metadata block, STREAMINFO, 34-byte payload.
        encoded.append(contentsOf: [0x66, 0x4c, 0x61, 0x43, 0x80, 0, 0, UInt8(streamInfoByteCount)])
        let nominalBlockSize = UInt16(nativeFLACBlockSamples)
        for _ in 0..<2 {
            encoded.append(UInt8(nominalBlockSize >> 8))
            encoded.append(UInt8(truncatingIfNeeded: nominalBlockSize))
        }
        for _ in 0..<2 {
            encoded.append(UInt8(truncatingIfNeeded: frameByteCount >> 16))
            encoded.append(UInt8(truncatingIfNeeded: frameByteCount >> 8))
            encoded.append(UInt8(truncatingIfNeeded: frameByteCount))
        }
        // 20-bit rate, 3-bit (channels - 1), 5-bit (depth - 1), 36-bit count.
        let stream = (UInt64(MeetingMediaTimeline.sampleRate) << 44)
            | (UInt64(Int16.bitWidth - 1) << 36) | UInt64(samples.count)
        for shift in stride(from: 56, through: 0, by: -8) {
            encoded.append(UInt8(truncatingIfNeeded: stream >> shift))
        }
        encoded.append(contentsOf: repeatElement(UInt8(0), count: 16))

        let frameOffset = encoded.count
        // Fixed-block sync; 16-bit explicit block length; explicit 16-kHz rate;
        // mono 16-bit samples; frame number 0. Native decoding requires the
        // explicit rate (0x75), not the otherwise legal STREAMINFO-only 0x70.
        encoded.append(contentsOf: [0xff, 0xf8, 0x75, 0x08, 0x00])
        let lastSample = UInt16(samples.count - 1)
        encoded.append(UInt8(lastSample >> 8))
        encoded.append(UInt8(truncatingIfNeeded: lastSample))
        let headerCRCPolynomial: UInt8 = 0x07
        var headerCRC: UInt8 = 0
        for byte in encoded[frameOffset...] {
            headerCRC ^= byte
            for _ in 0..<8 {
                headerCRC = headerCRC & 0x80 != 0 ? (headerCRC &<< 1) ^ headerCRCPolynomial : headerCRC &<< 1
            }
        }
        encoded.append(headerCRC)
        encoded.append(0x02) // Verbatim subframe, no wasted bits.
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            encoded.append(UInt8(value >> 8))
            encoded.append(UInt8(truncatingIfNeeded: value))
        }
        let frameCRCPolynomial: UInt16 = 0x8005
        var frameCRC: UInt16 = 0
        for byte in encoded[frameOffset...] {
            frameCRC ^= UInt16(byte) << 8
            for _ in 0..<8 {
                frameCRC = frameCRC & 0x8000 != 0 ? (frameCRC &<< 1) ^ frameCRCPolynomial : frameCRC &<< 1
            }
        }
        encoded.append(UInt8(frameCRC >> 8))
        encoded.append(UInt8(truncatingIfNeeded: frameCRC))
        return encoded
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
