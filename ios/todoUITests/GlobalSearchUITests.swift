import XCTest

@MainActor
final class GlobalSearchUITests: SIFTUITestCase {
    private let todoTitle = "Q3 Contract Review"
    private let mailQuery = "SIFT UI Test Fixture"
    private let mailSubject = "SIFT UI Test Fixture — Row 1"

    private func launchSearchFixture() {
        launch(.init(additionalArguments: [
            "-pieroot.todo.board.isBoardMode", "YES",
            "-pieroot.todo.imap.account", "ui-test-fixture@example.com",
            "-ui-test-mail-fixture"
        ]))
    }

    func testSearchFindsCreatedTodoAndPreservesQueryAfterDetail() throws {
        launchSearchFixture()

        step("검색할 할 일 만들기") {
            tap(app.buttons["todo.addButton"], message: "할 일 추가 버튼이 없습니다.")
            let title = app.textFields["todo.add.titleField"]
            tap(title, message: "제목 필드가 없습니다.")
            title.typeText(todoTitle)
            tap(app.buttons["todo.add.saveButton"], message: "할 일 저장 버튼이 없습니다.")
            require(app.staticTexts[todoTitle], message: "검색용 할 일이 생성되지 않았습니다.")
        }

        step("검색 drawer 열고 할 일 찾기") {
            app.swipeDown()
            let search = app.searchFields.firstMatch
            if !search.waitForExistence(timeout: 3) { app.swipeDown() }
            tap(search, message: "검색 필드가 없습니다.")
            search.typeText(todoTitle)
            let result = app.buttons.matching(identifier: "search.result.todo").firstMatch
            tap(result, message: "할 일 검색 결과가 없습니다.")
        }

        step("상세 진입 후 검색어 보존 확인") {
            require(app.textFields["todo.detail.titleField"], message: "할 일 상세로 이동하지 못했습니다.")
            tap(app.buttons["todo.detail.cancelButton"], message: "상세 닫기 버튼이 없습니다.")
            let value = app.searchFields.firstMatch.value as? String ?? ""
            XCTAssertTrue(value.contains(todoTitle))
        }
    }

    func testMailSearchRespectsSourceFilters() throws {
        launchSearchFixture()

        step("메일 fixture 검색") {
            app.swipeDown()
            let search = app.searchFields.firstMatch
            if !search.waitForExistence(timeout: 3) { app.swipeDown() }
            tap(search, message: "검색 필드가 없습니다.")
            search.typeText(mailQuery)
            search.typeText(XCUIKeyboardKey.return.rawValue)
            require(app.staticTexts[mailSubject], message: "메일 fixture 검색 결과가 없습니다.")
        }

        step("할 일/메일 source filter 확인") {
            tap(app.buttons["search.scope.todo"], message: "할 일 filter가 없습니다.")
            XCTAssertFalse(app.staticTexts[mailSubject].exists)
            tap(app.buttons["search.scope.mail"], message: "메일 filter가 없습니다.")
            require(app.staticTexts[mailSubject], message: "메일 filter에서 fixture 결과가 없습니다.")
        }
    }
}
