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
            tap(app.buttons["todo.add.saveButton"], message: "할 일 저장 버튼이 없습니다.")
            require(app.staticTexts[source], message: "생성한 할 일이 목록에 없습니다.")
        }

        step("수정 후 폐기하기") {
            tap(app.staticTexts[source], message: "생성한 할 일을 찾지 못했습니다.")
            replaceText(in: app.textFields["todo.detail.titleField"], with: changed)
            tap(app.buttons["todo.detail.cancelButton"], message: "취소 버튼이 없습니다.")
            tap(app.buttons["폐기"], message: "폐기 확인 버튼이 없습니다.")
            require(app.staticTexts[source], message: "원래 제목이 보존되지 않았습니다.")
            XCTAssertFalse(app.staticTexts[changed].exists)
        }
    }
}
