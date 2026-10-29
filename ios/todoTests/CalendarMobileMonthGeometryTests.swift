import Foundation
import UIKit
import Testing
@testable import todo

@Suite("Mobile calendar month sections")
@MainActor
struct CalendarMobileMonthGeometryTests {
    private func calendar(firstWeekday: Int = 1) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func event(_ id: String, start: Date, end: Date, allDay: Bool = false) -> CalendarService.CalendarEventSummary {
        CalendarService.CalendarEventSummary(title: id, startDate: start, endDate: end,
            isRecurring: true, isAllDay: allDay, identifier: id, calendarTitle: "Work", calendarID: "work")
    }

    @Test("November and December split a shared week without duplicate or missing days")
    func partialMonthBoundary() {
        let calendar = calendar()
        let november = CalendarMobileMonthGeometry(month: date(2026, 11, 15, calendar: calendar), calendar: calendar)
        let december = CalendarMobileMonthGeometry(month: date(2026, 12, 15, calendar: calendar), calendar: calendar)
        #expect(november.weeks.last!.days.map { calendar.component(.day, from: $0) } == [29, 30])
        #expect(november.weeks.last!.firstColumn == 0)
        #expect(december.weeks.first!.days.map { calendar.component(.day, from: $0) } == [1, 2, 3, 4, 5])
        #expect(december.weeks.first!.firstColumn == 2)
        let days = november.weeks.flatMap(\.days) + december.weeks.flatMap(\.days)
        #expect(days.count == 61)
        #expect(Set(days).count == days.count)
        for pair in zip(days, days.dropFirst()) {
            #expect(calendar.date(byAdding: .day, value: 1, to: pair.0) == pair.1)
        }
    }

    @Test("Leap February and every first weekday preserve exact local-day alignment")
    func leapAndWeekdayAlignment() {
        for firstWeekday in 1...7 {
            let calendar = calendar(firstWeekday: firstWeekday)
            for (year, month, count) in [(2024, 2, 29), (2026, 2, 28), (2026, 3, 31), (2026, 11, 30)] {
                let geometry = CalendarMobileMonthGeometry(month: date(year, month, 18, calendar: calendar), calendar: calendar)
                let days = geometry.weeks.flatMap(\.days)
                #expect(days.count == count)
                #expect(Set(days).count == count)
                #expect(calendar.component(.day, from: days.first!) == 1)
                #expect(calendar.component(.day, from: days.last!) == count)
                for week in geometry.weeks {
                    #expect(week.firstColumn + week.days.count <= 7)
                    for (index, day) in week.days.enumerated() {
                        #expect((calendar.component(.weekday, from: day) - firstWeekday + 7) % 7 == index + week.firstColumn)
                    }
                }
                for pair in zip(days, days.dropFirst()) {
                    #expect(calendar.date(byAdding: .day, value: 1, to: pair.0) == pair.1)
                }
            }
        }
    }

    @Test("Local date rows cross both DST transitions rather than adding fixed seconds")
    func daylightSavingDates() {
        let calendar = calendar(firstWeekday: 2)
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let geometry = CalendarMobileMonthGeometry(month: date(2026, month, day, calendar: calendar), calendar: calendar)
            let days = geometry.weeks.flatMap(\.days)
            let start = date(2026, month, day, calendar: calendar)
            let next = calendar.date(byAdding: .day, value: 1, to: start)!
            #expect(days.contains(start))
            #expect(days.contains(next))
            #expect(next.timeIntervalSince(start) == Double(hours * 3600))
            #expect(geometry.weeks.allSatisfy { $0.days.allSatisfy { calendar.startOfDay(for: $0) == $0 } })
        }
    }

    @Test("A midnight DST gap does not hide the following Monday's early task or event")
    func midnightDaylightSavingBoundary() {
        var calendar = calendar(firstWeekday: 2)
        calendar.timeZone = TimeZone(identifier: "America/Havana")!
        let month = date(2026, 3, 1, calendar: calendar)
        let geometry = CalendarMobileMonthGeometry(month: month, calendar: calendar)
        let days = geometry.weeks.flatMap(\.days)
        #expect(days.count == 31)
        #expect(days.allSatisfy { calendar.startOfDay(for: $0) == $0 })
        let sunday = date(2026, 3, 8, hour: 12, calendar: calendar)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 30))!
        let appointment = event("early Monday", start: monday, end: calendar.date(byAdding: .minute, value: 15, to: monday)!)
        let task = CalendarMonthTodo(title: "Early task", date: monday, eventID: nil)
        let window = CalendarMobileMonthWindow(centeredOn: month, calendar: calendar)
        let sundayPath = window.path(containing: sunday)!
        let mondayPath = window.path(containing: monday)!
        #expect(mondayPath.section == sundayPath.section)
        #expect(mondayPath.row == sundayPath.row + 1)
        let week = window.months[mondayPath.section].weeks[mondayPath.row - 1]
        #expect(week.firstColumn == 0)
        #expect(week.days[0] == calendar.startOfDay(for: monday))
        #expect(!CalendarMonthGeometry.occupies(appointment, day: sunday, calendar: calendar))
        let content = CalendarMobileMonthContentIndex(window: window, events: [appointment], todos: [task])
        let mondayIndex = window.rowStarts[mondayPath.section] + mondayPath.row - 1
        let sundayIndex = window.rowStarts[sundayPath.section] + sundayPath.row - 1
        #expect(content.events[sundayIndex].isEmpty)
        #expect(content.todos[sundayIndex].isEmpty)
        let layout = CalendarMonthWeekLayout(days: week.days, events: content.events[mondayIndex], todos: content.todos[mondayIndex], calendar: calendar)
        #expect(layout.items[0].count == 2)
        #expect(layout.items.dropFirst().allSatisfy { $0.isEmpty })
        #expect(layout.spans.isEmpty)
    }

    @Test("Month-spanning events clip to occupied columns and exclude their midnight end")
    func spanningEventMonthBoundary() {
        let calendar = calendar()
        let start = date(2026, 11, 29, calendar: calendar)
        let end = date(2026, 12, 3, calendar: calendar)
        let reservation = event("reservation", start: start, end: end, allDay: true)
        let window = CalendarMobileMonthWindow(centeredOn: start, calendar: calendar)
        let content = CalendarMobileMonthContentIndex(window: window, events: [reservation], todos: [])
        let novemberPath = window.path(containing: start)!
        let decemberPath = window.path(containing: date(2026, 12, 1, calendar: calendar))!
        for path in [novemberPath, decemberPath] {
            let week = window.months[path.section].weeks[path.row - 1]
            let index = window.rowStarts[path.section] + path.row - 1
            let layout = CalendarMonthWeekLayout(days: week.days, events: content.events[index], todos: [], calendar: calendar)
            #expect(layout.spans.count == 1)
            #expect(layout.spans[0].firstColumn == 0)
            #expect(layout.spans[0].lastColumn == 1)
            #expect(layout.spans[0].lane == 0)
            for column in week.days.indices {
                let occupied = column >= layout.spans[0].firstColumn && column <= layout.spans[0].lastColumn
                #expect(occupied == CalendarMonthGeometry.occupies(reservation, day: week.days[column], calendar: calendar))
            }
        }
        #expect(window.months[decemberPath.section].weeks[0].firstColumn == 2)
    }

    @Test("Fractional date anchor survives compact, stacked, details and width resize geometry")
    func styleDateAnchor() {
        let calendar = calendar(firstWeekday: 2)
        let window = CalendarMobileMonthWindow(centeredOn: date(2026, 12, 1, calendar: calendar), calendar: calendar)
        let day = date(2026, 12, 15, calendar: calendar)
        let path = window.path(containing: day)!
        let weekStart = window.months[path.section].weeks[path.row - 1].days[0]
        let anchor = CalendarMobileMonthWindow.Anchor(date: weekStart, fraction: 0.375, isHeader: false)
        for height in [CGFloat(51), 69, 89, 119, 174] {
            let offset = window.offset(for: anchor, rowHeight: height)!
            let restored = window.anchor(at: offset, rowHeight: height)
            #expect(restored.date == anchor.date)
            #expect(abs(restored.fraction - anchor.fraction) < 0.00001)
            #expect(!restored.isHeader)
        }
        let header = CalendarMobileMonthWindow.Anchor(date: window.months[path.section].month, fraction: 0.5, isHeader: true)
        #expect(window.anchor(at: window.offset(for: header, rowHeight: 51)!, rowHeight: 51) == header)
        #expect(window.anchor(at: window.offset(for: header, rowHeight: 174)!, rowHeight: 174) == header)
    }

    @Test("Rebased bounded windows retain partial-week anchors and month-start navigation")
    func rebaseAndNavigation() {
        let calendar = calendar()
        let original = CalendarMobileMonthWindow(centeredOn: date(2026, 11, 1, calendar: calendar), calendar: calendar)
        let farDate = date(2028, 12, 31, calendar: calendar)
        let path = original.path(containing: farDate)!
        let anchor = CalendarMobileMonthWindow.Anchor(date: original.months[path.section].weeks[path.row - 1].days[0], fraction: 0.72, isHeader: false)
        let rebased = CalendarMobileMonthWindow(centeredOn: anchor.date, calendar: calendar)
        let offset = rebased.offset(for: anchor, rowHeight: 89)!
        let restored = rebased.anchor(at: offset, rowHeight: 89)
        #expect(restored.date == anchor.date)
        #expect(abs(restored.fraction - anchor.fraction) < 0.00001)
        let section = rebased.section(containing: farDate)!
        let monthTop = rebased.sectionOffset(section, rowHeight: 89)
        let monthAnchor = rebased.anchor(at: monthTop, rowHeight: 89)
        #expect(monthAnchor.isHeader)
        #expect(monthAnchor.date == date(2028, 12, 1, calendar: calendar))
        #expect(monthAnchor.fraction == 0)
        #expect(original.section(containing: date(2040, 1, 1, calendar: calendar)) == nil)
    }

    @Test("Linked tasks replace only matching recurrence occurrences in partial rows")
    func recurrenceAndTaskDeduplication() {
        let calendar = calendar()
        let first = date(2026, 11, 30, hour: 9, calendar: calendar)
        let second = date(2026, 12, 1, hour: 9, calendar: calendar)
        let events = [first, second].map { event("series", start: $0, end: calendar.date(byAdding: .hour, value: 1, to: $0)!) }
        let todo = CalendarMonthTodo(title: "Linked task", date: first, eventID: "series")
        let window = CalendarMobileMonthWindow(centeredOn: first, calendar: calendar)
        let content = CalendarMobileMonthContentIndex(window: window, events: events, todos: [todo])
        var items: [CalendarMonthWeekLayout.Item] = []
        for date in [first, second] {
            let path = window.path(containing: date)!
            let index = window.rowStarts[path.section] + path.row - 1
            let week = window.months[path.section].weeks[path.row - 1]
            items += CalendarMonthWeekLayout(days: week.days, events: content.events[index], todos: content.todos[index], calendar: calendar).items.flatMap { $0 }
        }
        #expect(items.count == 2)
        #expect(items.filter { if case .event = $0 { true } else { false } }.count == 1)
        #expect(items.filter { if case .todo = $0 { true } else { false } }.count == 1)
    }

    @Test("Today stays visible when the scaled month cannot fit the viewport")
    func revealTodayAtAccessibilitySize() {
        let calendar = calendar()
        let today = date(2026, 10, 29, calendar: calendar)
        let window = CalendarMobileMonthWindow(centeredOn: today, calendar: calendar)
        let path = window.path(containing: today)!
        let monthTop = window.sectionOffset(path.section, rowHeight: 119)
        #expect(window.navigationOffset(to: today, rowHeight: 119, viewportHeight: 700) == monthTop)
        for viewport in [CGFloat(200), 480, 900] {
            let height: CGFloat = 340
            let rowTop = window.sectionOffset(path.section, rowHeight: height)
                + CalendarMobileMonthWindow.headerHeight + CGFloat(path.row - 1) * height
            let offset = window.navigationOffset(to: today, rowHeight: height, viewportHeight: viewport)!
            #expect(rowTop >= offset)
            #expect(rowTop < offset + viewport)
            if height <= viewport { #expect(rowTop + height <= offset + viewport) }
        }
    }
}
