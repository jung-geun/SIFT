import XCTest

@MainActor
final class TodoSwipeActionsUITests: SIFTUITestCase {
    private enum SwipeDirection {
        case leading
        case trailing
    }

    private func launchList() {
        launch(.init(additionalArguments: ["-pieroot.todo.board.isBoardMode", "NO"]))
    }

    private func addTodo(_ title: String) -> XCUIElement {
        tap(app.buttons["todo.addButton"], message: "할 일 추가 버튼이 없습니다.")
        let field = app.textFields["todo.add.titleField"]
        tap(field, message: "제목 필드가 없습니다.")
        field.typeText(title)
        tap(app.buttons["todo.add.saveButton"], message: "할 일 저장 버튼이 없습니다.")
        let row = todoRow(title)
        require(row, message: "검증용 할 일이 목록에 없습니다.")
        return row
    }

    private func todoRow(_ title: String) -> XCUIElement {
        app.cells.containing(.staticText, identifier: title).firstMatch
    }

    private var completeAction: XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "완료", "todo.filter.completed"
        )).firstMatch
    }

    private func swipe(_ row: XCUIElement, toward direction: SwipeDirection, full: Bool = false) {
        let start: CGFloat = direction == .trailing ? 0.85 : 0.15
        let partialDistance = min(0.37, 140 / max(row.frame.width, 1))
        let end: CGFloat
        if direction == .trailing {
            end = full ? 0.03 : start - partialDistance
        } else {
            end = full ? 0.97 : start + partialDistance
        }
        let from = row.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5))
        let to = row.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5))
        from.press(forDuration: 0.2, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    private func createReviewRow(_ title: String) throws -> XCUIElement {
        launch(.init(additionalArguments: [
            "-pieroot.todo.board.showActive", "YES",
            "-pieroot.todo.board.showReview", "YES",
            "-pieroot.todo.board.showOverdue", "NO",
            "-pieroot.todo.board.showCompleted", "NO",
            "-pieroot.todo.board.autoHideEmpty", "NO"
        ]))
        guard app.frame.width >= 700 else {
            throw XCTSkip("Review queue is created by dragging between iPad board columns.")
        }
        if !app.staticTexts["항목 없음"].firstMatch.exists {
            tap(app.buttons["todo.moreActionsMenu"], message: "더보기에서 보드 보기 설정을 열 수 없습니다.")
            tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "보드 보기")).firstMatch,
                message: "보드 보기로 전환할 수 없습니다.")
        }

        step("보드에서 할 일을 등록 대기열로 옮기기") {
            tap(app.buttons["todo.addButton"], message: "할 일 추가 버튼이 없습니다.")
            let field = app.textFields["todo.add.titleField"]
            tap(field, message: "제목 필드가 없습니다.")
            field.typeText(title)
            tap(app.buttons["todo.add.saveButton"], message: "추가 버튼이 없습니다.")
            let card = app.buttons[title]
            require(card, message: "보드에 생성한 할 일이 없습니다.")
            let reviewColumn = app.staticTexts["항목 없음"].firstMatch
            require(reviewColumn, message: "등록 대기열 드롭 영역을 찾지 못했습니다.")
            card.press(forDuration: 1.0, thenDragTo: reviewColumn, withVelocity: .slow, thenHoldForDuration: 0.5)
            tap(app.buttons["todo.moreActionsMenu"], message: "더보기에서 보기 방식을 열 수 없습니다.")
            tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "목록 보기")).firstMatch,
                message: "목록 보기로 전환할 수 없습니다.")
            selectFilter("review")
        }
        let row = todoRow(title)
        require(row, message: "보드에서 옮긴 할 일이 등록 대기열에 없습니다.")
        return row
    }

    private func selectFilter(_ identifier: String) {
        let chip = app.buttons["todo.filter.\(identifier)"]
        require(chip, message: "\(identifier) 필터가 없습니다.")
        if !chip.isHittable {
            app.scrollViews.containing(.button, identifier: "todo.filter.\(identifier)").firstMatch.swipeLeft()
        }
        tap(chip, message: "\(identifier) 필터를 선택할 수 없습니다.")
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPartialTrailingSwipeRequiresDeleteButtonTap() {
        launchList()
        let title = "부분 삭제 확인"
        let row = addTodo(title)

        step("부분 스와이프로 삭제 버튼만 표시") {
            swipe(row, toward: .trailing)
            require(row, message: "부분 스와이프만으로 할 일이 삭제되었습니다.")
            require(app.buttons["삭제"], message: "부분 스와이프 후 삭제 버튼이 없습니다.")
            attachScreenshot("부분 스와이프 - 삭제 전")
        }
        step("삭제 버튼을 눌러 삭제") {
            tap(app.buttons["삭제"], message: "삭제 버튼을 누를 수 없습니다.")
            XCTAssertTrue(row.waitForNonExistence(timeout: 5), "삭제 버튼을 눌러도 할 일이 남았습니다.")
            attachScreenshot("삭제 후")
        }
    }

    func testPartialLeadingSwipeRequiresCompleteButtonTap() {
        launchList()
        let title = "부분 완료 확인"
        let row = addTodo(title)

        step("부분 스와이프로 완료 버튼만 표시") {
            swipe(row, toward: .leading)
            require(row, message: "부분 스와이프만으로 할 일이 완료되었습니다.")
            require(completeAction, message: "부분 스와이프 후 완료 버튼이 없습니다.")
            attachScreenshot("부분 스와이프 - 완료 전")
        }
        step("완료 버튼을 눌러 완료 필터에서 확인") {
            tap(completeAction, message: "완료 버튼을 누를 수 없습니다.")
            XCTAssertTrue(row.waitForNonExistence(timeout: 5), "완료 후 진행중 목록에서 사라지지 않았습니다.")
            selectFilter("completed")
            require(todoRow(title), message: "완료 필터에 할 일이 없습니다.")
            attachScreenshot("완료 후")
        }
    }

    func testFullTrailingSwipeDeletesWithoutButtonTap() {
        launchList()
        let row = addTodo("전체 삭제 확인")

        step("전체 왼쪽 스와이프만으로 삭제") {
            swipe(row, toward: .trailing, full: true)
            XCTAssertTrue(row.waitForNonExistence(timeout: 5), "전체 스와이프 후 할 일이 삭제되지 않았습니다.")
            attachScreenshot("전체 스와이프 삭제 후")
        }
    }

    func testFullLeadingSwipeCompletesWithoutButtonTap() {
        launchList()
        let title = "전체 완료 확인"
        let row = addTodo(title)

        step("전체 오른쪽 스와이프만으로 완료") {
            swipe(row, toward: .leading, full: true)
            XCTAssertTrue(row.waitForNonExistence(timeout: 5), "전체 스와이프 후 진행중 할 일이 남았습니다.")
            selectFilter("completed")
            require(todoRow(title), message: "전체 스와이프한 할 일이 완료 필터에 없습니다.")
            attachScreenshot("전체 스와이프 완료 후")
        }
    }

    func testCompletedRowPartialLeadingSwipeRequiresUndoButtonTap() {
        launchList()
        let title = "부분 되돌리기 확인"
        let activeRow = addTodo(title)
        swipe(activeRow, toward: .leading, full: true)
        XCTAssertTrue(activeRow.waitForNonExistence(timeout: 5))
        selectFilter("completed")
        let completedRow = todoRow(title)
        require(completedRow, message: "완료된 할 일이 보이지 않습니다.")

        step("부분 스와이프로 되돌리기 버튼만 표시") {
            swipe(completedRow, toward: .leading)
            require(completedRow, message: "부분 스와이프만으로 완료가 취소되었습니다.")
            require(app.buttons["되돌리기"], message: "부분 스와이프 후 되돌리기 버튼이 없습니다.")
            attachScreenshot("부분 스와이프 - 되돌리기 전")
        }
        step("되돌리기 버튼을 눌러 진행중으로 복귀") {
            tap(app.buttons["되돌리기"], message: "되돌리기 버튼을 누를 수 없습니다.")
            XCTAssertTrue(completedRow.waitForNonExistence(timeout: 5))
            selectFilter("active")
            require(todoRow(title), message: "되돌린 할 일이 진행중 목록에 없습니다.")
            attachScreenshot("되돌리기 후")
        }
    }

    func testSmallDragReverseDragScrollAndTapDoNotMutateTodo() {
        launchList()
        let title = "일반 탐색 확인"
        let row = addTodo(title)

        step("작은 이동과 반대 방향 드래그는 액션을 실행하지 않음") {
            let from = row.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            let to = row.coordinate(withNormalizedOffset: CGVector(dx: 0.64, dy: 0.5))
            from.press(forDuration: 0.2, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
            if app.buttons["todo.detail.cancelButton"].exists {
                tap(app.buttons["todo.detail.cancelButton"], message: "작은 이동으로 열린 상세 화면을 닫을 수 없습니다.")
            }
            require(row, message: "작은 이동으로 할 일이 변경되었습니다.")
            swipe(row, toward: .trailing)
            require(app.buttons["삭제"], message: "삭제 액션이 표시되지 않았습니다.")
            let reverseFrom = row.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
            let reverseTo = row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            reverseFrom.press(forDuration: 0.2, thenDragTo: reverseTo, withVelocity: .slow, thenHoldForDuration: 0.2)
            require(row, message: "반대 방향 드래그로 할 일이 삭제되었습니다.")
            XCTAssertFalse(app.buttons["삭제"].exists, "반대 방향 드래그 후 삭제 액션이 닫히지 않았습니다.")
        }
        step("세로 스크롤 후 일반 탭은 상세로 이동") {
            row.swipeUp()
            require(row, message: "세로 스크롤로 할 일이 변경되었습니다.")
            tap(row, message: "할 일 행을 탭할 수 없습니다.")
            require(app.textFields["todo.detail.titleField"], message: "일반 탭으로 상세 화면이 열리지 않았습니다.")
        }
    }

    func testReviewRowPartialLeadingSwipePromotesAfterButtonTap() throws {
        let title = "대기열 부분 승격 확인"
        let row = try createReviewRow(title)

        step("부분 오른쪽 스와이프는 등록 대기열에서만 버튼 노출") {
            swipe(row, toward: .leading)
            require(row, message: "부분 스와이프로 대기열 항목이 사라졌습니다.")
            require(app.buttons["진행중으로 추가"], message: "대기열의 오른쪽 액션이 진행중으로 추가가 아닙니다.")
            attachScreenshot("대기열 부분 스와이프 - 승격 전")
        }
        step("버튼 탭은 완료가 아닌 진행중으로 이동") {
            tap(app.buttons["진행중으로 추가"], message: "승격 버튼을 누를 수 없습니다.")
            XCTAssertTrue(row.waitForNonExistence(timeout: 5), "승격 후에도 등록 대기열에 남았습니다.")
            selectFilter("active")
            require(todoRow(title), message: "승격한 할 일이 진행중에 없습니다.")
            selectFilter("completed")
            XCTAssertFalse(todoRow(title).exists, "승격한 할 일이 완료로 잘못 처리되었습니다.")
            attachScreenshot("대기열 버튼 승격 후")
        }
    }

    func testReviewRowFullLeadingSwipePromotesWithoutButtonTap() throws {
        let title = "대기열 전체 승격 확인"
        let row = try createReviewRow(title)

        step("전체 오른쪽 스와이프는 바로 진행중으로 이동") {
            swipe(row, toward: .leading, full: true)
            XCTAssertTrue(row.waitForNonExistence(timeout: 5), "전체 스와이프 후에도 등록 대기열에 남았습니다.")
            selectFilter("active")
            require(todoRow(title), message: "전체 스와이프한 할 일이 진행중에 없습니다.")
            selectFilter("completed")
            XCTAssertFalse(todoRow(title).exists, "전체 스와이프로 완료되어서는 안 됩니다.")
            attachScreenshot("대기열 전체 스와이프 승격 후")
        }
    }

}
