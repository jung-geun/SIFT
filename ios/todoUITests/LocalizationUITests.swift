import XCTest

final class LocalizationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication().terminate()
    }

    private func launchEnglish() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-pieroot.todo.hasOnboarded", "YES",
            "-pieroot.todo.hasCompletedTutorial", "YES",
            "-pieroot.todo.launchBehavior", "lastUsed",
            "-pieroot.todo.selectedTab", "0",
            "-pieroot.todo.uiTestShowAllTabs"
        ]
        app.launch()
        return app
    }

    @MainActor
    func testEnglishTabsAndAddForm() throws {
        let app = launchEnglish()
        XCTAssertTrue(app.tabBars.buttons["To-Dos"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Calendar"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Mail"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Meetings"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Calendar"].tap()
        app.tabBars.buttons["Mail"].tap()


        app.tabBars.buttons["To-Dos"].tap()

        let add = app.buttons["todo.addButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertEqual(add.label, "Add New To-Do")
        add.tap()
        XCTAssertTrue(app.navigationBars["New To-Do"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Title (Required)"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.textFields["Notes (Optional)"].waitForExistence(timeout: 3)
                || app.textViews["Notes (Optional)"].waitForExistence(timeout: 3)
        )
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testEnglishSettingsAndLegalCopy() throws {
        let app = launchEnglish()
        let settings = app.buttons["todo.settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let appInfo = app.buttons["settings.appInfoRow"]
        XCTAssertTrue(appInfo.waitForExistence(timeout: 10))
        appInfo.tap()
        XCTAssertTrue(app.navigationBars["App Info"].waitForExistence(timeout: 10))

        let privacy = app.buttons["Privacy Policy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy Policy"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["View Korean Original Online"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Information collected and purposes"].waitForExistence(timeout: 10))
    }
}
