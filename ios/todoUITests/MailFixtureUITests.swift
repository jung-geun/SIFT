import XCTest

final class MailFixtureUITests: XCTestCase {
    private let firstFixtureSubject = "SIFT UI Test Fixture — Row 1"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication().terminate()
    }

    @MainActor
    func testPopulatedMailboxBeginsBelowHeaderWithoutBlankGap() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(ko)",
            "-AppleLocale", "ko_KR",
            "-pieroot.todo.appLanguageOverride", "ko",
            "-pieroot.todo.hasOnboarded", "YES",
            "-pieroot.todo.hasCompletedTutorial", "YES",
            "-pieroot.todo.launchBehavior", "fixed",
            "-pieroot.todo.launchTab", "2",
            "-pieroot.todo.uiTestShowAllTabs",
            "-pieroot.todo.imap.account", "ui-test-fixture@example.com",
            "-ui-test-mail-fixture",
            "-ui-test-suppress-crash-prompt"
        ]
        app.launch()

        let mailboxHeader = app.staticTexts["mail.mailboxHeader"]
        let firstRow = app.staticTexts[firstFixtureSubject]
        XCTAssertTrue(mailboxHeader.waitForExistence(timeout: 30))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        XCTAssertTrue(firstRow.isHittable)
        XCTAssertGreaterThanOrEqual(firstRow.frame.minY, mailboxHeader.frame.maxY)
        XCTAssertLessThan(
            firstRow.frame.minY - mailboxHeader.frame.maxY,
            60,
            "The first inbox row must follow the mailbox header without a blank List row."
        )
    }

    @MainActor
    func testConsecutiveMailDeletesKeepOnlyLatestUndoAction() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(ko)",
            "-AppleLocale", "ko_KR",
            "-pieroot.todo.appLanguageOverride", "ko",
            "-pieroot.todo.hasOnboarded", "YES",
            "-pieroot.todo.hasCompletedTutorial", "YES",
            "-pieroot.todo.launchBehavior", "fixed",
            "-pieroot.todo.launchTab", "2",
            "-pieroot.todo.uiTestShowAllTabs",
            "-pieroot.todo.imap.account", "ui-test-fixture@example.com",
            "-ui-test-mail-fixture",
            "-ui-test-suppress-crash-prompt"
        ]
        app.launch()

        let firstRow = app.staticTexts[firstFixtureSubject]
        let secondRow = app.staticTexts["SIFT UI Test Fixture — Row 2"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 30))
        XCTAssertTrue(secondRow.waitForExistence(timeout: 10))

        deleteMailRow(firstRow, in: app)
        deleteMailRow(secondRow, in: app)

        let undoActions = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "mail.trash.undo.")
        )
        XCTAssertEqual(
            undoActions.count,
            1,
            "Only the most recently deleted mail may be undone"
        )
    }

    @MainActor
    private func deleteMailRow(_ row: XCUIElement, in app: XCUIApplication) {
        row.swipeLeft()
        let deleteButton = app.buttons["삭제"].firstMatch
        let fallbackDeleteButton = app.buttons["Delete"].firstMatch
        if deleteButton.waitForExistence(timeout: 3) {
            deleteButton.tap()
        } else {
            XCTAssertTrue(fallbackDeleteButton.waitForExistence(timeout: 3), "Missing mail delete action")
            fallbackDeleteButton.tap()
        }
    }
}
