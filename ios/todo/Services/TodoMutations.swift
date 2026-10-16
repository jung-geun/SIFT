import Foundation
import SwiftData

/// Todo 완료·삭제의 단일 choke point.
/// 목록과 상세가 동일한 캘린더/알림/학습/행동 로그 부작용을 공유한다.
@MainActor
enum TodoMutations {
    static func setCompleted(_ todo: Todo, completed: Bool, in context: ModelContext) {
        let wasCompleted = todo.isCompleted
        todo.isCompleted = completed
        todo.completedAt = completed ? Date() : nil
        todo.updatedAt = Date()
        TaskBehaviorRecorder.recordCompletionChange(
            of: todo,
            from: wasCompleted,
            to: completed,
            actor: .user,
            in: context
        )
        NotificationService.shared.cancel(todo: todo)

        guard completed else { return }

        let calendarCompletionAction: String = SettingsStore.shared.get(
            "pieroot.todo.calendarCompletionAction",
            defaultValue: "silence"
        )
        if calendarCompletionAction == "silence" {
            if let eventID = todo.calendarEventID {
                _ = try? CalendarService.shared.removeAlarms(eventID: eventID)
            }
            // 알람만 끈 경우 calendarEventID는 유지 (이벤트는 캘린더에 남음)
        } else if todo.todoSource == .email {
            _ = CalendarService.shared.removeEmailCalendarArtifacts(for: todo)
        } else if let eventID = todo.calendarEventID {
            _ = try? CalendarService.shared.removeEvent(eventID: eventID)
            todo.calendarEventID = nil
        }
    }

    /// Success means the deletion and its audit records are on disk, not awaiting autosave.
    /// A failed save restores the row and must be presented by the caller as an error.
    static func delete(_ todo: Todo, in context: ModelContext) throws {
        // Establish a baseline so rollback cannot discard unrelated pending edits.
        if context.hasChanges {
            try context.save()
        }

        // SwiftData can invalidate a deleted model after save. Retain only the inputs
        // required by the existing cleanup APIs, without inserting this detached copy.
        let cleanupTodo = Todo(
            id: todo.id,
            startDate: todo.startDate,
            dueDate: todo.dueDate,
            source: todo.todoSource,
            sourceRef: todo.sourceRef
        )
        cleanupTodo.isCompleted = todo.isCompleted
        cleanupTodo.triageStatus = todo.triageStatus
        cleanupTodo.isFixedSchedule = todo.isFixedSchedule
        cleanupTodo.calendarEventID = todo.calendarEventID
        cleanupTodo.calendarEventExternalID = todo.calendarEventExternalID
        cleanupTodo.sourceSenderEmail = todo.sourceSenderEmail

        // User deletion and both audit records form one durable transaction.
        TaskBehaviorRecorder.recordDeletion(of: todo, actor: .user, in: context)
        context.insert(TaskAuditEvent(from: todo))
        context.delete(todo)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        // Do not cancel reminders, remove calendar events, or teach email dismissal
        // for a deletion that failed to persist.
        performDeletionSideEffects(for: cleanupTodo)
    }

    private static func performDeletionSideEffects(for todo: Todo) {
        NotificationService.shared.cancel(todo: todo)
        // 대기열(review) 항목은 캘린더 이벤트 보존 — 큐에서 제거해도 이벤트는 유지
        // 태스크(todo)로 승격된 항목만 함께 삭제
        if !todo.isCompleted && todo.triage == .todo {
            if todo.todoSource == .email {
                _ = CalendarService.shared.removeEmailCalendarArtifacts(for: todo)
            } else if let eventID = todo.calendarEventID {
                if todo.isFixedSchedule, let anchor = todo.scheduleAnchor {
                    // 반복 이벤트: 일정 시작 시각 기준 해당 발생분만 제거
                    _ = try? CalendarService.shared.removeEventOccurrence(eventID: eventID, on: anchor)
                } else {
                    _ = try? CalendarService.shared.removeEvent(eventID: eventID)
                }
            }
        }
        // 이메일 출처 삭제 → 학습 기록 (단일 choke point)
        // - messageID(sourceRef) → dismissed 영속화: 재폴링 시 재생성 방지
        // - senderEmail → 삭제 카운트 누적: 2회 이상 시 자동 억제
        if todo.todoSource == .email {
            EmailLearningStore.shared.recordDeletion(
                senderEmail: todo.sourceSenderEmail,
                messageID: todo.sourceRef
            )
        }
    }
}
