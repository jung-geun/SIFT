import Foundation

struct MeetingMediaPart: Codable, Equatable, Sendable {
    let index: Int
    let partStartSample: Int64
    let ownedStartSample: Int64
    let ownedEndSample: Int64

    var ownedSampleCount: Int64 { ownedEndSample - ownedStartSample }
}

struct MeetingMediaTimeline: Sendable {
    static let sampleRate: Int64 = 16_000
    static let ownedSamplesPerPart: Int64 = 9_600_000
    static let overlapSamples: Int64 = 32_000
    static let maximumSamples: Int64 = 345_600_000
    static let maximumParts = 36

    private(set) var capturedSamples: Int64 = 0
    private(set) var parts: [MeetingMediaPart] = []

    mutating func append(_ samples: Int64) throws -> [MeetingMediaPart] {
        guard samples >= 0, capturedSamples <= Self.maximumSamples - samples else {
            throw MeetingMediaTimelineError.durationLimit
        }
        let previous = completedPartCount(for: capturedSamples)
        capturedSamples += samples
        let completed = completedPartCount(for: capturedSamples)
        guard completed <= Self.maximumParts else { throw MeetingMediaTimelineError.durationLimit }
        guard completed > previous else { return [] }
        let newlyCompleted = (previous..<completed).map(makePart)
        parts.append(contentsOf: newlyCompleted)
        return newlyCompleted
    }

    func finalPart() throws -> MeetingMediaPart? {
        guard capturedSamples > 0, capturedSamples % Self.ownedSamplesPerPart != 0 else { return nil }
        let index = Int(capturedSamples / Self.ownedSamplesPerPart)
        guard index < Self.maximumParts else { throw MeetingMediaTimelineError.durationLimit }
        return makePart(index)
    }

    func millisecond(for sample: Int64) -> Int64 {
        sample * 1_000 / Self.sampleRate
    }

    private func completedPartCount(for samples: Int64) -> Int {
        Int(samples / Self.ownedSamplesPerPart)
    }

    private func makePart(_ index: Int) -> MeetingMediaPart {
        let ownedStart = Int64(index) * Self.ownedSamplesPerPart
        let ownedEnd = min(ownedStart + Self.ownedSamplesPerPart, capturedSamples)
        return MeetingMediaPart(
            index: index,
            partStartSample: max(0, ownedStart - Self.overlapSamples),
            ownedStartSample: ownedStart,
            ownedEndSample: ownedEnd
        )
    }
}

enum MeetingMediaTimelineError: Error, Equatable {
    case durationLimit
}
