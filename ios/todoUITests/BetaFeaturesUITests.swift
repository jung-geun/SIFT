import XCTest

final class BetaFeaturesUITests: XCTestCase {
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


    @MainActor
    func testLegacyAISettingsKeepAFMAsTheDefaultBetaProvider() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(ko)",
            "-AppleLocale", "ko_KR",
            "-pieroot.todo.hasOnboarded", "YES",
            "-pieroot.todo.hasCompletedTutorial", "YES",
            "-pieroot.todo.launchBehavior", "lastUsed",
            "-pieroot.todo.launchTab", "0",
            "-pieroot.todo.selectedTab", "0",
            "-ui-test-reset-beta",
            "-ui-test-seed-legacy-ai",
            "-ui-test-suppress-crash-prompt"
        ]
        app.launch()

        let settings = app.buttons["todo.settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let betaRow = app.buttons["settings.betaFeaturesRow"]
        scrollToHittable(betaRow, in: app)
        betaRow.tap()

        XCTAssertTrue(app.staticTexts["beta.warning"].waitForExistence(timeout: 5))
        let afm = app.switches["beta.foundationModels.toggle"]
        let onDevice = app.switches["beta.onDevice.toggle"]
        let gemini = app.switches["beta.gemini.toggle"]
        let voice = app.switches["beta.voiceProcessing.toggle"]
        scrollToHittable(voice, in: app)
        XCTAssertTrue(afm.exists)
        XCTAssertTrue(onDevice.exists)
        XCTAssertTrue(gemini.exists)
        XCTAssertTrue(voice.exists)
        XCTAssertEqual(afm.value as? String, "1")
        XCTAssertEqual(onDevice.value as? String, "0")
        XCTAssertEqual(gemini.value as? String, "0")
        XCTAssertEqual(voice.value as? String, "0")
    }
}
