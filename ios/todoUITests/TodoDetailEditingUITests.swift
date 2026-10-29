import XCTest

@MainActor
final class TodoLifecycleUITests: SIFTUITestCase {
    func testCancelDiscardsUnsavedChanges() throws {
        launch(.init(additionalArguments: ["-pieroot.todo.board.isBoardMode", "YES"]))
        let source = "취소 원본"
        let changed = "저장하면 안 됨"

        step("검증용 할 일 만들기") {
            tap(app.buttons["todo.addButton"], message: "할 일 추가 버튼이 없습니다.")
            let title = app.textFields["todo.add.titleField"]
            tap(title, message: "제목 필드가 없습니다.")
            title.typeText(source)
            #if targetEnvironment(macCatalyst)
            assertTrailingEditorActions(prefix: "todo.add")
            #endif
            tap(app.buttons["todo.add.saveButton"], message: "할 일 저장 버튼이 없습니다.")
            require(taskTitle(source), message: "생성한 할 일이 목록에 없습니다.")
        }

        step("수정 후 폐기하기") {
            tap(taskTitle(source), message: "생성한 할 일을 찾지 못했습니다.")
            replaceText(in: app.textFields["todo.detail.titleField"], with: changed)
            #if targetEnvironment(macCatalyst)
            assertTrailingEditorActions(prefix: "todo.detail")
            #endif
            tap(app.buttons["todo.detail.cancelButton"], message: "취소 버튼이 없습니다.")
            tap(app.buttons["폐기"], message: "폐기 확인 버튼이 없습니다.")
            require(taskTitle(source), message: "원래 제목이 보존되지 않았습니다.")
            XCTAssertFalse(taskTitle(changed).exists)
        }
    }

    func testBoardMenuEditsRemainAvailableInListView() throws {
        launch(.init(additionalArguments: [
            "-pieroot.todo.board.showActive", "YES",
            "-pieroot.todo.board.showOverdue", "NO",
            "-pieroot.todo.board.showReview", "NO",
            "-pieroot.todo.board.showCompleted", "YES",
            "-pieroot.todo.board.autoHideEmpty", "NO"
        ]))
        guard app.frame.width >= 700 else {
            throw XCTSkip("Board detail navigation requires an iPad regular-width destination.")
        }
        tap(app.buttons["todo.moreActionsMenu"], message: "보드 보기 메뉴를 열 수 없습니다.")
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "보드 보기")).firstMatch,
            message: "보드 보기로 전환할 수 없습니다.")
        let original = "보드 상세 원본"
        let edited = "보드에서 수정한 할 일"
        let notes = "보드 메뉴에서 저장한 메모"

        step("보드 메뉴에서 기존 상세 편집 화면 열기") {
            tap(app.buttons["todo.addButton"], message: "할 일 추가 버튼이 없습니다.")
            let title = app.textFields["todo.add.titleField"]
            tap(title, message: "제목 필드가 없습니다.")
            title.typeText(original)
            tap(app.buttons["todo.add.saveButton"], message: "할 일 저장 버튼이 없습니다.")
            let card = taskTitle(original)
            require(card, message: "보드에 저장한 할 일이 없습니다.")
            card.press(forDuration: 1.0)
            tap(app.buttons["todo.board.openDetails"], message: "보드 메뉴에서 세부 정보를 열 수 없습니다.")
            replaceText(in: app.textFields["todo.detail.titleField"], with: edited)
            replaceText(in: app.textFields["todo.detail.notesField"], with: notes)
            tap(app.buttons["todo.detail.saveButton"], message: "보드 상세 변경사항을 저장할 수 없습니다.")
        }

        step("카드와 목록에서 동일한 저장 결과 확인") {
            tap(taskTitle(edited), message: "수정한 보드 카드를 열 수 없습니다.")
            XCTAssertEqual(app.textFields["todo.detail.titleField"].value as? String, edited)
            XCTAssertEqual(app.textFields["todo.detail.notesField"].value as? String, notes)
            tap(app.buttons["todo.detail.cancelButton"], message: "상세 화면을 닫을 수 없습니다.")
            tap(app.buttons["todo.moreActionsMenu"], message: "더보기에서 보기 방식을 열 수 없습니다.")
            tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "목록 보기")).firstMatch,
                message: "목록 보기로 전환할 수 없습니다.")
            tap(app.staticTexts[edited], message: "목록에서 수정한 할 일을 열 수 없습니다.")
            XCTAssertEqual(app.textFields["todo.detail.titleField"].value as? String, edited)
            XCTAssertEqual(app.textFields["todo.detail.notesField"].value as? String, notes)
        }
    }

    #if targetEnvironment(macCatalyst)
    private func assertTrailingEditorActions(prefix: String) {
        let cancel = app.buttons["\(prefix).cancelButton"]
        let save = app.buttons["\(prefix).saveButton"]
        require(cancel, message: "취소 버튼이 없습니다.")
        require(save, message: "저장 버튼이 없습니다.")
        XCTAssertEqual(cancel.frame.midY, save.frame.midY, accuracy: 8)
        XCTAssertLessThanOrEqual(cancel.frame.maxX, save.frame.minX + 1)
        XCTAssertLessThanOrEqual(save.frame.minX - cancel.frame.maxX, 44)
    }
    #endif

    private func taskTitle(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }
}
