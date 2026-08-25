import XCTest

final class TodoDetailEditingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication().terminate()
    }

    @MainActor
    func testTitleEditSurvivesSave() throws {
        let app = launchApp()
        let suffix = String(UUID().uuidString.prefix(8))
        let sourceTitle = "Detail Rename Source \(suffix)"
        let targetTitle = "Detail Rename Target \(suffix)"

        createTodo(named: sourceTitle, in: app)
        openTodo(named: sourceTitle, in: app)

        let titleField = app.textFields["todo.detail.titleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        XCTAssertEqual(titleField.value as? String, sourceTitle)
        replaceText(in: titleField, with: targetTitle, app: app)
        app.buttons["todo.detail.saveButton"].tap()

        XCTAssertTrue(todoRow(named: targetTitle, in: app).isHittable)

        openTodo(named: targetTitle, in: app)
        XCTAssertEqual(app.textFields["todo.detail.titleField"].value as? String, targetTitle)
    }

    @MainActor
    func testDetailDeleteRemovesTodo() throws {
        let app = launchApp()
        let title = "Detail Delete \(String(UUID().uuidString.prefix(8)))"

        createTodo(named: title, in: app)
        openTodo(named: title, in: app)

        let deleteButton = app.buttons["todo.detail.deleteButton"]
        scrollToHittable(deleteButton, in: app)
        XCTAssertTrue(deleteButton.isHittable, "Missing detail delete button")
        deleteButton.tap()
        let confirmDeleteButton = app.sheets.buttons["삭제"]
        XCTAssertTrue(confirmDeleteButton.waitForExistence(timeout: 5), "Missing delete confirmation")
        confirmDeleteButton.tap()

        XCTAssertTrue(app.buttons["todo.addButton"].waitForExistence(timeout: 5), "To-do list did not reappear")
        XCTAssertFalse(
            app.staticTexts[title].exists,
            "Deleted to-do remains visible in the active list"
        )
    }

    @MainActor
    func testCancelWithEditsPromptsAndDiscards() throws {
        let app = launchApp()
        let suffix = String(UUID().uuidString.prefix(8))
        let sourceTitle = "Detail Cancel Source \(suffix)"
        let targetTitle = "Detail Cancel Target \(suffix)"

        createTodo(named: sourceTitle, in: app)
        openTodo(named: sourceTitle, in: app)

        replaceText(in: app.textFields["todo.detail.titleField"], with: targetTitle, app: app)
        app.buttons["todo.detail.cancelButton"].tap()
        let discardButton = app.buttons["폐기"]
        XCTAssertTrue(discardButton.waitForExistence(timeout: 5), "Missing discard confirmation")
        discardButton.tap()

        XCTAssertTrue(todoRow(named: sourceTitle, in: app).isHittable)
    }

    @MainActor
    func testDetailCompleteActionMovesTodoToCompleted() throws {
        let app = launchApp()
        let title = "Detail Complete \(String(UUID().uuidString.prefix(8)))"

        createTodo(named: title, in: app)
        openTodo(named: title, in: app)

        let completeButton = app.buttons["todo.detail.completeButton"]
        scrollToHittable(completeButton, in: app)
        XCTAssertTrue(completeButton.isHittable, "Missing detail completion button")
        XCTAssertEqual(completeButton.label, "완료 처리")
        completeButton.tap()
        XCTAssertFalse(
            app.textFields["todo.detail.titleField"].waitForExistence(timeout: 5),
            "Detail view should dismiss after completion"
        )
        XCTAssertTrue(app.buttons["todo.addButton"].waitForExistence(timeout: 5), "To-do list did not reappear")
        let completedFilter = app.buttons["todo.filter.completed"]
        scrollToTop(in: app, until: completedFilter)
        XCTAssertTrue(completedFilter.waitForExistence(timeout: 5), "Missing completed filter")
        completedFilter.tap()
        XCTAssertTrue(todoRow(named: title, in: app).isHittable)
    }

    @MainActor
    func testStartTimeSurvivesSave() throws {
        let app = launchApp()
        let title = "Detail Start Time \(String(UUID().uuidString.prefix(8)))"

        createTodo(named: title, in: app)
        openTodo(named: title, in: app)

        let dueDateToggle = app.switches["마감 시각 설정"]
        XCTAssertTrue(dueDateToggle.waitForExistence(timeout: 5), "Missing deadline toggle")
        dueDateToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()

        XCTAssertTrue(
            app.datePickers.firstMatch.waitForExistence(timeout: 5),
            "Missing deadline date picker after enabling deadline toggle"
        )

        let startDateToggle = app.switches["todo.detail.startDateToggle"]
        scrollFormToHittable(startDateToggle, in: app)
        XCTAssertTrue(startDateToggle.waitForExistence(timeout: 5), "Missing start time toggle")
        startDateToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()

        let startDatePicker = app.datePickers["todo.detail.startDatePicker"]
        scrollFormToHittable(startDatePicker, in: app)
        XCTAssertTrue(startDatePicker.waitForExistence(timeout: 5), "Missing start time picker")

        let saveButton = app.buttons["todo.detail.saveButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Missing detail save button")
        saveButton.tap()

        openTodo(named: title, in: app)

        let reopenedStartDateToggle = app.switches["todo.detail.startDateToggle"]
        XCTAssertTrue(reopenedStartDateToggle.waitForExistence(timeout: 5), "Missing start time toggle after reopen")
        scrollFormToHittable(reopenedStartDateToggle, in: app)
        XCTAssertEqual(reopenedStartDateToggle.value as? String, "1")

        let reopenedStartDatePicker = app.datePickers["todo.detail.startDatePicker"]
        scrollFormToHittable(reopenedStartDatePicker, in: app)
        XCTAssertTrue(reopenedStartDatePicker.exists, "Missing start time picker after reopen")
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(ko)",
            "-AppleLocale", "ko_KR",
            "-pieroot.todo.appLanguageOverride", "ko",
            "-pieroot.todo.hasOnboarded", "YES",
            "-pieroot.todo.hasCompletedTutorial", "YES",
            "-pieroot.todo.iCloudSyncEnabled", "NO",
            "-ui-test-in-memory-store",
            "-pieroot.todo.launchBehavior", "fixed",
            "-pieroot.todo.launchTab", "0",
            "-pieroot.todo.uiTestShowAllTabs",
            "-pieroot.todo.imap.account", "ui-test-fixture@example.com",
            "-ui-test-mail-fixture",
            "-ui-test-suppress-crash-prompt"
        ]
        app.launchEnvironment["SIFT_UI_TESTING"] = "1"
        app.launch()
        return app
    }

    @MainActor
    private func createTodo(named title: String, in app: XCUIApplication) {
        let addButton = app.buttons["todo.addButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), "Missing Todo add button")
        addButton.tap()

        let titleField = app.textFields["제목 (필수)"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Missing add to-do title field")
        titleField.tap()
        titleField.typeText(title)

        let saveButton = app.buttons["todo.add.saveButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Missing add to-do save button")
        saveButton.tap()
        XCTAssertTrue(todoRow(named: title, in: app).isHittable, "Missing created to-do")
    }

    @MainActor
    private func openTodo(named title: String, in app: XCUIApplication) {
        let row = todoRow(named: title, in: app)
        XCTAssertTrue(row.isHittable, "Missing to-do row '\(title)'")
        row.tap()
        XCTAssertTrue(app.textFields["todo.detail.titleField"].waitForExistence(timeout: 10), "Failed to navigate to detail view")
    }

    @MainActor
    private func todoRow(named title: String, in app: XCUIApplication) -> XCUIElement {
        let row = app.staticTexts[title].firstMatch
        let list = app.collectionViews.firstMatch
        for _ in 0..<20 {
            if row.isHittable { return row }
            list.swipeUp()
        }
        return row
    }

    private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.isHittable { return }
            app.swipeUp()
        }
    }

    private func scrollFormToHittable(_ element: XCUIElement, in app: XCUIApplication) {
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5), "Missing detail Form container")
        for _ in 0..<12 {
            if element.isHittable { return }
            form.swipeUp()
        }
    }


    private func scrollToTop(in app: XCUIApplication, until element: XCUIElement) {
        let list = app.collectionViews.firstMatch
        for _ in 0..<12 where !element.exists {
            list.swipeDown()
        }
    }
    private func replaceText(in field: XCUIElement, with replacement: String, app: XCUIApplication) {
        _ = app
        let existingValue = field.value as? String ?? ""
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(existingValue.count, 1)))
        field.typeText(replacement)
    }
}
