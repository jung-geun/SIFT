import Foundation
import Testing
@testable import todo

struct BehaviorAnalysisContextTests {
    @Test("context analyzer uses injected calendar timezone")
    func injectedCalendarControlsCompletionBucket() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = utc.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12))!
        let completion = utc.date(from: DateComponents(year: 2026, month: 1, day: 9, hour: 9))!
        let snapshots = (0..<5).map { index in
            BehaviorTodoSnapshot(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                createdAt: completion.addingTimeInterval(-24 * 3600),
                completedAt: completion,
                dueDate: nil,
                isCompleted: true,
                triage: .todo,
                tags: [],
                observationDate: completion,
                isDeleted: false
            )
        }
        var pacific = utc
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let utcResult = MemoryService.computeAnalysis(
            context: BehaviorAnalysisContext(
                now: now,
                calendar: utc,
                events: [],
                todos: snapshots,
                behaviorProfile: .empty(),
                personaTypes: []
            ),
            language: .english
        )
        let pacificResult = MemoryService.computeAnalysis(
            context: BehaviorAnalysisContext(
                now: now,
                calendar: pacific,
                events: [],
                todos: snapshots,
                behaviorProfile: .empty(),
                personaTypes: []
            ),
            language: .english
        )

        #expect(utcResult.productiveHour == 9)
        #expect(pacificResult.productiveHour == 0)
        #expect(utcResult.productiveHour != pacificResult.productiveHour)
    }
}
