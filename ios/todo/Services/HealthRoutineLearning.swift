import Foundation
import CryptoKit

/// Only repeated, temporally consistent records yield a candidate. This is not adherence
/// analysis: no missing events, dose quantities, prescriptions or manual checkoffs are used.
nonisolated enum HealthRoutineLearning {
    static let historyDays = 90
    static let minimumDistinctDays = 4
    static let minimumRegularity = 0.8

    static func learn(records: [HealthHistoryRecord], approvedSources: Set<String>,
                      now: Date, calendar: Calendar = .current) -> [HealthRoutineCandidate] {
        let start = calendar.date(byAdding: .day, value: -historyDays, to: now) ?? now
        var seen = Set<String>()
        let eligible = records.filter {
            approvedSources.contains($0.sourceID) && $0.startDate >= start && $0.startDate <= now &&
            !$0.kindKey.isEmpty && !$0.sourceID.isEmpty && !$0.title.isEmpty &&
            ($0.category != .medication || $0.wasTaken) && seen.insert($0.id).inserted
        }
        let groups = Dictionary(grouping: eligible) { stableID(category: $0.category, sourceID: $0.sourceID, kindKey: $0.kindKey) }
        return groups.compactMap { id, unsorted in
            let events = unsorted.sorted { $0.startDate < $1.startDate }
            guard let first = events.first, let last = events.last else { return nil }
            let days = Dictionary(grouping: events) { calendar.startOfDay(for: $0.startDate) }
            guard days.count >= minimumDistinctDays else { return nil }
            // Multiple doses of one medication on one day do not imply a once-daily prescription.
            // Multi-dose schedules require a different model, so no automatic candidate is offered.
            if first.category == .medication && days.values.contains(where: { $0.count > 1 }) { return nil }
            let dates = days.keys.sorted()
            let gaps = zip(dates, dates.dropFirst()).compactMap { calendar.dateComponents([.day], from: $0.0, to: $0.1).day }
            let counts = Dictionary(grouping: gaps, by: { $0 }).mapValues(\.count)
            guard let period = counts.keys.sorted(by: {
                counts[$0, default: 0] == counts[$1, default: 0] ? $0 < $1 : counts[$0, default: 0] > counts[$1, default: 0]
            }).first, (1...90).contains(period) else { return nil }
            let regularity = Double(counts[period, default: 0]) / Double(gaps.count)
            guard regularity >= minimumRegularity else { return nil }
            let minutes = events.map { calendar.component(.hour, from: $0.startDate) * 60 + calendar.component(.minute, from: $0.startDate) }.sorted()
            // Unwrap the clock at its largest empty arc before taking the median.
            // Sorting is already required; this adds one linear pass without pairwise scoring.
            var firstMinute = 0
            var largestGap = -1
            for index in minutes.indices {
                let next = (index + 1) % minutes.count
                let gap = minutes[next] + (next == 0 ? 1440 : 0) - minutes[index]
                if gap > largestGap { largestGap = gap; firstMinute = next }
            }
            let lower = (firstMinute + (minutes.count - 1) / 2) % minutes.count
            let upper = (firstMinute + minutes.count / 2) % minutes.count
            let lowerValue = minutes[lower] + (lower < firstMinute ? 1440 : 0)
            let upperValue = minutes[upper] + (upper < firstMinute ? 1440 : 0)
            let proposed = ((lowerValue + upperValue) / 2) % 1440
            let timeMatches = minutes.reduce(0) { count, value in
                let distance = abs(value - proposed)
                return count + (min(distance, 1440 - distance) <= 90 ? 1 : 0)
            }
            guard Double(timeMatches) / Double(minutes.count) >= minimumRegularity else { return nil }
            return HealthRoutineCandidate(id: id, category: first.category, kindKey: first.kindKey,
                title: first.title, sourceID: first.sourceID, sourceName: first.sourceName,
                recordCount: events.count, distinctDays: days.count, evidenceStart: first.startDate,
                evidenceEnd: last.startDate, regularity: regularity, periodDays: period,
                hour: proposed / 60, minute: proposed % 60, anchorDate: last.startDate,
                timeZoneIdentifier: calendar.timeZone.identifier)
        }.sorted { $0.id < $1.id }
    }

    static func stableID(category: HealthHistoryCategory, sourceID: String, kindKey: String) -> String {
        SHA256.hash(data: Data("\(category.rawValue)\u{0}\(sourceID)\u{0}\(kindKey)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The next future occurrence only. Never backfill a missed medication or create make-up tasks.
    static func nextOccurrence(_ routine: HealthRoutineCandidate, now: Date) -> Date? {
        guard (1...90).contains(routine.periodDays), (0...23).contains(routine.hour),
              (0...59).contains(routine.minute), let zone = TimeZone(identifier: routine.timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let anchorDay = calendar.startOfDay(for: routine.anchorDate)
        let today = calendar.startOfDay(for: now)
        let elapsed = calendar.dateComponents([.day], from: anchorDay, to: today).day ?? 0
        let cycles = max(0, elapsed / routine.periodDays)
        // One extra cycle is sufficient if today's scheduled time has already passed.
        for index in cycles...(cycles + 1) {
            guard let day = calendar.date(byAdding: .day, value: index * routine.periodDays, to: anchorDay),
                  let time = calendar.date(bySettingHour: routine.hour, minute: routine.minute, second: 0, of: day),
                  time > now else { continue }
            return time
        }
        return nil
    }

    static func sourceRef(_ routine: HealthRoutineCandidate, occurrence: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: routine.timeZoneIdentifier) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: occurrence)
        return "health:\(routine.id):\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
