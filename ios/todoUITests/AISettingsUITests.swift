import XCTest

@MainActor
final class AISettingsUITests: SIFTUITestCase {
    func testChinaStorefrontHidesOpenAIAndKeepsLocalControls() throws {
        assertRestrictedStorefront("CHN", language: .english)
    }

    func testUnknownStorefrontHidesOpenAIAndKeepsLocalControls() throws {
        assertRestrictedStorefront("unknown", language: .korean)
    }

    func testNonChinaStorefrontKeepsChatGPTLoginInChinese() throws {
        for storefront in ["KOR", "USA"] {
            launch(.init(language: .simplifiedChinese, additionalArguments: [
                "-ui-test-reset-beta", "-sift-test-storefront", storefront
            ]))
            openAISettings()
            requireHittable(app.buttons["openai.signIn"], message: "An available storefront must offer direct ChatGPT login.")
            XCTAssertFalse(app.buttons["settings.openAIRow"].exists, "An unsigned account must not require opening a second settings screen to sign in.")
            capture("\(storefront) - Chinese direct ChatGPT login")
            app.terminate()
        }
    }

    func testModelDownloadsFollowIndividualFeatureChoice() throws {
        for language in [Language.korean, .english] {
            launch(.init(language: language, additionalArguments: ["-ui-test-reset-beta"]))
            openSettings()
            tap(app.buttons["settings.meetingRow"], message: "Open Meeting model management")
            for model in [
                (toggle: "beta.meetingDiarization.toggle", download: "meeting.diarization.download", delete: "beta.diarization.delete"),
                (toggle: "beta.whisper.auto", download: "beta.whisper.download", delete: "beta.whisper.delete")
            ] {
                step("\(model.toggle) keeps installation separate from activation") {
                    let toggle = app.switches[model.toggle]
                    reveal(toggle)
                    XCTAssertEqual(toggle.value as? String, model.toggle == "beta.meetingDiarization.toggle" ? "1" : "0")
                    set(toggle, enabled: false)
                    let installed = app.buttons[model.delete].exists
                    XCTAssertFalse(app.buttons[model.download].exists, "An inactive feature must not offer a download.")
                    set(toggle, enabled: true)
                    let action = app.buttons[installed ? model.delete : model.download]
                    requireHittable(action, maxSwipes: 12, message: "Enabling the feature must expose its explicit model action.")
                    XCTAssertEqual(app.buttons[model.delete].exists, installed, "Activation must not install or remove model files.")
                    capture("\(language.rawValue) - \(model.toggle) enabled")
                    reveal(toggle)
                    set(toggle, enabled: false)
                    XCTAssertFalse(app.buttons[model.download].exists)
                    XCTAssertEqual(app.buttons[model.delete].exists, installed, "Installed models must remain removable when the feature is off.")
                }
            }
            capture("\(language.rawValue) - meeting models disabled")
            reveal(app.switches["beta.voiceProcessing.toggle"])
            reveal(app.switches["beta.autoRefine.toggle"])
            tap(app.navigationBars.buttons.element(boundBy: 0), message: "Return to Settings")
            tap(app.buttons["settings.betaRow"], message: "Open local model management")
            let picker = app.descendants(matching: .any).matching(identifier: "beta.model.downloadPicker").firstMatch
            if picker.exists {
                reveal(picker)
                let action = app.buttons[app.buttons["beta.model.localDelete"].exists ? "beta.model.localDelete" : "beta.model.localDownload"].firstMatch
                reveal(action)
            }
            XCTAssertFalse(app.buttons["beta.model.localCancelDownload"].exists, "Opening Beta must not start a model download.")
            capture("\(language.rawValue) - Beta local model management")
            app.terminate()
        }
    }

    func testMeetingPreferencesPersistWithoutReturningToAIScreen() throws {
        launch(.init(language: .english, additionalArguments: ["-ui-test-reset-beta"]))
        openSettings()
        tap(app.buttons["settings.meetingRow"], message: "Open Meeting settings")
        let voice = app.switches["beta.voiceProcessing.toggle"]
        let refine = app.switches["beta.autoRefine.toggle"]
        requireHittable(voice, message: "Voice processing must be configurable.")
        requireHittable(refine, message: "Automatic transcript correction must be configurable.")
        set(voice, enabled: true)
        set(refine, enabled: false)
        capture("English - meeting voice on and transcript correction off")
        app.terminate()

        launch(.init(language: .english))
        openSettings()
        tap(app.buttons["settings.meetingRow"], message: "Reopen Meeting after relaunch")
        requireHittable(voice, message: "Voice processing must remain available after relaunch.")
        XCTAssertEqual(voice.value as? String, "1")
        XCTAssertEqual(refine.value as? String, "0", "An explicit correction opt-out must survive relaunch.")
        set(voice, enabled: false)
        set(refine, enabled: true)
    }

    func testLocalFallbackControlsInstallationWithoutDownloading() throws {
        launch(.init(language: .english, additionalArguments: ["-ui-test-reset-beta", "-sift-test-ad-free"]))
        openSettings()
        tap(app.buttons["settings.betaRow"], message: "Open optional local models")
        let fallback = app.switches["beta.localFallback.toggle"]
        let download = app.buttons["beta.model.localDownload"]
        guard fallback.exists else {
            XCTAssertFalse(download.exists, "Apple-supported hardware must not offer fallback installation.")
            return
        }
        XCTAssertEqual(fallback.value as? String, "0")
        if download.exists {
            reveal(download)
            XCTAssertFalse(download.isEnabled, "Fallback opt-out must not expose a silent no-op install action.")
        }
        set(fallback, enabled: true)
        if download.exists {
            reveal(download)
            XCTAssertTrue(download.isEnabled, "Explicit opt-in must permit the separate install action.")
        }
        XCTAssertFalse(app.buttons["beta.model.localCancelDownload"].exists)
        set(fallback, enabled: false)
        if download.exists { XCTAssertFalse(download.isEnabled) }
        capture("Local fallback activation is separate from installation")
    }

    func testDisconnectedPersonalScreensDoNotOfferRemoteAnalysis() throws {
        launch(.init(language: .english, additionalArguments: ["-ui-test-reset-beta", "-sift-test-ad-free"]))
        openAISettings()
        requireHittable(app.buttons["openai.signIn"], message: "Fixture must be genuinely disconnected.")
        tap(app.navigationBars.buttons.element(boundBy: 0), message: "Return to Settings")
        let routines = app.buttons["settings.routinesRow"]
        requireHittable(routines, message: "Open local routine settings")
        tap(routines, message: "Open local routines")
        XCTAssertFalse(app.buttons["routines.basicRequest"].exists)
        XCTAssertFalse(app.buttons["routines.advancedRequest"].exists)
        XCTAssertFalse(app.switches["openai.consent.routines"].exists)
        capture("Disconnected routines remain local")
        tap(app.navigationBars.buttons.element(boundBy: 0), message: "Return to Settings")
        let advanced = app.buttons["settings.advanced"]
        requireHittable(advanced, message: "Reveal personal analysis settings")
        tap(advanced, message: "Expand Advanced")
        for screen in ["My Persona", "Behavior Pattern Analysis"] {
            let row = app.buttons[screen]
            requireHittable(row, message: "Open \(screen)")
            tap(row, message: "Open \(screen)")
            let localAction = app.buttons[screen == "My Persona" ? "Generate Persona" : "Analyze Patterns Now"]
            requireHittable(localAction, message: "Local analysis remains accessible while disconnected.")
            XCTAssertFalse(app.buttons["persona.advancedRequest"].exists)
            XCTAssertFalse(app.buttons["memory.advancedRequest"].exists)
            XCTAssertFalse(app.switches["openai.consent.persona"].exists)
            XCTAssertFalse(app.switches["openai.consent.routines"].exists)
            capture("Disconnected \(screen)")
            tap(app.navigationBars.buttons.element(boundBy: 0), message: "Return from \(screen)")
        }
    }

    private func openAISettings() {
        openSettings()
        tap(app.buttons["settings.aiRow"], message: "Open AI settings")
        require(app.descendants(matching: .any).matching(identifier: "ai.apple.status").firstMatch, message: "AI settings did not open.")
    }

    private func assertRestrictedStorefront(_ storefront: String, language: Language) {
        launch(.init(language: language, additionalArguments: [
            "-ui-test-reset-beta", "-sift-test-storefront", storefront
        ]))
        openAISettings()
        assertOpenAIControlsAbsent()
        tap(app.navigationBars.buttons.element(boundBy: 0), message: "Return to Settings")
        tap(app.buttons["settings.betaRow"], message: "Open local model management")
        let fallback = app.switches["beta.localFallback.toggle"]
        if !fallback.exists {
            XCTAssertFalse(app.switches["beta.laya.toggle"].exists, "Apple-supported devices must not activate local fallback models.")
            return
        }
        set(fallback, enabled: true)
        let local = app.switches["beta.laya.toggle"]
        reveal(local)
        set(local, enabled: true)
        requireHittable(app.buttons["beta.laya.download"], message: "Regional restrictions must not block explicit local model management.")
        XCTAssertFalse(app.buttons["beta.laya.cancelDownload"].exists)
        capture("\(storefront) - local model management without OpenAI")
        set(local, enabled: false)
        set(fallback, enabled: false)
        tap(app.navigationBars.buttons.element(boundBy: 0), message: "Return to Settings")
        tap(app.buttons["settings.aiRow"], message: "Return to analysis provider controls")
        assertOpenAIControlsAbsent()
    }

    private func assertOpenAIControlsAbsent() {
        for identifier in [
            "settings.openAIRow", "openai.enabled", "openai.signIn", "openai.activeAccount",
            "openai.testConnection", "openai.modelCatalog", "openai.refreshModels",
            "openai.consent.tasks", "openai.consent.email", "openai.consent.routines", "openai.consent.persona"
        ] {
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists,
                           "Restricted storefront must not expose \(identifier).")
        }
        let remoteCopy = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "OpenAI", "ChatGPT"
        )).firstMatch
        XCTAssertFalse(remoteCopy.exists, "Restricted AI settings must not promote an unavailable remote provider.")
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<18 {
            guard element.exists else {
                app.swipeUp()
                continue
            }
            let frame = element.frame
            let viewport = app.frame
            let top = app.navigationBars.firstMatch.frame.maxY + 12
            let bottom = viewport.maxY - 60
            if element.isHittable, frame.midY > top, frame.midY < bottom { return }
            if frame.isEmpty || frame.midY >= bottom { app.swipeUp() }
            else { app.swipeDown() }
        }
        XCTFail("Could not reveal the switch thumb for \(element.identifier).")
    }

    private func set(_ toggle: XCUIElement, enabled: Bool) {
        reveal(toggle)
        let expected = enabled ? "1" : "0"
        if toggle.value as? String != expected {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, expected)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
