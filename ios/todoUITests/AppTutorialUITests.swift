import XCTest

@MainActor
final class AppTutorialUITests: SIFTUITestCase {
    func testExistingUserSeesTutorialAtFirstIncompleteStep() throws {
        launch(.init(showsAllTabs: false, hasCompletedTutorial: false))

        step("튜토리얼이 할 일 화면에서 시작하는지 확인") {
            require(app.navigationBars["할 일"], message: "튜토리얼 시작 화면이 할 일 탭이 아닙니다.")
            require(app.staticTexts["새 할 일 추가"], message: "첫 튜토리얼 안내가 없습니다.")
        }
    }

    func testTutorialSettingsStepUsesMoreAndKeepsAddRestricted() throws {
        launch(.init(showsAllTabs: false, hasCompletedTutorial: false))

        step("첫 단계에서는 Add만 허용") {
            let more = app.buttons["todo.moreActionsMenu"]
            require(more, message: "튜토리얼에서 More 메뉴가 없습니다.")
            XCTAssertFalse(more.isEnabled, "설정 단계 전에는 More를 열 수 없어야 합니다.")
            tap(app.buttons["todo.addButton"], message: "튜토리얼에서 Add를 열 수 없습니다.")
            tap(app.navigationBars.buttons["취소"], message: "추가를 취소하고 설정 단계로 이동할 수 없습니다.")
        }

        step("설정 안내에서 More를 통해 실제 Settings 열기") {
            require(app.staticTexts["설정 열기"], message: "설정 단계 안내가 없습니다.")
            require(
                app.staticTexts["우측 상단 더 보기 > 설정을 눌러 나의 페르소나를 확인해보세요."],
                message: "튜토리얼이 More를 통한 설정 경로를 안내하지 않습니다."
            )
            XCTAssertFalse(app.buttons["todo.addButton"].isEnabled, "설정 단계에서는 Add가 제한되어야 합니다.")
            openSettings()
            require(app.buttons["나의 페르소나"], message: "설정의 페르소나 항목에 접근할 수 없습니다.")
            tap(app.navigationBars.buttons["닫기"], message: "튜토리얼 설정을 닫을 수 없습니다.")
            require(app.buttons["todo.moreActionsMenu"], message: "설정을 닫은 뒤 More 메뉴가 없습니다.")
            XCTAssertTrue(app.buttons["todo.moreActionsMenu"].isEnabled)
            XCTAssertFalse(app.buttons["todo.addButton"].isEnabled)
        }
    }
}
