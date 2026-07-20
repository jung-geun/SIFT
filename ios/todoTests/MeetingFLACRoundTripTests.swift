import AVFoundation
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
        let total = Int(MeetingMediaTimeline.ownedSamplesPerPart)
            + Int(MeetingMediaTimeline.overlapSamples)
            + chunkSize
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
        _ = try writer.finish()
        let manifest = writer.manifest(relativeDirectory: "unused")
        #expect(manifest.parts.count == 2)
        #expect(manifest.totalSamples == total)
        let second = try #require(manifest.parts.last)
        #expect(second.partStartSample == MeetingMediaTimeline.ownedSamplesPerPart - MeetingMediaTimeline.overlapSamples)
        #expect(second.ownedStartSample == MeetingMediaTimeline.ownedSamplesPerPart)
        #expect(second.ownedEndSample == total)
        let secondFile = try AVAudioFile(
            forReading: directory.appendingPathComponent("part-01.flac")
        )
        let physical = try decodedSamples(from: secondFile)
        let overlapStart = Int(
            MeetingMediaTimeline.ownedSamplesPerPart
                - MeetingMediaTimeline.overlapSamples
        )
        #expect(Array(physical.prefix(Int(MeetingMediaTimeline.overlapSamples))) == Array(expected[overlapStart..<Int(MeetingMediaTimeline.ownedSamplesPerPart)]))
        #expect(Array(physical.dropFirst(Int(MeetingMediaTimeline.overlapSamples))) == Array(expected[Int(MeetingMediaTimeline.ownedSamplesPerPart)..<total]))
    }
}
