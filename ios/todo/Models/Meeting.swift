import Foundation
import CryptoKit
import SwiftData

// MARK: - Meeting wire models

enum MeetingProcessingMode: String, Codable, CaseIterable, Sendable {
    case onDevice
    case openAI
    case google
}

enum MeetingStatus: String, Codable, Sendable {
    case recording, paused, interrupted, stopping
    case finalizingTranscript, extractingActions, ready, failed, cancelled
    /// Raw audio and the provisional transcript are saved; only the Speech
    /// finalization step failed or timed out, so it can be retried.
    case transcriptFinalizationFailed
}

struct MeetingSegment: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let lineageID: String?
    var startMs: Int64
    var endMs: Int64
    var speakerIDs: [String]
    var text: String
    var isFinal: Bool
    var confidence: Double?

    init(id: String = UUID().uuidString.lowercased(), lineageID: String? = nil,
         startMs: Int64, endMs: Int64, speakerIDs: [String] = [], text: String,
         isFinal: Bool = true, confidence: Double? = nil) {
        self.id = id
        self.lineageID = lineageID
        self.startMs = startMs
        self.endMs = endMs
        self.speakerIDs = speakerIDs.sorted()
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
    }

    var stableLineageID: String { lineageID ?? id }

    var isValid: Bool {
        startMs >= 0 && endMs > startMs && id.isEmpty == false &&
        lineageID.map { !$0.isEmpty } ?? true &&
        speakerIDs == speakerIDs.sorted() &&
        confidence.map { $0.isFinite && (0...1).contains($0) } ?? true
    }
}

struct ProviderActionDraftInput: Codable, Hashable, Sendable {
    var title: String
    var notes: String
    var assignee: String?
    var dueAtISO8601: String?
    var sourceSegmentIDs: [String]
    var confidence: Double
    var requiresReview: Bool
}

struct ProviderMeetingExtraction: Codable, Hashable, Sendable {
    var title: String
    var summary: String
    var decisions: [String]
    var unresolvedQuestions: [String]
    var actionDrafts: [ProviderActionDraftInput]
}

struct MeetingActionDraft: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var title: String
    var notes: String
    var assignee: String?
    var dueAtISO8601: String?
    var sourceSegmentIDs: [String]
    var confidence: Double
    var requiresReview: Bool

    init(id: String? = nil, title: String, notes: String = "", assignee: String? = nil,
         dueAtISO8601: String? = nil, sourceSegmentIDs: [String] = [], confidence: Double = 0,
         requiresReview: Bool = true, meetingID: String? = nil) {
        self.title = title
        self.notes = notes
        self.assignee = assignee
        self.dueAtISO8601 = dueAtISO8601
        self.sourceSegmentIDs = sourceSegmentIDs
        self.confidence = confidence
        self.requiresReview = requiresReview
        self.id = id ?? (meetingID.map {
            MeetingCanonicalID.action(meetingID: $0, sourceSegmentIDs: sourceSegmentIDs,
                                      title: title, assignee: assignee, dueAtISO8601: dueAtISO8601)
        } ?? UUID().uuidString.lowercased())
    }
}

struct MeetingResult: nonisolated Codable, Hashable, Sendable {
    var transcriptRevision: Int
    var title: String
    var summary: String
    var decisions: [String]
    var unresolvedQuestions: [String]
    var segments: [MeetingSegment]
    var actionDrafts: [MeetingActionDraft]

    init(transcriptRevision: Int = 0, title: String = "", summary: String = "",
         decisions: [String] = [], unresolvedQuestions: [String] = [], segments: [MeetingSegment] = [],
         actionDrafts: [MeetingActionDraft] = []) {
        self.transcriptRevision = transcriptRevision
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.unresolvedQuestions = unresolvedQuestions
        self.segments = segments
        self.actionDrafts = actionDrafts
    }

    func validated() throws -> MeetingResult {
        guard transcriptRevision >= 0 else { throw MeetingModelError.invalidRevision }
        var segmentIDs = Set<String>()
        var lineageIDs = Set<String>()
        var previous: (Int64, Int64, String)?
        for segment in segments {
            guard segment.isValid else { throw MeetingModelError.invalidSegment(segment.id) }
            guard segmentIDs.insert(segment.id).inserted else {
                throw MeetingModelError.duplicateSegmentID(segment.id)
            }
            guard lineageIDs.insert(segment.stableLineageID).inserted else {
                throw MeetingModelError.duplicateSegmentLineage(segment.stableLineageID)
            }
            if let previous, (segment.startMs, segment.endMs, segment.id) <= previous {
                throw MeetingModelError.segmentsNotOrdered
            }
            previous = (segment.startMs, segment.endMs, segment.id)
        }
        return self
    }

    func segmentID(at milliseconds: Int64) -> String? {
        var lowerBound = 0
        var upperBound = segments.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if segments[middle].startMs <= milliseconds {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound > 0 else { return nil }
        let segment = segments[lowerBound - 1]
        guard milliseconds < segment.endMs,
              !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return segment.id
    }

    func hasSameTranscript(as other: MeetingResult) -> Bool {
        transcriptRevision == other.transcriptRevision && segments == other.segments
    }

    func replacingSummary(_ summary: String, ifTranscriptMatches source: MeetingResult) -> MeetingResult? {
        guard hasSameTranscript(as: source) else { return nil }
        var copy = self
        copy.summary = summary
        return copy
    }
}

enum MeetingModelError: Error, Equatable {
    case invalidRevision
    case invalidSegment(String)
    case duplicateSegmentID(String)
    case duplicateSegmentLineage(String)
    case segmentsNotOrdered
    case unpairedSurrogate
    case invalidMeetingID
    case invalidTimeline
    case invalidTransition
}

// MARK: - Canonical IDs

enum MeetingCanonicalID {
    nonisolated static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    static func replacementSegment(
        meetingID: String,
        transcriptRevision: Int,
        startMs: Int64,
        endMs: Int64,
        text: String,
        lineageID: String? = nil
    ) -> String {
        try! validateMeetingID(meetingID)
        precondition(transcriptRevision >= 0 && Int64(transcriptRevision) <= maximumSafeInteger)
        validateCanonicalMilliseconds(startMs, endMs)
        precondition(lineageID.map { !$0.isEmpty } ?? true)
        let canonicalText = MeetingText.normalize(text, collapseRuns: false)
        var fields: [(String, MeetingCanonicalJSON.Value)] = [
            ("meetingId", .string(meetingID)),
            ("transcriptRevision", .integer(Int64(transcriptRevision))),
            ("startMs", .integer(startMs)),
            ("endMs", .integer(endMs)),
            ("text", .string(canonicalText))
        ]
        if let lineageID {
            fields.append(("lineageId", .string(lineageID)))
        }
        return digest(MeetingCanonicalJSON.object(fields))
    }

    static func action(meetingID: String, sourceSegmentIDs: [String], title: String,
                       assignee: String?, dueAtISO8601: String?) -> String {
        try! validateMeetingID(meetingID)
        let ids = Array(Set(sourceSegmentIDs)).sorted()
        precondition(ids.allSatisfy(isValidSourceSegmentID))
        let canonicalDue = dueAtISO8601.map { value in
            guard let canonical = MeetingDate.canonicalUTC(value) else {
                preconditionFailure("invalid dueAt")
            }
            return canonical
        }
        let bytes = MeetingCanonicalJSON.object([
            ("meetingId", .string(meetingID)),
            ("sourceSegmentIds", .array(ids.map { .string($0) })),
            ("title", .string(MeetingText.normalize(title, collapseRuns: true))),
            ("assignee", assignee.map { .string(MeetingText.normalize($0, collapseRuns: true)) } ?? .null),
            ("dueAt", canonicalDue.map { .string($0) } ?? .null)
        ])
        return digest(bytes)
    }

    static func validateMeetingID(_ value: String) throws {
        guard value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil else {
            throw MeetingModelError.invalidMeetingID
        }
    }

    private static func validateCanonicalMilliseconds(_ startMs: Int64, _ endMs: Int64) {
        precondition(startMs >= 0 && endMs >= startMs && endMs <= maximumSafeInteger)
    }

    nonisolated private static func isValidSourceSegmentID(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7E && $0.value != 0x22 && $0.value != 0x5C }
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

enum MeetingCanonicalJSON {
    enum Value {
        case string(String), integer(Int64), null, array([Value])
    }

    nonisolated static func object(_ fields: [(String, Value)]) -> Data {
        var out = "{"; out.reserveCapacity(fields.count * 24)
        for (index, field) in fields.enumerated() {
            if index > 0 { out.append(",") }
            out += quote(field.0); out.append(":"); out += encode(field.1)
        }
        out.append("}")
        return Data(out.utf8)
    }

    nonisolated private static func encode(_ value: Value) -> String {
        switch value {
        case .string(let value): return quote(value)
        case .integer(let value):
            precondition(value >= 0 && value <= MeetingCanonicalID.maximumSafeInteger)
            return String(value)
        case .null: return "null"
        case .array(let values): return "[" + values.map(encode).joined(separator: ",") + "]"
        }
    }

    nonisolated static func quote(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: output += "\\\""
            case 0x5C: output += "\\\\"
            case 0x08: output += "\\b"
            case 0x09: output += "\\t"
            case 0x0A: output += "\\n"
            case 0x0C: output += "\\f"
            case 0x0D: output += "\\r"
            case 0...0x1F: output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        output.append("\"")
        return output
    }
}

enum MeetingText {
    static let trimScalars: Set<UInt32> = {
        var values = Set<UInt32>(9...13)
        values.formUnion([0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000])
        values.formUnion(0x2000...0x200A)
        return values
    }()

    static func normalize(_ input: String, collapseRuns: Bool) -> String {
        let nfc = input.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let scalars = Array(nfc.unicodeScalars)
        var first = 0, last = scalars.count
        while first < last && trimScalars.contains(scalars[first].value) { first += 1 }
        while last > first && trimScalars.contains(scalars[last - 1].value) { last -= 1 }
        var output = String(String.UnicodeScalarView(scalars[first..<last]))
        if collapseRuns {
            var collapsed = "", inRun = false
            for scalar in output.unicodeScalars {
                if trimScalars.contains(scalar.value) {
                    if !inRun { collapsed.append(" "); inRun = true }
                } else { collapsed.unicodeScalars.append(scalar); inRun = false }
            }
            output = collapsed
        }
        return output
    }
}

enum MeetingDate {
    private static let parseFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let emitFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    static func canonicalUTC(_ raw: String) -> String? {
        guard raw.range(of: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$", options: .regularExpression) != nil,
              let date = parseFormatter.date(from: raw),
              emitFormatter.string(from: date) == raw else {
            return nil
        }
        return raw
    }

    static func date(_ raw: String?) -> Date? {
        guard let raw, canonicalUTC(raw) != nil else { return nil }
        return parseFormatter.date(from: raw)
    }
}

// MARK: - Revision mechanics

struct MeetingRevisionEditor: Sendable {
    static func renameSpeaker(in result: MeetingResult, from oldID: String, to newID: String) -> MeetingResult {
        var copy = result
        copy.segments = copy.segments.map { segment in
            var segment = segment
            segment.speakerIDs = Array(Set(segment.speakerIDs.map { $0 == oldID ? newID : $0 })).sorted()
            return segment
        }
        return copy
    }

    static func editSegments(meetingID: String, in result: MeetingResult, segments: [MeetingSegment]) throws -> MeetingResult {
        guard segments != result.segments else { return result }
        let nextRevision = result.transcriptRevision + 1
        let normalized = segments.map { segment in
            let lineageID = segment.stableLineageID
            return MeetingSegment(
                id: MeetingCanonicalID.replacementSegment(
                    meetingID: meetingID,
                    transcriptRevision: nextRevision,
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: segment.text,
                    lineageID: lineageID
                ),
                lineageID: lineageID,
                startMs: segment.startMs,
                endMs: segment.endMs,
                speakerIDs: segment.speakerIDs,
                text: segment.text,
                isFinal: segment.isFinal,
                confidence: segment.confidence
            )
        }.sorted { ($0.startMs, $0.endMs, $0.id) < ($1.startMs, $1.endMs, $1.id) }
        let copy = MeetingResult(
            transcriptRevision: nextRevision,
            title: result.title,
            summary: "",
            decisions: [],
            unresolvedQuestions: [],
            segments: normalized,
            actionDrafts: []
        )
        _ = try copy.validated()
        return copy
    }
}

struct MeetingAudioPartManifest: nonisolated Codable, nonisolated Equatable, Sendable {
    let fileName: String
    let partIndex: Int
    let partStartSample: Int64
    let ownedStartSample: Int64
    let ownedEndSample: Int64
}

struct MeetingAudioManifest: nonisolated Codable, nonisolated Equatable, Sendable {
    let relativeDirectory: String
    let sampleRate: Int64
    let totalSamples: Int64
    let parts: [MeetingAudioPartManifest]
}

// MARK: - Local SwiftData record (never included in appSchema)

@Model
final class MeetingRecord {
    var meetingID: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var modeRaw: String = MeetingProcessingMode.onDevice.rawValue
    var languageTag: String = "en-US"
    var timezoneIdentifier: String = "UTC"
    var statusRaw: String = MeetingStatus.ready.rawValue
    var transcriptRevision: Int = 0
    var resultData: Data = Data()
    /// Snapshot of the transcript before automatic refinement. Re-snapshotted
    /// whenever a new transcription base is established so inline proofread
    /// provenance never compares against a stale transcription.
    var rawResultData: Data?
    /// Stable raw source ID that last committed the correction ("검수") pass:
    /// "apple-intelligence", "qwen", or "user-vocabulary". Empty when the
    /// current transcript is a raw base or has been edited by the user. Legacy
    /// localized labels are read for display but are never written by new commits.
    var refinementEngineLabel: String = ""
    /// Stable rule fallback reason for transcript refinement; legacy rows remain unknown.
    var refinementFallbackReasonRaw: String? = nil
    var manifestData: Data = Data()
    var retentionUntil: Date?
    var confirmedTodoIDs: [String] = []
    var disclosureVersionID: String = ""

    init(meetingID: String = UUID().uuidString.lowercased(), mode: MeetingProcessingMode = .onDevice,
         languageTag: String = "en-US", timezoneIdentifier: String = "UTC") {
        self.meetingID = meetingID.lowercased()
        self.modeRaw = mode.rawValue
        self.languageTag = languageTag
        self.timezoneIdentifier = timezoneIdentifier
        self.statusRaw = MeetingStatus.recording.rawValue
    }

    var mode: MeetingProcessingMode { MeetingProcessingMode(rawValue: modeRaw) ?? .onDevice }
    var status: MeetingStatus { MeetingStatus(rawValue: statusRaw) ?? .failed }
    func refinementEngineDisplayName(language: AppLanguage) -> String {
        let stored = refinementEngineLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return "" }
        if let source = MeetingRefinementEngine.Source(rawValue: stored) {
            return source.displayName(language: language)
        }
        switch stored {
        case "Apple Intelligence 온디바이스":
            return MeetingRefinementEngine.Source.appleIntelligence.displayName(language: language)
        case "온디바이스 LLM(Qwen)":
            return MeetingRefinementEngine.Source.qwen.displayName(language: language)
        case "사용자 단어장":
            return MeetingRefinementEngine.Source.userVocabulary.displayName(language: language)
        default:
            return AppLanguage.localized(
                "meeting.engine.unknown",
                defaultValue: language == .english ? "Unknown Engine" : "알 수 없는 엔진",
                language: language,
                comment: "Unknown legacy meeting engine provenance"
            )
        }
    }
    var result: MeetingResult? { try? JSONDecoder().decode(MeetingResult.self, from: resultData) }
    /// Pre-refinement transcript, if a raw base has been snapshotted.
    var rawResult: MeetingResult? {
        guard let rawResultData else { return nil }
        return try? JSONDecoder().decode(MeetingResult.self, from: rawResultData)
    }

    func update(result: MeetingResult, status: MeetingStatus = .ready) throws {
        resultData = try JSONEncoder().encode(result.validated())
        transcriptRevision = result.transcriptRevision
        statusRaw = status.rawValue
        updatedAt = Date()
    }

    /// Snapshots `result` as the raw (pre-refinement) baseline. Call whenever a
    /// new transcription base is established — first finalize and every
    /// re-transcription — so inline corrections compare with the correct source.
    func snapshotRawBase(_ result: MeetingResult) throws {
        rawResultData = try JSONEncoder().encode(result.validated())
    }

    func replaceTranscriptionBase(_ result: MeetingResult, status: MeetingStatus) throws {
        try update(result: result, status: status)
        try snapshotRawBase(result)
        refinementEngineLabel = ""
    }

    struct PersistenceSnapshot: Equatable {
        let resultData: Data
        let rawResultData: Data?
        let transcriptRevision: Int
        let statusRaw: String
        let refinementEngineLabel: String
        let refinementFallbackReasonRaw: String?
        let manifestData: Data
        let updatedAt: Date
    }

    func persistenceSnapshot() -> PersistenceSnapshot {
        PersistenceSnapshot(
            resultData: resultData,
            rawResultData: rawResultData,
            transcriptRevision: transcriptRevision,
            statusRaw: statusRaw,
            refinementEngineLabel: refinementEngineLabel,
            refinementFallbackReasonRaw: refinementFallbackReasonRaw,
            manifestData: manifestData,
            updatedAt: updatedAt
        )
    }

    func restore(_ snapshot: PersistenceSnapshot) {
        resultData = snapshot.resultData
        rawResultData = snapshot.rawResultData
        transcriptRevision = snapshot.transcriptRevision
        statusRaw = snapshot.statusRaw
        refinementEngineLabel = snapshot.refinementEngineLabel
        manifestData = snapshot.manifestData
        refinementFallbackReasonRaw = snapshot.refinementFallbackReasonRaw
        updatedAt = snapshot.updatedAt
    }

    func update(status: MeetingStatus) {
        statusRaw = status.rawValue
        updatedAt = Date()
    }
}

@MainActor
enum MeetingRecordCommitter {
    static func persist(
        record: MeetingRecord,
        save: () throws -> Void,
        mutate: () throws -> Void
    ) throws {
        let snapshot = record.persistenceSnapshot()
        do {
            try mutate()
            try save()
        } catch {
            record.restore(snapshot)
            throw error
        }
    }
}
