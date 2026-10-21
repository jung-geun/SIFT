import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import todo

private enum FLACRoundTripTestError: Error {
    case canonicalBufferAllocation
    case canonicalChannelData
    case bufferAllocation
    case missingAudioBuffer
    case missingAudioData
    case appendFailed(Int, String)
    case finishFailed(String)
    case fileOpenFailed(String)
    case unexpectedEmptyRead
}

private func canonicalPCMBuffer(
    format: AVAudioFormat,
    frameCount: Int,
    filling sample: (Int) -> Int16
) throws -> AVAudioPCMBuffer {
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frameCount)
    ) else {
        throw FLACRoundTripTestError.canonicalBufferAllocation
    }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    guard let channel = buffer.int16ChannelData?[0] else {
        throw FLACRoundTripTestError.canonicalChannelData
    }
    for index in 0..<frameCount { channel[index] = sample(index) }
    return buffer
}

private func decodedSamples(from file: AVAudioFile) throws -> [Int16] {
    var samples = [Int16]()
    while file.framePosition < file.length {
        let remaining = file.length - file.framePosition
        let requestedFrames = AVAudioFrameCount(min(4_096, remaining))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: requestedFrames
        ) else {
            throw FLACRoundTripTestError.bufferAllocation
        }
        try file.read(into: buffer, frameCount: requestedFrames)
        guard buffer.frameLength > 0 else {
            throw FLACRoundTripTestError.unexpectedEmptyRead
        }

        let frameCount = Int(buffer.frameLength)
        let buffers = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        guard let audioBuffer = buffers.first else {
            throw FLACRoundTripTestError.missingAudioBuffer
        }
        guard let data = audioBuffer.mData else {
            throw FLACRoundTripTestError.missingAudioData
        }
        switch buffer.format.commonFormat {
        case .pcmFormatInt16:
            let channel = data.assumingMemoryBound(to: Int16.self)
            samples.append(
                contentsOf: UnsafeBufferPointer(
                    start: channel,
                    count: frameCount
                )
            )
        case .pcmFormatFloat32:
            let channel = data.assumingMemoryBound(to: Float.self)
            for sample in UnsafeBufferPointer(start: channel, count: frameCount) {
                samples.append(
                    Int16(clamping: Int((sample * 32_768).rounded()))
                )
            }
        default:
            Issue.record(
                "Unsupported decoded format: \(buffer.format.commonFormat)"
            )
            return samples
        }
    }
    return samples
}

@Suite("Meeting FLAC round trip", .serialized)
struct MeetingFLACRoundTripTests {
    @Test("writer manifest owned range can be decoded")
    func writesAndReadsOwnedFrames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-flac-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = try MeetingFLACPartWriter(directory: directory)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(MeetingMediaTimeline.sampleRate),
            channels: 1,
            interleaved: true
        ))
        let input = try canonicalPCMBuffer(format: format, frameCount: 16_000) {
            Int16($0 % 32_000)
        }
        try writer.append(input)
        _ = try writer.finish()

        let manifest = writer.manifest(relativeDirectory: "unused")
        let part = try #require(manifest.parts.first)
        let file = try AVAudioFile(forReading: directory.appendingPathComponent(part.fileName))
        let skip = part.ownedStartSample - part.partStartSample
        let count = part.ownedEndSample - part.ownedStartSample
        #expect(skip + count <= file.length)
        file.framePosition = AVAudioFramePosition(skip)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)))
        try file.read(into: output, frameCount: AVAudioFrameCount(count))
        #expect(Int64(output.frameLength) == count)
    }

    @Test("finish immediately publishes exact lossless FLAC at block boundaries", arguments: [
        1, 7, 15, 16, 17, 19, 64, 1_600, 4_607, 4_608, 4_609, 9_215, 9_216, 9_217, 16_000,
    ])
    func finishesExactPositiveLength(frameCount: Int) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-flac-exact-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try MeetingFLACPartWriter(directory: directory)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        ))
        let expected = (0..<frameCount).map { Int16(truncatingIfNeeded: $0 * 7_919 + 32_768) }
        var offset = 0
        while offset < frameCount {
            let count = min(997, frameCount - offset)
            let buffer = try canonicalPCMBuffer(format: format, frameCount: count) { expected[offset + $0] }
            try writer.append(buffer)
            offset += count
        }

        let parts = try writer.finish()
        #expect(parts.count == 1)
        let part = try #require(parts.first)
        #expect(part.partStartSample == 0)
        #expect(part.ownedStartSample == 0)
        #expect(part.ownedEndSample == Int64(frameCount))
        #expect(writer.totalSamples == Int64(frameCount))
        let publishedPart = try #require(writer.manifest(relativeDirectory: "unused").parts.first)
        let url = directory.appendingPathComponent(publishedPart.fileName)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #expect(try handle.read(upToCount: 4) == Data("fLaC".utf8))
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatFLAC)
        #expect(file.length == Int64(frameCount))
        #expect(try decodedSamples(from: file) == expected)
        #expect(file.framePosition == Int64(frameCount))
        let defaultFormatFile = try AVAudioFile(forReading: url)
        #expect(try decodedSamples(from: defaultFormatFile) == expected)
        // Retain the writer: readability must not depend on its deinitialization.
        #expect(try writer.finish() == parts)
    }

    @Test("open writer progress is never published as finalized audio")
    func manifestOmitsOpenFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-flac-publication-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("audio", isDirectory: true)
        let writer = try MeetingFLACPartWriter(directory: directory)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        ))
        try writer.append(canonicalPCMBuffer(format: format, frameCount: 7) { Int16($0 - 3) })
        let live = writer.manifest(relativeDirectory: "audio")
        #expect(writer.totalSamples == 7)
        #expect(live.totalSamples == 0)
        #expect(live.parts.isEmpty)
        #expect(try MeetingLogicalAudioCursor.validatedParts(for: live).isEmpty)
        // A second writer must not truncate the first writer's physical file.
        #expect(throws: MeetingFLACPartWriterError.self) {
            _ = try MeetingFLACPartWriter(directory: directory)
        }
        _ = try writer.finish()
        let published = writer.manifest(relativeDirectory: "audio")
        #expect(published.totalSamples == 7)
        let cursor = try MeetingLogicalAudioCursor(manifest: published, rootURL: root)
        let decoded = try #require(try cursor.nextPCMBuffer(maxFrames: 7, outputFormat: format))
        let samples = try #require(decoded.int16ChannelData?[0])
        #expect(Array(UnsafeBufferPointer(start: samples, count: Int(decoded.frameLength))) == [-3, -2, -1, 0, 1, 2, 3])
    }

    @Test("short FLAC finalization failures never publish a completed part")
    func shortFinalizationPropagatesStorageFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-flac-write-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try MeetingFLACPartWriter(directory: directory)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        ))
        try writer.append(canonicalPCMBuffer(format: format, frameCount: 7) { Int16($0) })
        try FileManager.default.removeItem(at: directory)
        #expect(throws: (any Error).self) { try writer.finish() }
        #expect(writer.completedParts.isEmpty)
        // A failed finish must not turn into a successful empty manifest on retry.
        #expect(throws: (any Error).self) { try writer.finish() }
    }

    @Test("eighty-five seconds records without PCM loss")
    func recordsPastEightySecondsWithoutLoss() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-flac-eighty-five-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = try MeetingFLACPartWriter(directory: directory)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(MeetingMediaTimeline.sampleRate),
            channels: 1,
            interleaved: true
        ))
        var expected = [Int16]()
        expected.reserveCapacity(85 * 16_000)
        for second in 0..<85 {
            let buffer = try canonicalPCMBuffer(format: format, frameCount: 16_000) { sample in
                Int16(truncatingIfNeeded: second * 16_000 + sample)
            }
            for sample in 0..<Int(buffer.frameLength) {
                expected.append(
                    Int16(truncatingIfNeeded: second * 16_000 + sample)
                )
            }
            do {
                try writer.append(buffer)
            } catch {
                throw FLACRoundTripTestError.appendFailed(
                    second,
                    String(describing: error)
                )
            }
        }
        let parts: [MeetingMediaPart]
        do {
            parts = try writer.finish()
        } catch {
            throw FLACRoundTripTestError.finishFailed(
                String(describing: error)
            )
        }
        #expect(parts.count == 1)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forReading: directory.appendingPathComponent("part-00.flac")
            )
        } catch {
            throw FLACRoundTripTestError.fileOpenFailed(
                String(describing: error)
            )
        }
        let actual = try decodedSamples(from: file)
        #expect(actual == expected)
    }

    @Test("part rotation retains exact overlap and owned ranges")
    func rotatesWithoutOverlapCorruption() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-flac-rotation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = try MeetingFLACPartWriter(directory: directory)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(MeetingMediaTimeline.sampleRate),
            channels: 1,
            interleaved: true
        ))
        let chunkSize = 16_000
        // The rotated file has overlap plus only seven newly owned samples.
        // Neither encoder block alignment nor overlap may extend that ownership.
        let total = Int(MeetingMediaTimeline.ownedSamplesPerPart) + 7
        var expected = [Int16]()
        expected.reserveCapacity(total)
        var offset = 0
        while offset < total {
            let count = min(chunkSize, total - offset)
            let buffer = try canonicalPCMBuffer(format: format, frameCount: count) { index in
                Int16(truncatingIfNeeded: offset + index)
            }
            for index in 0..<count {
                expected.append(Int16(truncatingIfNeeded: offset + index))
            }
            do {
                try writer.append(buffer)
            } catch {
                throw FLACRoundTripTestError.appendFailed(
                    offset,
                    String(describing: error)
                )
            }
            offset += count
        }
        let live = writer.manifest(relativeDirectory: "unused")
        #expect(writer.totalSamples == total)
        #expect(live.totalSamples == MeetingMediaTimeline.ownedSamplesPerPart)
        #expect(live.parts.count == 1)
        #expect(try MeetingLogicalAudioCursor.validatedParts(for: live).count == 1)
        _ = try writer.finish()
        let manifest = writer.manifest(relativeDirectory: "unused")
        #expect(manifest.parts.count == 2)
        #expect(manifest.totalSamples == total)
        let second = try #require(manifest.parts.last)
        #expect(second.partStartSample == MeetingMediaTimeline.ownedSamplesPerPart - MeetingMediaTimeline.overlapSamples)
        #expect(second.ownedStartSample == MeetingMediaTimeline.ownedSamplesPerPart)
        #expect(second.ownedEndSample == total)
        let first = try #require(manifest.parts.first)
        #expect(first.partStartSample == 0)
        #expect(first.ownedStartSample == 0)
        #expect(first.ownedEndSample == second.ownedStartSample)
        let firstFile = try AVAudioFile(forReading: directory.appendingPathComponent(first.fileName))
        #expect(firstFile.length == MeetingMediaTimeline.ownedSamplesPerPart)
        #expect(try decodedSamples(from: firstFile) == Array(expected[..<Int(first.ownedEndSample)]))
        let secondFile = try AVAudioFile(
            forReading: directory.appendingPathComponent("part-01.flac")
        )
        let physical = try decodedSamples(from: secondFile)
        #expect(secondFile.length == MeetingMediaTimeline.overlapSamples + 7)
        #expect(physical.count == Int(secondFile.length))
        let overlapStart = Int(
            MeetingMediaTimeline.ownedSamplesPerPart
                - MeetingMediaTimeline.overlapSamples
        )
        #expect(Array(physical.prefix(Int(MeetingMediaTimeline.overlapSamples))) == Array(expected[overlapStart..<Int(MeetingMediaTimeline.ownedSamplesPerPart)]))
        #expect(Array(physical.dropFirst(Int(MeetingMediaTimeline.overlapSamples))) == Array(expected[Int(MeetingMediaTimeline.ownedSamplesPerPart)..<total]))
    }
}
