import XCTest

@MainActor
final class MeetingSourceControlsUITests: SIFTUITestCase {
    func testUnsupportedAppAudioCannotStartSourceLessRecording() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The unsupported-app state is specific to the simulator.")
        #else
        launch(.init(startTab: .meetings))
        let microphone = app.switches["meeting.source.microphone.toggle"]
        let appAudio = app.switches["meeting.source.app.toggle"]
        let start = app.buttons["meeting.action.startRecording"]
        require(microphone, message: "마이크 소스 스위치가 없습니다.")
        require(appAudio, message: "앱 오디오 소스 스위치가 없습니다.")
        XCTAssertFalse(appAudio.isEnabled, "Simulator must not pretend to capture another app")
        require(app.staticTexts["meeting.source.app.availability"], message: "앱 오디오 불가 안내가 없습니다.")

        let consent = app.switches.containing(NSPredicate(format: "label CONTAINS %@", "녹음 고지")).firstMatch
        tap(consent, message: "녹음 동의 스위치가 없습니다.")
        XCTAssertEqual(microphone.value as? String, "1")
        microphone.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let microphoneOff = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "0"), object: microphone
        )
        XCTAssertEqual(XCTWaiter.wait(for: [microphoneOff], timeout: 5), .completed)
        XCTAssertFalse(start.isEnabled, "Starting with both sources off must be impossible")
        microphone.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let microphoneOn = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"), object: microphone
        )
        XCTAssertEqual(XCTWaiter.wait(for: [microphoneOn], timeout: 5), .completed)
        XCTAssertTrue(start.isEnabled, "Restoring the microphone must permit recording")
        #endif
    }
}
