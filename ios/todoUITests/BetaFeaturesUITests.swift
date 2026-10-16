import XCTest

@MainActor
final class BetaFeaturesUITests: SIFTUITestCase {
    func testLegacySettingsNormalizeToSafeBetaDefaults() throws {
        launch(.init(additionalArguments: ["-ui-test-reset-beta", "-ui-test-seed-legacy-ai"]))

        step("설정에서 베타 기능 열기") {
            openSettings()
            tap(app.buttons["settings.advanced"], message: "고급 설정을 펼칠 수 없습니다.")
            let row = app.buttons["settings.betaFeaturesRow"]
            requireHittable(row, message: "베타 기능 설정 행이 없습니다.")
            row.tap()
        }

        step("안전한 기본 provider 상태 확인") {
            require(app.staticTexts["beta.warning"], message: "베타 기능 경고가 없습니다.")
            XCTAssertEqual(app.switches["beta.foundationModels.toggle"].value as? String, "1")
            XCTAssertEqual(app.switches["beta.onDevice.toggle"].value as? String, "0")
            XCTAssertEqual(app.switches["beta.openAI.toggle"].value as? String, "0")
        }

        step("오프라인 전사 동의와 모델 설치는 별도 동작") {
            let auto = app.switches["beta.whisper.auto"]
            if !auto.isHittable { app.swipeUp() }
            requireHittable(auto, message: "오프라인 전사 동의 스위치가 없습니다.")
            XCTAssertEqual(auto.value as? String, "0")
            auto.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            XCTAssertEqual(auto.value as? String, "1")
            let install = app.buttons["beta.whisper.download"]
            if !install.isHittable { app.swipeUp() }
            requireHittable(install, message: "모델 설치가 동의 스위치와 별도로 제공되지 않습니다.")
            XCTAssertFalse(app.buttons["beta.whisper.delete"].exists)
        }
    }
}
