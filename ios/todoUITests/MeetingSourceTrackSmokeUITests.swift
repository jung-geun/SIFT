import XCTest

@MainActor
final class MeetingSourceTrackSmokeUITests: SIFTUITestCase {
    func testImportSpeechChoiceReturnsImmediatelyAndPersists() throws {
        launch(.init(language: .english, startTab: .meetings, additionalArguments: ["-ui-test-reset-beta"]))
        tap(app.buttons["meeting.audioImport.open"], message: "Open local audio import")
        let start = app.buttons["meeting.audioImport.start"]
        require(start, message: "Import action missing")
        XCTAssertFalse(start.isEnabled)
        selectLanguage("hi", picker: "meeting.audioImport.language")
        XCTAssertTrue(app.buttons["meeting.audioImport.language"].label.contains("Hindi"))
        XCTAssertFalse(start.isEnabled, "Language selection must not import without an audio file")
        tap(app.buttons["meeting.audioImport.language"], message: "Reopen spoken-language choices")
        let selected = app.buttons["meeting.audioImport.language.option.hi"]
        requireHittable(selected, message: "Selected language missing")
        XCTAssertTrue(selected.isSelected)
        tap(selected, message: "Choose the selected language again")
        requireHittable(app.buttons["meeting.audioImport.language"], message: "Selecting an unchanged language must also return")
        attach("Manual language saved and immediately returned")
    }

    func testUnavailableAutomaticDetectionIsAbsent() throws {
        launch(.init(language: .english, startTab: .meetings, additionalArguments: ["-ui-test-reset-beta"]))
        tap(app.buttons["meeting.languages.source"], message: "Open recording language choices")
        XCTAssertFalse(app.buttons["meeting.languages.source.automatic"].exists,
            "An unavailable automatic mode must be absent, not a disabled choice")
        app.navigationBars.buttons.firstMatch.tap()
        tap(app.buttons["meeting.audioImport.open"], message: "Open local audio import")
        tap(app.buttons["meeting.audioImport.language"], message: "Open imported speech choices")
        XCTAssertFalse(app.buttons["meeting.audioImport.language.automatic"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        if app.buttons["meeting.audioImport.summaryLanguage"].exists {
            tap(app.buttons["meeting.audioImport.summaryLanguage"], message: "Open available summary choices")
            XCTAssertFalse(app.buttons["meeting.audioImport.summaryLanguage.automatic"].exists)
        }
        attach("Unavailable automatic choices hidden")
    }


    func testSavedSpeechChoiceReturnsAndPreservesTranscript() throws {
        launch(.init(language: .english, startTab: .meetings,
                     additionalArguments: ["-ui-test-source-track-smoke", "-ui-test-reset-beta"]))
        openGroup()
        let child = app.buttons["meeting.audioTrack.row.b53c91da-05f8-4a76-978c-22bd87411803"]
        revealMeetingElement(child, message: "Saved microphone source missing")
        tap(child, message: "Open saved source")
        tap(app.buttons["meeting.settings.open"], message: "Open source processing settings")
        selectLanguage("en", picker: "meeting.detail.sourceLanguage")
        let choice = app.buttons["meeting.detail.sourceLanguage"].label
        tap(app.buttons["Done"], message: "Close source settings")
        app.navigationBars.buttons.firstMatch.tap()
        revealMeetingElement(child, message: "Source list missing after Back")
        tap(child, message: "Reopen saved source")
        let original = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "마이크 트랙의 독립 전사")).firstMatch
        revealMeetingElement(original, message: "Language selection must not replace the original transcript")
        tap(app.buttons["meeting.settings.open"], message: "Reopen persisted source settings")
        let picker = app.buttons["meeting.detail.sourceLanguage"]
        revealMeetingElement(picker, message: "Saved language picker missing")
        XCTAssertEqual(picker.label, choice)
        attach("Saved speech choice and original transcript preserved")
    }

    private func selectLanguage(_ code: String, picker: String) {
        let entry = app.buttons[picker]
        revealMeetingElement(entry, message: "Language picker missing")
        tap(entry, message: "Open language picker")
        let search = app.searchFields.firstMatch
        tap(search, message: "Search supported content languages")
        search.typeText(code)
        let option = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "\(picker).option.\(code)")).firstMatch
        requireHittable(option, message: "Supported language missing: \(code)")
        tap(option, message: "Choose explicit content language")
        requireHittable(entry, message: "Language selection must save and return immediately")
    }

    func testFullMeetingPlaybackSeekBackAndSeparateSources() throws {
        launch(.init(startTab: .meetings, additionalArguments: ["-ui-test-source-track-smoke", "-ui-test-reset-beta"]))
        openGroup()
        let fullPlay = app.buttons["meeting.group.playbackButton"]
        requireHittable(fullPlay, message: "Full meeting playback missing")
        tap(fullPlay, message: "Play the aligned source mix")
        waitForPlaying(fullPlay)
        let fullTime = app.staticTexts["meeting.group.playbackButton.time"]
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "00:0[1-9]  /  00:10"), object: fullTime)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 6), .completed)
        let applicationPlay = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "meeting.conversation.saved.b53c91da-05f8-4a76-978c-22bd87411804.", ".play")).firstMatch
        requireHittable(applicationPlay, message: "The application source must have a separate playback control")
        tap(applicationPlay, message: "Seek intentionally by the application's parent-time offset")
        let sought = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "00:0[2-9]  /  00:10"), object: fullTime)
        XCTAssertEqual(XCTWaiter.wait(for: [sought], timeout: 4), .completed)
        attach("Full meeting playback and parent-time conversation seek")
        app.navigationBars.buttons.firstMatch.tap()
        openGroup()
        requireHittable(fullPlay, message: "Full meeting player missing on re-entry")
        XCTAssertEqual(fullPlay.label, "음성 재생")
        XCTAssertEqual(fullTime.label, "00:00  /  00:10")
        let microphone = app.buttons["meeting.audioTrack.row.b53c91da-05f8-4a76-978c-22bd87411803"]
        requireHittable(microphone, message: "Microphone source missing")
        tap(microphone, message: "Open microphone original")
        let play = app.buttons["meeting.playbackButton"]
        requireHittable(play, message: "Original source player missing")
        tap(play, message: "Play original microphone FLAC")
        waitForPlaying(play)
        app.navigationBars.buttons.firstMatch.tap()
        requireHittable(microphone, message: "Source list missing after source playback Back")
        tap(microphone, message: "Reopen source after stopping on Back")
        requireHittable(play, message: "Source player missing on re-entry")
        XCTAssertEqual(play.label, "음성 재생")
        XCTAssertEqual(app.staticTexts["meeting.playbackButton.time"].label, "00:00  /  00:08")
        let original = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "마이크 트랙의 독립 전사")).firstMatch
        requireHittable(original, message: "Microphone transcript missing below its audio player")
        XCTAssertFalse(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "앱 트랙의 독립 전사")).firstMatch.exists)
        attach("Back stops playback; originals stay independently controllable")
        app.navigationBars.buttons.firstMatch.tap()
        tap(app.buttons["meeting.audioTrack.exportAll"], message: "Export original source archive")
        require(app.otherElements["ActivityListView"], timeout: 30, message: "System sharing must receive the source archive")
    }

    func testSummaryTasksKeepSourceCitationsAndRegistrationOnReentry() throws {
        launch(.init(language: .english, startTab: .meetings,
                     additionalArguments: ["-ui-test-source-track-smoke", "-ui-test-cited-summary",
                                           "-ui-test-task-provenance", "-ui-test-reset-beta",
                                           "-pieroot.todo.board.isBoardMode", "NO"]))
        openGroup()
        assertNoTaskOrPersonAnalysis()
        selectDocumentTab("Summary")
        let groupTaskID = "meeting.summary.task.synthetic-multiple-sources.synthetic-group-task"
        let groupTask = assertSummaryTask(identifier: groupTaskID, title: "Share the combined meeting report.")
        XCTAssertTrue(groupTask.isEnabled)
        XCTAssertEqual(summaryTaskButtons.count, 1, "Only the task-classified summary sentence gets an Add control")

        // Both originals deliberately reuse the local segment ID "future".
        // Each citation must still target its own source, not the other source's identically named row.
        for sourceID in ["b53c91da-05f8-4a76-978c-22bd87411803", "b53c91da-05f8-4a76-978c-22bd87411804"] {
            assertSummaryDescription(sourceID: sourceID, sectionID: "synthetic-multiple-sources")
            let sources = app.buttons["Transcript source"]
            revealMeetingElement(sources, message: "Combined task citation menu missing")
            tap(sources, message: "Open both source-specific citations for the combined task")
            let citation = app.buttons["meeting.summary.citation.\(sourceID).future"]
            requireHittable(citation, message: "Task citation missing from the open source menu")
            tap(citation, message: "Navigate to this task's original source evidence")
            let exactRow = app.descendants(matching: .any)
                .matching(identifier: "meeting.conversation.saved.\(sourceID).future").firstMatch
            requireHittable(exactRow, message: "Shared local IDs must not merge citations across tracks")
            assertNoTaskOrPersonAnalysis()
            selectDocumentTab("Summary")
        }
        addSummaryTask(groupTask)
        app.navigationBars.buttons.firstMatch.tap()
        openGroup()
        selectDocumentTab("Summary")
        assertAddedSummaryTask(identifier: groupTaskID, title: "Share the combined meeting report.")

        for (sourceID, title, evidenceID, evidenceText) in [
            ("b53c91da-05f8-4a76-978c-22bd87411803", "Share the microphone report.", "future",
             "제가 Microphone · Synthetic microphone 보고서를 공유하겠습니다."),
            ("b53c91da-05f8-4a76-978c-22bd87411804", "Send the application summary.", "request",
             "미노님, Application audio · Synthetic application 요약을 보내주세요.")
        ] {
            let source = app.buttons["meeting.audioTrack.row.\(sourceID)"]
            revealMeetingElement(source, message: "Original source missing")
            tap(source, message: "Open original source document")
            assertNoTaskOrPersonAnalysis()
            selectDocumentTab("Summary")
            let identifier = "meeting.summary.task.synthetic-source.synthetic-task-\(sourceID)"
            let task = assertSummaryTask(identifier: identifier, title: title)
            XCTAssertTrue(task.isEnabled, "Importing the group sentence must not register a distinct source sentence")
            XCTAssertEqual(summaryTaskButtons.count, 1)
            assertSummaryDescription(sourceID: sourceID, sectionID: "synthetic-source")
            let citation = app.buttons["meeting.summary.citation.\(sourceID).\(evidenceID)"]
            revealMeetingElement(citation, message: "A source task must cite future work or a request")
            tap(citation, message: "Navigate to the source task's actual transcript")
            let exactRow = app.descendants(matching: .any)
                .matching(identifier: "meeting.transcript.segment.\(evidenceID)").firstMatch
            requireHittable(exactRow, message: "Source task must navigate to its exact evidence, not the introduction or completed work")
            let paragraph = app.textViews["meeting.transcript.segment.\(evidenceID).text"].value as? String
            XCTAssertTrue(paragraph?.contains(evidenceText) == true,
                          "The cited original sentence must survive within its speaker-continuity paragraph")
            assertNoTaskOrPersonAnalysis()
            selectDocumentTab("Summary")
            addSummaryTask(task)
            app.navigationBars.buttons.firstMatch.tap()
            revealMeetingElement(source, message: "Source list missing after registration")
            tap(source, message: "Reopen original without regenerating its saved summary")
            selectDocumentTab("Summary")
            assertAddedSummaryTask(identifier: identifier, title: title)
            assertSummaryDescription(sourceID: sourceID, sectionID: "synthetic-source")
            attach("Inline task and saved source summary preserved: \(sourceID)")
            app.navigationBars.buttons.firstMatch.tap()
        }
        selectDocumentTab("Summary")
        assertAddedSummaryTask(identifier: groupTaskID, title: "Share the combined meeting report.")
        attach("Combined summary task remains registered without duplicate submission")
        app.navigationBars.buttons.firstMatch.tap()
        let todoTab = app.tabBars.buttons.element(boundBy: 0)
        tap(todoTab, message: "Inspect locally imported review tasks without scheduling or promoting them")
        let active = app.buttons["todo.filter.active"]
        requireHittable(active, message: "Active task filter missing")
        tap(active, message: "Confirm summary imports do not enter active work automatically")
        let titles = ["Share the combined meeting report.", "Share the microphone report.", "Send the application summary."]
        for title in titles {
            XCTAssertFalse(app.staticTexts[title].exists, "Summary imports must remain review-only")
        }
        let review = app.buttons["todo.filter.review"]
        let filters = app.scrollViews.containing(.button, identifier: "todo.filter.active").firstMatch
        for _ in 0..<4 where !review.isHittable { filters.swipeLeft() }
        tap(review, message: "Open the review queue without accepting imported work")
        for title in titles {
            let imported = app.staticTexts.matching(identifier: title)
            require(imported.firstMatch, message: "The exact visible summary sentence must be the imported task title")
            XCTAssertEqual(imported.count, 1, "Reopening Added controls must not create duplicate review tasks")
        }
        attach("Exactly three summary sentences imported once, only into review")
    }

    func testTranscriptsWithoutTasksHaveNoEmptyAnalysisRows() throws {
        launch(.init(language: .english, startTab: .meetings,
                     additionalArguments: ["-ui-test-source-track-smoke", "-ui-test-task-provenance",
                                           "-ui-test-cited-summary", "-ui-test-no-extracted-tasks", "-ui-test-reset-beta"]))
        openGroup()
        assertNoTaskOrPersonAnalysis()
        selectDocumentTab("Summary")
        assertSummaryDescription(sourceID: "b53c91da-05f8-4a76-978c-22bd87411803", sectionID: "synthetic-multiple-sources")
        XCTAssertEqual(summaryTaskButtons.count, 0, "A descriptive-only summary must not offer Add task controls")
        selectDocumentTab("Transcript")
        for (sourceID, personName) in [
            ("b53c91da-05f8-4a76-978c-22bd87411803", "김민수"),
            ("b53c91da-05f8-4a76-978c-22bd87411804", "이서연")
        ] {
            let source = app.buttons["meeting.audioTrack.row.\(sourceID)"]
            revealMeetingElement(source, message: "Independent source missing")
            assertNoTaskOrPersonAnalysis()
            tap(source, message: "Open transcript without extracted tasks")
            let transcript = app.descendants(matching: .any).matching(identifier: "meeting.transcript.viewport").firstMatch
            revealMeetingElement(transcript, message: "The source transcript must remain available below playback")
            require(transcript.descendants(matching: .any).matching(NSPredicate(
                format: "value CONTAINS %@", "저는 \(personName)입니다."
            )).firstMatch, message: "An introduction alone must remain transcript evidence, not become an empty person analysis")
            assertNoTaskOrPersonAnalysis()
            selectDocumentTab("Summary")
            assertSummaryDescription(sourceID: sourceID, sectionID: "synthetic-source")
            XCTAssertEqual(summaryTaskButtons.count, 0, "An introduction must not turn its descriptive summary into a task")
            selectDocumentTab("Transcript")
            tap(app.buttons["meeting.settings.open"], message: "Open completed source settings")
            revealMeetingElement(app.buttons["meeting.detail.sourceLanguage"], message: "Source language control missing")
            tap(app.buttons["Done"], message: "Close source settings without replacing transcript")
            assertNoTaskOrPersonAnalysis()
            attach("No content-free analysis for source \(sourceID)")
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    func testCitedSummaryJumpsWithoutPlaybackAndSelectionRevealsTime() throws {
        launch(.init(language: .english, startTab: .meetings,
                     additionalArguments: ["-ui-test-source-track-smoke", "-ui-test-cited-summary", "-ui-test-reset-beta"]))
        openGroup()
        let transcript = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting.conversation.saved.")).firstMatch
        requireHittable(transcript, message: "Selectable native transcript prose missing")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "identifier ENDSWITH %@", ".timestamp")).firstMatch.exists,
                       "Timestamps must not be permanently visible in every row")
        transcript.press(forDuration: 1.2)
        require(app.staticTexts.matching(NSPredicate(format: "identifier ENDSWITH %@", ".timestamp")).firstMatch,
                message: "Actual native text selection or focus must reveal the segment time")
        let tabs = app.segmentedControls["meeting.document.tabs"]
        revealMeetingElement(tabs, message: "Meeting document tabs missing")
        tap(tabs.buttons["Summary"], message: "Open structured synthetic summary")
        let citation = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting.summary.citation.b53c91da-05f8-4a76-978c-22bd87411804.")).firstMatch
        revealMeetingElement(citation, message: "Application source citation missing")
        let sourceID = "b53c91da-05f8-4a76-978c-22bd87411804"
        let segmentID = String(citation.identifier.dropFirst("meeting.summary.citation.\(sourceID).".count))
        tap(citation, message: "Jump to the exact source transcript, without starting audio")
        XCTAssertTrue(tabs.buttons["Transcript"].isSelected)
        let exactRow = app.descendants(matching: .any).matching(identifier: "meeting.conversation.saved.\(sourceID).\(segmentID)").firstMatch
        requireHittable(exactRow, message: "Citation must scroll to its exact source-local segment")
        XCTAssertEqual(exactRow.value as? String, "Highlighted transcript segment")
        XCTAssertEqual(app.buttons["meeting.group.playbackButton"].label, "음성 재생")
        attach("Cited synthetic summary and native prose selection")
    }

    func testUnalignedCitationOpensOriginalAndSummarySettingsPersist() throws {
        launch(.init(language: .english, startTab: .meetings,
                     additionalArguments: ["-ui-test-source-track-smoke", "-ui-test-cited-summary", "-ui-test-unaligned-source", "-ui-test-reset-beta"]))
        openGroup()
        tap(app.buttons["meeting.settings.open"], message: "Open completed group settings")
        let format = app.buttons["meeting.settings.summaryFormat"]
        revealMeetingElement(format, message: "Summary format picker missing")
        tap(format, message: "Choose a real custom summary format")
        tap(app.buttons["Custom"], message: "Choose custom format")
        let instructions = app.textViews["meeting.settings.customInstructions"]
        revealMeetingElement(instructions, message: "Custom summary instructions editor missing")
        tap(instructions, message: "Edit persisted custom instructions")
        instructions.typeText("Synthetic QA: keep decisions concise.")
        tap(app.buttons["Done"], message: "Save and close group settings without regeneration")
        tap(app.buttons["meeting.settings.open"], message: "Reopen group settings")
        XCTAssertEqual(app.textViews["meeting.settings.customInstructions"].value as? String, "Synthetic QA: keep decisions concise.")
        tap(app.buttons["Done"], message: "Close persisted settings")
        let tabs = app.segmentedControls["meeting.document.tabs"]
        revealMeetingElement(tabs, message: "Meeting document tabs missing")
        tap(tabs.buttons["Summary"], message: "Open the earlier summary without regenerating it")
        let citation = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting.summary.citation.b53c91da-05f8-4a76-978c-22bd87411804.")).firstMatch
        revealMeetingElement(citation, message: "Unaligned source citation missing")
        let sourceID = "b53c91da-05f8-4a76-978c-22bd87411804"
        let segmentID = String(citation.identifier.dropFirst("meeting.summary.citation.\(sourceID).".count))
        tap(citation, message: "Open the correct unaligned original")
        let exactRow = app.descendants(matching: .any).matching(identifier: "meeting.transcript.segment.\(segmentID)").firstMatch
        requireHittable(exactRow, message: "Unaligned evidence must open and highlight its exact original segment")
        XCTAssertEqual(exactRow.value as? String, "Highlighted transcript segment")
        require(app.textViews["meeting.transcript.segment.\(segmentID).text"], message: "Exact source transcript prose missing")
        let source = app.staticTexts["meeting.transcript.segment.\(segmentID).source"]
        XCTAssertTrue(source.label.contains("Synthetic application"), "Citation must open the application source, not the microphone source")
        XCTAssertEqual(app.buttons["meeting.playbackButton"].label, "음성 재생")
        attach("Unaligned synthetic source citation and saved custom format")
    }

    private var summaryTaskButtons: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting.summary.task."))
    }

    private func selectDocumentTab(_ title: String) {
        let tabs = app.segmentedControls["meeting.document.tabs"]
        revealMeetingElement(tabs, message: "Meeting document tabs missing")
        tap(tabs.buttons[title], message: "Open \(title) document")
        XCTAssertTrue(tabs.buttons[title].isSelected)
    }

    @discardableResult
    private func assertSummaryTask(identifier: String, title: String) -> XCUIElement {
        revealMeetingElement(app.staticTexts[title], message: "Saved task summary sentence missing: \(title)")
        let button = app.buttons[identifier]
        revealMeetingElement(button, message: "The task sentence must have its own inline Add control")
        return button
    }

    private func assertSummaryDescription(sourceID: String, sectionID: String) {
        let sourceName = sourceID == "b53c91da-05f8-4a76-978c-22bd87411803"
            ? "Microphone · Synthetic microphone" : "Application audio · Synthetic application"
        revealMeetingElement(app.staticTexts["Synthetic QA summary for \(sourceName). This is generated fixture content, not an AI analysis."],
                             message: "Descriptive summary content must remain unchanged")
        XCTAssertFalse(app.buttons["meeting.summary.task.\(sectionID).synthetic-\(sourceID)"].exists,
                       "A descriptive non-task sentence must not offer registration")
    }

    private func addSummaryTask(_ button: XCUIElement) {
        revealMeetingElement(button, message: "Inline task control missing before registration")
        XCTAssertTrue(button.isEnabled)
        tap(button, message: "Add this exact summary sentence as a review task")
        let registered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [registered], timeout: 5), .completed)
    }

    private func assertAddedSummaryTask(identifier: String, title: String) {
        let button = assertSummaryTask(identifier: identifier, title: title)
        XCTAssertFalse(button.isEnabled, "Reopening must retain registration and prevent duplicate import")
    }

    private func assertNoTaskOrPersonAnalysis() {
        // Recording controls share meeting.action.* and can remain in the navigation hierarchy.
        // Obsolete draft cards instead used meeting.action.<record UUID>.<draft ID>.
        let draftCardIdentifier = "meeting\\.action\\.[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\..+"
        let analysis = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ OR identifier MATCHES %@ OR identifier BEGINSWITH %@",
            "meeting.actions.", draftCardIdentifier, "meeting.people.activity."
        ))
        XCTAssertEqual(analysis.count, 0, "Transcript must never display task-candidate or person-analysis rows: \(analysis.allElementsBoundByIndex.map(\.identifier))")
        XCTAssertEqual(summaryTaskButtons.count, 0, "Transcript must not contain a standalone task-candidate area or inline task controls")
    }

    private func assertNoPersonActivityRows() {
        let activities = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "meeting.people.activity."
        ))
        XCTAssertEqual(activities.count, 0, "Task results must not retain the obsolete person-activity analysis")
    }

    private func revealMeetingElement(_ element: XCUIElement, message: String) {
        // Scroll the outer list at its margin, not the independently scrolling transcript viewport.
        // A prior assertion may have scrolled past this document row.
        let playback = app.buttons.matching(NSPredicate(format: "identifier IN %@",
            ["meeting.group.playbackButton", "meeting.playbackButton"])).firstMatch
        for _ in 0..<16 where !element.isHittable && !playback.isHittable {
            assertNoPersonActivityRows()
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.8)))
        }
        for _ in 0..<16 where !element.isHittable {
            assertNoPersonActivityRows()
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.25)))
        }
        require(element, timeout: 2, message: message)
        XCTAssertTrue(element.isHittable, message)
        assertNoPersonActivityRows()
    }

    private func openGroup() {
        require(app.buttons["meeting.audioImport.open"], message: "Meeting screen did not finish presenting")
        let group = app.buttons["meeting.row.b53c91da-05f8-4a76-978c-22bd87411802"]
        func hasVisibleTapTarget() -> Bool {
            guard group.exists, group.isHittable else { return false }
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            let tabBar = app.tabBars.firstMatch
            let bottom = tabBar.exists ? tabBar.frame.minY - 8 : app.frame.maxY - 32
            return group.frame.midY > top && group.frame.midY < bottom
        }
        // The test banner may finish loading between the first snapshot and a tap.
        for _ in 0..<10 where !hasVisibleTapTarget() {
            let above = group.exists && group.frame.midY < app.navigationBars.firstMatch.frame.maxY + 8
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: above ? 0.4 : 0.7))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: above ? 0.7 : 0.4)))
        }
        require(group, message: "Saved source group missing")
        XCTAssertTrue(hasVisibleTapTarget(), "Saved source group tap point is behind navigation or tabs")
        tap(group, message: "Open saved meeting")
    }

    private func waitForPlaying(_ button: XCUIElement) {
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "음성 일시 정지"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
