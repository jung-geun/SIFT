import XCTest

#if !targetEnvironment(macCatalyst)
@MainActor
final class CalendarMobileUITests: SIFTUITestCase {
    func testPinchChangesMonthDensityWithoutOpeningDay() throws {
        XCUIDevice.shared.orientation = .portrait
        var configuration = LaunchConfiguration()
        configuration.language = .english
        configuration.startTab = .calendar
        configuration.additionalArguments = ["-sift-test-ad-free", "-ui-test-reset-beta", "-pieroot.todo.calendarAutoRegister", "NO"]
        launch(configuration)
        if app.frame.width > app.frame.height {
            XCUIDevice.shared.orientation = .landscapeRight
            XCUIDevice.shared.orientation = .portrait
        }
        let back = app.navigationBars.buttons["BackButton"]
        if back.exists { back.tap() }
        let table = app.tables["calendar.continuousWeeks"]
        let hasCalendar = table.waitForExistence(timeout: 10)
        let noPermission = app.descendants(matching: .any)["calendar.permissionUnavailable"].firstMatch
        try XCTSkipIf(!hasCalendar && noPermission.exists,
            "Grant Calendar access through the app's Settings before running the native gesture acceptance.")
        XCTAssertTrue(hasCalendar, "Authorized mobile month calendar must be visible")
        tap(app.buttons["calendar.viewMenu"], message: "Month view menu")
        tap(app.buttons["Stacked"], message: "Stacked month density")
        let day = visibleDate()
        let before = day.frame.height
        table.pinch(withScale: 1.7, velocity: 1)
        XCTAssertTrue(table.exists, "Pinch must not select a date or push Day")
        let expanded = day.frame.height
        XCTAssertGreaterThan(expanded, before, "Spreading must increase month density height")
        attach("Native pinch expanded month")
        table.pinch(withScale: 0.6, velocity: -1)
        XCTAssertTrue(table.exists, "Pinching must stay in Month")
        XCTAssertLessThan(day.frame.height, expanded, "Pinching must reduce month density height")
        attach("Native pinch compact month")
        tap(day, message: "A normal date tap after pinch must still open Day")
        XCTAssertFalse(table.exists, "A normal date tap must leave Month")
        require(app.staticTexts["23"], message: "Day renders its full hourly schedule through 23:00")
        require(app.navigationBars.buttons["BackButton"], message: "Day retains native Back navigation")
    }

    func testDeniedCalendarStaysUnavailableAcrossRotationAndTodayShortcut() throws {
        var configuration = LaunchConfiguration()
        configuration.language = .english
        configuration.startTab = .calendar
        configuration.additionalArguments = ["-sift-test-ad-free", "-ui-test-reset-beta", "-pieroot.todo.calendarAutoRegister", "NO"]
        launch(configuration)
        let unavailable = app.descendants(matching: .any)["calendar.permissionUnavailable"].firstMatch
        let isDenied = unavailable.waitForExistence(timeout: 10)
        try XCTSkipIf(!isDenied && app.tables["calendar.continuousWeeks"].exists,
            "This scenario requires Calendar permission denied for the QA app.")
        XCTAssertTrue(isDenied, "Denied Calendar must show its permission explanation")
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(unavailable.isHittable, "Landscape cannot bypass denial")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(unavailable.isHittable, "Returning to portrait cannot push Day")
        let calendarTab = app.tabBars.buttons["Calendar"]
        tap(calendarTab, message: "Calendar Today shortcut")
        tap(calendarTab, message: "Repeated Calendar Today shortcut")
        XCTAssertTrue(unavailable.isHittable, "Today shortcuts cannot bypass denial")
        XCTAssertFalse(app.navigationBars.buttons["BackButton"].exists,
            "Denied Calendar must remain at its root, not push a day schedule")
        attach("Denied Calendar after rotation and repeated Today")
    }


    private func visibleDate() -> XCUIElement {
        let calendar = Calendar.current
        let today = Date()
        return app.buttons["calendar.day.\(calendar.component(.year, from: today))-\(calendar.component(.month, from: today))-1"]
    }


    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
