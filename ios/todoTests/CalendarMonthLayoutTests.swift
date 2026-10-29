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

    @Test("a linked multi-day event remains visible in every occupied week")
    func linkedMultiDayEventKeepsContinuations() {
        let calendar = calendar()
        let start = date(2026, 10, 8, hour: 9, calendar: calendar)
        let end = date(2026, 10, 16, hour: 10, calendar: calendar)
        let event = event("reservation", start: start, end: end)
        let todo = CalendarMonthTodo(title: "Reservation task", date: start, eventID: event.identifier)
        let weeks = CalendarMonthGeometry(month: start, calendar: calendar).weeks
            .map { CalendarMonthWeekLayout(days: $0, events: [event], todos: [todo], calendar: calendar) }
        for week in weeks {
            for column in week.days.indices {
                let occupies = CalendarMonthGeometry.occupies(event, day: week.days[column], calendar: calendar)
                let spans = week.spans.filter { $0.firstColumn <= column && $0.lastColumn >= column }
                #expect(spans.count == (occupies ? 1 : 0))
                #expect(week.items[column].isEmpty)
            }
        }
    }

    @Test("continuous boundary weeks do not repeat days across a month or DST change")
    func continuousWeekBoundary() {
        for firstWeekday in [1, 2, 7] {
            let calendar = calendar(firstWeekday: firstWeekday)
            let start = CalendarMonthGeometry.weekStart(containing: date(2026, 10, 31, calendar: calendar), calendar: calendar)
            let next = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
            #expect(calendar.component(.weekday, from: start) == firstWeekday)
            for offset in 0..<7 {
                let day = calendar.date(byAdding: .day, value: offset, to: start)!
                #expect(CalendarMonthGeometry.weekStart(containing: day, calendar: calendar) == start)
            }
            #expect(calendar.date(byAdding: .day, value: 7, to: start) == next)
            #expect(CalendarMonthGeometry.weekStart(containing: next, calendar: calendar) == next)
        }
    }

    @Test("continuous window indices round-trip through years and both DST transitions")
    func continuousWindowDateIdentity() {
        for firstWeekday in [1, 2, 7] {
            let calendar = calendar(firstWeekday: firstWeekday)
            let anchor = date(2026, 12, 31, hour: 14, calendar: calendar)
            let window = CalendarWeekWindow(centeredOn: anchor, calendar: calendar)
            #expect(window.index(containing: anchor) == CalendarWeekWindow.center)
            #expect(Set(window.starts).count == CalendarWeekWindow.count)
            for index in window.starts.indices {
                let days = window.days(at: index)
                #expect(days.count == 7)
                #expect(calendar.component(.weekday, from: days[0]) == firstWeekday)
                for day in days {
                    #expect(window.index(containing: day) == index)
                    #expect(day == calendar.startOfDay(for: day))
                }
                let next = calendar.date(byAdding: .day, value: 7, to: days[0])!
                #expect(next == (index + 1 < window.starts.count ? window.starts[index + 1] : window.end))
            }
        }
    }

    @Test("mixed-month weeks keep the leading date's month until it scrolls away")
    func leadingDateOwnsVisibleMonth() {
        let calendar = calendar()
        let october = date(2026, 10, 1, calendar: calendar)
        let november = date(2026, 11, 1, calendar: calendar)
        let window = CalendarWeekWindow(centeredOn: october, calendar: calendar)
        #expect(window.months[window.index(containing: date(2026, 10, 31, calendar: calendar))] == october)
        #expect(window.months[window.index(containing: november)] == november)
        #expect(window.months[window.index(containing: date(2026, 11, 30, calendar: calendar))] == november)
    }

    @Test("moving events and tasks refreshes old and new weeks without losing other occurrences")
    func weekContentChangesFollowOccurrences() {
        let calendar = calendar()
        let first = date(2026, 10, 5, hour: 9, calendar: calendar)
        let second = date(2026, 10, 12, hour: 9, calendar: calendar)
        let third = date(2026, 10, 19, hour: 9, calendar: calendar)
        let window = CalendarWeekWindow(centeredOn: first, calendar: calendar)
        let recurring = event("series", start: third, end: third.addingTimeInterval(3600))
        let before = CalendarWeekContentIndex(window: window,
            events: [event("moved", start: first, end: first.addingTimeInterval(3600)), recurring],
            todos: [CalendarMonthTodo(title: "Task", date: first, eventID: nil)])
        let after = CalendarWeekContentIndex(window: window,
            events: [event("moved", start: second, end: second.addingTimeInterval(3600)), recurring],
            todos: [CalendarMonthTodo(title: "Task", date: second, eventID: nil)])
        let oldIndex = window.index(containing: first), newIndex = window.index(containing: second)
        #expect(after.changedWeeks(from: before) == [oldIndex, newIndex])
        let oldWeek = CalendarMonthWeekLayout(days: window.days(at: oldIndex),
            events: after.events[oldIndex], todos: after.todos[oldIndex], calendar: calendar)
        #expect(oldWeek.items.allSatisfy { $0.isEmpty })
        let newWeek = CalendarMonthWeekLayout(days: window.days(at: newIndex),
            events: after.events[newIndex], todos: after.todos[newIndex], calendar: calendar)
        #expect(Set(newWeek.items.flatMap { $0 }.map(\.title)) == ["moved", "Task"])
        #expect(after.events[window.index(containing: third)].map(\.identifier) == ["series"])
        let removed = CalendarWeekContentIndex(window: window, events: [recurring], todos: [])
        #expect(removed.changedWeeks(from: after) == [newIndex])
    }

    @Test("calendar header ignores clipped boundary rows after resize")
    func stableHeaderAtFractionalWeekBoundary() {
        let rowHeight: CGFloat = 971.5 / 6
        let boundary = CGFloat(CalendarWeekWindow.center) * rowHeight
        #expect(CalendarWeekWindow.headerIndex(offset: boundary.nextDown, rowHeight: rowHeight) == CalendarWeekWindow.center)
        #expect(CalendarWeekWindow.headerIndex(offset: boundary - rowHeight * 0.49, rowHeight: rowHeight) == CalendarWeekWindow.center)
        #expect(CalendarWeekWindow.headerIndex(offset: boundary - rowHeight * 0.51, rowHeight: rowHeight) == CalendarWeekWindow.center - 1)
        #expect(CalendarWeekWindow.headerIndex(offset: boundary + rowHeight, rowHeight: rowHeight) == CalendarWeekWindow.center + 1)
        #expect(CalendarWeekWindow.headerIndex(offset: -rowHeight, rowHeight: rowHeight) == 0)
    }

    @Test("rebasing preserves visible week dates")
    func continuousWindowRebase() {
        let calendar = calendar(firstWeekday: 2)
        let window = CalendarWeekWindow(centeredOn: date(2026, 11, 1, calendar: calendar), calendar: calendar)
        for index in [10, 510] {
            let rebased = CalendarWeekWindow(centeredOn: window.starts[index], calendar: calendar)
            #expect(rebased.days(at: CalendarWeekWindow.center) == window.days(at: index))
            #expect(rebased.days(at: CalendarWeekWindow.center + 1) == window.days(at: index + 1))
        }
    }

    @Test("week lookup honors exclusive ends and clips spanning events to its window")
    func continuousWindowEventCoverage() {
        let calendar = calendar()
        let start = date(2026, 10, 31, hour: 23, calendar: calendar)
        let boundary = date(2026, 11, 1, calendar: calendar)
        let window = CalendarWeekWindow(centeredOn: start, calendar: calendar)
        let first = window.index(containing: start)
        #expect(Array(window.occupiedWeekIndices(from: start, to: boundary)) == [first])
        let afterDST = date(2026, 11, 2, calendar: calendar)
        #expect(Array(window.occupiedWeekIndices(from: start, to: afterDST)) == [first, first + 1])
        #expect(Array(window.occupiedWeekIndices(from: start, to: start)) == [first])
        #expect(window.occupiedWeekIndices(from: boundary, to: boundary).isEmpty)
        let midweekMidnight = date(2026, 11, 3, calendar: calendar)
        #expect(window.occupiedWeekIndices(from: midweekMidnight, to: midweekMidnight).isEmpty)
        let instant = event("instant", start: start, end: start)
        #expect(CalendarMonthGeometry.occupies(instant, day: start, calendar: calendar))
        #expect(window.occupiedWeekIndices(from: window.end, to: calendar.date(byAdding: .day, value: 1, to: window.end)!).isEmpty)
        let before = calendar.date(byAdding: .day, value: -1, to: window.starts[0])!
        let after = calendar.date(byAdding: .day, value: 1, to: window.end)!
        #expect(window.occupiedWeekIndices(from: before, to: after) == 0..<CalendarWeekWindow.count)
    }
}
