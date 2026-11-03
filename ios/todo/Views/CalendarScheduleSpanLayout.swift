import Foundation

/// One all-day representation per occurrence across the displayed civil-day cohorts.
/// The retained item keeps its original dates and linked task; only the columns are clipped.
struct CalendarScheduleSpanLayout {
    struct Span: Identifiable {
        let item: CalendarScheduleItem
        let firstColumn: Int
        let lastColumn: Int
        let lane: Int
        let continuesBefore: Bool
        let continuesAfter: Bool

        var id: String { item.id }
    }

    let spans: [Span]
    let laneCount: Int

    private struct Candidate {
        let id: String
        let item: CalendarScheduleItem
        let firstColumn: Int
        var lastColumn: Int
    }

    init(days: [CalendarScheduleDay]) {
        var candidates: [Candidate] = []
        var indicesByID: [String: Int] = [:]
        for (column, day) in days.enumerated() {
            for item in day.items where item.isAllDay {
                // Cohort membership is half-open, including midnight and DST day boundaries.
                guard item.start < day.end, item.end > day.date else { continue }
                let id = item.id
                if let index = indicesByID[id] {
                    candidates[index].lastColumn = column
                } else {
                    indicesByID[id] = candidates.count
                    candidates.append(Candidate(id: id, item: item, firstColumn: column, lastColumn: column))
                }
            }
        }
        // Chronological placement lets the month's first-available-lane pattern reuse
        // every expired lane. Longer spans win ties, then source identity breaks ties.
        candidates.sort {
            if $0.firstColumn != $1.firstColumn { return $0.firstColumn < $1.firstColumn }
            if $0.lastColumn != $1.lastColumn { return $0.lastColumn > $1.lastColumn }
            if $0.item.start != $1.item.start { return $0.item.start < $1.item.start }
            return $0.id < $1.id
        }
        var laneEnds: [Int] = []
        var assigned: [Span] = []
        assigned.reserveCapacity(candidates.count)
        for candidate in candidates {
            let lane = laneEnds.firstIndex(where: { $0 < candidate.firstColumn }) ?? laneEnds.count
            if lane == laneEnds.count {
                laneEnds.append(candidate.lastColumn)
            } else {
                laneEnds[lane] = candidate.lastColumn
            }
            assigned.append(Span(item: candidate.item,
                                 firstColumn: candidate.firstColumn,
                                 lastColumn: candidate.lastColumn,
                                 lane: lane,
                                 continuesBefore: candidate.item.start < days[candidate.firstColumn].date,
                                 continuesAfter: candidate.item.end > days[candidate.lastColumn].end))
        }
        spans = assigned
        laneCount = laneEnds.count
    }
}
