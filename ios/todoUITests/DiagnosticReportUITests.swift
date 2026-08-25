import XCTest

final class DiagnosticReportUITests: XCTestCase {
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
    func testDiagnosticReportSendPresentsExportSheetOnFirstTap() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-pieroot.todo.appLanguageOverride", "en",
            "-pieroot.todo.hasOnboarded", "YES",
            "-pieroot.todo.hasCompletedTutorial", "YES",
            "-pieroot.todo.launchBehavior", "lastUsed",
            "-pieroot.todo.selectedTab", "0",
            "-ui-test-seed-diagnostic-report",
            "-ui-test-suppress-crash-prompt"
        ]
        app.launch()

        let settings = app.buttons["todo.settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let appInfo = app.buttons["settings.appInfoRow"]
        scrollToHittable(appInfo, in: app)
        appInfo.tap()

        let diagnostics = app.buttons["appInfo.diagnosticReports"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        diagnostics.tap()

        let send = app.buttons["diagnostics.sendButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertTrue(send.isEnabled)
        send.tap()

        XCTAssertTrue(
            app.buttons["header.closeButton"].waitForExistence(timeout: 10),
            "The first Send tap must present the native report share sheet."
        )
    }
}
