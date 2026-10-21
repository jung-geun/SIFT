import Foundation

/// Keeps review-triage items out of user-facing scheduling side effects.
@MainActor
final class TodoEligibilityReconciler {
    typealias NotificationCanceller = @MainActor @Sendable (Todo) async -> Void

    static let shared = TodoEligibilityReconciler()

    private let cancelNotifications: NotificationCanceller
    private var reconciledReviewIDs: Set<UUID> = []

    init(
        cancelNotifications: @escaping NotificationCanceller = { todo in
            await NotificationService.shared.cancelAndWait(todo: todo)
        }
    ) {
        self.cancelNotifications = cancelNotifications
    }

    func setTriage(_ triage: TodoTriage, for todo: Todo) async {
        if triage != .review {
            reconciledReviewIDs.remove(todo.id)
        }
        todo.triageStatus = triage.rawValue
        await reconcile(todo)
    }

    func promoteUpcomingRecurringReviews(
        in todos: [Todo],
        now: Date,
        selectedCalendarIDs: Set<String>
    ) async {
        var sourcesByExternalID: [String: Set<String>] = [:]
        for todo in todos where todo.todoSource == .calendar && !todo.calendarEventExternalID.isEmpty {
            sourcesByExternalID[todo.calendarEventExternalID, default: []].insert(todo.calendarSourceID)
        }
        let weekAhead = now.addingTimeInterval(7 * 24 * 3_600)
        for todo in todos where todo.triage == .review && todo.isFixedSchedule && !todo.isCompleted {
            guard let due = todo.dueDate, due >= now, due <= weekAhead else { continue }
            if todo.todoSource == .calendar {
                guard CalendarService.isTaskAnalysisTodo(todo, selectedCalendarIDs: selectedCalendarIDs),
                      todo.calendarEventExternalID.isEmpty
                        || sourcesByExternalID[todo.calendarEventExternalID]?.count == 1 else { continue }
            }
            await setTriage(.todo, for: todo)
        }
    }

    static func isExpiredReview(_ todo: Todo, now: Date, selectedCalendarIDs: Set<String>) -> Bool {
        guard todo.triage == .review, !todo.isCompleted,
              let due = todo.dueDate, due < now else { return false }
        return todo.todoSource != .calendar || todo.calendarSourceID.isEmpty
            || selectedCalendarIDs.contains(todo.calendarSourceID)
    }

    func reconcile(_ todo: Todo) async {
        guard todo.triage == .review else {
            reconciledReviewIDs.remove(todo.id)
            return
        }
        guard reconciledReviewIDs.insert(todo.id).inserted else { return }
        await cancelNotifications(todo)
    }

    func reconcileAll(_ todos: [Todo]) async {
        for todo in todos where todo.triage == .review {
            await reconcile(todo)
        }
    }
}
