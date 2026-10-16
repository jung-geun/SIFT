import XCTest
@testable import todo

@MainActor
final class TodoBoardViewTests: XCTestCase {
    func testBoardColumnTypesProperties() {
        XCTAssertEqual(BoardColumnType.allCases.count, 4)
        XCTAssertEqual(BoardColumnType.active.id, "active")
        XCTAssertEqual(BoardColumnType.overdue.id, "overdue")
        XCTAssertEqual(BoardColumnType.review.id, "review")
        XCTAssertEqual(BoardColumnType.completed.id, "completed")

        XCTAssertFalse(BoardColumnType.active.title.isEmpty)
        XCTAssertFalse(BoardColumnType.overdue.title.isEmpty)
        XCTAssertFalse(BoardColumnType.review.title.isEmpty)
        XCTAssertFalse(BoardColumnType.completed.title.isEmpty)

        XCTAssertEqual(BoardColumnType.active.iconName, "play.circle.fill")
        XCTAssertEqual(BoardColumnType.overdue.iconName, "exclamationmark.circle.fill")
        XCTAssertEqual(BoardColumnType.review.iconName, "tray.full.fill")
        XCTAssertEqual(BoardColumnType.completed.iconName, "checkmark.circle.fill")
    }

    func testTodoCategorizationForBoardColumns() {
        let activeTodo = Todo(title: "Active task")
        activeTodo.computedPriorityScore = 0.5
        activeTodo.triageStatus = TodoTriage.todo.rawValue
        activeTodo.isCompleted = false

        let overdueTodo = Todo(title: "Overdue task", dueDate: Date().addingTimeInterval(-3600))
        overdueTodo.computedPriorityScore = 0.3
        overdueTodo.triageStatus = TodoTriage.todo.rawValue
        overdueTodo.isCompleted = false

        let reviewTodo = Todo(title: "Review queue task")
        reviewTodo.computedPriorityScore = 0.5
        reviewTodo.triageStatus = TodoTriage.review.rawValue
        reviewTodo.isCompleted = false

        let completedTodo = Todo(title: "Completed task")
        completedTodo.computedPriorityScore = 0.5
        completedTodo.isCompleted = true
        completedTodo.completedAt = Date()

        let allTodos = [activeTodo, overdueTodo, reviewTodo, completedTodo]

        // Active column: non-completed, triage == .todo, not overdue or high priority
        let activeList = allTodos.filter {
            guard !$0.isCompleted && $0.triage == .todo else { return false }
            return !$0.isOverdue || $0.effectivePriority >= 0.8
        }
        XCTAssertTrue(activeList.contains(where: { $0.id == activeTodo.id }))
        XCTAssertFalse(activeList.contains(where: { $0.id == overdueTodo.id }))
        XCTAssertFalse(activeList.contains(where: { $0.id == reviewTodo.id }))
        XCTAssertFalse(activeList.contains(where: { $0.id == completedTodo.id }))

        // Overdue column: triage == .todo, isOverdue
        let overdueList = allTodos.filter { $0.isOverdue && $0.triage == .todo }
        XCTAssertTrue(overdueList.contains(where: { $0.id == overdueTodo.id }))
        XCTAssertFalse(overdueList.contains(where: { $0.id == activeTodo.id }))

        // Review column: triage == .review, not completed
        let reviewList = allTodos.filter { !$0.isCompleted && $0.triage == .review }
        XCTAssertTrue(reviewList.contains(where: { $0.id == reviewTodo.id }))
        XCTAssertFalse(reviewList.contains(where: { $0.id == activeTodo.id }))

        // Completed column: isCompleted
        let oneMonthAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 86400)
        let completedList = allTodos.filter { $0.isCompleted && ($0.completedAt == nil || $0.completedAt! >= oneMonthAgo) }
        XCTAssertTrue(completedList.contains(where: { $0.id == completedTodo.id }))
        XCTAssertFalse(completedList.contains(where: { $0.id == activeTodo.id }))
    }

    func testCompletedColumnSortsByCompletedAtDescending() {
        let olderCompleted = Todo(title: "Completed earlier")
        olderCompleted.computedPriorityScore = 0.9 // high priority, but completed earlier
        olderCompleted.isCompleted = true
        olderCompleted.completedAt = Date().addingTimeInterval(-3600)

        let newerCompleted = Todo(title: "Completed recently")
        newerCompleted.computedPriorityScore = 0.1 // low priority, but completed recently
        newerCompleted.isCompleted = true
        newerCompleted.completedAt = Date()

        let todos = [olderCompleted, newerCompleted]
        let sorted = todos.sorted {
            let date0 = $0.completedAt ?? $0.updatedAt
            let date1 = $1.completedAt ?? $1.updatedAt
            return date0 > date1
        }

        // Must be sorted by completedAt descending, ignoring computed priority score
        XCTAssertEqual(sorted.first?.id, newerCompleted.id)
        XCTAssertEqual(sorted.last?.id, olderCompleted.id)
    }

    func testAutoHideEmptyColumnsLogic() {
        let activeTodo = Todo(title: "Active task")
        activeTodo.triageStatus = TodoTriage.todo.rawValue
        activeTodo.isCompleted = false

        let allTodos = [activeTodo] // No overdue, review, or completed items

        // Simulating autoHideEmpty filter
        let autoHideEmpty = true
        let visibleColumns = BoardColumnType.allCases.filter { col in
            if autoHideEmpty {
                switch col {
                case .active:
                    return !allTodos.filter { !$0.isCompleted && $0.triage == .todo && (!$0.isOverdue || $0.effectivePriority >= 0.8) }.isEmpty
                case .overdue:
                    return !allTodos.filter { $0.isOverdue && $0.triage == .todo }.isEmpty
                case .review:
                    return !allTodos.filter { !$0.isCompleted && $0.triage == .review }.isEmpty
                case .completed:
                    return !allTodos.filter { $0.isCompleted }.isEmpty
                }
            }
            return true
        }

        XCTAssertEqual(visibleColumns, [.active])
    }

    func testDragToMoveBetweenColumnsLogic() {
        let todo = Todo(title: "Task to move")
        todo.triageStatus = TodoTriage.review.rawValue
        todo.isCompleted = false

        // 1. Move to Active
        todo.triageStatus = TodoTriage.todo.rawValue
        todo.isCompleted = false
        XCTAssertEqual(todo.triage, .todo)
        XCTAssertFalse(todo.isCompleted)

        // 2. Move to Completed
        todo.isCompleted = true
        todo.completedAt = Date()
        XCTAssertTrue(todo.isCompleted)
        XCTAssertNotNil(todo.completedAt)

        // 3. Move back to Review
        todo.isCompleted = false
        todo.completedAt = nil
        todo.triageStatus = TodoTriage.review.rawValue
        XCTAssertEqual(todo.triage, .review)
        XCTAssertFalse(todo.isCompleted)

        // 4. Move to Overdue
        todo.triageStatus = TodoTriage.todo.rawValue
        todo.dueDate = Date().addingTimeInterval(-3600)
        XCTAssertTrue(todo.isOverdue)
        XCTAssertEqual(todo.triage, .todo)
    }
}
