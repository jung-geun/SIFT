import XCTest

@MainActor
final class TodoCaptureUITests: SIFTUITestCase {
    func testDismissingUnsubmittedDraftDoesNotCreateTodo() throws {
        launch()

        let draftTitle = "미완성 계약 검토"
        step("할 일 초안 입력 후 시트 닫기") {
            tap(app.buttons["todo.addButton"], message: "할 일 추가 버튼이 없습니다.")
            let title = app.textFields["todo.add.titleField"]
            tap(title, message: "제목 입력란이 없습니다.")
            title.typeText(draftTitle)

            let sheetBar = app.navigationBars["새 할 일"]
            require(sheetBar, message: "새 할 일 시트가 열리지 않았습니다.")
            sheetBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(
                    forDuration: 0.1,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                )
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)],
                    timeout: 2
                ),
                .completed,
                "아래로 스와이프해도 초안 시트가 닫히지 않았습니다."
            )
        }

        step("명시적으로 저장하지 않은 초안이 목록에 나타나지 않음") {
            XCTAssertFalse(app.staticTexts[draftTitle].waitForExistence(timeout: 3), "저장하지 않은 초안이 할 일로 생성됐습니다.")
        }
    }

    func testExplicitSaveAddsUndatedTodoToHome() throws {
        launch(.init(additionalArguments: ["-pieroot.todo.board.isBoardMode", "YES"]))

        let taskTitle = "신규 계약 검토"
        step("기본 입력란에서 저장") {
            tap(app.buttons["todo.addButton"], message: "할 일 추가 버튼이 없습니다.")
            let title = app.textFields["todo.add.titleField"]
            tap(title, message: "제목 입력란이 없습니다.")
            title.typeText(taskTitle)
            tap(app.buttons["todo.add.saveButton"], message: "할 일 저장 버튼이 없습니다.")
        }

        step("기한을 강제하지 않고 진행중 목록에 표시") {
            let rowTitle = app.staticTexts[taskTitle]
            tap(rowTitle, message: "저장한 할 일이 목록에 나타나지 않았습니다.")
            let deadlineToggle = app.switches["마감 시각 설정"]
            require(deadlineToggle, message: "할 일 상세에서 기한을 확인할 수 없습니다.")
            XCTAssertEqual(deadlineToggle.value as? String, "0", "수동 할 일에 기한이 강제로 추가됐습니다.")
        }
    }

    func testExpandedOptionsWithKeyboard() throws {
        try exerciseExpandedOptions()
    }

    func testExpandedOptionsWithKeyboardInLandscape() throws {
        try exerciseExpandedOptions(landscape: true)
    }

    func testExpandedOptionsWithKeyboardAtAccessibilityTextSize() throws {
        try exerciseExpandedOptions(accessibilityTextSize: true)
    }

    func testCancellingExpandedDraftDoesNotCreateTodo() throws {
        launch()
        let draftTitle = "추가 옵션 취소 검증"
        tap(app.buttons["todo.addButton"], message: "할 일 추가 버튼이 없습니다.")
        let title = app.textFields["todo.add.titleField"]
        tap(title, message: "제목 입력란이 없습니다.")
        title.typeText(draftTitle)
        tap(app.buttons["todo.add.dismissKeyboard"], message: "키보드 닫기 버튼이 없습니다.")
        tap(app.buttons["todo.add.moreOptions"], message: "추가 옵션이 없습니다.")
        let form = app.descendants(matching: .any)["todo.add.form"].firstMatch
        let tags = app.textFields["todo.add.tagsField"]
        requireHittable(tags, in: form, message: "태그 입력란에 접근할 수 없습니다.")
        tags.tap()
        tags.typeText("저장하지 않음")
        tap(app.navigationBars["새 할 일"].buttons["취소"], message: "취소 버튼이 없습니다.")
        XCTAssertFalse(title.exists)
        XCTAssertFalse(app.staticTexts[draftTitle].waitForExistence(timeout: 3), "취소한 초안이 저장됐습니다.")
    }

    private func exerciseExpandedOptions(
        landscape: Bool = false,
        accessibilityTextSize: Bool = false
    ) throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        var arguments = ["-pieroot.todo.board.isBoardMode", "NO"]
        if accessibilityTextSize {
            arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        launch(.init(additionalArguments: arguments))
        let taskTitle = "추가 옵션 키보드 검증"
        tap(app.buttons["todo.addButton"], message: "할 일 추가 버튼이 없습니다.")
        let title = app.textFields["todo.add.titleField"]
        tap(title, message: "제목 입력란이 없습니다.")
        title.typeText(taskTitle)
        tap(app.buttons["todo.add.dismissKeyboard"], message: "키보드 닫기 버튼이 없습니다.")

        if landscape {
            XCUIDevice.shared.orientation = .landscapeLeft
            let rotated = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    let frame = self.app.windows.firstMatch.frame
                    return frame.width > frame.height
                },
                object: app
            )
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed)
        }

        let form = app.descendants(matching: .any)["todo.add.form"].firstMatch
        let dueDate = app.switches["todo.add.dueDateToggle"]
        requireHittable(dueDate, in: form, message: "마감 설정에 접근할 수 없습니다.")
        dueDate.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(dueDate.value as? String, "1", "마감 설정이 활성화되지 않았습니다.")
        let moreOptions = app.buttons["todo.add.moreOptions"]
        requireHittable(moreOptions, in: form, message: "추가 옵션에 접근할 수 없습니다.")
        moreOptions.tap()

        step("펼친 우선순위와 알림에 접근") {
            let automaticPriority = app.buttons["todo.add.priority.automatic"]
            revealExpandedControl(automaticPriority, in: form, message: "우선순위에 접근할 수 없습니다.")
            automaticPriority.tap()
            let reminder = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "todo.add.reminder.")).firstMatch
            revealExpandedControl(reminder, in: form, message: "알림에 접근할 수 없습니다.")
            reminder.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(reminder.value as? String, "1")
        }

        let tags = app.textFields["todo.add.tagsField"]
        revealExpandedControl(tags, in: form, message: "태그 입력란에 접근할 수 없습니다.")
        tags.tap()
        tags.typeText("회귀검증,키보드")
        let save = app.buttons["todo.add.saveButton"]
        let keyboard = app.keyboards.firstMatch
        step("키보드 위에서 태그와 저장 버튼이 겹치지 않음") {
            require(keyboard, message: "소프트웨어 키보드가 표시되지 않았습니다.")
            let unobscured = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    tags.isHittable && save.isHittable
                        && !tags.frame.intersects(save.frame)
                        && tags.frame.maxY <= keyboard.frame.minY
                        && save.frame.maxY <= keyboard.frame.minY
                },
                object: app
            )
            XCTAssertEqual(XCTWaiter.wait(for: [unobscured], timeout: 5), .completed, "입력란 또는 저장 버튼이 키보드/서로에 가려졌습니다.")
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Expanded task options - landscape=\(landscape) accessibility=\(accessibilityTextSize)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        step("스크롤로 키보드를 닫아도 저장하지 않음") {
            form.swipeDown()
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
            XCTAssertTrue(save.exists, "키보드를 닫는 동작이 초안을 저장하거나 닫았습니다.")
            requireHittable(tags, in: form, message: "키보드를 닫은 후 태그에 접근할 수 없습니다.")
            tags.tap()
            require(keyboard, message: "태그 편집 키보드가 표시되지 않았습니다.")
        }

        step("키보드가 열린 상태에서 명시적으로 저장") {
            tap(save, message: "키보드 위의 저장 버튼을 누를 수 없습니다.")
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
            require(app.staticTexts[taskTitle], message: "명시적으로 저장한 할 일이 없습니다.")
        }
    }

    private func revealExpandedControl(_ element: XCUIElement, in form: XCUIElement, message: String) {
        // Full-height swipes can skip a short row entirely in landscape.
        for _ in 0..<16 where !element.isHittable {
            let above = element.exists && element.frame.maxY < app.navigationBars["새 할 일"].frame.maxY
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: above ? 0.45 : 0.7))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: above ? 0.7 : 0.45)))
        }
        require(element, message: message)
        XCTAssertTrue(element.isHittable, message)
    }

}
