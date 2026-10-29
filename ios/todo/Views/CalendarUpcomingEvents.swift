import Foundation

/// The agenda keeps already presented occurrences while the bounded reader advances.
/// Source/revision/authorization/calendar changes discard the snapshot, not just its next page.
struct CalendarUpcomingEvents {
    private struct Occurrence: Hashable {
        let calendarID: String
        let identifier: String
        let start: Date
        let end: Date
        init(_ event: CalendarService.CalendarEventSummary) {
            calendarID = event.calendarID; identifier = event.identifier
            start = event.startDate; end = event.endDate
        }
    }
    private var request: CalendarMonthRequest?
    private var start: Date?
    private(set) var events: [CalendarService.CalendarEventSummary] = []
    private(set) var through: Date?

    /// A discarded snapshot must start reading at its original day again,
    /// rather than treating an advanced paging center as complete coverage.
    mutating func restart(around date: Date, calendar: Calendar) -> Date {
        self = Self()
        return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    mutating func merge(_ incoming: [CalendarService.CalendarEventSummary],
                        request next: CalendarMonthRequest, startDate: Date) {
        let lower = next.calendar.startOfDay(for: startDate)
        if start != lower || request?.revision != next.revision
            || request?.disabledIDs != next.disabledIDs || request?.calendar != next.calendar
            || request?.authorized != next.authorized {
            events.removeAll()
            through = nil
        }
        start = lower
        request = next
        guard next.authorized,
              let center = next.calendar.dateInterval(of: .month, for: next.month)?.start,
              let upper = next.calendar.date(byAdding: .month, value: 4, to: center) else {
            events.removeAll(); through = nil
            return
        }
        var combined: [Occurrence: CalendarService.CalendarEventSummary] = [:]
        for event in events { combined[Occurrence(event)] = event }
        for event in incoming where !next.disabledIDs.contains(event.calendarID)
            && event.startDate < upper && event.endDate > lower {
            combined[Occurrence(event)] = event
        }
        events = combined.values.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            if $0.endDate != $1.endDate { return $0.endDate < $1.endDate }
            if $0.calendarID != $1.calendarID { return $0.calendarID < $1.calendarID }
            return $0.identifier < $1.identifier
        }
        through = max(through ?? upper, upper)
    }
}
