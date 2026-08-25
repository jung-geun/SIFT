import Foundation
import Testing
@testable import todo

struct BehaviorEventLatencyTests {
    @Test("completion latency uses valid user events and excludes corrupt or review events")
    func validEventLatencyOnly() {
        let now = Date(timeIntervalSince1970: 1_768_046_400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let created = now.addingTimeInterval(-48 * 3600)
        let validCompletion = now.addingTimeInterval(-24 * 3600)
        let id = UUID()
        func event(
            id: UUID,
            timestamp: Date,
            createdAt: Date?,
            triage: TodoTriage = .todo
        ) -> BehaviorEventSnapshot {
            BehaviorEventSnapshot(
                todoID: id,
                kind: .completionChanged,
                timestamp: timestamp,
                actorRawValue: TaskBehaviorActor.user.rawValue,
                triageRawValue: triage.rawValue,
                todoCreatedAt: createdAt,
                beforeCompletion: false,
                afterCompletion: true,
                beforeDueDate: nil,
                afterDueDate: nil,
                beforeManualPriority: nil,
                afterManualPriority: nil
            )
        }
        let context = BehaviorAnalysisContext(
            now: now,
            calendar: calendar,
            events: [
                event(id: id, timestamp: validCompletion, createdAt: created),
                event(id: UUID(), timestamp: validCompletion, createdAt: nil),
                event(id: UUID(), timestamp: validCompletion, createdAt: validCompletion.addingTimeInterval(1)),
                event(id: UUID(), timestamp: validCompletion, createdAt: created, triage: .review)
            ],
            todos: []
        )

        let result = MemoryService.computeAnalysis(context: context, language: .english)
        let insight = result.behaviorProfile.insights.first { $0.metric == .completionLatencyHours }

        #expect(insight?.numerator == 1)
        #expect(insight?.denominator == 1)
        #expect(insight?.value == 24)
    }
}
