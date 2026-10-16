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

        step("다시 검토한 뒤 명시적으로 공유 계속") {
            sendReport()
            tap(app.buttons["diagnostics.preview.continue"], message: "공유 계속 버튼이 없습니다.")
            require(deliveryScreen, message: "검토 승인 후 메일 또는 공유 화면이 열리지 않았습니다.")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Approved diagnostic delivery"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    private var deliveryScreen: XCUIElement {
        // UIKit can replace the representable root with its remote share container.
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@",
            ["diagnostics.shareSheet", "diagnostics.mailComposer", "ActivityListView", "ShareSheet.RemoteContainerView"]
        )).firstMatch
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
