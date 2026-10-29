import Foundation
import Testing
@testable import todo

@Suite("Embedded calendar schedules")
@MainActor
struct CalendarDayScheduleTests {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return result
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func event(_ id: String, start: Date, end: Date, allDay: Bool = false) -> CalendarService.CalendarEventSummary {
        .init(title: id, startDate: start, endDate: end, isRecurring: false, isAllDay: allDay,
              identifier: id, calendarTitle: "Synthetic", calendarID: "synthetic")
    }

    @Test("Civil-day clipping honors DST and an exclusive midnight end")
    func civilDayClipping() {
        for (month, day, hours) in [(3, 8, 23.0), (11, 1, 25.0)] {
            let start = date(month, day)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let event = event("civil-day", start: start, end: end)
            let schedule = CalendarScheduleDay(date: start, events: [event], todos: [], calendar: calendar)
            #expect(schedule.end.timeIntervalSince(schedule.date) == hours * 3_600)
            #expect(schedule.allDayItems.count == 1)
            #expect(schedule.items.first?.clippedStart == start)
            #expect(schedule.items.first?.clippedEnd == end)
            #expect(schedule.minuteOffset(end, calendar: calendar) == 1_440)
            #expect(CalendarScheduleDay(date: end, events: [event], todos: [], calendar: calendar).items.isEmpty)
            let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: start)!
            #expect(schedule.minuteOffset(nine, calendar: calendar) == 540)
        }
    }

    @Test("Overnight tasks and events clip on each day without leaking beyond their end")
    func overnightClipping() {
        let start = date(10, 28, 23)
        let end = date(10, 29, 1)
        let event = event("overnight", start: start, end: end)
        let todo = Todo(title: "Overnight task", startDate: start, dueDate: end)
        let first = CalendarScheduleDay(date: start, events: [event], todos: [todo], calendar: calendar)
        let second = CalendarScheduleDay(date: end, events: [event], todos: [todo], calendar: calendar)
        #expect(first.timedItems.count == 2)
        #expect(second.timedItems.count == 2)
        #expect(first.items.allSatisfy { $0.clippedEnd == date(10, 29) })
        #expect(second.items.allSatisfy { $0.clippedStart == date(10, 29) && $0.clippedEnd == end })
        #expect(CalendarScheduleDay(date: date(10, 30), events: [event], todos: [todo], calendar: calendar).items.isEmpty)
    }

    @Test("Due-only tasks remain on their anchor date and completed tasks are excluded")
    func pointTasks() {
        let todo = Todo(title: "Late task", dueDate: date(10, 28, 23, 50))
        let completed = Todo(title: "Complete", dueDate: date(10, 28, 12))
        completed.isCompleted = true
        let first = CalendarScheduleDay(date: date(10, 28), events: [], todos: [todo, completed], calendar: calendar)
        #expect(first.items.count == 1)
        #expect(first.items.first?.clippedEnd == date(10, 29))
        #expect(CalendarScheduleDay(date: date(10, 29), events: [], todos: [todo], calendar: calendar).items.isEmpty)
    }

    @Test("Deduplication targets an occurrence rather than every event sharing its identifier")
    func linkedOccurrences() {
        let first = event("series", start: date(10, 28, 9), end: date(10, 28, 10))
        let second = event("series", start: date(10, 29, 9), end: date(10, 29, 10))
        let todo = Todo(title: "Linked occurrence", startDate: first.startDate, dueDate: first.endDate)
        todo.calendarEventID = "series"
        let day = CalendarScheduleDay(date: first.startDate, events: [first, second], todos: [todo], calendar: calendar)
        #expect(day.items.count == 1)
        #expect(day.items.first?.linkedEvent?.startDate == first.startDate)
        if case .todo? = day.items.first?.source {} else { Issue.record("Expected the linked task representation") }
        let following = CalendarScheduleDay(date: second.startDate, events: [first, second], todos: [todo], calendar: calendar)
        #expect(following.items.count == 1)
        if case .event? = following.items.first?.source {} else { Issue.record("Expected the next real recurrence") }
    }

    @Test("A multi-day linked reservation has one representation and keeps the task reachable")
    func linkedMultiDay() {
        let reservation = event("reservation", start: date(10, 28), end: date(10, 31), allDay: true)
        let todo = Todo(title: "Reservation task", startDate: reservation.startDate, dueDate: reservation.endDate)
        todo.calendarEventID = reservation.identifier
        for day in 28...30 {
            let schedule = CalendarScheduleDay(date: date(10, day), events: [reservation], todos: [todo], calendar: calendar)
            #expect(schedule.items.count == 1)
            #expect(schedule.allDayItems.count == 1)
            #expect(schedule.items.first?.linkedTodo?.id == todo.id)
        }
        #expect(CalendarScheduleDay(date: date(10, 31), events: [reservation], todos: [todo], calendar: calendar).items.isEmpty)
    }

    @Test("Overlap columns account for clipped minimum-height blocks and separate clusters")
    func overlapColumns() {
        let events = [
            event("short", start: date(10, 28, 9), end: date(10, 28, 9, 5)),
            event("close", start: date(10, 28, 9, 10), end: date(10, 28, 10)),
            event("later", start: date(10, 28, 12), end: date(10, 28, 13))
        ]
        let schedule = CalendarScheduleDay(date: date(10, 28), events: events, todos: [], calendar: calendar)
        let columns = CalendarScheduleColumn.layout(schedule.timedItems)
        #expect(columns[0].columnCount == 2)
        #expect(columns[1].columnCount == 2)
        #expect(columns[0].column != columns[1].column)
        #expect(columns[2].columnCount == 1)
        #expect(columns[2].column == 0)
    }

    @Test("Repeated fall-back hour stays positive and uses nonoverlapping visual columns")
    func repeatedHour() {
        let dayStart = date(11, 1)
        let firstOneThirty = dayStart.addingTimeInterval(90 * 60)
        let repeatedOneFifteen = dayStart.addingTimeInterval(135 * 60)
        let events = [
            event("across-fold", start: firstOneThirty, end: firstOneThirty.addingTimeInterval(45 * 60)),
            event("after-fold", start: repeatedOneFifteen, end: repeatedOneFifteen.addingTimeInterval(60 * 60))
        ]
        let schedule = CalendarScheduleDay(date: dayStart, events: events, todos: [], calendar: calendar)
        #expect(schedule.items.allSatisfy { $0.displayEndMinute > $0.displayStartMinute })
        #expect(CalendarScheduleColumn.layout(schedule.timedItems).allSatisfy { $0.columnCount == 2 })
    }

    @Test("A midnight DST gap does not include the following day's early event")
    func midnightDSTGap() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Havana")!
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 30))!
        let event = event("Monday", start: monday, end: monday.addingTimeInterval(1800))
        let previous = CalendarScheduleDay(date: sunday, events: [event], todos: [], calendar: calendar)
        #expect(previous.end == calendar.startOfDay(for: monday))
        #expect(previous.items.isEmpty)
        let next = CalendarScheduleDay(date: monday, events: [event], todos: [], calendar: calendar)
        #expect(next.items.first?.clippedStart == monday)
        #expect(next.items.first?.displayStartMinute == 30)
    }

    @Test("A short midnight event keeps a full clickable body and separate edges without changing its real times")
    func midnightMinimumBody() throws {
        let original = event("midnight-short", start: date(10, 30, 23, 55), end: date(10, 31))
        let day = CalendarScheduleDay(date: original.startDate, events: [original], todos: [], calendar: calendar)
        let item = try #require(day.timedItems.first)
        #expect(item.start == original.startDate && item.end == original.endDate)
        #expect(item.displayEndMinute <= 1440)
        #expect(item.displayEndMinute - item.displayStartMinute >= 28.125)
        #expect(item.displayStartMinute >= 0)
    }
}
