import Foundation
import SwiftData

@MainActor
enum MeetingTodoImporter {
    /// Imports the persisted draft rather than caller-provided fields, so a stale or
    /// modified UI draft cannot create a Todo that differs from the reviewed meeting.
    static func confirm(
        draftID: String,
        transcriptRevision: Int,
        meeting: MeetingRecord,
        todoContext: ModelContext,
        meetingContext: ModelContext
    ) throws -> Todo {
        guard transcriptRevision == meeting.transcriptRevision,
              let result = meeting.result,
              let draft = result.actionDrafts.first(where: { $0.id == draftID })
        else {
            throw MeetingTodoImportError.staleOrUnknownDraft
        }

        let language = AppLanguage.current
        let sourceRef = "meeting:\(meeting.meetingID):action:\(draft.id)"
        let descriptor = FetchDescriptor<Todo>(predicate: #Predicate { todo in
            todo.sourceRef == sourceRef
        })
        let todo: Todo
        if let existing = try todoContext.fetch(descriptor).first {
            todo = existing
        } else {
            todo = Todo(
                title: draft.title,
                notes: notes(for: draft, meetingID: meeting.meetingID, language: language),
                dueDate: MeetingDate.date(draft.dueAtISO8601),
                source: .meeting,
                sourceRef: sourceRef,
                reminderOffsets: []
            )
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

    private static func notes(for draft: MeetingActionDraft, meetingID: String, language: AppLanguage) -> String {
        var lines = [String]()
        if !draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(draft.notes.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let assignee = draft.assignee?.trimmingCharacters(in: .whitespacesAndNewlines), !assignee.isEmpty {
            lines.append(
                {
                    let defaultValue = language == .english
                        ? "Assignee: \(assignee)"
                        : "담당자: \(assignee)"
                    let localized = AppLanguage.localized(
                        "meeting.notes.assignee",
                        defaultValue: defaultValue,
                        language: language,
                        comment: "Meeting action assignee note"
                    )
                    return localized == defaultValue
                        ? localized
                        : String(format: localized, locale: language.locale, assignee)
                }()
            )
        }
        lines.append(
            {
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
            }()
        )
        return lines.joined(separator: "\n")
    }
}

enum MeetingTodoImportError: LocalizedError, Equatable {
    case staleOrUnknownDraft

    var errorDescription: String? {
        AppLanguage.localized("meeting.action.error.staleDraft", defaultValue: "This action item has changed. Review the meeting again before adding it.",
                              language: .current, comment: "A stale or missing meeting action draft cannot be imported.")
    }
}
