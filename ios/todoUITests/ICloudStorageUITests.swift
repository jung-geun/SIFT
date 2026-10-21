import XCTest

@MainActor
final class ICloudStorageUITests: SIFTUITestCase {
    func testExpandedStorageRequiresConfirmationAndCancellationPreservesLocalMode() throws {
        for language in [Language.korean, .english] {
            for legacyEnabled in [false, true] {
                launch(.init(language: language, additionalArguments: [
                    "-pieroot.todo.iCloudSyncEnabled", legacyEnabled ? "YES" : "NO",
                    "-pieroot.todo.iCloudFullDataConsentVersion", "0"
                ]))
                openSettings()
                tap(app.buttons["settings.syncRow"], message: "전체 저장 설정을 열 수 없습니다.")
                let toggle = app.switches["settings.sync.full.toggle"]
                requireHittable(toggle, message: "전체 저장 동의 스위치가 없습니다.")
                XCTAssertEqual(toggle.value as? String, "0", "기존의 좁은 범위 동의만으로 메일·녹음을 전송하면 안 됩니다.")
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
                require(app.buttons["settings.sync.full.confirm"], message: "확대된 저장 범위를 명시적으로 확인해야 합니다.")
                let preview = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                preview.name = "Full storage consent \(language.rawValue) legacy=\(legacyEnabled)"
                preview.lifetime = .keepAlways
                add(preview)
                // The native popover has no Cancel row; an outside tap cancels it.
                app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(app.buttons["settings.sync.full.confirm"].waitForNonExistence(timeout: 5),
                              "범위 확인을 취소한 뒤 확인창이 닫혀야 합니다.")
                XCTAssertEqual(toggle.value as? String, "0", "취소 후 전체 저장이 활성화되면 안 됩니다.")
                let restored = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                restored.name = "Local mode preserved \(language.rawValue) legacy=\(legacyEnabled)"
                restored.lifetime = .keepAlways
                add(restored)
                app.terminate()
            }
        }
    }
}
