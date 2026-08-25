import XCTest

final class AppTutorialUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication().terminate()
    }

    @MainActor
    func testTutorialAutoOpensOnLaunchForExistingUser() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(ko)",
            "-AppleLocale", "ko_KR",
            "-pieroot.todo.hasOnboarded", "YES",
            "-pieroot.todo.hasCompletedTutorial", "NO",
            "-pieroot.todo.launchBehavior", "lastUsed",
            "-pieroot.todo.launchTab", "0",
            "-pieroot.todo.selectedTab", "0",
            "-ui-test-suppress-crash-prompt"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["할 일"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["새 할 일 추가"].waitForExistence(timeout: 10))
        app.terminate()
    }
}
