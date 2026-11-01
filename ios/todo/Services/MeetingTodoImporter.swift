import Foundation
import CryptoKit
import SwiftData

@MainActor
enum MeetingTodoImporter {
    /// Identity follows the reviewed content and its original evidence, not a
    /// provider's positional item ID or the section in which it was rendered.
    static func summarySourceRef(item: MeetingSummaryItem, meetingID: String) -> String {
        let citations = canonicalCitations(item.citations)
        var hash = SHA256()
        func append(_ value: String) {
            let bytes = Data(value.utf8)
            hash.update(data: Data("\(bytes.count):".utf8))
            hash.update(data: bytes)
        }
        append(item.text)
        for citation in citations {
            append(citation.trackID)
            append(citation.segmentID)
            append(String(citation.transcriptRevision))
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return "meeting:\(meetingID):summary:\(digest)"
    }

    /// Includes proven registrations made by the former draft UI. A title
    /// match alone cannot alias a task from different original evidence.
    static func summarySourceRefs(item: MeetingSummaryItem, meeting: MeetingRecord) -> Set<String> {
        var refs: Set<String> = [summarySourceRef(item: item, meetingID: meeting.meetingID)]
        guard !meeting.isAudioTrackGroup, let result = meeting.result,
              result.transcriptRevision == meeting.transcriptRevision,
              !item.citations.isEmpty,
              item.citations.allSatisfy({ $0.trackID == meeting.meetingID && $0.transcriptRevision == meeting.transcriptRevision }) else {
            return refs
        }
        let segmentIDs = Set(item.citations.map(\.segmentID))
        for draft in result.actionDrafts where draft.title == item.text
            && !draft.sourceSegmentIDs.isEmpty && Set(draft.sourceSegmentIDs) == segmentIDs {
            refs.insert("meeting:\(meeting.meetingID):action:\(draft.id)")
        }
        return refs
    }

    /// Resolves the persisted sentence and original track-qualified evidence at
    /// the moment of review. Adding a task never invokes analysis or naming.
    static func confirmSummaryItem(
        sectionID: String,
        itemID: String,
        reviewedSourceRef: String,
        meeting: MeetingRecord,
        todoContext: ModelContext,
        meetingContext: ModelContext
    ) throws -> Todo {
        guard let result = meeting.result,
              let sections = result.summarySections,
              sections.lazy.filter({ $0.id == sectionID }).count == 1,
              let section = sections.first(where: { $0.id == sectionID }),
              section.items.lazy.filter({ $0.id == itemID }).count == 1,
              let item = section.items.first(where: { $0.id == itemID }),
              !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              MeetingSummaryTaskClassification.isTask(item, in: section, result: result),
              !item.citations.isEmpty else {
            throw MeetingTodoImportError.staleOrUnknownSummaryItem
        }
        let sourceRef = summarySourceRef(item: item, meetingID: meeting.meetingID)
        guard sourceRef == reviewedSourceRef else {
            throw MeetingTodoImportError.staleOrUnknownSummaryItem
        }

        let tracks: [MeetingRecord]
        if meeting.isAudioTrackGroup {
            do {
                guard try MeetingGroupSummaryService.summaryEvidenceValidity(parent: meeting, in: meetingContext) == .current else {
                    throw MeetingTodoImportError.staleOrUnknownSummaryItem
                }
                tracks = try MeetingAudioTrackStore.tracks(for: meeting, in: meetingContext)
            } catch is MeetingCaptureRecoveryStore.RecoveryError {
                throw MeetingTodoImportError.staleOrUnknownSummaryItem
            }
        } else {
            guard result.transcriptRevision == meeting.transcriptRevision,
                  result.summarySourceFingerprint == MeetingSummaryEvidence.sourceFingerprint(result) else {
                throw MeetingTodoImportError.staleOrUnknownSummaryItem
            }
            tracks = [meeting]
        }
        var evidence: [String] = []
        for citation in canonicalCitations(item.citations) {
            guard let track = tracks.first(where: { $0.meetingID == citation.trackID }),
                  track.transcriptRevision == citation.transcriptRevision,
                  let source = track.result,
                  source.transcriptRevision == citation.transcriptRevision,
                  source.segments.lazy.filter({ $0.id == citation.segmentID }).count == 1,
                  let segment = source.segments.first(where: { $0.id == citation.segmentID }),
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingTodoImportError.staleOrUnknownSummaryItem
            }
            evidence.append("[\(citation.trackID) · \(citation.segmentID) · r\(citation.transcriptRevision)]\n\(segment.text)")
        }

        // Validate even on a duplicate tap: an existing registration must not
        // make changed or no-longer-actionable summary evidence importable.
        let descriptor = FetchDescriptor<Todo>(predicate: #Predicate { $0.sourceRef == sourceRef })
        var registered = try todoContext.fetch(descriptor).first
        if registered == nil {
            let legacyRefs = summarySourceRefs(item: item, meeting: meeting).subtracting([sourceRef])
            for legacyRef in legacyRefs.sorted() {
                let legacyDescriptor = FetchDescriptor<Todo>(predicate: #Predicate { $0.sourceRef == legacyRef })
                if let existing = try todoContext.fetch(legacyDescriptor).first {
                    existing.sourceRef = sourceRef
                    try todoContext.save()
                    registered = existing
                    break
                }
            }
        }
        let todo: Todo
        if let existing = registered {
            todo = existing
        } else {
            todo = Todo(title: item.text,
                        notes: ([meetingNote(meetingID: meeting.meetingID, language: .current)] + evidence).joined(separator: "\n\n"),
                        dueDate: nil, source: .meeting, sourceRef: sourceRef, reminderOffsets: [])
            todo.triageStatus = TodoTriage.review.rawValue
            todo.aiNeedsNotification = false
            todo.aiRecommendedTime = nil
            todoContext.insert(todo)
            TaskBehaviorRecorder.recordCreation(of: todo, actor: .meetingImport, in: todoContext)
            try todoContext.save()
        }
        if !meeting.confirmedTodoIDs.contains(todo.id.uuidString) {
            meeting.confirmedTodoIDs.append(todo.id.uuidString)
            meeting.updatedAt = Date()
            try meetingContext.save()
        }
        return todo
    }

    private static func canonicalCitations(_ citations: [MeetingSummaryCitation]) -> [MeetingSummaryCitation] {
        Set(citations).sorted {
            if $0.trackID != $1.trackID { return $0.trackID < $1.trackID }
            if $0.segmentID != $1.segmentID { return $0.segmentID < $1.segmentID }
            return $0.transcriptRevision < $1.transcriptRevision
        }
    }

    private static func meetingNote(meetingID: String, language: AppLanguage) -> String {
        let defaultValue = language == .english
            ? "Meeting: \(meetingID)"
            : "회의: \(meetingID)"
        let localized = AppLanguage.localized(
            "meeting.notes.meeting",
            defaultValue: defaultValue,
            language: language,
            comment: "Meeting action source note"
        )
        return localized == defaultValue
            ? localized
            : String(format: localized, locale: language.locale, meetingID)
    }
}

enum MeetingTodoImportError: LocalizedError, Equatable {
    case staleOrUnknownSummaryItem

    var errorDescription: String? {
        AppLanguage.localized("meeting.action.error.staleDraft", defaultValue: "This action item has changed. Review the meeting again before adding it.",
                              language: .current, comment: "A stale or missing meeting summary item cannot be imported.")
    }
}
