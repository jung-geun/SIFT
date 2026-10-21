import Foundation
import Testing
@testable import todo

@Suite("Local activity-specific routine learning")
@MainActor
struct RoutineLearningServiceTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ day: Int, hour: Int = 10, minute: Int = 15) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute))!
    }

    private func completed(_ title: String, at date: Date, source: TodoSource = .manual) -> Todo {
        let task = Todo(title: title, source: source, tags: ["health"])
        task.createdAt = date.addingTimeInterval(-3600)
        task.isCompleted = true
        task.completedAt = date
        return task
    }

    @Test("Exact normalized activities remain separate despite shared broad tags")
    func activityEvidence() throws {
        let rows = [completed("  Walk   dog ", at: date(1)), completed("walk dog", at: date(2)),
                    completed("WALK DOG", at: date(3)), completed("Take medicine", at: date(1)),
                    completed("Take medicine", at: date(2)), completed("Take medicine", at: date(3))]
        let learned = RoutineLearningService.learn(todos: rows, now: date(4, hour: 8), calendar: calendar)
        #expect(learned.map(\.activityKey) == ["take medicine", "walk dog"])
        let walk = try #require(learned.last)
        #expect(walk.sampleCount == 3)
        #expect(walk.distinctCompletionDays == 3)
        #expect(walk.recordedCompletionHours == [10, 10, 10])
        #expect(walk.periodDays == 1)
        #expect(walk.nextOccurrence == date(4))
        #expect(walk.dayPeriod == .morning)
        #expect(walk.confidence >= RoutineLearningService.minimumPredictionConfidence)
        #expect(walk.confidence <= 0.95)
        #expect(!walk.isConfirmed)
    }

    @Test("Repeated same-day samples never meet the distinct-day minimum")
    func distinctDaysRequired() {
        let rows = (0..<10).map { completed("Read", at: date(1, hour: $0)) }
        #expect(RoutineLearningService.learn(todos: rows, now: date(4), calendar: calendar).isEmpty)
        let twoDays = rows + [completed("Read", at: date(2))]
        #expect(RoutineLearningService.learn(todos: twoDays, now: date(4), calendar: calendar).isEmpty)
    }

    @Test("Only consent-source live manual completed task rows provide evidence")
    func excludedRows() {
        let valid = [completed("Read", at: date(1)), completed("Read", at: date(2))]
        let email = completed("Read", at: date(3), source: .email)
        let meeting = completed("Read", at: date(3), source: .meeting)
        let imported = completed("Read", at: date(3), source: .calendar)
        let review = completed("Read", at: date(3)); review.triageStatus = "review"
        let fixed = completed("Read", at: date(3)); fixed.isFixedSchedule = true
        let external = completed("Read", at: date(3)); external.calendarEventOrigin = "externalCalendar"
        let future = completed("Read", at: date(9))
        let missing = completed("Read", at: date(3)); missing.completedAt = nil
        let active = completed("Read", at: date(3)); active.isCompleted = false
        let impossible = completed("Read", at: date(3)); impossible.createdAt = date(4)
        let old = completed("Read", at: date(1).addingTimeInterval(-100 * 86400))
        let unknown = completed("Read", at: date(3)); unknown.source = "unknown"
        let restoredEmail = completed("Read", at: date(3)); restoredEmail.sourceMessageID = "private-message"
        let restoredMeeting = completed("Read", at: date(3)); restoredMeeting.sourceRef = "meeting:private:action:1"
        let calendarEmail = completed("Read", at: date(3)); calendarEmail.calendarEventOrigin = "siftEmail"
        let calendarMeeting = completed("Read", at: date(3)); calendarMeeting.calendarEventOrigin = "siftMeeting"
        let health = completed("Read", at: date(3)); health.sourceRef = "health:workout:occurrence"
        let rows = valid + [email, meeting, imported, review, fixed, external, future, missing, active, impossible, old, unknown, restoredEmail, restoredMeeting, calendarEmail, calendarMeeting, health]
        #expect(RoutineLearningService.learn(todos: rows, now: date(4), calendar: calendar).isEmpty)
    }

    @Test("Weekly intervals predict the next local occurrence; irregular histories have low confidence")
    func intervalConfidence() throws {
        let weekly = [1, 8, 15, 22].map { completed("Water plants", at: date($0, hour: 18)) }
        let stable = try #require(RoutineLearningService.learn(todos: weekly, now: date(23), calendar: calendar).first)
        #expect(stable.periodDays == 7)
        #expect(stable.nextOccurrence == date(29, hour: 18))
        #expect(stable.dayPeriod == .evening)
        let irregular = [1, 2, 16].map { completed("Read", at: date($0)) }
        let candidate = try #require(RoutineLearningService.learn(todos: irregular, now: date(17), calendar: calendar).first)
        #expect(candidate.confidence < RoutineLearningService.minimumPredictionConfidence)
    }

    @Test("Circular checkoff time inference does not turn midnight activity into noon")
    func midnightTimes() throws {
        let rows = [completed("Journal", at: date(1, hour: 23, minute: 50)),
                    completed("Journal", at: date(2, hour: 0, minute: 10)),
                    completed("Journal", at: date(3, hour: 0, minute: 20))]
        let routine = try #require(RoutineLearningService.learn(todos: rows, now: date(3, hour: 20), calendar: calendar).first)
        #expect(routine.preferredHour == 0)
        #expect(routine.preferredMinute == 10)
        #expect(routine.dayPeriod == .night)
    }

    @Test("Daily prediction crosses the DST spring gap with calendar-local day arithmetic")
    func daylightSavingPrediction() throws {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func march(_ day: Int, _ hour: Int) -> Date {
            local.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: 30))!
        }
        let rows = [5, 6, 7].map { completed("Stretch", at: march($0, 2)) }
        let routine = try #require(RoutineLearningService.learn(todos: rows, now: march(7, 20), calendar: local).first)
        #expect(local.component(.day, from: routine.nextOccurrence) == 8)
        #expect(local.component(.hour, from: routine.nextOccurrence) == 3)
        #expect(routine.timeZoneIdentifier == "America/Los_Angeles")
        #expect(routine.preferredHour == 2)
    }
}
