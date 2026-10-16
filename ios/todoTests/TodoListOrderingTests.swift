import Foundation
import XCTest
@testable import todo

@MainActor
final class TodoListOrderingTests: XCTestCase {
    func testActiveHomeIncludesLowPriorityOverdueBeforeFutureAndUndatedTodos() {
        let olderDueDate = Date(timeIntervalSince1970: 1_600_000_000)
        let newerDueDate = Date(timeIntervalSince1970: 1_650_000_000)
        let futureDueDate = Date(timeIntervalSince1970: 3_000_000_000)

        let overdueLow = Todo(title: "Older overdue", dueDate: olderDueDate)
        overdueLow.computedPriorityScore = 0.1
        let overdueHigh = Todo(title: "Newer overdue", dueDate: newerDueDate)
        overdueHigh.computedPriorityScore = 0.9
        let futureHigh = Todo(title: "Future", dueDate: futureDueDate)
        futureHigh.computedPriorityScore = 1
        let undated = Todo(title: "Undated")
        undated.manualPriority = 5
        let completed = Todo(title: "Completed overdue", dueDate: olderDueDate)
        completed.isCompleted = true
        let review = Todo(title: "Review overdue", dueDate: olderDueDate)
        review.triageStatus = TodoTriage.review.rawValue

        let sorted = TodoListOrdering.activeTodos(from: [undated, futureHigh, completed, overdueHigh, review, overdueLow])

        XCTAssertEqual(sorted.map(\.id), [overdueLow.id, overdueHigh.id, futureHigh.id, undated.id])
        XCTAssertEqual(overdueLow.dueDate, olderDueDate)
        XCTAssertEqual(futureHigh.dueDate, futureDueDate)
        XCTAssertNil(undated.dueDate)
    }

    func testManualPriorityBreaksEqualDeadlineTiesWithoutOverridingSoonerDeadline() {
        let soon = Date(timeIntervalSince1970: 3_000_000_000)
        let later = Date(timeIntervalSince1970: 3_100_000_000)
        let earlyLow = Todo(title: "Sooner low", dueDate: soon)
        earlyLow.manualPriority = 1
        let laterHigh = Todo(title: "Later critical", dueDate: later)
        laterHigh.manualPriority = 5
        let laterLow = Todo(title: "Later low", dueDate: later)
        laterLow.manualPriority = 1
        let laterAI = Todo(title: "Later AI", dueDate: later)
        laterAI.computedPriorityScore = 1

        let sorted = TodoListOrdering.activeTodos(from: [laterLow, laterAI, laterHigh, earlyLow])

        XCTAssertEqual(sorted.map(\.id), [earlyLow.id, laterHigh.id, laterLow.id, laterAI.id])
    }
}

@MainActor
final class TodoAnalysisPresentationTests: XCTestCase {
    func testEveryActualAIEngineEarnsMarkerWithoutScoreReasonOrPersonaFit() {
        let engines: [PriorityEngine] = [.foundationModels, .onDeviceMLX, .openAI, .laya]
        for engine in engines {
            let todo = Todo(title: "Analyzed")
            todo.apply(result(for: todo, engine: engine))

            XCTAssertTrue(todo.hasSuccessfulAIAnalysis, engine.rawValue)
            XCTAssertEqual(todo.computedPriorityScore, 0)
            XCTAssertTrue(todo.priorityReason.isEmpty)
            XCTAssertFalse(todo.aiPersonaFit)
        }
    }

    func testRulesAndUnprocessedOrUnknownProvenanceNeverEarnMarker() {
        for engine in ["", PriorityEngine.heuristic.rawValue, "Unknown engine"] {
            let todo = Todo(title: "Not AI analyzed")
            todo.aiEngine = engine
            todo.computedPriorityScore = 1
            todo.priorityReason = "A reason is not evidence of AI execution"
            todo.aiDetail = "Nor is a detail"
            todo.aiPersonaFit = true
            todo.aiRequestedProvider = "openAI"

            XCTAssertFalse(todo.hasSuccessfulAIAnalysis, engine)
        }
    }

    func testFallbackDoesNotAdvertiseAISuccessEvenWithAIEngine() {
        let engines: [PriorityEngine] = [.foundationModels, .onDeviceMLX, .openAI, .laya, .heuristic]
        for engine in engines {
            let todo = Todo(title: "Fallback")
            todo.apply(result(for: todo, engine: engine, fallbackReason: "Requested provider failed"))

            XCTAssertFalse(todo.hasSuccessfulAIAnalysis, engine.rawValue)
        }
    }

    func testMarkerTracksLatestAppliedResultAndRetainsDetailedReason() {
        let todo = Todo(title: "Reanalyzed")
        let success = PriorityResult(
            todoID: todo.id, score: 0, reason: "Detailed priority reason",
            detail: "Detailed analysis", needsNotification: false, recommendedTime: nil,
            personaFit: false, engine: .laya
        )
        todo.apply(success)
        XCTAssertTrue(todo.hasSuccessfulAIAnalysis)
        XCTAssertEqual(todo.priorityReason, "Detailed priority reason")
        XCTAssertEqual(todo.aiDetail, "Detailed analysis")

        // A later manual override does not erase the fact that analysis happened.
        todo.manualPriority = 1
        XCTAssertTrue(todo.hasSuccessfulAIAnalysis)
        todo.manualPriority = nil
        todo.apply(result(for: todo, engine: .heuristic, fallbackReason: "Unavailable"))
        XCTAssertFalse(todo.hasSuccessfulAIAnalysis)
        todo.apply(success)
        XCTAssertTrue(todo.hasSuccessfulAIAnalysis)
        XCTAssertTrue(todo.aiFallbackReason.isEmpty)
    }

    func testUnappliedAnalysisDoesNotMarkManuallyPrioritizedTask() {
        let todo = Todo(title: "Manual priority")
        todo.manualPriority = 3
        todo.apply(result(for: todo, engine: .foundationModels))
        XCTAssertTrue(todo.aiEngine.isEmpty)
        XCTAssertFalse(todo.hasSuccessfulAIAnalysis)
    }

    private func result(for todo: Todo, engine: PriorityEngine, fallbackReason: String = "") -> PriorityResult {
        PriorityResult(
            todoID: todo.id, score: 0, reason: "", detail: "", needsNotification: false,
            recommendedTime: nil, personaFit: false, engine: engine, fallbackReason: fallbackReason
        )
    }
}
