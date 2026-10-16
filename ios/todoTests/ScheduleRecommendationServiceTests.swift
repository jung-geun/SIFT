import Foundation
import Testing
@testable import todo

@Suite("Bounded local collision-aware scheduling")
@MainActor
struct ScheduleRecommendationServiceTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ day: Int = 4, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute))!
    }
    private func event(_ start: Date, _ end: Date, id: String = UUID().uuidString,
                       allDay: Bool = false, external: String = "", marker: CalendarEventMarker? = nil) -> CalendarService.CalendarEventSummary {
        CalendarService.CalendarEventSummary(title: "Busy", startDate: start, endDate: end,
                                             isRecurring: false, isAllDay: allDay, identifier: id,
                                             externalIdentifier: external, marker: marker,
                                             calendarTitle: "Test", calendarID: "test")
    }

    @Test("Conflicting preferred time uses a valid alternate before the hard deadline")
    func conflictAlternate() throws {
        let task = Todo(title: "Read", dueDate: date(4, 12))
        task.estimatedDurationMinutes = 30
        let reserved = Todo(title: "Other task", startDate: date(4, 9), dueDate: date(4, 10))
        let busy = event(date(4, 10), date(4, 11))
        let result = try #require(ScheduleRecommendationService.recommend(todo: task, todos: [task, reserved],
                                 events: [busy], preferredStart: date(4, 10), now: date(4, 9), calendar: calendar))
        #expect(result.start == date(4, 11))
        #expect(result.end == date(4, 11, 30))
        #expect(result.end <= task.dueDate!)
        #expect(task.startDate == nil && task.dueDate == date(4, 12)) // Recommendation is read-only.
    }

    @Test("Search projects onto the closest feasible gap, including an earlier alternative")
    func nearestGapAndDeadline() throws {
        let task = Todo(title: "Read", dueDate: date(4, 12))
        let busy = event(date(4, 10), date(4, 11))
        let result = try #require(ScheduleRecommendationService.recommend(todo: task, todos: [], events: [busy],
                                 preferredStart: date(4, 10), now: date(4, 9), calendar: calendar))
        #expect(result.start == date(4, 9, 30))
        #expect(result.end == date(4, 10)) // Touching an event boundary is not an overlap.
        let afterDeadline = try #require(ScheduleRecommendationService.recommend(todo: task, todos: [], events: [],
                                        preferredStart: date(4, 16), now: date(4, 9), calendar: calendar))
        #expect(afterDeadline.start == date(4, 11, 30) && afterDeadline.end == date(4, 12))
    }

    @Test("No-slot, expired and insufficient deadline windows return nil instead of scheduling late")
    func noFeasibleSlot() {
        let task = Todo(title: "Read", dueDate: date(4, 12))
        #expect(ScheduleRecommendationService.recommend(todo: task, todos: [],
                events: [event(date(4, 9), date(4, 12))], preferredStart: date(4, 10), now: date(4, 9), calendar: calendar) == nil)
        task.dueDate = date(4, 9, 15)
        #expect(ScheduleRecommendationService.recommend(todo: task, todos: [], events: [], preferredStart: nil,
                now: date(4, 9), calendar: calendar) == nil)
        task.dueDate = date(4, 8)
        #expect(ScheduleRecommendationService.recommend(todo: task, todos: [], events: [], preferredStart: nil,
                now: date(4, 9), calendar: calendar) == nil)
    }

    @Test("All-day intervals and overlapping task/event reservations are merged before searching")
    func allDayAndOverlappingReservations() throws {
        let task = Todo(title: "Read")
        let reserved = Todo(title: "Long meeting", startDate: date(5, 9), dueDate: date(5, 11))
        let result = try #require(ScheduleRecommendationService.recommend(todo: task, todos: [reserved], events: [
            event(date(4, 0), date(5, 0), allDay: true), event(date(5, 10), date(5, 12)), event(date(5, 11), date(5, 13))
        ], preferredStart: date(4, 10), now: date(4, 9), calendar: calendar))
        #expect(result.start == date(5, 13))
    }

    @Test("Stable self identities exclude old reservations but unrelated same-title events still block")
    func selfExclusion() throws {
        let task = Todo(title: "Busy", startDate: date(4, 9), dueDate: date(4, 12))
        task.calendarEventID = "own"
        task.calendarEventExternalID = "external-own"
        let marker = CalendarEventMarker(entity: .todo, identifier: task.id, origin: .siftManual)
        let selfEvents = [event(date(4, 9), date(4, 12), id: "own"),
                          event(date(4, 9), date(4, 12), external: "external-own"),
                          event(date(4, 9), date(4, 12), marker: marker)]
        let result = try #require(ScheduleRecommendationService.recommend(todo: task, todos: [task],
                                 events: selfEvents + [event(date(4, 9), date(4, 10))], preferredStart: date(4, 9),
                                 now: date(4, 9), calendar: calendar))
        #expect(result.start == date(4, 10))
    }

    @Test("Imported, fixed, completed and review tasks cannot be rescheduled")
    func immutableTargets() {
        let imported = Todo(title: "Imported", startDate: date(4, 10), dueDate: date(4, 11), source: .calendar)
        let fixed = Todo(title: "Fixed"); fixed.isFixedSchedule = true
        let completed = Todo(title: "Done"); completed.isCompleted = true
        let review = Todo(title: "Review"); review.triageStatus = "review"
        let external = Todo(title: "External"); external.calendarEventOrigin = "externalCalendar"
        for task in [imported, fixed, completed, review, external] {
            #expect(ScheduleRecommendationService.recommend(todo: task, todos: [], events: [], preferredStart: date(4, 9),
                    now: date(4, 8), calendar: calendar) == nil)
        }
        #expect(imported.startDate == date(4, 10) && imported.dueDate == date(4, 11))
    }

    @Test("Invalid durations and availability fail safely; deadline-only tasks are not false reservations")
    func durationAndAvailability() throws {
        let task = Todo(title: "Read", dueDate: date(4, 12))
        task.estimatedDurationMinutes = 0
        #expect(ScheduleRecommendationService.recommend(todo: task, todos: [], events: [], preferredStart: nil,
                now: date(4, 9), calendar: calendar) == nil)
        task.estimatedDurationMinutes = 30
        #expect(ScheduleRecommendationService.recommend(todo: task, todos: [], events: [], preferredStart: nil,
                now: date(4, 9), calendar: calendar, availabilityStartHour: 22, availabilityEndHour: 9) == nil)
        let deadlineOnly = Todo(title: "Deadline only", dueDate: date(4, 10))
        let completed = Todo(title: "Done", startDate: date(4, 9), dueDate: date(4, 12)); completed.isCompleted = true
        let result = try #require(ScheduleRecommendationService.recommend(todo: task, todos: [deadlineOnly, completed],
                                 events: [], preferredStart: nil, now: date(4, 9), calendar: calendar))
        #expect(result.start == date(4, 9))
    }

    @Test("Calendar timezone controls availability rather than UTC hours")
    func localAvailability() throws {
        var local = calendar; local.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = local.date(from: DateComponents(year: 2026, month: 1, day: 4, hour: 23))!
        let task = Todo(title: "Read")
        let result = try #require(ScheduleRecommendationService.recommend(todo: task, todos: [], events: [],
                                 preferredStart: now, now: now, calendar: local, availabilityStartHour: 9, availabilityEndHour: 22))
        #expect(local.component(.day, from: result.start) == 5)
        #expect(local.component(.hour, from: result.start) == 9)
        #expect(result.start >= now)
    }

    @Test("DST gaps and folds retain actual duration within calendar-local availability")
    func daylightSavingSlots() throws {
        var local = calendar; local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (month, day) in [(3, 8), (11, 1)] {
            let midnight = local.date(from: DateComponents(year: 2026, month: month, day: day))!
            let opening = try #require(RoutineLearningService.localTime(on: midnight, hour: 1, minute: 0, calendar: local))
            let closing = try #require(RoutineLearningService.localTime(on: midnight, hour: 4, minute: 0, calendar: local))
            let task = Todo(title: "Read", dueDate: closing); task.estimatedDurationMinutes = 120
            let result = try #require(ScheduleRecommendationService.recommend(todo: task, todos: [], events: [],
                                     preferredStart: opening, now: midnight, calendar: local,
                                     availabilityStartHour: 1, availabilityEndHour: 4))
            #expect(result.start == opening)
            #expect(result.end.timeIntervalSince(result.start) == 7200)
            #expect(result.end <= closing)
        }
    }

    @Test("Search never escapes its fourteen calendar-day bound")
    func boundedSearch() {
        let now = date(4, 0)
        let task = Todo(title: "Read")
        let end = calendar.date(byAdding: .day, value: 14, to: now)!
        #expect(ScheduleRecommendationService.recommend(todo: task, todos: [], events: [event(now, end, allDay: true)],
                preferredStart: end, now: now, calendar: calendar) == nil)
    }
}
