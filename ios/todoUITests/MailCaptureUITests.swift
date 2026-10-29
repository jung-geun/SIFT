import XCTest

@MainActor
final class MailCaptureUITests: SIFTUITestCase {
    func testPlainEmailSavesAsTodoWithoutInventedDeadline() throws {
        launch(.init(additionalArguments: [
            "-pieroot.todo.imap.account", "ui-test-fixture@example.com",
            "-ui-test-mail-fixture"
        ]))

        step("마감 문구가 없는 로컬 메일 열기") {
            let search = app.searchFields.firstMatch
            tap(search, message: "메일을 찾을 검색 필드가 없습니다.")
            search.typeText("SIFT UI Test Fixture")
            search.typeText(XCUIKeyboardKey.return.rawValue)
            tap(app.buttons.matching(identifier: "search.result.mail").firstMatch,
                message: "테스트 메일 검색 결과가 없습니다.")
            require(app.descendants(matching: .any)["mail.detail.layaDecision"],
                    message: "Laya의 할 일 후보 표시가 메일 원본과 함께 보이지 않습니다.")
            let detail = XCTAttachment(screenshot: app.screenshot())
            detail.name = "Mail detail with Laya suggestion"
            detail.lifetime = .keepAlways
            add(detail)
            tap(app.buttons["mail.detail.saveTodo"], message: "메일에서 할 일을 저장할 버튼이 없습니다.")
        }

        step("찾지 못한 마감을 임의로 만들지 않고 저장") {
            let save = app.buttons["mail.register.save"]
            require(save, message: "메일 할 일 저장 버튼이 없습니다.")
            let deadlineToggle = app.switches["mail.register.deadlineToggle"]
            require(deadlineToggle, message: "마감 설정 버튼이 없습니다.")
            XCTAssertTrue(save.waitForExistence(timeout: 10) && save.isEnabled,
                          "본문 분석 후 할 일을 저장할 수 있어야 합니다.")
            XCTAssertEqual(deadlineToggle.value as? String, "0", "마감이 없는 메일에 기한을 임의로 설정했습니다.")
            tap(save, message: "마감 없이 할 일을 저장하지 못했습니다.")
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: save)],
                    timeout: 5
                ),
                .completed,
                "저장한 뒤 확인 시트가 닫히지 않았습니다."
            )
        }

        step("저장된 할 일에도 기한이 없는지 확인") {
            tap(app.navigationBars["메일"].buttons["닫기"], message: "메일 상세를 닫을 수 없습니다.")
            let search = app.searchFields.firstMatch
            XCTAssertTrue((search.value as? String ?? "").contains("SIFT UI Test Fixture"))
            tap(app.buttons["search.scope.todo"], message: "검색 결과를 할 일로 좁힐 수 없습니다.")
            tap(app.buttons.matching(identifier: "search.result.todo").firstMatch,
                message: "저장한 메일 할 일이 검색되지 않습니다.")
            let deadlineToggle = app.switches["마감 시각 설정"]
            require(deadlineToggle, message: "저장한 할 일의 마감 설정을 확인할 수 없습니다.")
            XCTAssertEqual(deadlineToggle.value as? String, "0", "저장된 할 일에 임의의 마감이 생겼습니다.")
        }
    }
}
