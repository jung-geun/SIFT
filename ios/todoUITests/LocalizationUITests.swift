import XCTest

@MainActor
final class LocalizationUITests: SIFTUITestCase {
    func testMoreSettingsNavigationPreservesPrimaryAddAction() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        launch(.init(language: .english))

        step("To-Dos keeps Add primary and Settings inside More") {
            require(app.buttons["todo.addButton"], message: "Primary Add action is missing.")
            require(app.buttons["todo.moreActionsMenu"], message: "More menu is missing.")
            XCTAssertFalse(app.buttons["todo.settingsButton"].exists, "Settings should not be a separate toolbar button.")
            openSettings()
            require(app.buttons["settings.languagePicker"], message: "Settings language picker is missing.")
            tap(app.navigationBars.buttons["Close"], message: "Settings cannot be closed.")
        }

        step("Add remains usable after returning from Settings") {
            tap(app.buttons["todo.addButton"], message: "Primary Add action is no longer accessible.")
            require(app.navigationBars["New To-Do"], message: "Add did not open the to-do form.")
            tap(app.navigationBars.buttons["Cancel"], message: "The add form cannot be dismissed.")
            require(app.buttons["todo.moreActionsMenu"], message: "More did not return after dismissing Add.")
        }
    }

    func testLanguageSwitchPreservesTaskAndResetUsesSystemLanguage() throws {
        launch(.init(language: .english, setsLanguageOverride: false,
                     additionalArguments: ["-pieroot.todo.board.isBoardMode", "NO"]))
        openSettings()
        tap(app.buttons["settings.languagePicker"], message: "Language picker missing")
        tap(app.buttons["English"], message: "English choice missing")
        tap(app.buttons["settings.closeButton"], message: "Settings cannot close")

        let source = "Original text / 원문 / 2026"
        tap(app.buttons["todo.addButton"], message: "Add missing")
        tap(app.textFields["todo.add.titleField"], message: "Title missing")
        app.textFields["todo.add.titleField"].typeText(source)
        tap(app.buttons["todo.add.saveButton"], message: "Save missing")

        for nativeName in ["Español", "日本語", "简体中文", "Français", "Italiano", "Deutsch"] {
            openSettings()
            tap(app.buttons["settings.languagePicker"], message: "Language picker missing")
            tap(app.buttons[nativeName], message: "Missing language: \(nativeName)")
            XCTAssertFalse(app.navigationBars["Settings"].exists, "Switch did not change the active screen language")
            tap(app.buttons["settings.closeButton"], message: "Localized Settings cannot close")
            require(app.staticTexts[source], message: "Switching language changed or lost original task text")
            tap(app.buttons["todo.addButton"], message: "Add missing after language change")
            require(app.textFields["todo.add.titleField"], message: "Localized Add form missing")
            XCTAssertFalse(app.navigationBars["New To-Do"].exists, "Form silently fell back to English")
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "Language-\(nativeName)-Add"
            attachment.lifetime = .keepAlways
            add(attachment)
            tap(app.buttons["todo.add.cancelButton"], message: "Localized Cancel missing")
        }

        openSettings()
        tap(app.buttons["settings.languagePicker"], message: "Language picker missing")
        tap(app.buttons["English"], message: "English choice missing")
        tap(app.buttons["settings.languagePicker"], message: "Language picker missing")
        tap(app.buttons["System Language"], message: "System reset choice missing")
        require(app.navigationBars["Settings"], message: "Reset did not restore the English system locale")
        tap(app.buttons["settings.closeButton"], message: "Settings cannot close after reset")
        require(app.staticTexts[source], message: "Reset changed the source task")
    }

    func testEnglishNavigationAndAddFormUseEnglishCopy() throws {
        launch(.init(language: .english))

        step("영문 탭 이름 확인") {
            for label in ["To-Dos", "Calendar", "Mail", "Meetings"] {
                require(app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch, message: "\(label) 탭이 없습니다.")
            }
        }

        step("영문 새 할 일 양식 확인") {
            tap(app.buttons["todo.addButton"], message: "Add New To-Do 기본 버튼이 없습니다.")
            require(app.navigationBars["New To-Do"], message: "New To-Do 제목이 없습니다.")
            require(app.textFields["Title (Required)"], message: "영문 제목 필드가 없습니다.")
            XCTAssertTrue(
                app.textFields["Notes (Optional)"].exists || app.textViews["Notes (Optional)"].exists
            )
            tap(app.buttons["Cancel"], message: "Cancel 버튼이 없습니다.")
        }
    }

    func testEnglishPrivacyScreenExposesRequiredCopy() throws {
        launch(.init(language: .english))

        step("App Info 열기") {
            openSettings()
            let info = app.buttons["settings.appInfoRow"]
            requireHittable(info, message: "App Info 행이 없습니다.")
            info.tap()
        }

        step("Privacy Policy 핵심 문구 확인") {
            tap(app.buttons["Privacy Policy"], message: "Privacy Policy 행이 없습니다.")
            require(
                app.staticTexts["Information collected and purposes"],
                message: "개인정보 처리방침 핵심 문구가 없습니다."
            )
        }
    }
}
