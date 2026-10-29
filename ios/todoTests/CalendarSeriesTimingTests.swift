import Foundation
import Testing
@testable import todo

@Suite("Calendar whole-series time edits")
@MainActor
struct CalendarSeriesTimingTests {
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test("Resizing a later occurrence does not move the series anchor to that occurrence")
    func laterOccurrenceResizePreservesHistory() {
        let range = CalendarService.shiftedSeriesRange(seriesStart: date(1, 9), seriesEnd: date(1, 10),
            occurrenceStart: date(29, 9), occurrenceEnd: date(29, 10),
            newStart: date(29, 9), newEnd: date(29, 10, 45))
        #expect(range.start == date(1, 9))
        #expect(range.end == date(1, 10, 45))
    }

    @Test("Changing the start edge preserves the end and metadata-only edits preserve both original dates")
    func independentEdgesAndUnchangedTimes() {
        let earlier = CalendarService.shiftedSeriesRange(seriesStart: date(1, 9), seriesEnd: date(1, 10),
            occurrenceStart: date(29, 9), occurrenceEnd: date(29, 10),
            newStart: date(29, 8, 30), newEnd: date(29, 10))
        #expect(earlier.start == date(1, 8, 30))
        #expect(earlier.end == date(1, 10))
        let unchanged = CalendarService.shiftedSeriesRange(seriesStart: date(1, 9), seriesEnd: date(1, 10),
            occurrenceStart: date(29, 9), occurrenceEnd: date(29, 10),
            newStart: date(29, 9), newEnd: date(29, 10))
        #expect(unchanged.start == date(1, 9))
        #expect(unchanged.end == date(1, 10))
    }

    @Test("Moving an occurrence across DST preserves the requested civil clock time for the entire series")
    func daylightSavingMove() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func date(_ month: Int, _ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }
        let range = CalendarService.shiftedSeriesRange(seriesStart: date(1, 1, 9), seriesEnd: date(1, 1, 10),
            occurrenceStart: date(3, 7, 9), occurrenceEnd: date(3, 7, 10),
            newStart: date(3, 8, 9), newEnd: date(3, 8, 10), calendar: calendar)
        #expect(range.start == date(1, 2, 9))
        #expect(range.end == date(1, 2, 10))
    }

    @Test("Changing an edge across the DST gap transfers wall-clock displacement, not elapsed hours")
    func daylightSavingGapEdge() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func date(_ month: Int, _ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }
        let range = CalendarService.shiftedSeriesRange(seriesStart: date(1, 1, 1), seriesEnd: date(1, 1, 4),
            occurrenceStart: date(3, 8, 1), occurrenceEnd: date(3, 8, 4),
            newStart: date(3, 8, 3), newEnd: date(3, 8, 4), calendar: calendar)
        #expect(range.start == date(1, 1, 3))
        #expect(range.end == date(1, 1, 4))
    }

    @Test("Unchanged endpoints retain either absolute instant of an autumn repeated hour")
    func repeatedHourNoOp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let iso = ISO8601DateFormatter()
        for text in ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z"] {
            let start = iso.date(from: text)!
            let end = start.addingTimeInterval(1800)
            let range = CalendarService.shiftedSeriesRange(seriesStart: start, seriesEnd: end,
                occurrenceStart: start, occurrenceEnd: end, newStart: start, newEnd: end, calendar: calendar)
            #expect(range.start == start)
            #expect(range.end == end)
        }
    }
}
