import Foundation

/// Applies source evidence to future task drafts; completed work stays in the report.
enum MeetingActionAttribution {
    static func applying(to result: MeetingResult, meetingID: String,
                         profiles: [MeetingSpeakerProfile] = []) -> MeetingResult {
        let attribution = MeetingTranscriptAttribution(meetingID: meetingID, result: result, profiles: profiles)
        let completed = completedOnlySegmentIDs(in: attribution)
        var copy = result
        var seen = Set<String>()
        copy.actionDrafts = result.actionDrafts.compactMap { draft in
            guard !isCompleted(draft, completedSegmentIDs: completed) else { return nil }
            let assignee = supportedAssignee(for: draft, attribution: attribution)
            let attributed = assignee == draft.assignee ? draft : MeetingActionDraft(
                title: draft.title, notes: draft.notes, assignee: assignee,
                dueAtISO8601: draft.dueAtISO8601, sourceSegmentIDs: draft.sourceSegmentIDs,
                confidence: draft.confidence, requiresReview: true, meetingID: meetingID)
            return seen.insert(attributed.id).inserted ? attributed : nil
        }
        return copy
    }

    static func supportedAssignee(for draft: MeetingActionDraft, attribution: MeetingTranscriptAttribution) -> String? {
        // A stored/model-proposed name must not override current transcript evidence or a manual rename.
        var evidenceOnly = draft
        evidenceOnly.assignee = nil
        return attribution.assignee(for: evidenceOnly)
    }

    static func completedOnlySegmentIDs(in attribution: MeetingTranscriptAttribution) -> Set<String> {
        var completed = Set<String>()
        var pending = Set<String>()
        for activity in attribution.activities {
            if activity.kind == .completed { completed.formUnion(activity.sourceSegmentIDs) }
            else { pending.formUnion(activity.sourceSegmentIDs) }
        }
        return completed.subtracting(pending)
    }

    static func isCompleted(_ draft: MeetingActionDraft, completedSegmentIDs: Set<String>) -> Bool {
        !draft.sourceSegmentIDs.isEmpty && draft.sourceSegmentIDs.allSatisfy(completedSegmentIDs.contains)
    }
}
