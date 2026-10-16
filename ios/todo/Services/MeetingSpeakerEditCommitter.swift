import Foundation

enum MeetingSpeakerEditError: LocalizedError, Equatable {
    case unknownSpeaker
    case emptyName
    case unknownSegment
    case tooManySpeakers
    case unavailable

    var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .unknownSpeaker:
            return AppLanguage.localized(
                "meeting.speaker.error.unknown",
                defaultValue: english ? "That speaker no longer exists in this meeting." : "이 회의에 없는 화자입니다.",
                language: .current, comment: "Speaker edit referenced a missing profile."
            )
        case .emptyName:
            return AppLanguage.localized(
                "meeting.speaker.error.emptyName",
                defaultValue: english ? "Enter a speaker name." : "화자 이름을 입력하세요.",
                language: .current, comment: "Speaker rename with an empty name."
            )
        case .unknownSegment:
            return AppLanguage.localized(
                "meeting.speaker.error.segment",
                defaultValue: english ? "The transcript segment changed. Try again." : "전사 구간이 바뀌었습니다. 다시 시도하세요.",
                language: .current, comment: "Speaker assignment for a missing segment."
            )
        case .tooManySpeakers:
            return AppLanguage.localized(
                "meeting.speaker.error.limit",
                defaultValue: english ? "A meeting supports up to 8 speakers." : "회의당 화자는 최대 8명입니다.",
                language: .current, comment: "Speaker limit reached."
            )
        case .unavailable:
            return AppLanguage.localized(
                "meeting.speaker.error.unavailable",
                defaultValue: english
                    ? "Speakers can be edited only for meetings with saved audio."
                    : "저장된 음성이 있는 회의에서만 화자를 편집할 수 있습니다.",
                language: .current, comment: "Speaker edit without a saved recording."
            )
        }
    }
}

/// Speaker names and manual assignments. They never change transcript text,
/// timing, IDs, revision, summary or drafts; automatic passes do not override them.
@MainActor
enum MeetingSpeakerEditCommitter {
    static func rename(
        record: MeetingRecord,
        speakerID: String,
        displayName: String,
        save: () throws -> Void
    ) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MeetingSpeakerEditError.emptyName }
        var payload = try editablePayload(record: record).1
        guard let index = payload.profiles.firstIndex(where: { $0.id == speakerID }) else {
            throw MeetingSpeakerEditError.unknownSpeaker
        }
        payload.profiles[index].displayName = name
        // Display-only: an in-flight pass reads current names when it commits.
        try MeetingRecordCommitter.persist(record: record, save: save) {
            try record.update(diarization: payload)
        }
    }

    static func assign(
        record: MeetingRecord,
        segmentID: String,
        speakerIDs: [String],
        save: () throws -> Void
    ) throws {
        let (current, index, payload) = try editable(record: record, segmentID: segmentID)
        let ids = Array(Set(speakerIDs)).sorted()
        let known = Set(payload.profiles.map(\.id))
        guard ids.allSatisfy(known.contains) else { throw MeetingSpeakerEditError.unknownSpeaker }
        try commit(record: record, current: current, index: index, payload: payload, speakerIDs: ids, save: save)
    }

    /// Adds a speaker the model missed and assigns it to one segment atomically.
    @discardableResult
    static func createProfile(
        record: MeetingRecord,
        segmentID: String,
        displayName: String,
        save: () throws -> Void
    ) throws -> String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MeetingSpeakerEditError.emptyName }
        let (current, index, seeded) = try editable(record: record, segmentID: segmentID)
        var payload = seeded
        let id = UUID().uuidString.lowercased()
        var manual = payload.manualAssignments
        manual[current.segments[index].stableLineageID] = [id]
        let active = MeetingSpeakerProfileBook.activeIDs(intervals: payload.intervals, manualAssignments: manual)
        let used = Set(payload.profiles.filter { active.contains($0.id) }.map(\.ordinal))
        guard active.count <= MeetingSpeakerProfileBook.maximumActiveSpeakers,
              let ordinal = (1...MeetingSpeakerProfileBook.maximumActiveSpeakers).first(where: { !used.contains($0) })
        else { throw MeetingSpeakerEditError.tooManySpeakers }
        payload.profiles.append(MeetingSpeakerProfile(id: id, ordinal: ordinal, displayName: name))
        try commit(record: record, current: current, index: index, payload: payload, speakerIDs: [id], save: save)
        return id
    }

    private static func editable(
        record: MeetingRecord,
        segmentID: String
    ) throws -> (MeetingResult, Int, MeetingDiarizationPayload) {
        let (current, payload) = try editablePayload(record: record)
        guard let index = current.segments.firstIndex(where: { $0.id == segmentID }) else {
            throw MeetingSpeakerEditError.unknownSegment
        }
        return (current, index, payload)
    }

    /// Existing payload, or a first one that imports legacy labels as manual.
    private static func editablePayload(record: MeetingRecord) throws -> (MeetingResult, MeetingDiarizationPayload) {
        guard let manifest = record.audioManifest else { throw MeetingSpeakerEditError.unavailable }
        guard let current = record.result else { throw MeetingSpeakerEditError.unknownSegment }
        guard record.diarizationData == nil || record.diarization != nil else { throw MeetingSpeakerEditError.unavailable }
        let payload = try MeetingDiarizationPostProcessor.seed(
            record: record, source: current,
            manifestDigest: MeetingDiarizationFingerprint.manifest(manifest),
            sourceDigest: MeetingDiarizationFingerprint.source(current)
        )
        return (current, payload)
    }

    private static func commit(
        record: MeetingRecord,
        current: MeetingResult,
        index: Int,
        payload: MeetingDiarizationPayload,
        speakerIDs: [String],
        save: () throws -> Void
    ) throws {
        var payload = payload
        let lineage = current.segments[index].stableLineageID
        payload.manualAssignments[lineage] = speakerIDs
        guard MeetingSpeakerProfileBook.activeIDs(intervals: payload.intervals, manualAssignments: payload.manualAssignments).count
                <= MeetingSpeakerProfileBook.maximumActiveSpeakers else { throw MeetingSpeakerEditError.tooManySpeakers }
        // A manual change supersedes any pass started before it.
        payload.generation = UUID()
        if payload.status == .finalizing { payload.status = .interrupted }
        var updated = current
        updated.segments[index].speakerIDs = speakerIDs
        let raw = record.rawResult.map { raw -> MeetingResult in
            var copy = raw
            copy.segments = raw.segments.map { segment in
                var segment = segment
                if segment.stableLineageID == lineage { segment.speakerIDs = speakerIDs }
                return segment
            }
            return copy
        }
        let status = record.status
        try MeetingRecordCommitter.persist(record: record, save: save) {
            try record.update(result: updated, status: status)
            if let raw { try record.snapshotRawBase(raw) }
            try record.update(diarization: payload)
        }
    }
}
