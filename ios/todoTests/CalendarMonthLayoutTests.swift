import Foundation
import Testing
@testable import todo

@Suite("Visible calendar month behavior")
@MainActor
struct CalendarMonthLayoutTests {
    private func calendar(firstWeekday: Int = 1) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func event(_ id: String, start: Date, end: Date, allDay: Bool = false) -> CalendarService.CalendarEventSummary {
        CalendarService.CalendarEventSummary(title: id, startDate: start, endDate: end,
                                            isRecurring: false, isAllDay: allDay,
                                            identifier: id, calendarTitle: "Work", calendarID: "work")
    }

    @Test("load interval contains every adjacent-month cell and honors first weekday")
    func visibleRangeMatchesGrid() {
        for firstWeekday in [1, 2, 7] {
            let calendar = calendar(firstWeekday: firstWeekday)
            let october = date(2026, 10, 19, hour: 14, calendar: calendar)
            let grid = CalendarMonthGeometry(month: october, calendar: calendar)
            #expect(grid.weeks.count == 6)
            #expect(grid.days.count == 42)
            #expect(calendar.component(.weekday, from: grid.days[0]) == firstWeekday)
            #expect(calendar.component(.day, from: grid.month) == 1)
            #expect(grid.days.allSatisfy { $0 >= grid.interval.start && $0 < grid.interval.end })
            #expect(calendar.date(byAdding: .day, value: 1, to: grid.days[41]) == grid.interval.end)
        }
    }

    @Test("DST all-day events occupy local dates, never the exclusive end date")
    func daylightSavingEndExclusive() {
        let calendar = calendar()
        for (month, startDay, endDay) in [(3, 8, 10), (11, 1, 3)] {
            let start = date(2026, month, startDay, calendar: calendar)
            let end = date(2026, month, endDay, calendar: calendar)
            let event = event("DST", start: start, end: end, allDay: true)
            #expect(CalendarMonthGeometry.occupies(event, day: start, calendar: calendar))
            #expect(CalendarMonthGeometry.occupies(event, day: calendar.date(byAdding: .day, value: 1, to: start)!, calendar: calendar))
            #expect(!CalendarMonthGeometry.occupies(event, day: end, calendar: calendar))
        }
    }

    @Test("short overnight events span both occupied days while midnight endings do not leak")
    func overnightSpan() {
        let calendar = calendar()
        let grid = CalendarMonthGeometry(month: date(2026, 10, 1, calendar: calendar), calendar: calendar)
        let overnight = event("overnight", start: date(2026, 10, 5, hour: 23, calendar: calendar),
                              end: date(2026, 10, 6, hour: 1, calendar: calendar))
        let midnight = event("midnight", start: date(2026, 10, 5, hour: 22, calendar: calendar),
                             end: date(2026, 10, 6, calendar: calendar))
        let days = grid.weeks[1]
        let week = CalendarMonthWeekLayout(days: days, events: [overnight, midnight], todos: [], calendar: calendar)
        #expect(week.spans.count == 1)
        #expect(week.spans[0].event.identifier == "overnight")
        #expect(week.spans[0].lastColumn - week.spans[0].firstColumn == 1)
        let tuesday = days.firstIndex { calendar.component(.day, from: $0) == 6 }!
        #expect(week.items[tuesday].isEmpty)
    }

    @Test("overlapping spans keep separate lanes and overflow counts every hidden occurrence")
    func spanLanesAndOverflow() {
        let calendar = calendar()
        let days = CalendarMonthGeometry(month: date(2026, 10, 1, calendar: calendar), calendar: calendar).weeks[1]
        let start = date(2026, 10, 5, calendar: calendar)
        let end = date(2026, 10, 7, calendar: calendar)
        let events = (0..<4).map { event("span-\($0)", start: start, end: end, allDay: true) }
        let week = CalendarMonthWeekLayout(days: days, events: events, todos: [], calendar: calendar)
        let column = days.firstIndex { calendar.isDate($0, inSameDayAs: start) }!
        #expect(Set(week.spans.map(\.lane)).count == 4)
        #expect(week.availableLanes(column: column, capacity: 3).isEmpty)
        #expect(week.overflow(column: column, capacity: 3) == 1)
        #expect(week.overflow(column: column, capacity: 5) == 0)
    }

    @Test("recurrence occurrences sharing an identifier render independently")
    func recurrenceOccurrencesRemainDistinct() {
        let calendar = calendar()
        let days = CalendarMonthGeometry(month: date(2026, 10, 1, calendar: calendar), calendar: calendar).weeks[1]
        let events = [5, 6].map { day in
            event("same-series", start: date(2026, 10, day, hour: 9, calendar: calendar),
                  end: date(2026, 10, day, hour: 10, calendar: calendar))
        }
        let week = CalendarMonthWeekLayout(days: days, events: events, todos: [], calendar: calendar)
        #expect(week.items.flatMap { $0 }.count == 2)
        #expect(week.items.filter { !$0.isEmpty }.count == 2)
        let linkedTodo = CalendarMonthTodo(title: "First occurrence", date: events[0].startDate, eventID: "same-series")
        let withLinkedOccurrence = CalendarMonthWeekLayout(days: days, events: events, todos: [linkedTodo], calendar: calendar)
        let rendered = withLinkedOccurrence.items.flatMap { $0 }
        #expect(rendered.count == 2)
        let renderedEvents = rendered.filter { if case .event = $0 { return true }; return false }
        #expect(renderedEvents.count == 1)
    }

    @Test("a displayed linked todo replaces its event without a duplicate chip")
    func displayedTodoDeduplication() {
        let calendar = calendar()
        let days = CalendarMonthGeometry(month: date(2026, 10, 1, calendar: calendar), calendar: calendar).weeks[1]
        let start = date(2026, 10, 5, hour: 9, calendar: calendar)
        let event = event("linked", start: start, end: date(2026, 10, 5, hour: 10, calendar: calendar))
        let visible = CalendarMonthTodo(title: "Todo", date: start, eventID: "linked")
        let withoutTodo = CalendarMonthWeekLayout(days: days, events: [event], todos: [], calendar: calendar)
        let withTodo = CalendarMonthWeekLayout(days: days, events: [event], todos: [visible], calendar: calendar)
        #expect(withoutTodo.items.flatMap { $0 }.count == 1)
        #expect(withTodo.items.flatMap { $0 }.count == 1)
        if case .todo = withTodo.items.flatMap({ $0 })[0] {} else { Issue.record("Linked event should be represented by its displayed todo") }
    }
}
