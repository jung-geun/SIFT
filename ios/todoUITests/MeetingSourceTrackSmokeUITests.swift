import XCTest

@MainActor
final class MeetingSourceTrackSmokeUITests: SIFTUITestCase {
    func testSourceTracksHaveSeparatePlaybackAndGroupExport() throws {
        launch(.init(startTab: .meetings, additionalArguments: ["-ui-test-source-track-smoke", "-ui-test-reset-beta"]))
        let group = app.buttons["meeting.row.b53c91da-05f8-4a76-978c-22bd87411802"]
        requireHittable(group, message: "Saved source group is missing")
        tap(group, message: "Open source group")
        let microphone = app.buttons["meeting.audioTrack.row.b53c91da-05f8-4a76-978c-22bd87411803"]
        let application = app.buttons["meeting.audioTrack.row.b53c91da-05f8-4a76-978c-22bd87411804"]
        require(microphone, message: "Microphone child is missing")
        require(application, message: "Application child is missing")
        attach("Separate original tracks")
        tap(microphone, message: "Open microphone track")
        require(app.staticTexts["meeting.audioTrack.source"], message: "Source identity is missing")
        let microphoneText = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "마이크 트랙의 독립 전사")).firstMatch
        require(microphoneText, message: "Microphone transcript is missing")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "앱 트랙의 독립 전사")).firstMatch.exists)
        let play = app.buttons["meeting.playbackButton"]
        requireHittable(play, message: "Track playback is missing")
        tap(play, message: "Play microphone FLAC")
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "음성 일시 정지"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        let advanced = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "00:0[1-7]  /  00:08")).firstMatch
        require(advanced, timeout: 6, message: "Playback did not advance through real saved audio")
        attach("Microphone-only playback")
        tap(play, message: "Pause microphone playback")
        app.navigationBars.buttons.firstMatch.tap()
        tap(application, message: "Open application track")
        let applicationText = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "앱 트랙의 독립 전사")).firstMatch
        require(applicationText, message: "Application transcript is missing")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "마이크 트랙의 독립 전사")).firstMatch.exists)
        attach("Application-only transcript")
        app.navigationBars.buttons.firstMatch.tap()
        tap(app.buttons["meeting.audioTrack.exportAll"], message: "Export separate original tracks")
        let sheet = app.otherElements["ActivityListView"]
        if !sheet.waitForExistence(timeout: 30) {
            attach("Export surface")
            print(app.debugDescription)
        }
        XCTAssertTrue(sheet.exists, "A real system sharing sheet must receive the track archive")
        attach("Separate FLAC archive sharing")
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
