import Foundation
import SwiftData

/// Parent rows group source records; they are never an audio or speaker namespace.
@MainActor
enum MeetingAudioTrackStore {
    /// An existing standalone row is never repurposed as a group, even if its
    /// ID collides with a new capture. Groups contain no source evidence.
    static func validateGroup(_ parent: MeetingRecord) throws {
        try MeetingCanonicalID.validateMeetingID(parent.meetingID)
        guard parent.parentMeetingID == nil, !parent.audioTrackIDs.isEmpty,
              Set(parent.audioTrackIDs).count == parent.audioTrackIDs.count,
              !parent.audioTrackIDs.contains(parent.meetingID),
              parent.audioTrackKindRaw == nil, parent.manifestData.isEmpty,
              parent.rawResultData == nil, parent.appleRawResultData == nil,
              parent.diarizationData == nil,
              parent.result?.segments.isEmpty != false else {
            throw MeetingCaptureRecoveryStore.RecoveryError.invalidManifest
        }
        for id in parent.audioTrackIDs { try MeetingCanonicalID.validateMeetingID(id) }
    }

    static func tracks(for parent: MeetingRecord, in context: ModelContext) throws -> [MeetingRecord] {
        try validateGroup(parent)
        let parentID = parent.meetingID
        let records = try context.fetch(FetchDescriptor<MeetingRecord>(
            predicate: #Predicate { $0.parentMeetingID == parentID }
        ))
        guard Set(records.map(\.meetingID)).count == records.count,
              Set(records.map(\.meetingID)) == Set(parent.audioTrackIDs),
              records.allSatisfy({ $0.audioTrackIDs.isEmpty && $0.audioTrackKind != nil }) else {
            throw MeetingCaptureRecoveryStore.RecoveryError.invalidManifest
        }
        let order = Dictionary(uniqueKeysWithValues: parent.audioTrackIDs.enumerated().map { ($0.element, $0.offset) })
        return records.sorted {
            if $0.audioTrackStartSample != $1.audioTrackStartSample {
                return $0.audioTrackStartSample < $1.audioTrackStartSample
            }
            let lhs = order[$0.meetingID] ?? Int.max
            let rhs = order[$1.meetingID] ?? Int.max
            return lhs == rhs ? $0.meetingID < $1.meetingID : lhs < rhs
        }
    }

    static func refresh(
        parent: MeetingRecord, in context: ModelContext,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let children = try tracks(for: parent, in: context)
        guard !children.isEmpty else { return }
        let title = parent.result?.title.isEmpty == false
            ? parent.result!.title
            : AppLanguage.localized("meeting.title.untitled", defaultValue: "Meeting", language: .current,
                                    comment: "Fallback title for an untitled meeting.")
        let status: MeetingStatus
        if children.contains(where: { $0.status == .finalizingTranscript || $0.status == .stopping }) {
            status = .finalizingTranscript
        } else if children.contains(where: { $0.status == .ready }) {
            status = .ready
        } else {
            status = .transcriptFinalizationFailed
        }
        try MeetingRecordCommitter.persist(record: parent, save: { try save(context) }) {
            parent.audioTrackIDs = children.map(\.meetingID)
            // No transcript concatenation or speaker reassignment at group level.
            try parent.update(result: MeetingResult(title: title), status: status)
        }
    }

    static func refreshParent(of track: MeetingRecord, in context: ModelContext) throws {
        guard let parentID = track.parentMeetingID else { return }
        guard let parent = try context.fetch(FetchDescriptor<MeetingRecord>(
            predicate: #Predicate { $0.meetingID == parentID }
        )).first else { return }
        try refresh(parent: parent, in: context)
    }
}
