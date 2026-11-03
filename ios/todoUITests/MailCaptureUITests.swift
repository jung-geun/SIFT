import XCTest

@MainActor
final class MailCaptureUITests: SIFTUITestCase {
    func testPlainEmailSavesAsTodoWithoutInventedDeadline() throws {
        launch(.init(additionalArguments: [
            "-pieroot.todo.imap.account", "ui-test-fixture@example.com",
            "-ui-test-mail-fixture",
            "-pieroot.todo.board.isBoardMode", "NO",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"
        ]))

        step("마감 문구가 없는 로컬 메일 열기") {
            let search = app.searchFields.firstMatch
            tap(search, message: "메일을 찾을 검색 필드가 없습니다.")
            search.typeText("SIFT UI Test Fixture — Row 1")
            search.typeText(XCUIKeyboardKey.return.rawValue)
            tap(app.buttons["search.scope.mail"], message: "메일 검색 범위를 선택할 수 없습니다.")
            tap(app.buttons.matching(identifier: "search.result.mail").firstMatch,
                message: "테스트 메일 검색 결과가 없습니다.")
            require(app.buttons["mail.detail.action.SIFT UI Test Fixture — Review required settings"],
                    message: "본문에서 확인된 처리 필요 항목이 없습니다.")
            let selectedAction = app.buttons["mail.detail.action.SIFT UI Test Fixture — Renew token if needed"]
            requireHittable(selectedAction, message: "선택할 처리 필요 항목까지 스크롤할 수 없습니다.")
            let detail = XCTAttachment(screenshot: app.screenshot())
            detail.name = "Mail detail with selected body action visible"
            detail.lifetime = .keepAlways
            add(detail)
            tap(selectedAction, message: "선택한 처리 필요 항목을 검토할 수 없습니다.")
        }

        step("찾지 못한 마감을 임의로 만들지 않고 저장") {
            let save = app.buttons["mail.register.save"]
            require(save, message: "메일 할 일 저장 버튼이 없습니다.")
            let deadlineToggle = app.switches["mail.register.deadlineToggle"]
            require(deadlineToggle, message: "마감 설정 버튼이 없습니다.")
            XCTAssertTrue(save.waitForExistence(timeout: 10) && save.isEnabled,
                          "본문 분석의 처리 항목을 검토한 뒤 저장할 수 있어야 합니다.")
            XCTAssertEqual(deadlineToggle.value as? String, "0", "마감이 없는 메일에 기한을 임의로 설정했습니다.")
            XCTAssertEqual(
                app.descendants(matching: .any)["mail.register.title"].value as? String,
                "SIFT UI Test Fixture — Renew token if needed",
                "할 일 제목은 메일 제목이 아니라 선택한 처리 필요 항목이어야 합니다."
            )
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
            replaceText(in: search, with: "SIFT UI Test Fixture — Renew token if needed")
            search.typeText(XCUIKeyboardKey.return.rawValue)
            tap(app.buttons["search.scope.todo"], message: "검색 결과를 할 일로 좁힐 수 없습니다.")
            tap(app.buttons.matching(identifier: "search.result.todo").firstMatch,
                message: "저장한 메일 할 일이 검색되지 않습니다.")
            let deadlineToggle = app.switches["마감 시각 설정"]
            require(deadlineToggle, message: "저장한 할 일의 마감 설정을 확인할 수 없습니다.")
            XCTAssertEqual(deadlineToggle.value as? String, "0", "저장된 할 일에 임의의 마감이 생겼습니다.")
        }

        let renamedTitle = "Renamed verified email action"
        step("제목 변경 뒤 삭제와 실행 취소로 처리 항목 식별자를 보존") {
            replaceText(in: app.textFields["todo.detail.titleField"], with: renamedTitle)
            tap(app.buttons["todo.detail.saveButton"], message: "메일 할 일의 새 제목을 저장할 수 없습니다.")
            // Leave the search overlay before swiping the actual list row.
            tap(app.navigationBars["할 일"].buttons["닫기"], message: "할 일 검색을 닫을 수 없습니다.")
            let row = app.cells.containing(.staticText, identifier: renamedTitle).firstMatch
            requireHittable(row, message: "수정한 메일 할 일이 목록에 없습니다.")
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.5))
            start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            tap(app.buttons["삭제"], message: "메일 할 일의 삭제 동작을 실행할 수 없습니다.")
            XCTAssertTrue(row.waitForNonExistence(timeout: 5), "삭제한 할 일이 목록에 남았습니다.")
            app.typeKey("z", modifierFlags: .command)
            require(row, message: "실행 취소로 메일 할 일이 복원되지 않았습니다.")
        }

        step("복원한 할 일은 변경 전 처리 항목의 중복 저장을 막음") {
            let search = app.searchFields.firstMatch
            replaceText(in: search, with: "SIFT UI Test Fixture — Row 1")
            search.typeText(XCUIKeyboardKey.return.rawValue)
            tap(app.buttons["search.scope.mail"], message: "메일 검색 범위를 선택할 수 없습니다.")
            tap(app.buttons.matching(identifier: "search.result.mail").firstMatch,
                message: "원본 메일 검색 결과가 없습니다.")
            let selectedAction = app.buttons["mail.detail.action.SIFT UI Test Fixture — Renew token if needed"]
            requireHittable(selectedAction, message: "원본 처리 항목을 다시 열 수 없습니다.")
            tap(selectedAction, message: "처리 항목의 중복 검토를 열 수 없습니다.")
            require(app.descendants(matching: .any)["mail.register.duplicate"].firstMatch,
                message: "삭제 실행 취소 뒤 원본 처리 항목의 중복 저장이 허용됐습니다.")
            XCTAssertFalse(app.buttons["mail.register.save"].isEnabled)
            let restored = XCTAttachment(screenshot: app.screenshot())
            restored.name = "Renamed email action remains duplicate after deletion undo"
            restored.lifetime = .keepAlways
            add(restored)
        }
    }
}
