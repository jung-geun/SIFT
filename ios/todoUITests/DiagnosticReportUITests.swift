import XCTest

@MainActor
final class DiagnosticReportUITests: SIFTUITestCase {
    func testPreparedReportRequiresReviewAndCancelPreservesLogs() throws {
        launch(.init(
            language: .english,
            additionalArguments: ["-ui-test-seed-diagnostic-report"]
        ))

        step("Error Reports 화면 열기") {
            openSettings()
            let info = app.buttons["settings.appInfoRow"]
            requireHittable(info, message: "App Info 행이 없습니다.")
            info.tap()
            tap(app.buttons["appInfo.diagnosticReports"], message: "Error Reports 행이 없습니다.")
        }

        step("Send는 로컬 검토만 열고 취소는 진단을 유지") {
            sendReport()
            require(app.staticTexts["diagnostics.preview.deviceSummary"], message: "저장 공간·가동 시간 검토가 없습니다.")
            require(app.staticTexts["diagnostics.preview.eventSnapshots"], message: "오류 시점 스냅샷이 없습니다.")
            let payload = app.staticTexts["diagnostics.preview.payload"]
            require(payload, message: "전체 보고서 원문이 없습니다.")
            XCTAssertTrue(payload.label.contains("\"systemUptimeSeconds\""))
            XCTAssertTrue(payload.label.contains("\"availableDiskBytes\""))
            XCTAssertTrue(payload.label.contains("\"events\""))
            XCTAssertFalse(deliveryScreen.exists)
            tap(app.buttons["diagnostics.preview.cancel"], message: "취소 버튼이 없습니다.")
            let send = app.buttons["diagnostics.sendButton"]
            requireHittable(send, message: "취소 후 Send 버튼이 돌아오지 않았습니다.")
            XCTAssertTrue(send.isEnabled, "취소로 로컬 진단이 삭제되었습니다.")
        }

        step("진단 검토 후 로그인 없는 의견 작성 화면 열기") {
            sendReport()
            tap(app.buttons["diagnostics.preview.continue"], message: "의견 작성 계속 버튼이 없습니다.")
            require(deliveryScreen, message: "검토 후 인앱 의견 작성 화면이 열리지 않았습니다.")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Approved diagnostic delivery"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        step("의견 작성 취소 후 같은 진단 검토와 초안 유지") {
            let title = app.textFields["feedback.titleField"]
            replaceText(in: title, with: "Retained diagnostic draft")
            tap(app.buttons["feedback.close"], message: "의견 작성 취소 버튼이 없습니다.")
            require(app.staticTexts["diagnostics.preview.payload"], message: "취소 후 원래 진단 검토로 돌아오지 않았습니다.")
            tap(app.buttons["diagnostics.preview.continue"], message: "같은 의견 작성을 다시 열 수 없습니다.")
            require(deliveryScreen, message: "의견 초안이 돌아오지 않았습니다.")
            XCTAssertEqual(deliveryScreen.value as? String, "Retained diagnostic draft")
            requireHittable(app.buttons["feedback.reviewButton"], message: "보내기 전 검토 버튼이 보이지 않습니다.")
            tap(app.buttons["feedback.reviewButton"], message: "보내기 전 검토 버튼이 없습니다.")
            let consent = app.switches["feedback.consentToggle"]
            requireHittable(consent, message: "명시적 전송 동의가 없습니다.")
            XCTAssertEqual(consent.value as? String, "0")
            tap(app.buttons["feedback.close"], message: "전송 전 취소 버튼이 없습니다.")
            require(app.staticTexts["diagnostics.preview.payload"], message: "검토 취소 후 진단 보고서가 없어졌습니다.")
            tap(app.buttons["diagnostics.preview.continue"], message: "전송 검토를 다시 열 수 없습니다.")
            requireHittable(app.switches["feedback.consentToggle"], message: "보내기 검토 상태가 소실되었습니다.")
            XCTAssertEqual(app.switches["feedback.consentToggle"].value as? String, "0")
        }
    }

    private var deliveryScreen: XCUIElement {
        app.textFields["feedback.titleField"]
    }

    private func sendReport() {
        let send = app.buttons["diagnostics.sendButton"]
        for _ in 0..<4 {
            if send.exists && send.isHittable { break }
            app.swipeUp()
        }
        tap(send, message: "Send 버튼이 없습니다.")
    }
}
