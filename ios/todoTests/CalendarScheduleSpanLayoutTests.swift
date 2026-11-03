import Foundation
import Testing
@testable import todo

@Suite("Continuous calendar schedule spans")
@MainActor
struct CalendarScheduleSpanLayoutTests {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return result
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func event(_ id: String, start: Date, end: Date, allDay: Bool = true,
                       calendarID: String = "synthetic", recurring: Bool = false) -> CalendarService.CalendarEventSummary {
        .init(title: id, startDate: start, endDate: end, isRecurring: recurring, isAllDay: allDay,
              identifier: id, calendarTitle: "Synthetic", calendarID: calendarID)
    }

    private func days(start: Date, count: Int, events: [CalendarService.CalendarEventSummary],
                      todos: [Todo] = [], calendar: Calendar? = nil) -> [CalendarScheduleDay] {
        let calendar = calendar ?? self.calendar
        let index = CalendarScheduleIndex(events: events, todos: todos)
        return (0..<count).map {
            CalendarScheduleDay(date: calendar.date(byAdding: .day, value: $0, to: start)!,
                                events: events, todos: todos, calendar: calendar, index: index)
        }
    }

    @Test("Empty and timed-only cohorts do not reserve an all-day lane")
    func emptyAndTimedDays() {
        let empty = CalendarScheduleSpanLayout(days: [])
        #expect(empty.spans.isEmpty)
        #expect(empty.laneCount == 0)
        let timed = event("overnight", start: date(10, 28, 23), end: date(10, 29, 1), allDay: false)
        let todo = Todo(title: "Overnight task", startDate: timed.startDate, dueDate: timed.endDate)
        let cohorts = days(start: date(10, 28), count: 2, events: [timed], todos: [todo])
        #expect(cohorts.allSatisfy { $0.timedItems.count == 2 })
        let layout = CalendarScheduleSpanLayout(days: cohorts)
        #expect(layout.spans.isEmpty)
        #expect(layout.laneCount == 0)
    }

    @Test("Cross-week clipping changes columns and continuation flags, not original dates or identity")
    func crossWeekClipping() throws {
        let reservation = event("cross-week", start: date(10, 25), end: date(11, 5))
        let first = CalendarScheduleSpanLayout(days: days(start: date(10, 26), count: 7, events: [reservation]))
        let firstSpan = try #require(first.spans.first)
        #expect(first.spans.count == 1)
        #expect(firstSpan.firstColumn == 0 && firstSpan.lastColumn == 6)
        #expect(firstSpan.continuesBefore && firstSpan.continuesAfter)
        #expect(firstSpan.item.start == reservation.startDate)
        #expect(firstSpan.item.end == reservation.endDate)
        let next = CalendarScheduleSpanLayout(days: days(start: date(11, 2), count: 7, events: [reservation]))
        let nextSpan = try #require(next.spans.first)
        #expect(next.spans.count == 1)
        #expect(nextSpan.id == firstSpan.id)
        #expect(nextSpan.firstColumn == 0 && nextSpan.lastColumn == 2)
        #expect(nextSpan.continuesBefore && !nextSpan.continuesAfter)
        #expect(nextSpan.item.start == reservation.startDate && nextSpan.item.end == reservation.endDate)
    }

    @Test("Midnight is an exclusive end and boundary equality is not continuation")
    func exclusiveMidnight() throws {
        let reservation = event("midnight", start: date(10, 28), end: date(10, 30))
        let cohorts = days(start: date(10, 28), count: 4, events: [reservation])
        let layout = CalendarScheduleSpanLayout(days: cohorts)
        let span = try #require(layout.spans.first)
        #expect(layout.spans.count == 1)
        #expect(span.firstColumn == 0 && span.lastColumn == 1)
        #expect(!span.continuesBefore && !span.continuesAfter)
        #expect(cohorts[2].items.isEmpty && cohorts[3].items.isEmpty)
        let exactWindow = CalendarScheduleSpanLayout(days: Array(cohorts.prefix(2)))
        #expect(exactWindow.spans.first?.continuesAfter == false)
    }

    @Test("Spring and fall DST spans use civil-day membership, not fixed 24-hour arithmetic")
    func dstCivilDays() throws {
        for (month, day, hours) in [(3, 8, 23.0), (11, 1, 25.0)] {
            let start = date(month, day)
            let previous = calendar.date(byAdding: .day, value: -1, to: start)!
            let next = calendar.date(byAdding: .day, value: 1, to: start)!
            let after = calendar.date(byAdding: .day, value: 2, to: start)!
            let reservation = event("DST", start: previous, end: after)
            let cohorts = days(start: previous, count: 4, events: [reservation])
            let layout = CalendarScheduleSpanLayout(days: cohorts)
            let span = try #require(layout.spans.first)
            #expect(cohorts[1].end.timeIntervalSince(cohorts[1].date) == hours * 3_600)
            #expect(cohorts[1].end == next)
            #expect(layout.spans.count == 1)
            #expect(span.firstColumn == 0 && span.lastColumn == 2)
            #expect(!span.continuesBefore && !span.continuesAfter)
            #expect(span.item.start == previous && span.item.end == after)
            #expect(cohorts[3].items.isEmpty)
        }
    }

    @Test("A midnight DST gap retains correct exclusive civil-day edges")
    func midnightDSTGap() throws {
        var havana = Calendar(identifier: .gregorian)
        havana.timeZone = TimeZone(identifier: "America/Havana")!
        let sundayNoon = havana.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let sundayStart = havana.startOfDay(for: sundayNoon)
        let mondayStart = havana.date(byAdding: .day, value: 1, to: sundayStart).map { havana.startOfDay(for: $0) }!
        let reservation = event("gap", start: sundayStart, end: mondayStart)
        let cohorts = days(start: sundayStart, count: 2, events: [reservation], calendar: havana)
        let span = try #require(CalendarScheduleSpanLayout(days: cohorts).spans.first)
        #expect(havana.component(.hour, from: sundayStart) == 1)
        #expect(span.firstColumn == 0 && span.lastColumn == 0)
        #expect(!span.continuesBefore && !span.continuesAfter)
        #expect(span.item.end == mondayStart)
        #expect(cohorts[1].items.isEmpty)
    }

    @Test("The same occurrence repeated in input and daily cohorts produces exactly one span")
    func repeatedOccurrence() throws {
        let reservation = event("repeated", start: date(10, 28), end: date(11, 1))
        let cohorts = days(start: date(10, 28), count: 5, events: [reservation, reservation])
        #expect(cohorts.prefix(4).allSatisfy { $0.allDayItems.count == 1 })
        let layout = CalendarScheduleSpanLayout(days: cohorts)
        let span = try #require(layout.spans.first)
        #expect(layout.spans.count == 1)
        #expect(layout.laneCount == 1)
        #expect(span.firstColumn == 0 && span.lastColumn == 3)
        #expect(span.id == cohorts[0].items.first?.id)
    }

    @Test("Overlapping spans use deterministic lanes and reuse a lane immediately after its last occupied date")
    func overlappingLaneReuse() throws {
        let events = [
            event("long", start: date(10, 26), end: date(10, 29)),
            event("short", start: date(10, 27), end: date(10, 28)),
            event("next", start: date(10, 28), end: date(10, 30)),
            event("later", start: date(10, 30), end: date(10, 31))
        ]
        let layout = CalendarScheduleSpanLayout(days: days(start: date(10, 26), count: 7, events: events))
        #expect(layout.laneCount == 2)
        let byTitle = Dictionary(uniqueKeysWithValues: layout.spans.map { ($0.item.title, $0) })
        let long = try #require(byTitle["long"])
        let short = try #require(byTitle["short"])
        let next = try #require(byTitle["next"])
        let later = try #require(byTitle["later"])
        #expect(long.lane == 0 && short.lane == 1)
        #expect(next.lane == short.lane && next.lane != long.lane)
        #expect(later.lane == 0)
        for (index, left) in layout.spans.enumerated() {
            for right in layout.spans.dropFirst(index + 1) where left.lane == right.lane {
                #expect(left.lastColumn < right.firstColumn || right.lastColumn < left.firstColumn)
            }
        }
        let reversed = CalendarScheduleSpanLayout(days: days(start: date(10, 26), count: 7, events: Array(events.reversed())))
        #expect(reversed.spans.map(\.id) == layout.spans.map(\.id))
        #expect(reversed.spans.map(\.lane) == layout.spans.map(\.lane))
    }

    @Test("Recurrences and calendar IDs remain distinct even when titles and EventKit identifiers match")
    func distinctOccurrencesAndCalendars() {
        let first = event("series", start: date(10, 28), end: date(10, 30), recurring: true)
        let second = event("series", start: date(10, 29), end: date(10, 31), recurring: true)
        let otherCalendar = event("series", start: first.startDate, end: first.endDate, calendarID: "other", recurring: true)
        let layout = CalendarScheduleSpanLayout(days: days(start: date(10, 28), count: 4,
                                                           events: [second, otherCalendar, first]))
        #expect(layout.spans.count == 3)
        #expect(Set(layout.spans.map(\.id)).count == 3)
        #expect(layout.laneCount == 3)
        #expect(layout.spans.filter { $0.item.event?.startDate == first.startDate }.count == 2)
        #expect(Set(layout.spans.compactMap { $0.item.event?.calendarID }) == ["synthetic", "other"])
    }

    @Test("Single-day all-day entries stay separate and a linked single-day task keeps its own identity")
    func singleDayIdentities() throws {
        let first = event("first", start: date(10, 28), end: date(10, 29))
        let second = event("second", start: first.startDate, end: first.endDate)
        let linked = event("linked", start: first.startDate, end: first.endDate)
        let todo = Todo(title: "Linked single day", startDate: linked.startDate, dueDate: linked.endDate)
        todo.calendarEventID = linked.identifier
        let layout = CalendarScheduleSpanLayout(days: days(start: first.startDate, count: 2,
                                                           events: [first, second, linked], todos: [todo]))
        #expect(layout.spans.count == 3)
        #expect(Set(layout.spans.map(\.id)).count == 3)
        #expect(layout.spans.allSatisfy { $0.firstColumn == 0 && $0.lastColumn == 0 })
        let linkedSpan = try #require(layout.spans.first { $0.item.linkedEvent != nil })
        #expect(linkedSpan.id == "todo-\(todo.id.uuidString)")
        #expect(linkedSpan.item.linkedEvent?.identifier == linked.identifier)
        if case .todo(let retained) = linkedSpan.item.source {
            #expect(retained === todo)
        } else {
            Issue.record("Expected the real linked task representation")
        }
    }

    @Test("A linked multi-day reservation retains one event span and the original linked-task control")
    func linkedMultiDayRepresentation() throws {
        let reservation = event("reservation", start: date(10, 28), end: date(11, 2))
        let todo = Todo(title: "Reservation task", startDate: reservation.startDate, dueDate: reservation.endDate)
        todo.calendarEventID = reservation.identifier
        let cohorts = days(start: date(10, 29), count: 3, events: [reservation], todos: [todo])
        let layout = CalendarScheduleSpanLayout(days: cohorts)
        let span = try #require(layout.spans.first)
        #expect(layout.spans.count == 1 && layout.laneCount == 1)
        #expect(cohorts.allSatisfy { $0.items.count == 1 })
        #expect(span.firstColumn == 0 && span.lastColumn == 2)
        #expect(span.continuesBefore && span.continuesAfter)
        #expect(span.item.linkedTodo === todo)
        #expect(span.item.start == reservation.startDate && span.item.end == reservation.endDate)
        #expect(span.item.event?.identifier == reservation.identifier)
        if case .event = span.item.source {} else { Issue.record("Expected the original event representation") }
    }

    @Test("Long timed reservations follow the existing all-day classifier without changing their raw times")
    func longTimedReservation() throws {
        let reservation = event("long timed", start: date(10, 28, 9), end: date(10, 30, 10), allDay: false)
        let layout = CalendarScheduleSpanLayout(days: days(start: date(10, 28), count: 3, events: [reservation]))
        let span = try #require(layout.spans.first)
        #expect(layout.spans.count == 1)
        #expect(span.firstColumn == 0 && span.lastColumn == 2)
        #expect(!span.continuesBefore && !span.continuesAfter)
        #expect(span.item.event?.isAllDay == false)
        #expect(span.item.isAllDay)
        #expect(span.item.start == reservation.startDate && span.item.end == reservation.endDate)
    }
}
