import Foundation
import Testing
@testable import todo

struct TodoEligibilityReconcilerTests {
    @Test("review reconciliation cancels notifications once and preserves manual calendar links")
    @MainActor
    func reviewCleanupIsIdempotent() async {
        var cancellationCount = 0
        let reconciler = TodoEligibilityReconciler(
            cancelNotifications: { _ in cancellationCount += 1 }
        )
        let todo = Todo(title: "review item")
        todo.source = TodoSource.email.rawValue
        todo.calendarEventID = "manually-linked-event"
        todo.calendarEventExternalID = "cross-device-manual-link"

        await reconciler.setTriage(.review, for: todo)
        await reconciler.reconcile(todo)
        await reconciler.reconcileAll([todo])

        #expect(todo.triage == .review)
        #expect(cancellationCount == 1)
        #expect(todo.calendarEventID == "manually-linked-event")
        #expect(todo.calendarEventExternalID == "cross-device-manual-link")
    }

    @Test("non-review reconciliation preserves scheduling artifacts")
    @MainActor
    func nonReviewDoesNotClean() async {
        var cancellationCount = 0
        let reconciler = TodoEligibilityReconciler(
            cancelNotifications: { _ in cancellationCount += 1 }
        )
        let todo = Todo(title: "active item")
        todo.source = TodoSource.email.rawValue
        todo.calendarEventID = "existing-event"

        await reconciler.reconcile(todo)
        await reconciler.setTriage(.todo, for: todo)

        #expect(todo.triage == .todo)
        #expect(cancellationCount == 0)
        #expect(todo.calendarEventID == "existing-event")
    }

    @Test("review cleanup cancels notifications for non-email items and retains calendar links")
    @MainActor
    func nonEmailReviewOnlyCancelsNotifications() async {
        var cancellationCount = 0
        let reconciler = TodoEligibilityReconciler(
            cancelNotifications: { _ in cancellationCount += 1 }
        )
        let todo = Todo(title: "manual review")
        todo.calendarEventID = "manual-event"

        await reconciler.reconcile(todo)
        todo.triageStatus = TodoTriage.review.rawValue
        await reconciler.reconcile(todo)

        #expect(cancellationCount == 1)
        #expect(todo.calendarEventID == "manual-event")
    }

    @Test("recurring promotion respects source opt-in and the seven-day boundary")
    @MainActor
    func recurringPromotionRequiresSelectedCalendar() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let selected = Todo(title: "Selected", dueDate: now, source: .calendar)
        selected.calendarSourceID = "selected"
        selected.calendarEventExternalID = "selected-uid"
        let excluded = Todo(title: "Excluded", dueDate: now.addingTimeInterval(3_600), source: .calendar)
        excluded.calendarSourceID = "excluded"
        let outside = Todo(title: "Outside", dueDate: now.addingTimeInterval(7 * 86_400 + 1), source: .calendar)
        outside.calendarSourceID = "selected"
        let manual = Todo(title: "Manual", dueDate: now.addingTimeInterval(7 * 86_400), source: .manual)
        let tasks = [selected, excluded, outside, manual]
        for task in tasks {
            task.triageStatus = TodoTriage.review.rawValue
            task.isFixedSchedule = true
        }
        await TodoEligibilityReconciler().promoteUpcomingRecurringReviews(
            in: tasks, now: now, selectedCalendarIDs: ["selected"]
        )
        #expect(selected.triage == .todo && manual.triage == .todo)
        #expect(excluded.triage == .review && outside.triage == .review)
        #expect(selected.calendarSourceID == "selected" && selected.calendarEventExternalID == "selected-uid")
    }

    @Test("past legacy reviews expire while known deselected, approved, and completed tasks remain")
    @MainActor
    func expiredReviewsRespectProvenanceAndApproval() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let todo = Todo(title: "Restored suggestion", dueDate: now.addingTimeInterval(-1), source: .calendar)
        todo.triageStatus = TodoTriage.review.rawValue
        todo.calendarEventID = "legacy-local-id"
        #expect(TodoEligibilityReconciler.isExpiredReview(todo, now: now, selectedCalendarIDs: []))
        todo.calendarSourceID = "excluded"
        #expect(!TodoEligibilityReconciler.isExpiredReview(todo, now: now, selectedCalendarIDs: ["selected"]))
        todo.calendarSourceID = "selected"
        #expect(TodoEligibilityReconciler.isExpiredReview(todo, now: now, selectedCalendarIDs: ["selected"]))
        todo.isCompleted = true
        #expect(!TodoEligibilityReconciler.isExpiredReview(todo, now: now, selectedCalendarIDs: ["selected"]))
        todo.isCompleted = false
        todo.triageStatus = TodoTriage.todo.rawValue
        #expect(!TodoEligibilityReconciler.isExpiredReview(todo, now: now, selectedCalendarIDs: ["selected"]))
        todo.triageStatus = TodoTriage.review.rawValue
        todo.dueDate = now
        #expect(!TodoEligibilityReconciler.isExpiredReview(todo, now: now, selectedCalendarIDs: ["selected"]))
    }
}
