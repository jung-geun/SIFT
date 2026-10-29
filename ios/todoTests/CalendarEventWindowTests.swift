import Foundation
import Testing
@testable import todo

@Suite("Bounded calendar event window")
@MainActor
struct CalendarEventWindowTests {
    private typealias Event = CalendarService.CalendarEventSummary

    private func calendar(timeZone: String = "America/Los_Angeles") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int = 1,
                      hour: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func event(_ id: String, start: Date, end: Date? = nil,
                       calendarID: String = "work", title: String? = nil,
                       recurring: Bool = false) -> Event {
        Event(title: title ?? id, startDate: start, endDate: end ?? start.addingTimeInterval(3_600),
              isRecurring: recurring, isAllDay: false, identifier: id,
              calendarTitle: calendarID, calendarID: calendarID)
    }

    @Test("a cold window uses one query and adjacent navigation reads only entering months")
    func adjacentNavigationReuse() async throws {
        let calendar = calendar()
        let october = date(2026, 10, 19, hour: 14, calendar: calendar)
        let reader = WindowReader(events: (7...12).map { month in
            event("month-\(month)", start: date(2026, month, 15, calendar: calendar))
        } + [event("january", start: date(2027, 1, 15, calendar: calendar)),
             event("february", start: date(2027, 2, 15, calendar: calendar)),
             event("march", start: date(2027, 3, 15, calendar: calendar))])
        let window = CalendarEventWindow(read: reader.read)
        let first = try #require(await window.events(around: october, revision: 0,
                                                    disabledIDs: [], authorized: true, calendar: calendar))
        #expect(reader.calls == [DateInterval(start: date(2026, 7, calendar: calendar),
                                             end: date(2027, 2, calendar: calendar))])
        #expect(first.map(\.identifier) == (7...12).map { "month-\($0)" } + ["january"])

        let next = try #require(await window.events(around: date(2026, 11, calendar: calendar), revision: 0,
                                                   disabledIDs: [], authorized: true, calendar: calendar))
        #expect(reader.calls.count == 2)
        #expect(reader.calls[1] == DateInterval(start: date(2027, 2, calendar: calendar),
                                                end: date(2027, 3, calendar: calendar)))
        #expect(next.map(\.identifier) == (8...12).map { "month-\($0)" } + ["january", "february"])
        let returned = try #require(await window.events(around: october, revision: 0,
                                                       disabledIDs: [], authorized: true, calendar: calendar))
        #expect(reader.calls.count == 3)
        #expect(reader.calls[2] == DateInterval(start: date(2026, 7, calendar: calendar),
                                                end: date(2026, 8, calendar: calendar)))
        #expect(returned.map(\.identifier) == first.map(\.identifier))

        let december = try #require(await window.events(around: date(2026, 12, calendar: calendar), revision: 0,
                                                       disabledIDs: [], authorized: true, calendar: calendar))
        #expect(reader.calls.count == 4)
        #expect(reader.calls[3] == DateInterval(start: date(2027, 2, calendar: calendar),
                                                end: date(2027, 4, calendar: calendar)))
        #expect(december.map(\.identifier) == (9...12).map { "month-\($0)" } + ["january", "february", "march"])
        _ = await window.events(around: date(2030, 5, calendar: calendar), revision: 0,
                                disabledIDs: [], authorized: true, calendar: calendar)
        #expect(reader.calls.count == 5)
        #expect(reader.calls[4] == DateInterval(start: date(2030, 2, calendar: calendar),
                                                end: date(2030, 9, calendar: calendar)))
        _ = await window.events(around: october, revision: 0,
                                disabledIDs: [], authorized: true, calendar: calendar)
        #expect(reader.calls.count == 6)
        #expect(reader.calls[5] == reader.calls[0])
    }

    @Test("source filters, revision, time zone and calendar settings invalidate cached reads")
    func contextInvalidation() async throws {
        let calendar = calendar()
        let october = date(2026, 10, calendar: calendar)
        let work = event("work-item", start: date(2026, 10, 5, calendar: calendar))
        let personal = event("personal-item", start: date(2026, 10, 6, calendar: calendar), calendarID: "personal")
        let reader = WindowReader(events: [work, personal])
        let window = CalendarEventWindow(read: reader.read)
        _ = await window.events(around: october, revision: 0,
                                disabledIDs: [], authorized: true, calendar: calendar)
        #expect(reader.calls.count == 1)
        let filtered = try #require(await window.events(around: october, revision: 0,
                                                       disabledIDs: ["work"], authorized: true, calendar: calendar))
        #expect(reader.calls.count == 2)
        #expect(filtered.map(\.identifier) == ["personal-item"])
        #expect(reader.calls[1] == reader.calls[0])

        reader.events = [event("updated", start: personal.startDate, calendarID: "personal")]
        let revised = try #require(await window.events(around: october, revision: 1,
                                                      disabledIDs: ["work"], authorized: true, calendar: calendar))
        #expect(reader.calls.count == 3)
        #expect(revised.map(\.identifier) == ["updated"])
        let tokyo = self.calendar(timeZone: "Asia/Tokyo")
        _ = await window.events(around: october, revision: 1,
                                disabledIDs: ["work"], authorized: true, calendar: tokyo)
        #expect(reader.calls.count == 4)
        #expect(reader.calls[3] == DateInterval(start: date(2026, 7, calendar: tokyo),
                                                end: date(2027, 2, calendar: tokyo)))
        #expect(reader.calls[3].start != reader.calls[2].start)
        var monday = tokyo
        monday.firstWeekday = 2
        _ = await window.events(around: october, revision: 1,
                                disabledIDs: ["work"], authorized: true, calendar: monday)
        #expect(reader.calls.count == 5)
        _ = await window.events(around: october, revision: 1,
                                disabledIDs: ["work"], authorized: true, calendar: monday)
        #expect(reader.calls.count == 5)
        let enabled = try #require(await window.events(around: october, revision: 1,
                                                      disabledIDs: [], authorized: true, calendar: monday))
        #expect(reader.calls.count == 6)
        #expect(enabled.map(\.identifier) == ["updated"])
    }

    @Test("coalesced reads and entering month boundaries honor daylight saving time")
    func exactMonthRanges() async {
        let calendar = calendar()
        let reader = WindowReader()
        let window = CalendarEventWindow(read: reader.read)
        _ = await window.events(around: date(2026, 2, 28, hour: 18, calendar: calendar), revision: 0,
                                disabledIDs: [], authorized: true, calendar: calendar)
        #expect(reader.calls == [DateInterval(start: date(2025, 11, calendar: calendar),
                                             end: date(2026, 6, calendar: calendar))])
        _ = await window.events(around: date(2025, 11, calendar: calendar), revision: 0,
                                disabledIDs: [], authorized: true, calendar: calendar)
        #expect(reader.calls.count == 2)
        #expect(reader.calls[1] == DateInterval(start: date(2025, 8, calendar: calendar),
                                                end: date(2025, 11, calendar: calendar)))
        _ = await window.events(around: date(2025, 12, calendar: calendar), revision: 0,
                                disabledIDs: [], authorized: true, calendar: calendar)
        #expect(reader.calls.count == 3)
        let march = reader.calls[2]
        #expect(march.start == date(2026, 3, calendar: calendar))
        #expect(march.end == date(2026, 4, calendar: calendar))
        #expect(march.duration == 31 * 86_400 - 3_600)
    }

    @Test("partitioning deduplicates spans without merging recurrence occurrences or source identities")
    func occurrenceDeduplicationAndOrdering() async throws {
        let calendar = calendar()
        let recurringStart = date(2026, 10, 5, hour: 9, calendar: calendar)
        let span = event("span", start: date(2026, 7, 31, calendar: calendar),
                         end: date(2026, 8, 2, calendar: calendar))
        let first = event("series", start: recurringStart, title: "first", recurring: true)
        let second = event("series", start: date(2026, 10, 12, hour: 9, calendar: calendar),
                           title: "second", recurring: true)
        let otherSource = event("series", start: recurringStart, calendarID: "personal", title: "other-source")
        let longer = event("series", start: recurringStart, end: recurringStart.addingTimeInterval(7_200), title: "longer")
        let reader = WindowReader(events: [second, longer, first, otherSource, span])
        let window = CalendarEventWindow(read: reader.read)
        let result = try #require(await window.events(around: date(2026, 10, calendar: calendar), revision: 0,
                                                     disabledIDs: [], authorized: true, calendar: calendar))
        #expect(reader.calls.count == 1)
        #expect(result.map(\.title) == ["span", "other-source", "first", "longer", "second"])
        #expect(result.filter(\.isRecurring).count == 2)
        let moved = try #require(await window.events(around: date(2026, 11, calendar: calendar), revision: 0,
                                                    disabledIDs: [], authorized: true, calendar: calendar))
        #expect(reader.calls.count == 2)
        #expect(moved.map(\.title) == result.map(\.title))
        // July was evicted; the July/August span must still exist in August's bucket.
        #expect(moved.filter { $0.identifier == "span" }.count == 1)
    }

    @Test("month buckets preserve strict overlap and timed zero-duration semantics")
    func halfOpenPartitionBoundaries() async throws {
        let calendar = calendar()
        let boundary = date(2026, 8, calendar: calendar)
        let noon = date(2026, 8, 1, hour: 12, calendar: calendar)
        let reader = WindowReader(events: [
            event("ends-at-boundary", start: date(2026, 7, 31, hour: 23, calendar: calendar), end: boundary),
            event("zero-midnight", start: boundary, end: boundary),
            event("starts-at-boundary", start: boundary),
            event("zero-noon", start: noon, end: noon)
        ])
        let window = CalendarEventWindow(read: reader.read)
        let first = try #require(await window.events(around: date(2026, 10, calendar: calendar), revision: 0,
                                                    disabledIDs: [], authorized: true, calendar: calendar))
        #expect(first.map(\.identifier) == ["ends-at-boundary", "starts-at-boundary", "zero-noon"])
        let moved = try #require(await window.events(around: date(2026, 11, calendar: calendar), revision: 0,
                                                    disabledIDs: [], authorized: true, calendar: calendar))
        #expect(moved.map(\.identifier) == ["starts-at-boundary", "zero-noon"])
        #expect(reader.calls.count == 2)
    }

    @Test("a superseded read in the same context cannot overwrite the newer cache")
    func staleCompletion() async throws {
        let calendar = calendar()
        let month = date(2026, 10, calendar: calendar)
        let fresh = event("fresh", start: date(2026, 7, 15, calendar: calendar))
        let reader = WindowReader(events: [fresh], suspendedCalls: [1])
        let window = CalendarEventWindow(read: reader.read)
        let old = Task { await window.events(around: month, revision: 0,
                                             disabledIDs: [], authorized: true, calendar: calendar) }
        await reader.waitForCall(1)
        let newest = try #require(await window.events(around: month, revision: 0,
                                                     disabledIDs: [], authorized: true, calendar: calendar))
        #expect(newest.map(\.identifier) == ["fresh"])
        #expect(reader.calls.count == 2)
        reader.resume(call: 1, returning: [event("stale", start: fresh.startDate)])
        let oldResult = await old.value
        #expect(oldResult == nil)
        let cached = try #require(await window.events(around: month, revision: 0,
                                                     disabledIDs: [], authorized: true, calendar: calendar))
        #expect(cached.map(\.identifier) == ["fresh"])
        #expect(reader.calls.count == 2)
    }

    @Test("an already-cancelled old caller cannot invalidate a newer suspended request")
    func cancelledLateEntryPreservesNewerRequest() async throws {
        let calendar = calendar()
        let month = date(2026, 10, calendar: calendar)
        let fresh = event("fresh", start: date(2026, 7, 15, calendar: calendar))
        let reader = WindowReader(events: [fresh], suspendedCalls: [1])
        let entryGate = WindowReader(suspendedCalls: [1])
        let window = CalendarEventWindow(read: reader.read)
        let old = Task {
            _ = await entryGate.read(from: month, to: month.addingTimeInterval(1))
            return await window.events(around: month, revision: 0,
                                       disabledIDs: [], authorized: true, calendar: calendar)
        }
        await entryGate.waitForCall(1)
        old.cancel()
        let newer = Task {
            await window.events(around: month, revision: 1,
                                disabledIDs: [], authorized: true, calendar: calendar)
        }
        await reader.waitForCall(1)
        entryGate.resume(call: 1, returning: [])
        let oldResult = await old.value
        #expect(oldResult == nil)
        #expect(reader.calls.count == 1)
        reader.resume(call: 1, returning: [fresh])
        let newerResult = try #require(await newer.value)
        #expect(newerResult.map(\.identifier) == ["fresh"])
        let cached = try #require(await window.events(around: month, revision: 1,
                                                     disabledIDs: [], authorized: true, calendar: calendar))
        #expect(cached.map(\.identifier) == ["fresh"])
        #expect(reader.calls.count == 1)
    }

    @Test("cancelling a missing edge read preserves committed buckets without caching cancelled data")
    func cancellationPreservesCommittedWindow() async throws {
        let calendar = calendar()
        let october = date(2026, 10, calendar: calendar)
        let november = date(2026, 11, calendar: calendar)
        let retained = event("retained", start: date(2026, 10, 15, calendar: calendar))
        let entering = event("entering", start: date(2027, 2, 15, calendar: calendar))
        let reader = WindowReader(events: [retained], suspendedCalls: [2])
        let window = CalendarEventWindow(read: reader.read)
        _ = await window.events(around: october, revision: 0,
                                disabledIDs: [], authorized: true, calendar: calendar)
        let cancelled = Task { await window.events(around: november, revision: 0,
                                                   disabledIDs: [], authorized: true, calendar: calendar) }
        await reader.waitForCall(2)
        cancelled.cancel()
        reader.resume(call: 2, returning: [event("cancelled", start: entering.startDate)])
        let cancelledResult = await cancelled.value
        #expect(cancelledResult == nil)
        reader.events = [entering]
        let previous = try #require(await window.events(around: october, revision: 0,
                                                       disabledIDs: [], authorized: true, calendar: calendar))
        #expect(previous.map(\.identifier) == ["retained"])
        #expect(reader.calls.count == 2)
        let fresh = try #require(await window.events(around: november, revision: 0,
                                                    disabledIDs: [], authorized: true, calendar: calendar))
        #expect(reader.calls.count == 3)
        #expect(reader.calls[2] == reader.calls[1])
        #expect(fresh.map(\.identifier) == ["retained", "entering"])
    }

    @Test("revocation clears cached data and supersedes an outstanding read without waiting")
    func unauthorizedClearsAndSupersedes() async throws {
        let calendar = calendar()
        let month = date(2026, 10, calendar: calendar)
        let start = date(2026, 7, 15, calendar: calendar)
        let sensitive = event("old-private", start: start)
        let reader = WindowReader(events: [sensitive], suspendedCalls: [2])
        let window = CalendarEventWindow(read: reader.read)
        _ = await window.events(around: month, revision: 0,
                                disabledIDs: [], authorized: true, calendar: calendar)
        let outstanding = Task { await window.events(around: month, revision: 1,
                                                     disabledIDs: [], authorized: true, calendar: calendar) }
        await reader.waitForCall(2)
        let revoked = try #require(await window.events(around: month, revision: 1,
                                                      disabledIDs: [], authorized: false, calendar: calendar))
        #expect(revoked.isEmpty)
        #expect(reader.calls.count == 2)
        reader.events = [event("newly-authorized", start: start)]
        let restored = try #require(await window.events(around: month, revision: 1,
                                                       disabledIDs: [], authorized: true, calendar: calendar))
        #expect(reader.calls.count == 3)
        #expect(restored.map(\.identifier) == ["newly-authorized"])
        reader.resume(call: 2, returning: [sensitive])
        let outstandingResult = await outstanding.value
        #expect(outstandingResult == nil)
        let cached = try #require(await window.events(around: month, revision: 1,
                                                     disabledIDs: [], authorized: true, calendar: calendar))
        #expect(cached.map(\.identifier) == ["newly-authorized"])
        #expect(reader.calls.count == 3)
        let cleared = try #require(await window.events(around: month, revision: 1,
                                                      disabledIDs: [], authorized: false, calendar: calendar))
        #expect(cleared.isEmpty)
        reader.events = []
        let empty = try #require(await window.events(around: month, revision: 1,
                                                    disabledIDs: [], authorized: true, calendar: calendar))
        #expect(empty.isEmpty)
        #expect(reader.calls.count == 4)
    }
}

/// Deliberately ignores cancellation to exercise rejection of late external reads.
@MainActor
private final class WindowReader {
    typealias Event = CalendarService.CalendarEventSummary
    var events: [Event]
    private(set) var calls: [DateInterval] = []
    private let suspendedCalls: Set<Int>
    private var continuations: [Int: CheckedContinuation<[Event], Never>] = [:]
    private var callWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(events: [Event] = [], suspendedCalls: Set<Int> = []) {
        self.events = events
        self.suspendedCalls = suspendedCalls
    }

    func read(from start: Date, to end: Date) async -> [Event] {
        calls.append(DateInterval(start: start, end: end))
        let call = calls.count
        if suspendedCalls.contains(call) {
            return await withCheckedContinuation { continuation in
                continuations[call] = continuation
                callWaiters.removeValue(forKey: call)?.resume()
            }
        }
        callWaiters.removeValue(forKey: call)?.resume()
        return events.filter { $0.startDate < end && $0.endDate > start }
    }

    func waitForCall(_ call: Int) async {
        if calls.count >= call { return }
        await withCheckedContinuation { callWaiters[call] = $0 }
    }

    func resume(call: Int, returning events: [Event]) {
        guard let continuation = continuations.removeValue(forKey: call) else {
            Issue.record("Expected read \(call) to be suspended")
            return
        }
        continuation.resume(returning: events)
    }
}
