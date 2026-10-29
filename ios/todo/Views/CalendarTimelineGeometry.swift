import Foundation

/// Timeline coordinates are civil minutes, not elapsed seconds: a DST day still has a 24:00 edge.
enum CalendarTimelineGeometry {
    enum Edge { case start, end }
    static let snapMinutes = 15
    static let minimumDuration: TimeInterval = 15 * 60

    static func snappedMinute(_ minute: Double) -> Int {
        guard minute.isFinite else { return 0 }
        return Int((min(1_440, max(0, minute)) / Double(snapMinutes)).rounded()) * snapMinutes
    }

    static func date(at minute: Double, on day: Date, calendar: Calendar, near endpoint: Date? = nil) -> Date {
        let start = calendar.startOfDay(for: day)
        let end = calendar.dateInterval(of: .day, for: start)!.end
        let snapped = snappedMinute(minute)
        if snapped == 1_440 { return end }
        let first = calendar.date(bySettingHour: snapped / 60, minute: snapped % 60,
            second: 0, of: start, matchingPolicy: .nextTime, repeatedTimePolicy: .first,
            direction: .forward) ?? start
        guard let endpoint else { return min(end, max(start, first)) }
        let last = calendar.date(bySettingHour: snapped / 60, minute: snapped % 60,
            second: 0, of: start, matchingPolicy: .nextTime, repeatedTimePolicy: .last,
            direction: .forward) ?? first
        let components = calendar.dateComponents([.hour, .minute, .second], from: endpoint)
        let originalMinute = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
            + Double(components.second ?? 0) / 60
        // Compare against the intended wall-clock movement, not raw proximity to the original instant.
        // This retains first/second occurrence identity even when dragging across the repeated hour.
        let intended = endpoint.addingTimeInterval((Double(snapped) - originalMinute) * 60)
        let target = abs(last.timeIntervalSince(intended)) < abs(first.timeIntervalSince(intended)) ? last : first
        return min(end, max(start, target))
    }

    static func creationRange(from first: Double, to last: Double, on day: Date,
                              calendar: Calendar, isClick: Bool = false) -> DateInterval {
        let dayEnd = calendar.dateInterval(of: .day, for: day)!.end
        var start = date(at: min(first, last), on: day, calendar: calendar)
        var end = date(at: max(first, last), on: day, calendar: calendar)
        if isClick { end = min(dayEnd, start.addingTimeInterval(3_600)) }
        if end.timeIntervalSince(start) < minimumDuration {
            end = min(dayEnd, start.addingTimeInterval(minimumDuration))
            start = min(start, end.addingTimeInterval(-minimumDuration))
        }
        return DateInterval(start: start, end: end)
    }

    /// Only the selected original endpoint moves. The offscreen endpoint of an overnight event is retained.
    static func resizedRange(start: Date, end: Date, edge: Edge, minute: Double,
                             on day: Date, calendar: Calendar) -> DateInterval {
        let target = date(at: minute, on: day, calendar: calendar, near: edge == .start ? start : end)
        let minimum = min(minimumDuration, end.timeIntervalSince(start))
        switch edge {
        case .start: return DateInterval(start: min(target, end.addingTimeInterval(-minimum)), end: end)
        case .end: return DateInterval(start: start, end: max(target, start.addingTimeInterval(minimum)))
        }
    }
}
