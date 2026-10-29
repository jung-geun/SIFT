import Foundation
import Testing
@testable import todo

@Suite("Calendar timeline editing geometry")
@MainActor
struct CalendarTimelineGeometryTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("Pointer minutes snap to quarter-hours and clamp without integer overflow")
    func snap() {
        #expect(CalendarTimelineGeometry.snappedMinute(547) == 540)
        #expect(CalendarTimelineGeometry.snappedMinute(548) == 555)
        #expect(CalendarTimelineGeometry.snappedMinute(-100) == 0)
        #expect(CalendarTimelineGeometry.snappedMinute(1_500) == 1_440)
        #expect(CalendarTimelineGeometry.snappedMinute(Double.greatestFiniteMagnitude) == 1_440)
        #expect(CalendarTimelineGeometry.snappedMinute(.nan) == 0)
    }

    @Test("Upward and downward range drags produce the same snapped start and end")
    func reverseDrag() {
        let forward = CalendarTimelineGeometry.creationRange(from: 548, to: 608, on: date(10, 30), calendar: calendar)
        let backward = CalendarTimelineGeometry.creationRange(from: 608, to: 548, on: date(10, 30), calendar: calendar)
        #expect(forward == backward)
        #expect(forward.start == date(10, 30, 9, 15))
        #expect(forward.end == date(10, 30, 10, 15))
    }

    @Test("Simple clicks default to one hour; stationary and day-end drags remain positive")
    func positiveCreation() {
        let click = CalendarTimelineGeometry.creationRange(from: 540, to: 540, on: date(10, 30), calendar: calendar, isClick: true)
        #expect(click.start == date(10, 30, 9))
        #expect(click.end == date(10, 30, 10))
        let tiny = CalendarTimelineGeometry.creationRange(from: 540, to: 541, on: date(10, 30), calendar: calendar)
        #expect(tiny.duration == 900)
        let midnight = CalendarTimelineGeometry.creationRange(from: 1_440, to: 1_440, on: date(10, 30), calendar: calendar, isClick: true)
        #expect(midnight.start == date(10, 30, 23, 45))
        #expect(midnight.end == date(10, 31))
    }

    @Test("The 24:00 boundary is the next civil day on both DST transitions")
    func dstDayEnd() {
        for (month, day, elapsedHours) in [(3, 8, 23.0), (11, 1, 25.0)] {
            let start = date(month, day)
            let end = CalendarTimelineGeometry.date(at: 1_440, on: start, calendar: calendar)
            #expect(end.timeIntervalSince(start) == elapsedHours * 3_600)
            let range = CalendarTimelineGeometry.creationRange(from: 1_425, to: 1_440, on: start, calendar: calendar)
            #expect(range.start == date(month, day, 23, 45))
            #expect(range.end == end)
            #expect(range.duration == 900)
        }
    }

    @Test("Nonexistent spring times resolve forward and repeated fall times have a deterministic first occurrence")
    func dstAmbiguity() {
        let spring = CalendarTimelineGeometry.creationRange(from: 135, to: 150, on: date(3, 8), calendar: calendar)
        #expect(spring.start == date(3, 8, 3))
        #expect(spring.duration == 900)
        let fall = CalendarTimelineGeometry.date(at: 90, on: date(11, 1), calendar: calendar)
        #expect(calendar.timeZone.secondsFromGMT(for: fall) == -7 * 3_600)
        #expect(calendar.component(.hour, from: fall) == 1)
        #expect(calendar.component(.minute, from: fall) == 30)
    }

    @Test("Resizing either fall-back endpoint preserves its repeated-hour occurrence")
    func repeatedHourResize() {
        let day = date(11, 1)
        let firstOne = CalendarTimelineGeometry.date(at: 60, on: day, calendar: calendar)
        let secondOne = firstOne.addingTimeInterval(3_600)
        let secondOneThirty = secondOne.addingTimeInterval(1_800)
        let end = date(11, 1, 2, 30)
        let shorterStart = CalendarTimelineGeometry.resizedRange(start: secondOneThirty, end: end,
            edge: .start, minute: 105, on: day, calendar: calendar)
        #expect(shorterStart.start == secondOne.addingTimeInterval(2_700))
        #expect(shorterStart.duration == end.timeIntervalSince(secondOneThirty) - 900)
        let longerStart = CalendarTimelineGeometry.resizedRange(start: secondOneThirty, end: end,
            edge: .start, minute: 60, on: day, calendar: calendar)
        #expect(longerStart.start == secondOne)
        let shorterEnd = CalendarTimelineGeometry.resizedRange(start: day, end: secondOneThirty,
            edge: .end, minute: 75, on: day, calendar: calendar)
        #expect(shorterEnd.end == secondOne.addingTimeInterval(900))
        let longerEnd = CalendarTimelineGeometry.resizedRange(start: day, end: secondOneThirty,
            edge: .end, minute: 105, on: day, calendar: calendar)
        #expect(longerEnd.end == secondOne.addingTimeInterval(2_700))
        let firstOneFortyFive = firstOne.addingTimeInterval(2_700)
        let earlierFirst = CalendarTimelineGeometry.resizedRange(start: firstOneFortyFive, end: end,
            edge: .start, minute: 60, on: day, calendar: calendar)
        #expect(earlierFirst.start == firstOne)
    }

    @Test("Both endpoints can shorten or lengthen without crossing the other endpoint")
    func resize() {
        let start = date(10, 30, 9)
        let end = date(10, 30, 10)
        let longerStart = CalendarTimelineGeometry.resizedRange(start: start, end: end, edge: .start, minute: 480, on: start, calendar: calendar)
        #expect(longerStart.start == date(10, 30, 8))
        #expect(longerStart.end == end)
        let shorterStart = CalendarTimelineGeometry.resizedRange(start: start, end: end, edge: .start, minute: 800, on: start, calendar: calendar)
        #expect(shorterStart.start == date(10, 30, 9, 45))
        #expect(shorterStart.end == end)
        let shorterEnd = CalendarTimelineGeometry.resizedRange(start: start, end: end, edge: .end, minute: 0, on: start, calendar: calendar)
        #expect(shorterEnd.start == start)
        #expect(shorterEnd.end == date(10, 30, 9, 15))
        let longerEnd = CalendarTimelineGeometry.resizedRange(start: start, end: end, edge: .end, minute: 660, on: start, calendar: calendar)
        #expect(longerEnd.start == start)
        #expect(longerEnd.end == date(10, 30, 11))
    }

    @Test("Resizing a visible overnight endpoint preserves the offscreen original endpoint")
    func multiDayResize() {
        let start = date(10, 30, 23)
        let end = date(10, 31, 2)
        let firstDay = CalendarTimelineGeometry.resizedRange(start: start, end: end, edge: .start, minute: 1_350, on: start, calendar: calendar)
        #expect(firstDay.start == date(10, 30, 22, 30))
        #expect(firstDay.end == end)
        let secondDay = CalendarTimelineGeometry.resizedRange(start: start, end: end, edge: .end, minute: 90, on: end, calendar: calendar)
        #expect(secondDay.start == start)
        #expect(secondDay.end == date(10, 31, 1, 30))
    }

    @Test("Resizing a short midnight event cannot expand an unchanged boundary merely to enforce the grid minimum")
    func shortMidnightResize() {
        let start = date(10, 30, 23, 55)
        let end = date(10, 31)
        let shorter = CalendarTimelineGeometry.resizedRange(start: start, end: end, edge: .end,
            minute: 1_425, on: start, calendar: calendar)
        #expect(shorter.start == start)
        #expect(shorter.end == end)
    }
}
