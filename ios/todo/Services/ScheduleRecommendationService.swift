import Foundation

nonisolated struct ScheduleRecommendation: Sendable, Equatable {
    let start: Date
    let end: Date
}

/// Read-only recommendations. The caller must re-fetch tasks/events and revalidate at approval.
@MainActor
enum ScheduleRecommendationService {
    private struct Interval {
        var start: Date
        var end: Date
    }

    static func recommend(
        todo: Todo, todos: [Todo], events: [CalendarService.CalendarEventSummary],
        preferredStart: Date?, now: Date = Date(), calendar: Calendar = .current,
        availabilityStartHour: Int = 9, availabilityEndHour: Int = 22
    ) -> ScheduleRecommendation? {
        guard !todo.isCompleted, !todo.isFixedSchedule,
              todo.source != TodoSource.calendar.rawValue, todo.calendarOrigin != .externalCalendar,
              todo.triageStatus == TodoTriage.todo.rawValue,
              (1...1440).contains(todo.estimatedDurationMinutes),
              (0...23).contains(availabilityStartHour), (1...24).contains(availabilityEndHour),
              availabilityStartHour < availabilityEndHour, now.timeIntervalSince1970.isFinite,
              let horizon = calendar.date(byAdding: .day, value: 14, to: calendar.startOfDay(for: now)) else { return nil }
        let duration = TimeInterval(todo.estimatedDurationMinutes) * 60
        let deadline = min(todo.dueDate ?? horizon, horizon)
        guard deadline.timeIntervalSince1970.isFinite, deadline.timeIntervalSince(now) >= duration else { return nil }
        let preferred = preferredStart ?? todo.startDate ?? now
        guard preferred.timeIntervalSince1970.isFinite else { return nil }

        var busy: [Interval] = events.compactMap { event in
            // Only stable identities exclude self; title matching would hide unrelated meetings.
            if (!event.identifier.isEmpty && event.identifier == todo.calendarEventID) ||
                (!event.externalIdentifier.isEmpty && event.externalIdentifier == todo.calendarEventExternalID) ||
                (event.marker?.entity == .todo && event.marker?.identifier == todo.id) { return nil }
            guard event.startDate < event.endDate else { return nil }
            // All-day EventKit summaries already carry their calendar-local start/end boundaries.
            return Interval(start: event.startDate, end: event.endDate)
        }
        busy += todos.compactMap { other in
            guard other.id != todo.id, !other.isCompleted, other.triageStatus == TodoTriage.todo.rawValue,
                  let start = other.startDate, let end = other.dueDate, start < end else { return nil }
            return Interval(start: start, end: end)
        }
        busy.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var merged: [Interval] = []
        for interval in busy {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }

        var best: ScheduleRecommendation?
        var bestDistance = TimeInterval.infinity
        for offset in 0..<14 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  let opening = RoutineLearningService.localTime(on: day, hour: availabilityStartHour, minute: 0, calendar: calendar)
            else { continue }
            let closing: Date?
            if availabilityEndHour == 24 {
                closing = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
            } else {
                closing = RoutineLearningService.localTime(on: day, hour: availabilityEndHour, minute: 0, calendar: calendar)
            }
            guard let closing else { continue }
            let windowStart = max(now, opening)
            let windowEnd = min(deadline, closing)
            guard windowEnd.timeIntervalSince(windowStart) >= duration else { continue }
            var cursor = windowStart
            var gaps: [Interval] = []
            for interval in merged where interval.end > windowStart && interval.start < windowEnd {
                if interval.start > cursor { gaps.append(Interval(start: cursor, end: min(interval.start, windowEnd))) }
                cursor = max(cursor, interval.end)
                if cursor >= windowEnd { break }
            }
            if cursor < windowEnd { gaps.append(Interval(start: cursor, end: windowEnd)) }
            for gap in gaps where gap.end.timeIntervalSince(gap.start) >= duration {
                // Project onto the entire feasible gap, not a grid. This finds the nearest
                // alternate even when the preferred start collides or a gap is off-minute.
                let latestStart = gap.end.addingTimeInterval(-duration)
                let start = min(max(preferred, gap.start), latestStart)
                let distance = abs(start.timeIntervalSince(preferred))
                if distance < bestDistance || (distance == bestDistance && start < (best?.start ?? .distantFuture)) {
                    bestDistance = distance
                    best = ScheduleRecommendation(start: start, end: start.addingTimeInterval(duration))
                }
            }
        }
        return best
    }
}
