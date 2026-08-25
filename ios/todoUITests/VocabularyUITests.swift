import XCTest

final class VocabularyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication().terminate()
    }

    @MainActor
    func testManualVocabularyTermAppearsInReviewScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(ko)",
            "-AppleLocale", "ko_KR",
            "-pieroot.todo.hasOnboarded", "YES",
            "-pieroot.todo.hasCompletedTutorial", "YES",
            "-pieroot.todo.selectedTab", "0",
            "-ui-test-suppress-crash-prompt"
        ]
        app.launchEnvironment["SIFT_UI_TESTING"] = "1"
        app.launch()

        let settings = app.buttons["todo.settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let vocabulary = app.buttons["settings.vocabularyRow"]
        XCTAssertTrue(vocabulary.waitForExistence(timeout: 10))
        vocabulary.tap()

        let termField = app.textFields["정규 표기"]
        XCTAssertTrue(termField.waitForExistence(timeout: 10))
        termField.tap()
        termField.typeText("쿠버네티스")
        app.buttons["추가"].tap()

        XCTAssertTrue(app.staticTexts["쿠버네티스"].waitForExistence(timeout: 10))
    }
}
