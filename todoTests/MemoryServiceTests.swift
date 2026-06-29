import Foundation
import Testing
@testable import todo

@Suite("MemoryService computeAnalysis")
struct MemoryServiceTests {
    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("computeAnalysis preserves key heuristic outputs")
    func computeAnalysisPreservesHeuristics() {
        let fastCreated = makeDate(year: 2026, month: 1, day: 1, hour: 8)
        let fastCompleted = makeDate(year: 2026, month: 1, day: 1, hour: 10)
        let slowCreated = makeDate(year: 2026, month: 1, day: 2, hour: 8)
        let slowCompleted = makeDate(year: 2026, month: 1, day: 3, hour: 10)

        let fastTodo = Todo(title: "빠른 할 일", dueDate: makeDate(year: 2026, month: 1, day: 1, hour: 9))
        fastTodo.createdAt = fastCreated
        fastTodo.updatedAt = fastCompleted
        fastTodo.isCompleted = true
        fastTodo.completedAt = fastCompleted
        fastTodo.tags = ["fast"]

        let slowTodo = Todo(title: "느린 할 일", dueDate: makeDate(year: 2026, month: 1, day: 3, hour: 12))
        slowTodo.createdAt = slowCreated
        slowTodo.updatedAt = slowCompleted
        slowTodo.isCompleted = true
        slowTodo.completedAt = slowCompleted
        slowTodo.tags = ["slow"]

        let incompleteTodo = Todo(title: "미완료")

        let result = MemoryService.computeAnalysis(todos: [fastTodo, slowTodo, incompleteTodo])

        #expect(result.summary.contains("가장 생산적인 시간대: 10시~11시 (2건 완료)"))
        #expect(result.summary.contains("전체 완료율: 67% (2/3개)"))
        #expect(result.fastTags == ["fast"])
        #expect(result.overdueRate == 0.5)
        #expect(result.productiveHour == 10)
    }
}
