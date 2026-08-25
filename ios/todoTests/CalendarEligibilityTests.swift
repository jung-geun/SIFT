import Foundation
import Testing
@testable import todo

struct CalendarEligibilityTests {
    @Test("review manual and meeting todos are not automatic calendar candidates")
    @MainActor
    func reviewTodosAreRejectedGlobally() {
        let manual = Todo(title: "manual review")
        manual.dueDate = Date().addingTimeInterval(3600)
        manual.triageStatus = TodoTriage.review.rawValue

        let meeting = Todo(title: "meeting review")
        meeting.source = TodoSource.meeting.rawValue
        meeting.dueDate = Date().addingTimeInterval(3600)
        meeting.triageStatus = TodoTriage.review.rawValue

        #expect(!CalendarService.isAutomaticRegistrationCandidate(manual))
        #expect(!CalendarService.isAutomaticRegistrationCandidate(meeting))
    }
}
