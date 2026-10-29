import XCTest

@MainActor
final class SettingsIntegrationSmokeUITests: SIFTUITestCase {

    #if !targetEnvironment(macCatalyst)
    func testToDoSettingsPreserveStatusAndRulesAcrossBackground() throws {
        launch(.init(additionalArguments: ["-ui-test-reset-beta"]))
        openSettings()
        tap(app.buttons["settings.todoRow"], message: "할 일 설정을 열 수 없습니다.")
        let status = app.descendants(matching: .any).matching(identifier: "todo.notifications.status").firstMatch
        require(status, message: "할 일 알림 상태가 없습니다.")

        // No local model was loaded: background cleanup must not initialize Metal.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        require(status, message: "백그라운드에서 돌아온 뒤 할 일 설정이 유지되지 않았습니다.")
        tap(app.buttons["todo.priority.rules.row"], message: "복귀 후 우선순위 규칙을 열 수 없습니다.")
        tap(app.navigationBars.buttons.firstMatch, message: "할 일 설정으로 돌아갈 수 없습니다.")
        require(status, message: "규칙 확인 후 알림 상태가 사라졌습니다.")
    }
    #endif

    func testCalendarOptInAndDestinationPersistInActualUI() throws {
        launch()
        openSettings()
        tap(app.buttons["캘린더 설정"], message: "캘린더 설정을 열 수 없습니다.")
        let automatic = app.switches["calendar.autoRegister.toggle"]
        requireHittable(automatic, message: "자동 등록 설정이 없습니다.")
        if automatic.value as? String == "1" {
            tapCalendarToggle(automatic)
        }
        XCTAssertEqual(automatic.value as? String, "0")
        tapCalendarToggle(automatic)
        XCTAssertEqual(automatic.value as? String, "1")
        tap(app.navigationBars.buttons.firstMatch, message: "설정으로 돌아갈 수 없습니다.")
        tap(app.buttons["캘린더 설정"], message: "캘린더 설정을 다시 열 수 없습니다.")
        XCTAssertEqual(app.switches["calendar.autoRegister.toggle"].value as? String, "1")
        requireHittable(app.buttons["calendar.destination.row"], message: "등록 대상 선택을 화면에 표시할 수 없습니다.")
        tap(app.buttons["calendar.destination.row"], message: "등록 대상 선택을 열 수 없습니다.")
        tap(app.buttons["calendar.picker.systemDefault"], message: "시스템 기본값을 명시적으로 선택할 수 없습니다.")
        tap(app.navigationBars.buttons.firstMatch, message: "캘린더 설정으로 돌아갈 수 없습니다.")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Calendar consent and explicit destination"
        attachment.lifetime = .keepAlways
        add(attachment)
        tapCalendarToggle(app.switches["calendar.autoRegister.toggle"])
        XCTAssertEqual(app.switches["calendar.autoRegister.toggle"].value as? String, "0")
    }

    private func tapCalendarToggle(_ toggle: XCUIElement) {
        func hasVisibleTapTarget() -> Bool {
            guard toggle.exists, toggle.isHittable else { return false }
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            return toggle.frame.midY > top && toggle.frame.midY < app.frame.maxY - 32
        }
        // A visible label can be hittable while the switch thumb is behind the navigation bar.
        for _ in 0..<16 where !hasVisibleTapTarget() {
            let above = !toggle.exists || toggle.frame.midY < app.navigationBars.firstMatch.frame.maxY + 8
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: above ? 0.45 : 0.7))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: above ? 0.7 : 0.45)))
        }
        require(toggle, message: "자동 등록 동의를 찾을 수 없습니다.")
        XCTAssertTrue(hasVisibleTapTarget(), "자동 등록 스위치의 실제 탭 지점이 가려져 있습니다.")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    func testHealthRequiresSeparateTaskCreationConsent() throws {
        launch()
        openSettings()
        tap(app.buttons["settings.routinesRow"], message: "루틴 설정을 열 수 없습니다.")
        tap(app.buttons["routines.healthRow"], message: "건강 기록 설정을 열 수 없습니다.")
        require(app.buttons["health.connect.workout"], message: "운동 기록의 독립 연결 동작이 없습니다.")
        require(app.buttons["health.connect.medication"], message: "복약 기록의 독립 연결 동작이 없습니다.")
        let automatic = app.switches["health.autoCreate"]
        requireHittable(automatic, message: "독립 자동 생성 동의가 없습니다.")
        XCTAssertEqual(automatic.value as? String, "0")
        automatic.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        require(app.buttons["자동 생성 허용"], message: "생성된 할 일의 동기화 고지가 없습니다.")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Health automatic creation sync disclosure"
        attachment.lifetime = .keepAlways
        add(attachment)
        tap(app.buttons["취소"], message: "건강 자동 생성 동의를 취소할 수 없습니다.")
        XCTAssertEqual(automatic.value as? String, "0")
    }

    func testRealHealthKitPermissionAndEmptyHistorySurface() throws {
        launch()
        openSettings()
        tap(app.buttons["settings.routinesRow"], message: "루틴 설정을 열 수 없습니다.")
        tap(app.buttons["routines.healthRow"], message: "건강 기록 설정을 열 수 없습니다.")
        let connect = app.buttons["health.connect.workout"]
        requireHittable(connect, message: "운동 기록 연결을 열 수 없습니다.")
        XCTAssertTrue(connect.isEnabled, "시뮬레이터에서 실제 HealthKit 읽기 요청을 사용할 수 없습니다.")
        connect.tap()
        let workoutRead = app.switches["UIA.Health.Read.Workouts.SwitchCell.Switch"]
        if workoutRead.waitForExistence(timeout: 5) {
            if workoutRead.value as? String == "0" { workoutRead.tap() }
            let allow = app.buttons["UIA.Health.Allow.Button"]
            requireHittable(allow, message: "HealthKit 허용 동작이 없습니다.")
            XCTAssertTrue(allow.isEnabled)
            let promptAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            promptAttachment.name = "Real HealthKit read-only authorization surface"
            promptAttachment.lifetime = .keepAlways
            add(promptAttachment)
            allow.tap()
            let limitedHistory = app.staticTexts["Past 30 Days and Future Data"]
            if limitedHistory.waitForExistence(timeout: 5) {
                limitedHistory.tap()
                let historyAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                historyAttachment.name = "HealthKit minimum available history range selection"
                historyAttachment.lifetime = .keepAlways
                add(historyAttachment)
                tap(app.buttons["Allow"], message: "HealthKit 기록 범위 허용을 완료할 수 없습니다.")
            }
        }
        require(app.buttons["health.disconnect.workout"], timeout: 15, message: "읽기 요청 후 연결 상태로 돌아오지 않았습니다.")
        requireHittable(app.staticTexts["health.history.empty.workout"], message: "빈 결과를 권한 허용으로 단정하지 않는 안내가 없습니다.")
        let resultAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        resultAttachment.name = "Actual HealthKit query with ambiguous empty evidence"
        resultAttachment.lifetime = .keepAlways
        add(resultAttachment)
        requireHittable(app.buttons["health.disconnect.workout"], message: "운동 기록 연결 해제를 찾지 못했습니다.")
        tap(app.buttons["health.disconnect.workout"], message: "운동 기록 연결을 해제할 수 없습니다.")
        require(app.buttons["health.connect.workout"], message: "연결 해제 후 읽기 동작이 남았습니다.")
    }
}
