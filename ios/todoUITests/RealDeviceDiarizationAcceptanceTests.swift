import XCTest

/// Throwaway real-device QA driver (not a permanent test). Uses the normal
/// on-disk stores so persistence across relaunch is observable.
@MainActor
final class RealDeviceDiarizationAcceptanceTests: XCTestCase {
    let app = XCUIApplication()

    private static let recordedMeetingIDFile = URL(fileURLWithPath: "/tmp/sift-real-device-meeting-row-id.txt")
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(tab: Int) {
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-pieroot.todo.hasOnboarded", "YES",
            "-pieroot.todo.hasCompletedTutorial", "YES",
            "-pieroot.todo.launchBehavior", "fixed",
            "-pieroot.todo.launchTab", String(tab),
            "-pieroot.todo.selectedTab", String(tab),
            "-pieroot.todo.beta.meetingDiarizationEnabled", "YES",
            "-pieroot.todo.uiTestShowAllTabs",
            "-ui-test-suppress-crash-prompt"
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        // Release builds show the previous-session diagnostic sheet after a test kill.
        let close = app.buttons["닫기"]
        if close.waitForExistence(timeout: 4) { close.tap() }
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 10) {
        for _ in 0..<maxSwipes where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }

    private func dismissAlerts() {
        for label in ["확인", "OK", "허용", "Allow"] where app.alerts.buttons[label].exists {
            app.alerts.buttons[label].firstMatch.tap()
        }
    }

    private func openSettings() {
        let more = app.buttons["todo.moreActionsMenu"]
        XCTAssertTrue(more.waitForExistence(timeout: 20), "To-Do More menu is missing")
        XCTAssertTrue(more.isHittable, "To-Do More menu is not accessible")
        more.tap()
        let settings = app.buttons["todo.settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings is missing from More")
        settings.tap()
        XCTAssertTrue(app.buttons["settings.appInfoRow"].waitForExistence(timeout: 10))
    }

    func testA_InstallSpeakerModel() throws {
        launch(tab: 0)
        openSettings()
        let advanced = app.buttons["settings.advanced"]
        scrollTo(advanced)
        advanced.tap()
        let row = app.buttons["settings.betaFeaturesRow"]
        scrollTo(row)
        row.tap()

        let toggle = app.switches["beta.meetingDiarization.toggle"]
        scrollTo(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if toggle.value as? String == "0" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, "1")

        // If the model is already installed on the device, preserve it.
        let installed = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "화자 모델 설치됨")).firstMatch
        if installed.exists {
            shot("beta-installed")
            XCTAssertTrue(installed.exists)
            return
        }
        let download = app.buttons["meeting.diarization.download"]
        scrollTo(download, maxSwipes: 3)
        XCTAssertTrue(download.waitForExistence(timeout: 15))
        download.tap()
        let deadline = Date().addingTimeInterval(1_200)
        while !installed.exists, Date() < deadline {
            if app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "내려받거나 검증하지 못했습니다")).firstMatch.exists {
                shot("install-error")
                XCTFail("Speaker model install failed")
                return
            }
            sleep(5)
        }
        shot("beta-installed")
        XCTAssertTrue(installed.exists, "Speaker model was not installed in time")
    }

    /// A consenting person speaks into the phone during this 60-second capture.
    func testB_RecordHumanSpeech() throws {
        launch(tab: 3)
        let consent = app.switches.containing(NSPredicate(format: "label CONTAINS %@", "녹음 고지")).firstMatch
        XCTAssertTrue(consent.waitForExistence(timeout: 20))
        if consent.value as? String == "0" {
            let inner = consent.switches.firstMatch
            (inner.exists ? inner : consent).tap()
        }
        XCTAssertEqual(consent.value as? String, "1", "Consent switch did not turn on")
        let existingRowIDs = meetingRowIDs()
        let startByID = app.buttons["meeting.action.startRecording"].firstMatch
        let start = startByID.waitForExistence(timeout: 10)
            ? startByID
            : app.buttons["녹음 시작"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let confirm = app.alerts.buttons["녹음 시작"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        dismissAlerts()

        let stopByID = app.buttons["meeting.action.stopRecording"].firstMatch
        let stop = stopByID.waitForExistence(timeout: 20)
            ? stopByID
            : app.buttons["녹음 중지"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Recording did not start")
        for index in 1...5 {
            sleep(12)
            shot("live-\(index)")
        }
        stop.tap()

        // Final pass + proofreading/summary; wait for the capture controls to return.
        let deadline = Date().addingTimeInterval(600)
        sleep(3)
        while Date() < deadline {
            let diarizing = app.progressIndicators["meeting.diarization.state"].exists
            if !diarizing,
               app.buttons["meeting.action.startRecording"].firstMatch.exists || app.buttons["녹음 시작"].firstMatch.exists {
                break
            }
            if Int(Date().timeIntervalSince1970) % 15 == 0 { shot("finalizing") }
            dismissAlerts()
            sleep(1)
        }
        shot("after-stop")
        XCTAssertFalse(app.alerts["녹음 오류"].exists, "The recorded audio could not be saved")
        XCTAssertTrue(
            app.buttons["meeting.action.startRecording"].firstMatch.exists || app.buttons["녹음 시작"].firstMatch.exists,
            "Finalization did not finish in time"
        )
        let newIDs = meetingRowIDs().subtracting(existingRowIDs)
        guard let createdRowID = newIDs.first else {
            XCTFail("No newly created meeting row identifier was found")
            return
        }
        try createdRowID.write(to: Self.recordedMeetingIDFile, atomically: true, encoding: .utf8)
    }

    func testC_DetailLabelsRenameAndRelaunch() throws {
        launch(tab: 3)
        let rowID = try String(contentsOf: Self.recordedMeetingIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        openMeeting(rowID: rowID)
        let state = app.staticTexts["meeting.diarization.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 20), "No speaker state in detail")
        shot("detail-final")
        XCTAssertTrue(state.label.contains("기기에서 확인한 화자"), "Unexpected state: \(state.label)")

        let labeledRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "화자 1")).firstMatch
        XCTAssertTrue(labeledRow.waitForExistence(timeout: 10), "No row labeled 화자 1")
        labeledRow.press(forDuration: 1.2)
        let edit = app.buttons["화자 수정"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let speakerRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "화자 1")).firstMatch
        XCTAssertTrue(speakerRow.waitForExistence(timeout: 10))
        speakerRow.swipeLeft()
        app.buttons["이름 변경"].firstMatch.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("민수")
        app.alerts.buttons["저장"].tap()
        app.navigationBars.buttons["저장"].firstMatch.tap()
        sleep(2)
        shot("after-rename")

        app.terminate()
        launch(tab: 3)
        openMeeting(rowID: rowID)
        let renamed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "민수")).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 20), "Renamed speaker did not persist")
        shot("after-relaunch")
    }

    private func meetingRowIDs() -> Set<String> {
        let section = app.staticTexts["이 기기의 회의"]
        if section.exists { scrollTo(section, maxSwipes: 4) }
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting.row."))
        var ids: Set<String> = []
        for index in 0..<matches.count {
            let id = matches.element(boundBy: index).identifier
            if id.hasPrefix("meeting.row.") { ids.insert(id) }
        }
        return ids
    }

    private func openMeeting(rowID: String) {
        XCTAssertTrue(rowID.hasPrefix("meeting.row."), "Pinned meeting identifier is missing")
        let row = app.descendants(matching: .any)[rowID].firstMatch
        scrollTo(row)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Pinned meeting row \(rowID) not found")
        row.tap()
        XCTAssertTrue(app.navigationBars["회의 기록"].waitForExistence(timeout: 10))
    }
}
