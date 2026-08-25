import XCTest

final class LocalizationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication().terminate()
    }
    @MainActor
    private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) {
        for _ in 0..<maxSwipes where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        XCTAssertTrue(element.isHittable)
    }


    private func launchEnglish() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(ko)",
            "-AppleLocale", "ko_KR",
            "-pieroot.todo.appLanguageOverride", "en",
            "-pieroot.todo.hasOnboarded", "YES",
            "-pieroot.todo.hasCompletedTutorial", "YES",
            "-pieroot.todo.launchBehavior", "lastUsed",
            "-pieroot.todo.selectedTab", "0",
            "-pieroot.todo.uiTestShowAllTabs",
            "-ui-test-suppress-crash-prompt"
        ]
        app.launch()
        return app
    }

    private func launchSystemKorean() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(ko)",
            "-AppleLocale", "ko_KR",
            "-pieroot.todo.hasOnboarded", "YES",
            "-pieroot.todo.hasCompletedTutorial", "YES",
            "-pieroot.todo.launchBehavior", "lastUsed",
            "-pieroot.todo.selectedTab", "0",
            "-pieroot.todo.uiTestShowAllTabs",
            "-ui-test-suppress-crash-prompt"
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

        let appInfo = app.buttons["settings.appInfoRow"]
        scrollToHittable(appInfo, in: app)
        appInfo.tap()
        XCTAssertTrue(app.navigationBars["App Info"].waitForExistence(timeout: 10))

        let privacy = app.buttons["Privacy Policy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy Policy"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["View Korean Original Online"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Information collected and purposes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Effective date: July 31, 2026"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["1-6. User-consented diagnostic reporting (optional)"].waitForExistence(timeout: 10)
        )
        let excludedDiagnosticData = app.staticTexts
            .matching(NSPredicate(
                format: "label == %@",
                "Excluded: recordings, transcripts, to-dos, email bodies, subjects, and addresses, personas, account identifiers, and authentication tokens."
            ))
            .firstMatch
        XCTAssertTrue(excludedDiagnosticData.waitForExistence(timeout: 10))
    }

    @MainActor
    func testEnglishDiagnosticReportingConsentScreen() throws {
        let app = launchEnglish()
        let settings = app.buttons["todo.settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let appInfo = app.buttons["settings.appInfoRow"]
        scrollToHittable(appInfo, in: app)
        appInfo.tap()

        let diagnostics = app.buttons["appInfo.diagnosticReports"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        diagnostics.tap()
        XCTAssertTrue(app.navigationBars["Error Reports"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Diagnostics and privacy"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["diagnostics.collectionToggle"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testLanguageOverrideCanResetToSystem() throws {
        let app = launchSystemKorean()
        let settings = app.buttons["todo.settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let picker = app.descendants(matching: .any)["settings.languagePicker"]
        scrollToHittable(picker, in: app)
        picker.tap()
        let english = app.buttons["English"]
        XCTAssertTrue(english.waitForExistence(timeout: 10))
        english.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        picker.tap()
        let systemLanguage = app.buttons["System Language"]
        XCTAssertTrue(systemLanguage.waitForExistence(timeout: 10))
        systemLanguage.tap()
        XCTAssertTrue(app.navigationBars["설정"].waitForExistence(timeout: 10))

        app.buttons["닫기"].tap()
        XCTAssertTrue(app.tabBars.buttons["할 일"].waitForExistence(timeout: 10))
    }
}
