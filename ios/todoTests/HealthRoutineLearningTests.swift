import Foundation
import Testing
@testable import todo

@Suite("Real health evidence learning")
struct HealthRoutineLearningTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func day(_ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    private func records(_ days: [Int], category: HealthHistoryCategory = .workout,
                         source: String = "test.workouts", taken: Bool = true) -> [HealthHistoryRecord] {
        days.map { HealthHistoryRecord(id: "\(source)-\($0)", category: category, kindKey: "activity-1", title: "Recorded activity",
            startDate: day($0), sourceID: source, sourceName: "Test source", wasTaken: taken) }
    }
    @Test("Only four distinct repeated days with approved source yield evidence")
    func minimumEvidence() throws {
        #expect(HealthRoutineLearning.learn(records: records([1, 2, 3]), approvedSources: ["test.workouts"], now: day(8), calendar: calendar).isEmpty)
        #expect(HealthRoutineLearning.learn(records: records([1, 2, 3, 4]), approvedSources: [], now: day(8), calendar: calendar).isEmpty)
        let samples = records([1, 2, 3, 4])
        let candidate = try #require(HealthRoutineLearning.learn(records: samples + [samples[0]], approvedSources: ["test.workouts"], now: day(8), calendar: calendar).first)
        #expect(candidate.recordCount == 4 && candidate.distinctDays == 4)
        #expect(candidate.evidenceStart == day(1) && candidate.evidenceEnd == day(4))
        #expect(candidate.periodDays == 1 && candidate.hour == 9 && candidate.regularity == 1)
        #expect(!candidate.isConfirmed && !candidate.isEnabled)
        #expect(HealthRoutineLearning.learn(records: Array(repeating: samples[0], count: 10), approvedSources: ["test.workouts"], now: day(8), calendar: calendar).isEmpty)
    }
    @Test("Sparse irregular intervals and inconsistent times are not trusted")
    func irregular() {
        #expect(HealthRoutineLearning.learn(records: records([1, 2, 7, 19]), approvedSources: ["test.workouts"], now: day(22), calendar: calendar).isEmpty)
        var samples = records([1, 2, 3, 4, 5])
        samples[1].startDate = day(2, hour: 19)
        samples[3].startDate = day(4, hour: 21)
        #expect(HealthRoutineLearning.learn(records: samples, approvedSources: ["test.workouts"], now: day(8), calendar: calendar).isEmpty)
    }
    @Test("Skipped doses are excluded; multi-dose history never becomes once-daily advice")
    func medicationSafety() {
        let skipped = records([1, 2, 3, 4], category: .medication, taken: false)
        #expect(HealthRoutineLearning.learn(records: skipped, approvedSources: ["test.workouts"], now: day(8), calendar: calendar).isEmpty)
        var multiple = records([1, 2, 3, 4], category: .medication)
        var extra = multiple[0]; extra.id = "extra"; extra.startDate = day(1, hour: 18)
        multiple.append(extra)
        #expect(HealthRoutineLearning.learn(records: multiple, approvedSources: ["test.workouts"], now: day(8), calendar: calendar).isEmpty)
    }
    @Test("Sources never merge and out-of-window or future events are excluded")
    func sourceFiltering() throws {
        let samples = records([1, 2, 3, 4]) + records([1, 2, 3, 4], source: "other.source")
        let result = HealthRoutineLearning.learn(records: samples, approvedSources: ["other.source"], now: day(8), calendar: calendar)
        #expect(result.count == 1)
        #expect(result.first?.sourceID == "other.source")
        #expect(result.first?.recordCount == 4)
        #expect(HealthRoutineLearning.learn(records: samples, approvedSources: ["test.workouts"], now: day(2), calendar: calendar).isEmpty)
        #expect(HealthRoutineLearning.learn(records: samples, approvedSources: ["test.workouts"], now: day(8).addingTimeInterval(100 * 86400), calendar: calendar).isEmpty)
    }
    @Test("Consistent near-midnight histories stay together across the clock boundary")
    func nearMidnight() throws {
        let times = [(1, 22, 45), (2, 23, 30), (4, 0, 0), (5, 0, 30), (6, 1, 15), (7, 0, 45)]
        let samples = times.enumerated().map { index, time in
            HealthHistoryRecord(id: "midnight-\(index)", category: .workout, kindKey: "late-workout", title: "Late workout",
                startDate: calendar.date(from: DateComponents(year: 2026, month: 10, day: time.0, hour: time.1, minute: time.2))!,
                sourceID: "test.workouts", sourceName: "Test source")
        }
        let candidate = try #require(HealthRoutineLearning.learn(records: samples, approvedSources: ["test.workouts"], now: day(8), calendar: calendar).first)
        #expect(candidate.regularity == 0.8 && candidate.periodDays == 1)
        let minute = candidate.hour * 60 + candidate.minute
        #expect(min(minute, 1440 - minute) <= 45)
    }

    @Test("Next occurrence is strictly future after schedule passes; reference ignores hour edits")
    func occurrenceIdentity() throws {
        var candidate = try #require(HealthRoutineLearning.learn(records: records([1, 2, 3, 4]), approvedSources: ["test.workouts"], now: day(5), calendar: calendar).first)
        let next = try #require(HealthRoutineLearning.nextOccurrence(candidate, now: day(8, hour: 10)))
        #expect(next == day(9))
        #expect(HealthRoutineLearning.nextOccurrence(candidate, now: day(8)) == day(9))
        let ref = HealthRoutineLearning.sourceRef(candidate, occurrence: next)
        candidate.hour = 18
        #expect(ref == HealthRoutineLearning.sourceRef(candidate, occurrence: day(9, hour: 18)))
        #expect(ref.hasPrefix("health:"))
        candidate.periodDays = 0
        #expect(HealthRoutineLearning.nextOccurrence(candidate, now: day(8)) == nil)
    }
}
