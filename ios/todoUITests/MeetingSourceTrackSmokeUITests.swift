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
        selectLanguage("en", picker: "meeting.detail.sourceLanguage")
        let choice = app.buttons["meeting.detail.sourceLanguage"].label
        app.navigationBars.buttons.firstMatch.tap()
        revealMeetingElement(child, message: "Source list missing after Back")
        tap(child, message: "Reopen saved source")
        let original = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "마이크 트랙의 독립 전사")).firstMatch
        revealMeetingElement(original, message: "Language selection must not replace the original transcript")
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
        let applicationRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting.conversation.saved.b53c91da-05f8-4a76-978c-22bd87411804.")).firstMatch
        requireHittable(applicationRow, message: "The application source must appear in the combined timeline")
        tap(applicationRow, message: "Seek by the application's parent-time offset")
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
        let original = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "마이크 트랙의 독립 전사")).firstMatch
        requireHittable(original, message: "Microphone transcript missing below its audio player")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "앱 트랙의 독립 전사")).firstMatch.exists)
        attach("Back stops playback; originals stay independently controllable")
        app.navigationBars.buttons.firstMatch.tap()
        tap(app.buttons["meeting.audioTrack.exportAll"], message: "Export original source archive")
        require(app.otherElements["ActivityListView"], timeout: 30, message: "System sharing must receive the source archive")
    }

    func testExtractedTasksKeepSourceAndWholeContextProvenance() throws {
        launch(.init(language: .english, startTab: .meetings,
                     additionalArguments: ["-ui-test-source-track-smoke", "-ui-test-task-provenance", "-ui-test-reset-beta"]))
        openGroup()
        let groupID = "b53c91da-05f8-4a76-978c-22bd87411802"
        assertTask(recordID: groupID, title: "제가 Microphone · Synthetic microphone 보고서를 공유하겠습니다.",
                   source: "Whole-conversation context", assignee: nil)

        // The sources deliberately reuse speaker-1, local segment IDs and the alias 미노.
        // Only evidence in the owning source may resolve that alias to an assignee.
        for (sourceID, sourceName, personName, otherPerson, otherSource) in [
            ("b53c91da-05f8-4a76-978c-22bd87411803", "Microphone · Synthetic microphone", "김민수", "이서연", "Application audio · Synthetic application"),
            ("b53c91da-05f8-4a76-978c-22bd87411804", "Application audio · Synthetic application", "이서연", "김민수", "Microphone · Synthetic microphone")
        ] {
            for (title, timestamp) in [
                ("제가 \(sourceName) 보고서를 공유하겠습니다.", "00:03"),
                ("미노님, \(sourceName) 요약을 보내주세요.", "00:05")
            ] {
                let card = assertTask(recordID: sourceID, title: title, source: sourceName,
                                      assignee: personName, timestamp: timestamp)
                XCTAssertFalse(card.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", otherPerson)).firstMatch.exists,
                               "An identically numbered speaker or shared alias must not merge source identities")
                XCTAssertFalse(card.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", otherSource)).firstMatch.exists,
                               "Task evidence must stay in its owning source")
            }
            attach("Extracted tasks retain source-local identity: \(sourceName)")
            let source = app.buttons["meeting.audioTrack.row.\(sourceID)"]
            revealMeetingElement(source, message: "Open the owning source's task results")
            tap(source, message: "Review the original source independently")
            let originalTask = assertTask(recordID: sourceID,
                title: "제가 \(sourceName) 보고서를 공유하겠습니다.", source: sourceName,
                assignee: personName, timestamp: "00:03")
            XCTAssertFalse(originalTask.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", otherPerson)).firstMatch.exists,
                           "Opening the original must preserve the same source-local assignee")
            XCTAssertFalse(app.staticTexts["Source: Whole-conversation context"].exists,
                           "The source original must not inherit parent-context candidates")
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    func testTranscriptsWithoutTasksHaveNoEmptyAnalysisRows() throws {
        launch(.init(language: .english, startTab: .meetings,
                     additionalArguments: ["-ui-test-source-track-smoke", "-ui-test-task-provenance",
                                           "-ui-test-no-extracted-tasks", "-ui-test-reset-beta"]))
        openGroup()
        assertNoTaskOrPersonAnalysis()
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
                format: "label CONTAINS %@", "저는 \(personName)입니다."
            )).firstMatch, message: "An introduction alone must remain transcript evidence, not become an empty person analysis")
            assertNoTaskOrPersonAnalysis()
            revealMeetingElement(app.buttons["meeting.detail.sourceLanguage"], message: "Source language control missing")
            assertNoTaskOrPersonAnalysis()
            attach("No content-free analysis for source \(sourceID)")
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    @discardableResult
    private func assertTask(recordID: String, title: String, source: String, assignee: String?, timestamp: String? = nil) -> XCUIElement {
        // SwiftUI exposes the Section identifier on task-cell descendants, not the nested draft identifier.
        let card = app.cells.containing(NSPredicate(format: "identifier == %@", "meeting.actions.\(recordID)"))
            .containing(.staticText, identifier: title).firstMatch
        revealMeetingElement(card, message: "Extracted task missing from its owning record: \(title)")
        require(card.staticTexts["Source: \(source)"], message: "Task source provenance missing")
        if let timestamp {
            require(card.staticTexts["\(timestamp) · \(title)"], message: "Task must expose its actual transcript evidence")
        } else {
            XCTAssertFalse(card.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{2}:[0-9]{2} · .*"))
                .firstMatch.exists, "Context-wide candidates must not invent parent transcript evidence")
        }
        if let assignee {
            require(card.staticTexts["Assignee: \(assignee)"], message: "Source-local task assignee missing")
        } else {
            XCTAssertFalse(card.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Assignee:")).firstMatch.exists,
                           "Whole-context work must not borrow a source's speaker identity")
        }
        require(card.buttons["Register as To-Do"], message: "A real extracted task must remain reviewable")
        XCTAssertFalse(card.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "자료를 검토했습니다")).firstMatch.exists,
                       "Completed work is not evidence for a future task")
        return card
    }

    private func assertNoTaskOrPersonAnalysis() {
        let analysis = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
            "meeting.actions.", "meeting.action.", "meeting.people.activity."
        ))
        XCTAssertEqual(analysis.count, 0, "A transcript with no extracted work must not display analysis rows")
    }

    private func assertNoPersonActivityRows() {
        let activities = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "meeting.people.activity."
        ))
        XCTAssertEqual(activities.count, 0, "Task results must not retain the obsolete person-activity analysis")
    }

    private func revealMeetingElement(_ element: XCUIElement, message: String) {
        // Scroll the outer list at its margin, not the independently scrolling transcript viewport.
        // Canonical draft IDs determine row order, so a prior assertion may have scrolled past this row.
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
