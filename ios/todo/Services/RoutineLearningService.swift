import Foundation

@MainActor
enum RoutineLearningService {
    static let minimumDistinctDays = 3
    static let minimumPredictionConfidence = 0.65

    static func activityKey(_ title: String) -> String {
        title.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func learn(todos: [Todo], now: Date = Date(), calendar: Calendar = .current) -> [LearnedRoutine] {
        guard let cutoff = calendar.date(byAdding: .day, value: -90, to: now) else { return [] }
        let eligible = todos.filter { todo in
            guard todo.source == TodoSource.manual.rawValue,
                  todo.triageStatus == TodoTriage.todo.rawValue,
                  !todo.hasLocalOnlySourceContent,
                  !todo.sourceRef.lowercased().hasPrefix("meeting:"),
                  !todo.isFixedSchedule, todo.calendarOrigin != .externalCalendar,
                  todo.calendarOrigin != .siftEmail, todo.calendarOrigin != .siftMeeting,
                  todo.isCompleted, let completed = todo.completedAt,
                  completed >= todo.createdAt, completed >= cutoff, completed <= now
            else { return false }
            return !activityKey(todo.title).isEmpty
        }
        let grouped = Dictionary(grouping: eligible, by: { activityKey($0.title) })
        return grouped.keys.sorted().compactMap { key in
            guard let rows = grouped[key] else { return nil }
            // Repeated checkoffs on one day are evidence samples, not multiple recurrence days.
            let dates = rows.compactMap(\.completedAt).sorted()
            let days = Set(dates.map { calendar.startOfDay(for: $0) }).sorted()
            guard days.count >= minimumDistinctDays, let first = dates.first, let last = dates.last else { return nil }
            let intervals = zip(days, days.dropFirst()).map {
                calendar.dateComponents([.day], from: $0.0, to: $0.1).day ?? 0
            }.sorted()
            let period = max(1, intervals[intervals.count / 2])
            let stableCount = intervals.filter { abs($0 - period) <= (period <= 2 ? 0 : 1) }.count
            let consistency = Double(stableCount) / Double(intervals.count)
            // A single stable interval cannot establish a routine. Three days is the floor,
            // with confidence improving conservatively as additional distinct days agree.
            let confidence = min(0.95, (0.55 + min(0.4, Double(days.count) * 0.04)) * consistency)
            var minuteCounts: [Int: Int] = [:]
            for date in dates {
                let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
                minuteCounts[minute, default: 0] += 1
            }
            // Score each distinct minute once; circular distance keeps midnight checkoffs together.
            var preferred = 9 * 60
            var bestCost = Int.max
            for candidate in minuteCounts.keys {
                var cost = 0
                for (minute, count) in minuteCounts {
                    cost += circularDistance(candidate, minute) * count
                }
                if cost < bestCost || (cost == bestCost && candidate < preferred) {
                    preferred = candidate
                    bestCost = cost
                }
            }
            let hour = preferred / 60
            let minute = preferred % 60
            let durations = rows.map(\.estimatedDurationMinutes).filter { $0 > 0 && $0 <= 24 * 60 }.sorted()
            let duration = durations.isEmpty ? 30 : durations[durations.count / 2]
            var nextDay = calendar.date(byAdding: .day, value: period, to: days[days.count - 1]) ?? now
            // Bounded by the evidence window; skip missed cycles without inventing completion.
            for _ in 0..<92 {
                guard let candidate = localTime(on: nextDay, hour: hour, minute: minute, calendar: calendar) else { return nil }
                if candidate >= now {
                    let title = rows.sorted {
                        if $0.completedAt == $1.completedAt { return $0.id.uuidString < $1.id.uuidString }
                        return ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast)
                    }.last?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? key
                    return LearnedRoutine(
                        activityKey: key, title: title, periodDays: period,
                        preferredHour: hour, preferredMinute: minute,
                        estimatedDurationMinutes: duration, sampleCount: rows.count,
                        confidence: confidence, evidenceStart: first, evidenceEnd: last,
                        nextOccurrence: candidate,
                        uncertainty: "Based on \(rows.count) recorded task completions across \(days.count) distinct days. Checkoff times do not prove actual activity time or duration.\(confidence < minimumPredictionConfidence ? " Irregular intervals: confirm and edit before using this candidate." : " Confirm the activity, recurrence and preferred time before using it.")",
                        updatedAt: now, distinctCompletionDays: days.count,
                        recordedCompletionHours: dates.map { calendar.component(.hour, from: $0) },
                        timeZoneIdentifier: calendar.timeZone.identifier
                    )
                }
                guard let following = calendar.date(byAdding: .day, value: period, to: nextDay) else { return nil }
                nextDay = following
            }
            return nil
        }
    }

    /// Calendar-local wall time. In a DST gap, use the next valid time; in a fold,
    /// choose the first occurrence deterministically rather than adding 86,400 seconds.
    static func localTime(on day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                             matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    private static func circularDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let distance = abs(lhs - rhs)
        return min(distance, 24 * 60 - distance)
    }
}
