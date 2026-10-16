import CryptoKit
import Foundation

nonisolated enum MeetingSpeakerLabelState: String, Codable, Sendable {
    case unknown, provisional, final
}

nonisolated enum MeetingDiarizationStatus: String, Codable, Sendable {
    case notProcessed, modelUnavailable, runningLive, finalizing, completed, interrupted, failed
}

/// Stable, user-path-free failure codes persisted in `MeetingDiarizationPayload.failureCode`.
nonisolated enum MeetingDiarizationFailure: String, Error, Codable, Sendable {
    case modelUnavailable, artifactCorrupt, inferenceFailed, inputOverflow, audioUnavailable, timelineMismatch
}

/// Original transcript UTF-16 offsets and audio milliseconds; no text copy.
nonisolated struct MeetingTimedTextRun: Codable, Hashable, Sendable {
    let utf16Offset: Int
    let utf16Length: Int
    let startMs: Int64
    let endMs: Int64
}

/// Half-open sample interval at the canonical 16 kHz input rate.
nonisolated struct MeetingSpeakerInterval: Codable, Hashable, Sendable {
    let speakerID: String
    let startSample: Int64
    let endSample: Int64
}

nonisolated struct MeetingSpeakerProfile: Codable, Hashable, Sendable {
    let id: String
    let ordinal: Int
    var displayName: String?
}

/// Local-only metadata and speaker evidence. A failed retry can retain the
/// last successful intervals and profiles rather than erasing them.
nonisolated struct MeetingDiarizationPayload: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var status: MeetingDiarizationStatus
    var generation: UUID
    var manifestDigest: String
    var sourceTranscriptRevision: Int
    var sourceContentDigest: String
    var modelRevision: String
    var preset: String
    var coveredThroughSample: Int64
    var intervals: [MeetingSpeakerInterval]
    var profiles: [MeetingSpeakerProfile]
    /// Keyed by MeetingSegment.stableLineageID, not a mutable replacement ID.
    var manualAssignments: [String: [String]]
    var failureCode: String?

    func validated(totalSamples: Int64) throws -> MeetingDiarizationPayload {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MeetingDiarizationError.unsupportedVersion(schemaVersion)
        }
        guard totalSamples >= 0, (0...totalSamples).contains(coveredThroughSample),
              sourceTranscriptRevision >= 0 else { throw MeetingDiarizationError.invalidTimeline }
        let knownIDs = Set(profiles.map(\.id))
        guard failureCode.map({ MeetingDiarizationFailure(rawValue: $0) != nil }) ?? true,
              knownIDs.count == profiles.count,
              profiles.allSatisfy({ !$0.id.isEmpty && (1...8).contains($0.ordinal) }),
              intervals.allSatisfy({
                  knownIDs.contains($0.speakerID) && $0.startSample >= 0 &&
                  $0.startSample < $0.endSample && $0.endSample <= totalSamples
              }),
              manualAssignments.keys.allSatisfy({ !$0.isEmpty }),
              manualAssignments.values.allSatisfy({ ids in
                  ids.allSatisfy(knownIDs.contains) && ids == Array(Set(ids)).sorted()
              }) else { throw MeetingDiarizationError.invalidTimeline }
        return self
    }
}

nonisolated enum MeetingDiarizationFingerprint {

    static func manifest(_ manifest: MeetingAudioManifest) throws -> String {
        try digest(manifest)
    }

    static func source(_ result: MeetingResult) throws -> String {
        struct Content: Encodable {
            let transcriptRevision: Int
            let segments: [Segment]
        }
        struct Segment: Encodable {
            let id: String
            let lineageID: String?
            let text: String
            let startMs: Int64
            let endMs: Int64
            let isFinal: Bool
            let confidence: Double?
            let timedRuns: [MeetingTimedTextRun]?
        }
        let content = Content(transcriptRevision: result.transcriptRevision, segments: result.segments.map {
            Segment(id: $0.id, lineageID: $0.lineageID, text: $0.text,
                    startMs: $0.startMs, endMs: $0.endMs, isFinal: $0.isFinal,
                    confidence: $0.confidence, timedRuns: $0.timedRuns)
        })
        return try digest(content)
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum MeetingDiarizationError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidTimeline
}
