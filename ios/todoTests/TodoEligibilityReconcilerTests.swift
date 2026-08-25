import Testing
@testable import todo

struct TodoEligibilityReconcilerTests {
    @Test("review reconciliation cancels notifications and email calendar artifacts once")
    @MainActor
    func reviewCleanupIsIdempotent() async {
        var cancellationCount = 0
        var calendarCleanupCount = 0
        let reconciler = TodoEligibilityReconciler(
            cancelNotifications: { _ in cancellationCount += 1 },
            cleanCalendar: { _ in calendarCleanupCount += 1 }
        )
        let todo = Todo(title: "review item")
        todo.source = TodoSource.email.rawValue

        await reconciler.setTriage(.review, for: todo)
        await reconciler.reconcile(todo)
        await reconciler.reconcileAll([todo])

        #expect(todo.triage == .review)
        #expect(cancellationCount == 1)
        #expect(calendarCleanupCount == 1)
    }

    @Test("non-review reconciliation preserves scheduling artifacts")
    @MainActor
    func nonReviewDoesNotClean() async {
        var cancellationCount = 0
        var calendarCleanupCount = 0
        let reconciler = TodoEligibilityReconciler(
            cancelNotifications: { _ in cancellationCount += 1 },
            cleanCalendar: { _ in calendarCleanupCount += 1 }
        )
        let todo = Todo(title: "active item")
        todo.source = TodoSource.email.rawValue

        await reconciler.reconcile(todo)
        await reconciler.setTriage(.todo, for: todo)

        #expect(todo.triage == .todo)
        #expect(cancellationCount == 0)
        #expect(calendarCleanupCount == 0)
    }

    @Test("review cleanup cancels notifications for non-email items without calendar cleanup")
    @MainActor
    func nonEmailReviewOnlyCancelsNotifications() async {
        var cancellationCount = 0
        var calendarCleanupCount = 0
        let reconciler = TodoEligibilityReconciler(
            cancelNotifications: { _ in cancellationCount += 1 },
            cleanCalendar: { _ in calendarCleanupCount += 1 }
        )
        let todo = Todo(title: "manual review")

        await reconciler.reconcile(todo)
        todo.triageStatus = TodoTriage.review.rawValue
        await reconciler.reconcile(todo)

        #expect(cancellationCount == 1)
        #expect(calendarCleanupCount == 0)
    }
}
