import Foundation

/// Keeps review-triage items out of user-facing scheduling side effects.
@MainActor
final class TodoEligibilityReconciler {
    typealias NotificationCanceller = @MainActor @Sendable (Todo) async -> Void
    typealias CalendarCleaner = @MainActor @Sendable (Todo) -> Void

    static let shared = TodoEligibilityReconciler()

    private let cancelNotifications: NotificationCanceller
    private var reconciledReviewIDs: Set<UUID> = []
    private let cleanCalendar: CalendarCleaner

    init(
        cancelNotifications: @escaping NotificationCanceller = { todo in
            await NotificationService.shared.cancelAndWait(todo: todo)
        },
        cleanCalendar: @escaping CalendarCleaner = { todo in
            _ = CalendarService.shared.removeEmailCalendarArtifacts(for: todo)
        }
    ) {
        self.cancelNotifications = cancelNotifications
        self.cleanCalendar = cleanCalendar
    }

    func setTriage(_ triage: TodoTriage, for todo: Todo) async {
        if triage != .review {
            reconciledReviewIDs.remove(todo.id)
        }
        todo.triageStatus = triage.rawValue
        await reconcile(todo)
    }

    func reconcile(_ todo: Todo) async {
        guard todo.triage == .review else {
            reconciledReviewIDs.remove(todo.id)
            return
        }
        guard reconciledReviewIDs.insert(todo.id).inserted else { return }
        await cancelNotifications(todo)
        guard todo.todoSource == .email else { return }
        cleanCalendar(todo)
    }

    func reconcileAll(_ todos: [Todo]) async {
        for todo in todos where todo.triage == .review {
            await reconcile(todo)
        }
    }
}
