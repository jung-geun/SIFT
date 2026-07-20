import Foundation

/// User-facing transcript edit operations. Each operation builds the edited
/// segment list and delegates to `MeetingRevisionEditor.editSegments`, which
/// bumps the revision, regenerates canonical IDs, and clears the summary and
/// action drafts — so anything referencing the previous revision becomes
/// stale and is rejected by `MeetingTodoImporter`.
enum MeetingTranscriptEditor {
    static func editText(result: MeetingResult, meetingID: String, segmentID: String, text: String) throws -> MeetingResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditError.emptyText }
        var segments = result.segments
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { throw EditError.unknownSegment }
        segments[index].text = trimmed
        return try MeetingRevisionEditor.editSegments(meetingID: meetingID, in: result, segments: segments)
    }

    static func setSpeakers(result: MeetingResult, meetingID: String, segmentID: String, speakerIDs: [String]) throws -> MeetingResult {
        var segments = result.segments
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { throw EditError.unknownSegment }
        segments[index].speakerIDs = speakerIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        return try MeetingRevisionEditor.editSegments(meetingID: meetingID, in: result, segments: segments)
    }

    static func split(result: MeetingResult, meetingID: String, segmentID: String, atMs: Int64, firstText: String, secondText: String) throws -> MeetingResult {
        let first = firstText.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = secondText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, !second.isEmpty else { throw EditError.emptyText }
        var segments = result.segments
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { throw EditError.unknownSegment }
        let segment = segments[index]
        guard atMs > segment.startMs, atMs < segment.endMs else { throw EditError.invalidSplitPoint }
        let head = MeetingSegment(startMs: segment.startMs, endMs: atMs, speakerIDs: segment.speakerIDs, text: first)
        let tail = MeetingSegment(startMs: atMs, endMs: segment.endMs, speakerIDs: segment.speakerIDs, text: second)
        segments.replaceSubrange(index...index, with: [head, tail])
        return try MeetingRevisionEditor.editSegments(meetingID: meetingID, in: result, segments: segments)
    }

    static func mergeWithPrevious(result: MeetingResult, meetingID: String, segmentID: String) throws -> MeetingResult {
        var segments = result.segments
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { throw EditError.unknownSegment }
        guard index > 0 else { throw EditError.noPreviousSegment }
        let previous = segments[index - 1]
        let current = segments[index]
        let merged = MeetingSegment(
            startMs: previous.startMs,
            endMs: max(previous.endMs, current.endMs),
            speakerIDs: Array(Set(previous.speakerIDs + current.speakerIDs)),
            text: [previous.text, current.text]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        )
        segments.replaceSubrange((index - 1)...index, with: [merged])
        return try MeetingRevisionEditor.editSegments(meetingID: meetingID, in: result, segments: segments)
    }

    enum EditError: LocalizedError, Equatable {
        case unknownSegment
        case emptyText
        case invalidSplitPoint
        case noPreviousSegment

        var errorDescription: String? {
            errorDescription(language: .current)
        }

        func errorDescription(language: AppLanguage) -> String {
            switch self {
            case .unknownSegment:
                return AppLanguage.localized(
                    "error.meeting.transcriptEditor.unknownSegment",
                    defaultValue: language == .english
                        ? "The selected transcript segment could not be found."
                        : "선택한 전사 구간을 찾을 수 없습니다.",
                    language: language,
                    comment: "Meeting transcript editor error shown when a selected segment cannot be found."
                )
            case .emptyText:
                return AppLanguage.localized(
                    "error.meeting.transcriptEditor.emptyText",
                    defaultValue: language == .english
                        ? "Transcript text cannot be empty."
                        : "전사 내용은 비워둘 수 없습니다.",
                    language: language,
                    comment: "Meeting transcript editor error shown when an edit has empty transcript text."
                )
            case .invalidSplitPoint:
                return AppLanguage.localized(
                    "error.meeting.transcriptEditor.invalidSplitPoint",
                    defaultValue: language == .english
                        ? "The split point is outside the segment range."
                        : "분할 지점이 구간 범위를 벗어났습니다.",
                    language: language,
                    comment: "Meeting transcript editor error shown when a split point is outside a segment."
                )
            case .noPreviousSegment:
                return AppLanguage.localized(
                    "error.meeting.transcriptEditor.noPreviousSegment",
                    defaultValue: language == .english
                        ? "There is no previous segment to merge."
                        : "병합할 이전 구간이 없습니다.",
                    language: language,
                    comment: "Meeting transcript editor error shown when merging has no previous segment."
                )
            }
        }
    }
}
