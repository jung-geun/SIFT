import SwiftUI
import SwiftData

/// Shows actual saved candidates with their owning transcript, never an empty analysis placeholder.
struct MeetingActionDraftSection: View {
    @Environment(\.modelContext) private var meetingContext
    let record: MeetingRecord
    let sourceLabel: String
    @State private var registeredDraftIDs = Set<String>()
    @State private var importError: String?

    var body: some View {
        if let result = record.result, !result.actionDrafts.isEmpty {
            let attribution = MeetingTranscriptAttribution(meetingID: record.meetingID,
                result: result, profiles: record.diarization?.profiles ?? [])
            let completed = MeetingActionAttribution.completedOnlySegmentIDs(in: attribution)
            let segmentsByID = Dictionary(result.segments.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            let drafts = result.actionDrafts.filter {
                !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !MeetingActionAttribution.isCompleted($0, completedSegmentIDs: completed)
            }
            if !drafts.isEmpty {
                Section("확인 필요 태스크 후보") {
                    ForEach(drafts) { draft in
                        card(draft, revision: result.transcriptRevision, segmentsByID: segmentsByID, attribution: attribution)
                    }
                    if let importError {
                        Text(importError).font(.caption).foregroundStyle(AppTheme.destructive)
                    }
                }
                .accessibilityIdentifier("meeting.actions.\(record.meetingID)")
            }
        }
    }

    private func card(_ draft: MeetingActionDraft, revision: Int, segmentsByID: [String: MeetingSegment],
                      attribution: MeetingTranscriptAttribution) -> some View {
        let registered = registeredDraftIDs.contains(draft.id)
        let evidence = draft.sourceSegmentIDs.compactMap { segmentsByID[$0] }
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            Text(draft.title).font(.headline)
            Text(String(format: AppLanguage.localized("meeting.actions.source", defaultValue: "Source: %@",
                language: .current, comment: "The source transcript or whole-conversation context of a saved task candidate."),
                locale: AppLanguage.current.locale, sourceLabel))
                .font(.caption).foregroundStyle(.secondary)
            if let assignee = MeetingActionAttribution.supportedAssignee(for: draft, attribution: attribution) {
                Text(String(format: AppLanguage.localized("meeting.people.assignee", defaultValue: "Assignee: %@",
                    language: .current, comment: "Evidence-supported assignee of a reviewed meeting task."),
                    locale: AppLanguage.current.locale, assignee))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(evidence) { segment in
                Text("\(timestamp(segment.startMs)) · \(segment.text)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button {
                confirm(draft, revision: revision)
            } label: {
                Label(AppLanguage.localized(registered ? "meeting.action.registered" : "meeting.action.register",
                    defaultValue: registered ? "Registered" : "Register as To-Do", language: .current,
                    comment: "Review and register an extracted meeting task."),
                    systemImage: registered ? "checkmark.circle.fill" : "plus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(registered)
        }
        .padding(.vertical, AppTheme.Spacing.compact)
        .accessibilityIdentifier("meeting.action.\(record.meetingID).\(draft.id)")
    }

    private func confirm(_ draft: MeetingActionDraft, revision: Int) {
        importError = nil
        do {
            _ = try MeetingTodoImporter.confirm(draftID: draft.id, transcriptRevision: revision,
                meeting: record, todoContext: AppDataContainer.shared.container.mainContext,
                meetingContext: meetingContext)
            registeredDraftIDs.insert(draft.id)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func timestamp(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }
}
