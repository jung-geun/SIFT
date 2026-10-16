import Foundation
import CoreMedia
import Testing
@testable import todo

@Suite("Meeting audio source startup policy")
@MainActor
struct MeetingAudioSourceControlTests {
    @Test("Starting with both sources off rejects before recording")
    func rejectsNoSource() async {
        let coordinator = MeetingCaptureCoordinator()
        do {
            try await coordinator.start(meetingID: UUID().uuidString, languageTag: "en-US",
                                        microphoneEnabled: false, appAudioEnabled: false)
            Issue.record("A recording must not start without an enabled source")
        } catch {
            guard let error = error as? MeetingCaptureCoordinator.CaptureError,
                  case .noAudioSource = error else {
                Issue.record("Expected noAudioSource, received \(error)")
                return
            }
        }
        #expect(coordinator.status == .ready)
        #expect(coordinator.recordedAudioSamples == 0)
        #expect(coordinator.appAudioState == .disabled)
    }

    @Test("App-only startup rejects missing consent before speech or microphone setup")
    func requiresAppConsent() async {
        let coordinator = MeetingCaptureCoordinator()
        do {
            try await coordinator.start(meetingID: UUID().uuidString, languageTag: "en-US",
                                        microphoneEnabled: false, appAudioEnabled: true,
                                        consentConfirmed: false)
            Issue.record("App audio must not start without explicit consent")
        } catch {
            guard let error = error as? MeetingAppAudioCapture.CaptureError,
                  case .consentRequired = error else {
                Issue.record("Expected consentRequired, received \(error)")
                return
            }
        }
        #expect(coordinator.status == .failed)
        #expect(coordinator.microphoneEnabled == false)
        #expect(coordinator.recordedAudioSamples == 0)
        #expect(coordinator.appAudioState == .disabled)
    }

    @Test("Legacy audio manifests remain readable without source metadata")
    func decodesLegacyManifest() throws {
        let json = #"{"relativeDirectory":"legacy/audio","sampleRate":16000,"totalSamples":16000,"parts":[{"fileName":"part-00.flac","partIndex":0,"partStartSample":0,"ownedStartSample":0,"ownedEndSample":16000}]}"#
        let manifest = try JSONDecoder().decode(MeetingAudioManifest.self, from: Data(json.utf8))
        #expect(manifest.captureSourceMetadata == nil)
        #expect(manifest.parts[0].ownedEndSample == 16_000)
        #expect(manifest.totalSamples == 16_000)
    }



    @Test("Replaced source cannot deliver pending audio or reactivate after a newer selection")
    func replacementClosesOldSource() {
        let gate = MeetingCaptureSourceGate()
        let first = gate.replace()
        gate.activate(first)
        var delivered: [Int] = []
        gate.deliver(first) { delivered.append(1) }
        let second = gate.replace()
        gate.deliver(first) { delivered.append(2) }
        gate.activate(first)
        gate.deliver(first) { delivered.append(3) }
        gate.deliver(second) { delivered.append(4) }
        gate.activate(second)
        gate.deliver(second) { delivered.append(5) }
        #expect(delivered == [1, 5])
    }

    @Test("Audio-only iOS capture keeps host-aligned PTS when SCStream has no synchronization clock")
    func hostDomainPTSWithoutStreamClock() {
        let host = CMClockGetHostTimeClock()
        let recent = CMClockGetTime(host).seconds - 0.05
        let pts = CMTime(seconds: recent, preferredTimescale: 1_000_000)
        let converted = MeetingAppAudioTimestamp.hostTime(pts, sourceClock: nil, hostClock: host)
        #expect(converted != nil)
        if let converted { #expect(abs(converted - recent) < 0.001) }

        let unrelated = CMTime(seconds: recent - 60, preferredTimescale: 1_000_000)
        #expect(MeetingAppAudioTimestamp.hostTime(unrelated, sourceClock: nil, hostClock: host) == nil)
        #expect(MeetingAppAudioTimestamp.hostTime(.invalid, sourceClock: nil, hostClock: host) == nil)
        let convertedWithClock = MeetingAppAudioTimestamp.hostTime(unrelated, sourceClock: host, hostClock: host)
        #expect(convertedWithClock != nil)
        if let convertedWithClock { #expect(abs(convertedWithClock - (recent - 60)) < 0.001) }
    }

    @Test("Interruption revokes pending microphone approval and never auto-resumes")
    func interruptedApprovalCannotReopenMicrophone() {
        let gate = MeetingMicrophoneConsentGate()
        let pending = gate.beginApproval()
        var closures = 0
        let revoked = gate.interrupt { closures += 1 }
        #expect(closures == 1)
        #expect(gate.isCurrent(revoked))
        #expect(!gate.approve(pending, enabled: true))
        var deliveries = 0
        gate.deliver { deliveries += 1 }
        #expect(deliveries == 0)
        let retry = gate.beginApproval()
        #expect(!gate.approve(retry, enabled: true)) // Even a new picker callback cannot auto-resume.
        gate.clearInterruption() // Only an explicit user enable can clear the latch.
        let approved = gate.beginApproval()
        #expect(gate.approve(approved, enabled: true))
        gate.deliver { deliveries += 1 }
        #expect(deliveries == 1)
        _ = gate.revoke { closures += 1 }
        gate.deliver { deliveries += 1 }
        #expect(closures == 2)
        #expect(deliveries == 1)
    }
}
