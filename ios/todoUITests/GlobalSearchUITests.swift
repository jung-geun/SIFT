import XCTest

final class GlobalSearchUITests: XCTestCase {
    private let todoTitle = "Q3 Contract Review"
    private let mailQuery = "SIFT UI Test Fixture"
    private let mailRowSubject = "SIFT UI Test Fixture — Row 1"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication().terminate()
    }

    @MainActor
    func testGlobalSearchWorkflowAndSourceFiltering() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(ko)",
            "-AppleLocale", "ko_KR",
            "-pieroot.todo.appLanguageOverride", "ko",
            "-pieroot.todo.hasOnboarded", "YES",
            "-pieroot.todo.hasCompletedTutorial", "YES",
            "-pieroot.todo.launchBehavior", "fixed",
            "-pieroot.todo.launchTab", "0",
            "-pieroot.todo.uiTestShowAllTabs",
            "-pieroot.todo.imap.account", "ui-test-fixture@example.com",
            "-ui-test-mail-fixture",
            "-ui-test-suppress-crash-prompt"
        ]
        app.launchEnvironment["SIFT_UI_TESTING"] = "1"
        app.launch()

        XCTAssertFalse(app.tabBars.buttons["검색"].exists, "Search must not occupy a bottom tab")

        // 1. Create a Todo titled "Q3 Contract Review" through real UI
        let addTodoButton = app.buttons["todo.addButton"]
        XCTAssertTrue(addTodoButton.waitForExistence(timeout: 10), "Missing Todo add button")
        addTodoButton.tap()

        let titleTextField = app.textFields["제목 (필수)"]
        if !titleTextField.waitForExistence(timeout: 5) {
            let firstTextField = app.textFields.firstMatch
            XCTAssertTrue(firstTextField.waitForExistence(timeout: 5), "Missing title text field")
            firstTextField.tap()
            firstTextField.typeText(todoTitle)
        } else {
            titleTextField.tap()
            titleTextField.typeText(todoTitle)
        }

        let saveButton = app.navigationBars.buttons["추가"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Missing save button")
        saveButton.tap()

        // Saving may open the detail screen; return to the list before pulling down.
        if app.navigationBars[todoTitle].waitForExistence(timeout: 2) {
            app.navigationBars.buttons.firstMatch.tap()
        }

        let createdTodoItem = app.staticTexts[todoTitle].firstMatch
        XCTAssertTrue(createdTodoItem.waitForExistence(timeout: 10), "Missing created To-do")

        // 2. Pull down once to reveal the native global-search drawer.
        app.swipeDown()

        let searchField = app.searchFields.firstMatch
        if !searchField.waitForExistence(timeout: 3) {
            app.swipeDown()
        }
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Missing pull-down search field")
        searchField.tap()
        searchField.typeText(todoTitle)

        // 4. Locate and open the Todo search result
        let todoResultRow = app.buttons.matching(identifier: "search.result.todo").firstMatch
        if !todoResultRow.waitForExistence(timeout: 10) {
            let todoTextResult = app.staticTexts.matching(identifier: todoTitle).firstMatch
            XCTAssertTrue(todoTextResult.waitForExistence(timeout: 5), "Missing Todo search result for '\(todoTitle)'")
            todoTextResult.tap()
        } else {
            todoResultRow.tap()
        }

        // Verify navigation into TodoDetailView
        let todoDetailTitleField = app.textFields["todo.detail.titleField"]
        XCTAssertTrue(todoDetailTitleField.waitForExistence(timeout: 10), "Failed navigation to TodoDetailView for '\(todoTitle)'")
        XCTAssertEqual(todoDetailTitleField.value as? String, todoTitle)

        // 5. Return to Search and confirm query preservation
        let backButton = app.buttons["todo.detail.cancelButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "Missing cancel button in TodoDetailView")
        backButton.tap()

        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Search field missing after return")
        let preservedQuery = searchField.value as? String ?? ""
        XCTAssertTrue(preservedQuery.contains(todoTitle), "Query should be preserved after returning from TodoDetailView")

        // 6. Clear search field and search for mail fixture
        if searchField.buttons.firstMatch.exists {
            searchField.buttons.firstMatch.tap()
        } else {
            searchField.tap()
            searchField.doubleTap()
            searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: preservedQuery.count))
        }
        searchField.typeText(mailQuery)
        searchField.typeText(XCUIKeyboardKey.return.rawValue)

        // 7. Locate and open the Mail search result
        let mailResultRow = app.buttons.matching(identifier: "search.result.mail").firstMatch
        let mailTextResult = app.staticTexts.matching(identifier: mailRowSubject).firstMatch
        XCTAssertTrue(
            mailResultRow.waitForExistence(timeout: 10) || mailTextResult.waitForExistence(timeout: 5),
            "Missing Mail search result for '\(mailRowSubject)'"
        )
        if mailResultRow.exists {
            mailResultRow.tap()
        } else {
            mailTextResult.tap()
        }

        // The first row tap can dismiss an active native search keyboard on some simulator runtimes.
        let trashButton = app.buttons["mail.detail.trash"]
        if !trashButton.waitForExistence(timeout: 3) {
            XCTAssertTrue(mailTextResult.waitForExistence(timeout: 3), "Mail result disappeared before navigation")
            mailTextResult.tap()
        }
        XCTAssertTrue(trashButton.waitForExistence(timeout: 10), "Failed navigation to MailDetailView (missing mail.detail.trash)")

        // Return to Search via explicit '닫기' button
        let closeButton = app.buttons["닫기"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Missing '닫기' dismiss button in MailDetailView")
        closeButton.tap()

        // 8. Exercise source filter chips using accessibility identifiers and text
        let chipAll = app.buttons["search.scope.all"]
        let chipTodo = app.buttons["search.scope.todo"]
        let chipMail = app.buttons["search.scope.mail"]
        let chipMeeting = app.buttons["search.scope.meeting"]

        XCTAssertTrue(chipAll.waitForExistence(timeout: 5), "Missing scope chip search.scope.all")
        XCTAssertTrue(chipTodo.waitForExistence(timeout: 5), "Missing scope chip search.scope.todo")
        XCTAssertTrue(chipMail.waitForExistence(timeout: 5), "Missing scope chip search.scope.mail")
        XCTAssertTrue(chipMeeting.waitForExistence(timeout: 5), "Missing scope chip search.scope.meeting")

        // Filter by Todo: mail fixture result should disappear
        chipTodo.tap()
        XCTAssertFalse(app.buttons.matching(identifier: "search.result.mail").firstMatch.exists, "Mail result must not appear under Todo scope filter")

        // Filter by Mail: mail result should appear
        chipMail.tap()
        XCTAssertTrue(
            app.buttons.matching(identifier: "search.result.mail").firstMatch.waitForExistence(timeout: 5)
                || app.staticTexts.matching(identifier: mailRowSubject).firstMatch.waitForExistence(timeout: 5),
            "Mail result must appear under Mail scope filter for query '\(mailQuery)'"
        )

        // Filter by Meeting: mail result should disappear
        chipMeeting.tap()
        XCTAssertFalse(app.buttons.matching(identifier: "search.result.mail").firstMatch.exists, "Mail result must not appear under Meeting scope filter")

        // Return to All filter
        chipAll.tap()
    }

    @MainActor
    func testLongPullInvokesCalendarSynchronization() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(ko)",
            "-AppleLocale", "ko_KR",
            "-pieroot.todo.appLanguageOverride", "ko",
            "-pieroot.todo.hasOnboarded", "YES",
            "-pieroot.todo.hasCompletedTutorial", "YES",
            "-pieroot.todo.launchBehavior", "fixed",
            "-pieroot.todo.launchTab", "0",
            "-pieroot.todo.uiTestShowAllTabs",
            "-pieroot.todo.imap.account", "ui-test-fixture@example.com",
            "-ui-test-mail-fixture",
            "-ui-test-observe-todo-refresh",
            "-ui-test-suppress-crash-prompt"
        ]
        app.launchEnvironment["SIFT_UI_TESTING"] = "1"
        app.launch()

        let addTodoButton = app.buttons["todo.addButton"]
        XCTAssertTrue(addTodoButton.waitForExistence(timeout: 10), "Missing To-do screen")

        let completedFilter = app.buttons["todo.filter.completed"]
        XCTAssertTrue(completedFilter.waitForExistence(timeout: 5), "Filters must remain reachable above an empty state")
        completedFilter.tap()

        let refreshMarker = app.staticTexts["todo.refreshObserved"]
        XCTAssertTrue(refreshMarker.waitForExistence(timeout: 5), "Missing refresh test marker")
        let initialRefreshCount = refreshMarker.label

        let pullStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        let pullEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        pullStart.press(forDuration: 0.1, thenDragTo: pullEnd)

        let refreshCountChanged = NSPredicate(format: "label != %@", initialRefreshCount)
        expectation(for: refreshCountChanged, evaluatedWith: refreshMarker)
        waitForExpectations(timeout: 10)

    }
}
