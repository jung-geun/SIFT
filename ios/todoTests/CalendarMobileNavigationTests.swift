import Foundation
import Testing
@testable import todo

@Suite("Mobile Calendar navigation")
@MainActor
struct CalendarMobileNavigationTests {
    @Test("Today opens Day only when today's civil date intersects the month viewport")
    func todayUsesVisibleDatesNotHeaderMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 15))!
        let visibleToday = calendar.startOfDay(for: today)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: visibleToday)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: visibleToday)!
        #expect(CalendarMobileTodayDestination.resolve(today: today,
            visibleDates: [yesterday, visibleToday], calendar: calendar) == .day)
        #expect(CalendarMobileTodayDestination.resolve(today: today,
            visibleDates: [yesterday], calendar: calendar) == .month)
        #expect(CalendarMobileTodayDestination.resolve(today: today,
            visibleDates: [tomorrow], calendar: calendar) == .month)
        #expect(CalendarMobileTodayDestination.resolve(today: today,
            visibleDates: [], calendar: calendar) == .month)
    }

    @Test("Year overview includes every real month without entering the next year",
          arguments: [Calendar.Identifier.gregorian, .chinese, .hebrew])
    func yearOverviewUsesActualMonthStarts(identifier: Calendar.Identifier) throws {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let date = try #require(gregorian.date(from: DateComponents(year: 2025, month: 8, day: 1)))
        let year = try #require(calendar.dateInterval(of: .year, for: date))
        let months = CalendarYearOverview.months(inYearContaining: date, calendar: calendar)
        #expect(months.first == year.start)
        #expect(months.allSatisfy { year.contains($0) })
        let last = try #require(months.last)
        #expect(calendar.date(byAdding: .month, value: 1, to: last) == year.end)
        #expect(months.count == (identifier == .chinese ? 13 : 12))
        for pair in zip(months, months.dropFirst()) {
            #expect(calendar.date(byAdding: .month, value: 1, to: pair.0) == pair.1)
        }
    }
}
