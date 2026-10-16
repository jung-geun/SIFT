import XCTest
import UIKit

@MainActor
final class AdaptiveLayoutUITests: SIFTUITestCase {
    func testMoreOpensSettingsInPortraitAndLandscape() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        launch(.init(language: .english))

        for orientation in [UIDeviceOrientation.portrait, .landscapeRight] {
            rotate(to: orientation)
            step("Open Settings from More in \(orientation.rawValue)") {
                require(app.buttons["todo.addButton"], message: "Add is missing after rotation.")
                openSettings()
                let info = app.buttons["settings.appInfoRow"]
                requireHittable(info, message: "App Info is not accessible after opening Settings.")
                tap(app.navigationBars.buttons["Close"], message: "Settings cannot be closed after rotation.")
                require(app.buttons["todo.moreActionsMenu"], message: "More did not return after closing Settings.")
            }
        }
    }

    func testDraftAndSavedEditsSurviveOrientationChanges() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        launch(.init(additionalArguments: ["-pieroot.todo.board.isBoardMode", "NO"]))

        let originalTitle = "화면 전환 계약 검토"
        let suffix = " 수정"
        step("세로 화면에서 입력한 초안을 가로 화면에서도 보존") {
            tap(app.buttons["todo.addButton"], message: "할 일 추가 버튼이 없습니다.")
            let title = app.textFields["todo.add.titleField"]
            tap(title, message: "제목 입력란이 없습니다.")
            title.typeText(originalTitle)
            attachScreenshot("Portrait draft")
            rotate(to: .landscapeLeft)
            XCTAssertEqual(title.value as? String, originalTitle, "화면 전환으로 초안 제목이 유실됐습니다.")
            XCTAssertTrue(title.isHittable, "가로 화면에서 키보드가 열린 제목 입력란을 사용할 수 없습니다.")
            attachScreenshot("Landscape draft with keyboard")
            tap(app.buttons["todo.add.saveButton"], message: "가로 화면에서 저장 버튼을 누를 수 없습니다.")
        }

        step("저장된 할 일을 세로 화면에서 열고 수정 중 다시 회전") {
            rotate(to: .portrait)
            tap(app.staticTexts[originalTitle], message: "회전 후 저장된 할 일을 열 수 없습니다.")
            let title = app.textFields["todo.detail.titleField"]
            tap(title, message: "상세 제목 입력란이 없습니다.")
            title.typeText(suffix)
            rotate(to: .landscapeRight)
            XCTAssertEqual(title.value as? String, originalTitle + suffix, "회전으로 수정 중인 제목이 유실됐습니다.")
            attachScreenshot("Landscape edited detail")
            tap(app.buttons["todo.detail.saveButton"], message: "가로 화면에서 수정 내용을 저장할 수 없습니다.")
        }

        step("다시 세로 화면에서 저장 결과 확인") {
            rotate(to: .portrait)
            tap(app.staticTexts[originalTitle + suffix], message: "수정한 할 일이 목록에 없습니다.")
            XCTAssertEqual(
                app.textFields["todo.detail.titleField"].value as? String,
                originalTitle + suffix,
                "회전 후 다시 연 상세 화면에 저장한 제목이 없습니다."
            )
            attachScreenshot("Portrait saved detail")
        }
    }

    func testSettingsAndMeetingConsentSurviveOrientationChanges() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        launch(.init(startTab: .meetings))

        let consent = app.switches.containing(NSPredicate(format: "label CONTAINS %@", "녹음 고지")).firstMatch
        let start = app.buttons["meeting.action.startRecording"]
        step("동의하지 않은 상태에서 회전해도 녹음을 시작할 수 없음") {
            requireHittable(consent, message: "녹음 동의 스위치가 없습니다.")
            if consent.value as? String == "1" {
                consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            rotate(to: .landscapeLeft)
            require(start, message: "가로 화면에 녹음 시작 버튼이 없습니다.")
            XCTAssertEqual(consent.value as? String, "0", "회전으로 녹음 동의 상태가 바뀌었습니다.")
            XCTAssertFalse(start.isEnabled, "회전으로 동의 없이 녹음할 수 있게 됐습니다.")
            requireHittable(consent, message: "가로 화면에서 동의 스위치에 접근할 수 없습니다.")
            attachScreenshot("Landscape meeting consent")
            consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            rotate(to: .portrait)
            XCTAssertEqual(consent.value as? String, "1", "회전으로 명시적 동의가 유실됐습니다.")
            XCTAssertTrue(start.isEnabled, "세로 화면에서 동의 후 녹음 시작을 사용할 수 없습니다.")
            attachScreenshot("Portrait meeting controls")
        }

        step("설정 화면을 회전한 뒤에도 앱 정보에 접근") {
            tap(app.buttons.matching(identifier: "checklist").firstMatch, message: "할 일 탭을 선택할 수 없습니다.")
            openSettings()
            rotate(to: .landscapeRight)
            let info = app.buttons["settings.appInfoRow"]
            requireHittable(info, message: "가로 화면에서 앱 정보에 접근할 수 없습니다.")
            attachScreenshot("Landscape settings")
            info.tap()
            rotate(to: .portrait)
            requireHittable(app.buttons["appInfo.diagnosticReports"], message: "회전 후 앱 정보의 진단 보고서에 접근할 수 없습니다.")
            attachScreenshot("Portrait app info")
        }
    }

    private func rotate(to orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let landscape = orientation == .landscapeLeft || orientation == .landscapeRight
        var stableFrame = CGRect.zero
        var stableSince = Date()
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let frame = self.app.windows.firstMatch.frame
                let matchesOrientation = landscape ? frame.width > frame.height : frame.height > frame.width
                guard matchesOrientation else { return false }
                if frame != stableFrame {
                    stableFrame = frame
                    stableSince = Date()
                    return false
                }
                return Date().timeIntervalSince(stableSince) >= 1
            },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, "앱 화면이 요청한 방향으로 전환되지 않았습니다.")
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
