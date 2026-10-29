import Foundation
import Testing
@testable import todo

@Suite("Mobile upcoming agenda pages")
@MainActor
struct CalendarUpcomingEventsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
    private func date(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9))!
    }
    private func request(_ month: Int, revision: Int = 0, disabled: Set<String> = [], authorized: Bool = true) -> CalendarMonthRequest {
        .init(month: date(month, 1), revision: revision, disabledIDs: disabled, authorized: authorized, calendar: calendar)
    }
    private func event(_ month: Int, _ day: Int, title: String) -> CalendarService.CalendarEventSummary {
        .init(title: title, startDate: date(month, day), endDate: date(month, day).addingTimeInterval(3600),
              isRecurring: true, isAllDay: false, identifier: "series", calendarTitle: "Synthetic", calendarID: "synthetic")
    }
    @Test("Later pages keep earlier occurrences, update overlap, and retain recurring identities")
    func appendAndDeduplicate() {
        var agenda = CalendarUpcomingEvents()
        let early = event(3, 12, title: "Early")
        let overlap = event(5, 1, title: "Old")
        agenda.merge([early, overlap], request: request(3), startDate: date(3, 1))
        let later = event(8, 1, title: "Later")
        let updated = event(5, 1, title: "Updated")
        agenda.merge([updated, later], request: request(6), startDate: date(3, 1))
        #expect(agenda.events.map(\.title) == ["Early", "Updated", "Later"])
        #expect(agenda.through == calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
    }
    @Test("Refreshing, deselecting sources and revoking access cannot preserve old agenda data")
    func invalidateSensitiveSnapshot() {
        let old = event(3, 12, title: "Old")
        var agenda = CalendarUpcomingEvents()
        agenda.merge([old], request: request(3), startDate: date(3, 1))
        agenda.merge([], request: request(3, revision: 1), startDate: date(3, 1))
        #expect(agenda.events.isEmpty)
        agenda.merge([old], request: request(3), startDate: date(3, 1))
        agenda.merge([old], request: request(3, disabled: ["synthetic"]), startDate: date(3, 1))
        #expect(agenda.events.isEmpty)
        agenda.merge([old], request: request(3), startDate: date(3, 1))
        agenda.merge([old], request: request(3, authorized: false), startDate: date(3, 1))
        #expect(agenda.events.isEmpty)
        #expect(agenda.through == nil)
    }

    @Test("Two later pages followed by source or calendar invalidation retain early enabled events")
    func restartPagedAgenda() async throws {
        let calendar = calendar
        let start = date(10, 1)
        let events = (0..<10).flatMap { offset in
            ["enabled", "disabled"].map { source in
                let day = calendar.date(byAdding: .month, value: offset, to: start)!
                return CalendarService.CalendarEventSummary(title: "\(source)-\(offset)",
                    startDate: day, endDate: day.addingTimeInterval(3600), isRecurring: false,
                    isAllDay: false, identifier: "\(source)-\(offset)", calendarTitle: source, calendarID: source)
            }
        }
        let window = CalendarEventWindow { lower, upper in
            events.filter { $0.startDate < upper && $0.endDate > lower }
        }
        for changesTimeZone in [false, true] {
            var agenda = CalendarUpcomingEvents()
            for offset in [0, 3, 6] {
                let center = calendar.date(byAdding: .month, value: offset, to: start)!
                let request = CalendarMonthRequest(month: center, revision: 0, disabledIDs: [],
                    authorized: true, calendar: calendar)
                let page = try #require(await window.events(around: center, revision: 0,
                    disabledIDs: [], authorized: true, calendar: calendar))
                agenda.merge(page, request: request, startDate: start)
            }
            #expect(agenda.events.contains { $0.identifier == "enabled-0" })
            var nextCalendar = calendar
            if changesTimeZone { nextCalendar.timeZone = TimeZone(identifier: "Asia/Tokyo")! }
            let center = agenda.restart(around: start, calendar: nextCalendar)
            let request = CalendarMonthRequest(month: center, revision: 1, disabledIDs: ["disabled"],
                authorized: true, calendar: nextCalendar)
            let fresh = try #require(await window.events(around: center, revision: 1,
                disabledIDs: ["disabled"], authorized: true, calendar: nextCalendar))
            agenda.merge(fresh, request: request, startDate: start)
            #expect(Set(agenda.events.map(\.identifier)).isSuperset(of: ["enabled-0", "enabled-1", "enabled-2"]))
            #expect(!agenda.events.contains { $0.calendarID == "disabled" })
            #expect(agenda.through == nextCalendar.date(byAdding: .month, value: 4, to: center))
        }
    }
}
