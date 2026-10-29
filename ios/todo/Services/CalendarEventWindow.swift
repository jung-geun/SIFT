import Foundation

/// Keeps only the seven requested calendar months, committing reads as one window.
@MainActor
final class CalendarEventWindow {
    private struct Context: Equatable {
        let revision: Int
        let disabledIDs: Set<String>
        let authorized: Bool
        let calendar: Calendar
    }

    private struct Occurrence: Hashable {
        let calendarID: String
        let identifier: String
        let startDate: Date
        let endDate: Date

        init(_ event: CalendarService.CalendarEventSummary) {
            calendarID = event.calendarID
            identifier = event.identifier
            startDate = event.startDate
            endDate = event.endDate
        }
    }

    private let read: @MainActor (Date, Date) async -> [CalendarService.CalendarEventSummary]
    private var context: Context?
    private var buckets: [Date: [CalendarService.CalendarEventSummary]] = [:]
    private var requestGeneration: UInt64 = 0

    init(read: @escaping @MainActor (Date, Date) async -> [CalendarService.CalendarEventSummary]) {
        self.read = read
    }

    /// `nil` denotes cancellation or supersession, not an empty authorized window.
    func events(
        around month: Date,
        revision: Int,
        disabledIDs: Set<String>,
        authorized: Bool,
        calendar: Calendar
    ) async -> [CalendarService.CalendarEventSummary]? {
        // An obsolete authorized caller must not supersede newer work merely
        // because it reached this actor late. Revocation still clears immediately.
        if authorized && Task.isCancelled { return nil }
        requestGeneration &+= 1
        let generation = requestGeneration
        let requestedContext = Context(revision: revision, disabledIDs: disabledIDs,
                                       authorized: authorized, calendar: calendar)
        if context != requestedContext {
            // Revoke access to old data before any suspension, including while an
            // earlier EventKit read is still outstanding.
            buckets.removeAll()
            context = requestedContext
        }
        guard !Task.isCancelled else { return nil }
        guard authorized else { return [] }
        guard let center = calendar.dateInterval(of: .month, for: month) else { return [] }

        var intervals: [DateInterval] = []
        intervals.reserveCapacity(7)
        for offset in -3...3 {
            guard let date = calendar.date(byAdding: .month, value: offset, to: center.start),
                  let interval = calendar.dateInterval(of: .month, for: date) else { return [] }
            intervals.append(interval)
        }

        // Do not share partial reads: cancelled and superseded operations cannot
        // seed another request's cache, even when their contexts are identical.
        var nextBuckets: [Date: [CalendarService.CalendarEventSummary]] = [:]
        nextBuckets.reserveCapacity(7)
        var index = 0
        while index < intervals.count {
            let interval = intervals[index]
            if let cached = buckets[interval.start] {
                nextBuckets[interval.start] = cached
                index += 1
                continue
            }

            // One EventKit query for each contiguous gap: a cold window needs
            // one bounded query, while navigation reads only its entering edge.
            let firstMissing = index
            repeat {
                index += 1
            } while index < intervals.count && buckets[intervals[index].start] == nil
            let events = await read(interval.start, intervals[index - 1].end)
            guard !Task.isCancelled, generation == requestGeneration else { return nil }
            let enabled = events.filter { !disabledIDs.contains($0.calendarID) }
            for missing in intervals[firstMissing..<index] {
                nextBuckets[missing.start] = enabled.filter {
                    $0.startDate < missing.end && $0.endDate > missing.start
                }
            }
        }
        guard !Task.isCancelled, generation == requestGeneration else { return nil }
        buckets = nextBuckets

        var seen: Set<Occurrence> = []
        var combined: [CalendarService.CalendarEventSummary] = []
        for interval in intervals {
            for event in nextBuckets[interval.start] ?? [] {
                if seen.insert(Occurrence(event)).inserted {
                    combined.append(event)
                }
            }
        }
        return combined.sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
            if lhs.calendarID != rhs.calendarID { return lhs.calendarID < rhs.calendarID }
            return lhs.identifier < rhs.identifier
        }
    }
}
