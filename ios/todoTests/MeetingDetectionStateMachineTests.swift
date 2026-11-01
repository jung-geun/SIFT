import Foundation
import Testing
@testable import todo

@Suite("Meeting suggestion metadata state machine")
struct MeetingDetectionStateMachineTests {
    private let epoch = Date(timeIntervalSince1970: 1_000)
    private func candidate(_ id: String = "zoom:123:launch", input: Bool = true, output: Bool = true) -> MeetingDetectionCandidate {
        MeetingDetectionCandidate(sessionID: id, processID: 123, bundleIdentifier: "us.zoom.xos",
                                  displayName: "Zoom", isBrowser: false, runningInput: input, runningOutput: output)
    }

    @Test("Requires both directions and three seconds of stable activity")
    func stabilizesAndDebounces() {
        var machine = MeetingDetectionStateMachine()
        #expect(machine.observe([candidate(input: false)], at: epoch, recordingActive: false) == nil)
        #expect(machine.observe([candidate()], at: epoch.addingTimeInterval(1), recordingActive: false) == nil)
        #expect(machine.observe([candidate()], at: epoch.addingTimeInterval(3.9), recordingActive: false) == nil)
        let prompt = machine.observe([candidate()], at: epoch.addingTimeInterval(4), recordingActive: false)
        #expect(prompt?.candidate.processID == 123)
        #expect(prompt?.expiresAt == epoch.addingTimeInterval(34))
        #expect(machine.observe([candidate()], at: epoch.addingTimeInterval(5), recordingActive: false)?.token == prompt?.token)
    }

    @Test("Start consumes exactly once and cannot start during another recording")
    func duplicateStart() throws {
        var machine = MeetingDetectionStateMachine()
        _ = machine.observe([candidate()], at: epoch, recordingActive: false)
        let observedPrompt = machine.observe([candidate()], at: epoch.addingTimeInterval(3), recordingActive: false)
        let prompt = try #require(observedPrompt)
        #expect(machine.accept(token: prompt.token, at: epoch.addingTimeInterval(4), recordingActive: false) == candidate())
        #expect(machine.accept(token: prompt.token, at: epoch.addingTimeInterval(4), recordingActive: false) == nil)
        #expect(machine.observe([candidate()], at: epoch.addingTimeInterval(20), recordingActive: false) == nil)
        machine.reset()
        _ = machine.observe([candidate()], at: epoch, recordingActive: false)
        let observedSecondPrompt = machine.observe([candidate()], at: epoch.addingTimeInterval(3), recordingActive: false)
        let second = try #require(observedSecondPrompt)
        #expect(machine.accept(token: second.token, at: epoch.addingTimeInterval(4), recordingActive: true) == nil)
    }

    @Test("Exact deadline rejects stale clicks and expiry does not repeat")
    func expiry() throws {
        var machine = MeetingDetectionStateMachine()
        _ = machine.observe([candidate()], at: epoch, recordingActive: false)
        let observedPrompt = machine.observe([candidate()], at: epoch.addingTimeInterval(3), recordingActive: false)
        let prompt = try #require(observedPrompt)
        #expect(machine.accept(token: prompt.token, at: prompt.expiresAt, recordingActive: false) == nil)
        #expect(machine.observe([candidate()], at: epoch.addingTimeInterval(80), recordingActive: false) == nil)
    }

    @Test("Skip suppresses same-session mute and unmute, including long mic mute")
    func dismissalAndMute() throws {
        var machine = MeetingDetectionStateMachine()
        _ = machine.observe([candidate()], at: epoch, recordingActive: false)
        let observedPrompt = machine.observe([candidate()], at: epoch.addingTimeInterval(3), recordingActive: false)
        let prompt = try #require(observedPrompt)
        machine.dismiss(token: UUID())
        #expect(machine.suggestion?.token == prompt.token)
        machine.dismiss(token: prompt.token)
        #expect(machine.observe([candidate(input: false)], at: epoch.addingTimeInterval(4), recordingActive: false) == nil)
        #expect(machine.observe([candidate(input: false)], at: epoch.addingTimeInterval(180), recordingActive: false) == nil)
        #expect(machine.observe([candidate()], at: epoch.addingTimeInterval(181), recordingActive: false) == nil)
        #expect(machine.observe([candidate()], at: epoch.addingTimeInterval(190), recordingActive: false) == nil)
    }

    @Test("Both directions quiet for a minute permits a new call; process quit resets immediately")
    func sessionReset() throws {
        var machine = MeetingDetectionStateMachine()
        _ = machine.observe([candidate()], at: epoch, recordingActive: false)
        let observedFirstPrompt = machine.observe([candidate()], at: epoch.addingTimeInterval(3), recordingActive: false)
        let first = try #require(observedFirstPrompt)
        machine.dismiss(token: first.token)
        _ = machine.observe([candidate(input: false, output: false)], at: epoch.addingTimeInterval(5), recordingActive: false)
        _ = machine.observe([candidate(input: false, output: false)], at: epoch.addingTimeInterval(65), recordingActive: false)
        #expect(machine.observe([candidate()], at: epoch.addingTimeInterval(66), recordingActive: false) == nil)
        let observedSecondPrompt = machine.observe([candidate()], at: epoch.addingTimeInterval(69), recordingActive: false)
        let second = try #require(observedSecondPrompt)
        #expect(second.token != first.token)
        _ = machine.observe([], at: epoch.addingTimeInterval(70), recordingActive: false)
        #expect(machine.accept(token: second.token, at: epoch.addingTimeInterval(71), recordingActive: false) == nil)
        _ = machine.observe([candidate("zoom:456:newLaunch")], at: epoch.addingTimeInterval(72), recordingActive: false)
        #expect(machine.observe([candidate("zoom:456:newLaunch")], at: epoch.addingTimeInterval(75), recordingActive: false) != nil)
    }

    @Test("Activity changes retract prompt and reset clears sleep or disabled state")
    func retractAndReset() throws {
        var machine = MeetingDetectionStateMachine()
        _ = machine.observe([candidate()], at: epoch, recordingActive: false)
        let observedPrompt = machine.observe([candidate()], at: epoch.addingTimeInterval(3), recordingActive: false)
        let prompt = try #require(observedPrompt)
        #expect(machine.observe([candidate(output: false)], at: epoch.addingTimeInterval(4), recordingActive: false) == nil)
        #expect(machine.accept(token: prompt.token, at: epoch.addingTimeInterval(5), recordingActive: false) == nil)
        machine.reset()
        _ = machine.observe([candidate()], at: epoch.addingTimeInterval(6), recordingActive: false)
        #expect(machine.observe([candidate()], at: epoch.addingTimeInterval(9), recordingActive: false) != nil)
        #expect(machine.observe([candidate()], at: epoch.addingTimeInterval(10), recordingActive: true) == nil)
    }

    @Test("Detection opt-in and app allowlist cannot be exported or enabled by cloud restore")
    func detectionConsentIsNeverPortable() throws {
        let suite = "SIFTMeetingDetectionConsent-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = [MeetingDetectionPreferenceKey.enabled,
                    MeetingDetectionPreferenceKey.allowedApplication("us.zoom.xos"),
                    MeetingDetectionPreferenceKey.allowedApplication("com.google.Chrome")]
        for key in keys {
            #expect(!CloudPreferenceStore.isUserPreference(key))
            defaults.set(true, forKey: key)
        }
        let snapshot = try CloudPreferenceStore.capture(defaults: defaults)
        let foreign = try JSONEncoder().encode(CloudPreferenceValue.boolean(true))
        for key in keys {
            #expect(snapshot["preference/" + key] == nil)
            defaults.set(false, forKey: key)
            #expect(throws: CloudPreferenceError.self) {
                try CloudPreferenceStore.apply(key: "preference/" + key, payload: foreign,
                    expectedDigest: nil, defaults: defaults)
            }
            #expect(!defaults.bool(forKey: key))
        }
        // Earlier syncable namespace values are not read or migrated as consent.
        defaults.set(true, forKey: "pieroot.todo.meetingDetection.enabled")
        #expect(!defaults.bool(forKey: MeetingDetectionPreferenceKey.enabled))
    }
}
