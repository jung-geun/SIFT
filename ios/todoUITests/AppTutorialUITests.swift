import XCTest

@MainActor
final class AppTutorialUITests: SIFTUITestCase {
    func testExistingUserSeesTutorialAtFirstIncompleteStep() throws {
        launch(.init(showsAllTabs: false, hasCompletedTutorial: false))

        step("튜토리얼이 할 일 화면에서 시작하는지 확인") {
            require(app.navigationBars["할 일"], message: "튜토리얼 시작 화면이 할 일 탭이 아닙니다.")
            require(app.staticTexts["새 할 일 추가"], message: "첫 튜토리얼 안내가 없습니다.")
            let hint = app.staticTexts["새 할 일 추가"]
            let addButton = app.buttons["todo.addButton"]
            require(addButton, message: "튜토리얼의 실제 추가 버튼이 없습니다.")
            XCTAssertLessThan(
                abs(hint.frame.midY - addButton.frame.midY), 240,
                "추가 안내가 대상 버튼에서 멀리 떨어져 있습니다."
            )
        }
    }

    func testInlineTutorialKeepsFieldsReachableAndSavesEnteredText() throws {
        launch(.init(showsAllTabs: false, hasCompletedTutorial: false))
        let taskTitle = "Tutorial field placement"
        let notesText = "Keep this complete note"
        tap(app.buttons["todo.addButton"], message: "안내 중 실제 추가 버튼이 막혔습니다.")

        let hint = app.descendants(matching: .any).matching(identifier: "tutorial.hint").firstMatch
        let title = app.textFields["todo.add.titleField"]
        require(hint, message: "입력란에 연결된 안내가 없습니다.")
        require(title, message: "제목 입력란이 없습니다.")
        XCTAssertLessThanOrEqual(hint.frame.maxY, title.frame.minY + 1)
        XCTAssertLessThan(title.frame.minY - hint.frame.maxY, 32)
        tap(title, message: "안내가 제목 입력을 막습니다.")
        title.typeText(taskTitle)
        let notes = app.textFields["todo.add.notesField"]
        tap(notes, message: "안내가 메모 입력을 막습니다.")
        notes.typeText(notesText)
        XCTAssertEqual(notes.value as? String, notesText, "단계 전환이 입력 중인 메모를 끊었습니다.")

        let dismissKeyboard = app.buttons["todo.add.dismissKeyboard"]
        if dismissKeyboard.exists { tap(dismissKeyboard, message: "키보드를 닫을 수 없습니다.") }
        let due = app.switches["todo.add.dueDateToggle"]
        requireHittable(due, message: "마감 안내의 실제 스위치에 접근할 수 없습니다.")
        due.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        // Advancing guidance scrolls to priority; the prior row is then virtualized.
        let form = app.descendants(matching: .any)["todo.add.form"].firstMatch
        for _ in 0..<4 where !due.isHittable { form.swipeDown() }
        require(due, message: "마감 행을 다시 표시할 수 없습니다.")
        XCTAssertEqual(due.value as? String, "1", "실제 마감 스위치가 켜지지 않았습니다.")
        let automatic = app.buttons["todo.add.priority.automatic"]
        requireHittable(automatic, in: form, message: "우선순위 안내의 실제 항목에 접근할 수 없습니다.")
        XCTAssertTrue(app.buttons["tutorial.next"].isHittable, "우선순위 안내가 스크롤 영역 위로 잘렸습니다.")
        automatic.tap()
        tap(app.buttons["todo.add.saveButton"], message: "저장 안내가 실제 저장 버튼을 막습니다.")
        require(app.staticTexts[taskTitle], message: "튜토리얼 중 저장한 할 일이 없습니다.")
    }

    func testOptionalTabTutorialsStayBelowNavigationBars() throws {
        launch(.init(showsAllTabs: true, hasCompletedTutorial: false))
        tap(app.buttons["todo.addButton"], message: "튜토리얼 추가 화면을 열 수 없습니다.")
        tap(app.buttons["todo.add.cancelButton"], message: "추가 화면을 닫을 수 없습니다.")
        openSettings()
        let persona = app.buttons["나의 페르소나"]
        requireHittable(persona, message: "페르소나 안내의 실제 항목에 접근할 수 없습니다.")
        tap(persona, message: "페르소나 안내의 실제 항목을 열 수 없습니다.")
        tap(app.navigationBars["나의 페르소나"].buttons.firstMatch, message: "페르소나에서 돌아갈 수 없습니다.")
        let todoSettings = app.buttons["settings.todoRow"]
        let revealedSettings = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: todoSettings
        )
        XCTAssertEqual(XCTWaiter.wait(for: [revealedSettings], timeout: 10), .completed,
            "페르소나에서 돌아온 후 다음 안내 대상이 표시되지 않았습니다.")
        tap(app.buttons["settings.todoRow"], message: "할 일 설정을 열 수 없습니다.")
        let rules = app.buttons["todo.priority.rules.row"]
        requireHittable(rules, message: "우선순위 규칙에 접근할 수 없습니다.")
        tap(rules, message: "우선순위 규칙을 열 수 없습니다.")
        tap(app.navigationBars["TODO 우선순위 규칙"].buttons.firstMatch, message: "규칙에서 돌아갈 수 없습니다.")
        tap(app.navigationBars["할 일 설정"].buttons.firstMatch, message: "설정으로 돌아갈 수 없습니다.")
        tap(app.buttons["이메일 연동"], message: "이메일 안내의 실제 항목을 열 수 없습니다.")
        tap(app.navigationBars["이메일 연동"].buttons.firstMatch, message: "이메일 설정에서 돌아갈 수 없습니다.")
        tap(app.buttons["settings.todoRow"], message: "알림 안내의 할 일 설정을 열 수 없습니다.")
        require(app.descendants(matching: .any)["todo.notifications.status"].firstMatch,
            message: "할 일 설정의 알림 상태가 없습니다.")
        tap(app.navigationBars["할 일 설정"].buttons.firstMatch, message: "알림 확인 후 돌아갈 수 없습니다.")
        tap(app.buttons["settings.closeButton"], message: "설정을 닫을 수 없습니다.")

        for (tab, title) in [("캘린더", "캘린더 확인"), ("메일", "메일 확인")] {
            tap(app.tabBars.buttons[tab], message: "선택형 탭을 열 수 없습니다: \(tab)")
            let hint = app.descendants(matching: .any).matching(identifier: "tutorial.hint")
                .containing(.staticText, identifier: title).firstMatch
            require(hint, message: "실제 탭의 튜토리얼 안내가 없습니다: \(tab)")
            XCTAssertGreaterThanOrEqual(hint.frame.minY, app.navigationBars.firstMatch.frame.maxY - 1,
                "튜토리얼 안내가 탐색 막대 위에 놓였습니다: \(tab)")
            XCTAssertLessThan(hint.frame.maxY, app.tabBars.firstMatch.frame.minY)
            tap(app.tabBars.buttons["할 일"], message: "선택형 화면에서 할 일로 돌아갈 수 없습니다.")
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
