import XCTest

@MainActor
final class VocabularyUITests: SIFTUITestCase {
    func testUserCanAddManualVocabularyTerm() throws {
        launch()

        step("사용자 단어 화면 열기") {
            openSettings()
            tap(app.buttons["settings.advanced"], message: "고급 설정을 펼칠 수 없습니다.")
            let row = app.buttons["settings.vocabularyRow"]
            requireHittable(row, message: "사용자 단어 설정 행이 없습니다.")
            row.tap()
        }

        step("단어를 추가하고 목록 반영 확인") {
            let field = app.textFields["정규 표기"]
            tap(field, message: "정규 표기 입력 필드가 없습니다.")
            field.typeText("쿠버네티스")
            tap(app.buttons["추가"], message: "단어 추가 버튼이 없습니다.")
            require(app.staticTexts["쿠버네티스"], message: "추가한 단어가 목록에 나타나지 않습니다.")
        }
    }
}
