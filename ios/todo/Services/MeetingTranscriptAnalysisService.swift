import Foundation

/// Conservative local extractor. It only emits review drafts for explicit
/// requests/commitments; persona relevance is intentionally not task evidence.
struct MeetingTranscriptAnalysisService {
    func analyze(meetingID: String, result: MeetingResult, language: AppLanguage) -> MeetingResult {
        let drafts = result.segments.compactMap { segment -> MeetingActionDraft? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isExplicitAction(text) else { return nil }
            let title = normalizedTitle(text)
            guard !title.isEmpty else { return nil }
            let defaultValue = language == .english
                ? "Meeting transcript: \(text)"
                : "회의 전사: \(text)"
            let localized = AppLanguage.localized(
                "meeting.notes.transcriptPrefix",
                defaultValue: defaultValue,
                language: language,
                comment: "Meeting action draft source transcript note"
            )
            let notes = localized == defaultValue
                ? localized
                : String(format: localized, locale: language.locale, text)
            return MeetingActionDraft(
                id: MeetingCanonicalID.action(
                    meetingID: meetingID,
                    sourceSegmentIDs: [segment.id],
                    title: title,
                    assignee: nil,
                    dueAtISO8601: nil
                ),
                title: title,
                notes: notes,
                assignee: nil,
                dueAtISO8601: nil,
                sourceSegmentIDs: [segment.id],
                confidence: 0.55,
                requiresReview: true
            )
        }
        var copy = result
        copy.actionDrafts = Array(Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) }).values)
            .sorted { $0.id < $1.id }
        return copy
    }

    private func isExplicitAction(_ text: String) -> Bool {
        let koreanPatterns = ["해주세요", "해 주세요", "해야", "하겠습니다", "보내", "제출", "확인해", "공유해"]
        if koreanPatterns.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        let englishPatterns = [
            #"\b(i|we|you)\s+(will|need to|should|must|am going to|are going to)\b"#,
            #"\b(i|we|you)['’]ll\b"#,
            #"\b(can|could|would) you\b"#,
            #"\baction item\b"#,
            #"\bfollow[- ]up\b"#,
            #"^(please\s+)?(send|submit|share|review|confirm|schedule|prepare|update|deliver|follow up)\b"#
        ]
        return englishPatterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    private func normalizedTitle(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
