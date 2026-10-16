import Foundation
import Testing
@testable import todo

@Suite("Meeting app audio picker ownership")
@MainActor
struct MeetingAppAudioCaptureTests {
    @Test("Only the pending presenter consumes a nil-stream selection")
    func selectionRoutesToPresenter() {
        let sessions = MeetingAppAudioPickerSessions()
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        let firstGate = MeetingAppAudioPickerDecisionGate()
        let secondGate = MeetingAppAudioPickerDecisionGate()
        #expect(sessions.reserve(first, supportsMultipleSources: true))
        #expect(firstGate.update(streamID: nil, ownsPresentation: sessions.ownsPresentation(first)) == .selected)
        #expect(secondGate.update(streamID: nil, ownsPresentation: sessions.ownsPresentation(second)) == .ignored)
        #expect(firstGate.hasSelection)
        #expect(!secondGate.hasSelection)
        // Keep ownership until startCapture completes; another start cannot race it.
        #expect(!sessions.reserve(second, supportsMultipleSources: true))
        sessions.finishPresentation(first)
        #expect(sessions.reserve(second, supportsMultipleSources: true))
        #expect(firstGate.update(streamID: nil, ownsPresentation: sessions.ownsPresentation(first)) == .ignored)
        #expect(secondGate.update(streamID: nil, ownsPresentation: sessions.ownsPresentation(second)) == .selected)
    }

    @Test("Nil cancellation and picker startup failure belong only to the presenter")
    func cancellationRoutesToPresenter() {
        let first = MeetingAppAudioPickerDecisionGate()
        let second = MeetingAppAudioPickerDecisionGate()
        #expect(!first.cancel(streamID: nil, ownsPresentation: false))
        #expect(second.cancel(streamID: nil, ownsPresentation: true))
        #expect(second.update(streamID: nil, ownsPresentation: true) == .ignored)
        #expect(!second.hasSelection)
        #expect(first.update(streamID: nil, ownsPresentation: true) == .selected)
    }

    @Test("Late dismissal and duplicate nil selection cannot revoke approved content")
    func ignoresLateDismissal() {
        let gate = MeetingAppAudioPickerDecisionGate()
        #expect(gate.update(streamID: nil, ownsPresentation: true) == .selected)
        #expect(!gate.cancel(streamID: nil, ownsPresentation: true))
        #expect(gate.update(streamID: nil, ownsPresentation: true) == .ignored)
        #expect(gate.hasSelection)
    }

    @Test("Existing stream callbacks route by object identity, never by pending presentation")
    func streamUpdatesAreIndependent() {
        let firstStream = NSObject()
        let secondStream = NSObject()
        let first = MeetingAppAudioPickerDecisionGate()
        let second = MeetingAppAudioPickerDecisionGate()
        #expect(first.update(streamID: nil, ownsPresentation: true) == .selected)
        #expect(second.update(streamID: nil, ownsPresentation: true) == .selected)
        first.bind(streamID: ObjectIdentifier(firstStream))
        second.bind(streamID: ObjectIdentifier(secondStream))
        #expect(first.update(streamID: ObjectIdentifier(secondStream), ownsPresentation: true) == .ignored)
        #expect(second.update(streamID: ObjectIdentifier(secondStream), ownsPresentation: false) == .revoked)
        #expect(first.hasSelection)
        #expect(!second.hasSelection)
        #expect(second.update(streamID: nil, ownsPresentation: true) == .ignored)
        #expect(second.update(streamID: ObjectIdentifier(secondStream), ownsPresentation: true) == .ignored)
    }

    @Test("Cancelling an existing-stream picker leaves both approved selections intact")
    func existingStreamCancellationDoesNotStopCapture() {
        let stream = NSObject()
        let gate = MeetingAppAudioPickerDecisionGate()
        #expect(gate.update(streamID: nil, ownsPresentation: true) == .selected)
        gate.bind(streamID: ObjectIdentifier(stream))
        #expect(!gate.cancel(streamID: ObjectIdentifier(stream), ownsPresentation: true))
        #expect(gate.hasSelection)
        let pending = MeetingAppAudioPickerDecisionGate()
        #expect(!pending.cancel(streamID: ObjectIdentifier(stream), ownsPresentation: true))
        #expect(pending.update(streamID: nil, ownsPresentation: true) == .selected)
    }

    @Test("A pending observer ignores updates for somebody else's real stream")
    func pendingDoesNotAdoptExistingStream() {
        let stream = NSObject()
        let gate = MeetingAppAudioPickerDecisionGate()
        #expect(gate.update(streamID: ObjectIdentifier(stream), ownsPresentation: true) == .ignored)
        #expect(!gate.hasSelection)
        #expect(gate.update(streamID: nil, ownsPresentation: true) == .selected)
    }

    @Test("Immutable selection update revokes queued delivery without an actor hop")
    func selectionUpdateClosesDelivery() {
        let stream = NSObject()
        let selection = MeetingAppAudioPickerDecisionGate()
        let delivery = MeetingCaptureSourceGate()
        #expect(selection.update(streamID: nil, ownsPresentation: true) == .selected)
        selection.bind(streamID: ObjectIdentifier(stream))
        let ticket = delivery.replace()
        delivery.activate(ticket)
        var samples: [Int] = []
        delivery.deliver(ticket) { samples.append(1) }
        if selection.update(streamID: ObjectIdentifier(stream), ownsPresentation: false) == .revoked {
            _ = delivery.replace() // Same synchronous operation as the SDK callback.
        }
        delivery.deliver(ticket) { samples.append(2) }
        delivery.activate(ticket) // A suspended start must not reopen the old lane.
        delivery.deliver(ticket) { samples.append(3) }
        #expect(samples == [1])
        #expect(!selection.hasSelection)
    }

    @Test("Readiness gates delivery and revoking one session leaves another live")
    func deliveryGatesAreIndependent() {
        let first = MeetingCaptureSourceGate()
        let second = MeetingCaptureSourceGate()
        let firstTicket = first.replace()
        let secondTicket = second.replace()
        var samples: [Int] = []
        first.deliver(firstTicket) { samples.append(0) }
        first.activate(firstTicket)
        second.activate(secondTicket)
        first.deliver(firstTicket) { samples.append(1) }
        second.deliver(secondTicket) { samples.append(2) }
        _ = first.replace()
        first.activate(firstTicket)
        first.deliver(firstTicket) { samples.append(3) }
        second.deliver(secondTicket) { samples.append(4) }
        #expect(samples == [1, 2, 4])
    }

    @Test("Invalidating an observer rejects all callbacks and binding attempts")
    func invalidatedObserverStaysClosed() {
        let stream = NSObject()
        let gate = MeetingAppAudioPickerDecisionGate()
        gate.invalidate()
        gate.bind(streamID: ObjectIdentifier(stream))
        #expect(gate.update(streamID: nil, ownsPresentation: true) == .ignored)
        #expect(gate.update(streamID: ObjectIdentifier(stream), ownsPresentation: true) == .ignored)
        #expect(!gate.cancel(streamID: nil, ownsPresentation: true))
        #expect(!gate.hasSelection)
    }

    @Test("Mac session capacity admits four independent owners and recycles stopped slots")
    func macCapacityAndCleanup() {
        let sessions = MeetingAppAudioPickerSessions()
        let ids = (0..<5).map { _ in UUID().uuidString.lowercased() }
        for id in ids.prefix(4) {
            #expect(sessions.reserve(id, supportsMultipleSources: true))
            sessions.finishPresentation(id)
        }
        #expect(!sessions.reserve(ids[4], supportsMultipleSources: true))
        #expect(!sessions.reserve(ids[0], supportsMultipleSources: true))
        #expect(!sessions.release(ids[1])) // Other streams still own the active picker.
        #expect(sessions.reserve(ids[4], supportsMultipleSources: true))
        #expect(sessions.ownsPresentation(ids[4]))
        sessions.finishPresentation(ids[0]) // Foreign readiness cannot clear this presentation.
        #expect(sessions.ownsPresentation(ids[4]))
        #expect(!sessions.release(ids[0]))
        #expect(!sessions.release(ids[2]))
        #expect(!sessions.release(ids[3]))
        #expect(sessions.release(ids[4]))
        #expect(!sessions.ownsPresentation(ids[4]))
    }

    @Test("Stopping a foreign owner cannot cancel another pending selection")
    func cleanupPreservesPendingOwner() {
        let sessions = MeetingAppAudioPickerSessions()
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        #expect(sessions.reserve(first, supportsMultipleSources: true))
        sessions.finishPresentation(first)
        #expect(sessions.reserve(second, supportsMultipleSources: true))
        #expect(!sessions.release(first))
        #expect(sessions.ownsPresentation(second))
        #expect(sessions.release(second))
        #expect(!sessions.ownsPresentation(second))
    }

    @Test("iPhone capacity stays one even after picker readiness")
    func phoneCapacityIsOne() {
        let sessions = MeetingAppAudioPickerSessions()
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        #expect(sessions.reserve(first, supportsMultipleSources: false))
        sessions.finishPresentation(first)
        #expect(!sessions.reserve(second, supportsMultipleSources: false))
        #expect(sessions.release(first))
        #expect(sessions.reserve(second, supportsMultipleSources: false))
    }

    @Test("Capture identities are independent clean UUIDs or the coordinator's supplied UUID")
    func captureMetadata() throws {
        let first = MeetingAppAudioCapture(receive: { _, _, _ in }, stateChanged: { _ in }, microphoneFailed: { _ in })
        let second = MeetingAppAudioCapture(receive: { _, _, _ in }, stateChanged: { _ in }, microphoneFailed: { _ in })
        #expect(first.sourceID != second.sourceID)
        #expect(first.sourceID == first.sourceID.lowercased())
        #expect(UUID(uuidString: first.sourceID) != nil)
        #expect(UUID(uuidString: second.sourceID) != nil)
        let suppliedID = UUID().uuidString.lowercased()
        let supplied = MeetingAppAudioCapture(sourceID: suppliedID, receive: { _, _, _ in }, stateChanged: { _ in }, microphoneFailed: { _ in })
        #expect(supplied.sourceID == suppliedID)
        #expect(supplied.sourceKind == .screen)
        #expect(supplied.selectedSourceDescription == nil)
        #expect(supplied.state == .disabled)
        #if !targetEnvironment(macCatalyst) || targetEnvironment(simulator)
        #expect(!MeetingAppAudioCapture.supportsMultipleSources)
        #endif
    }

    @Test("Missing consent rejects before presenting or reserving a system source")
    func requiresConsent() async {
        let capture = MeetingAppAudioCapture(receive: { _, _, _ in }, stateChanged: { _ in }, microphoneFailed: { _ in })
        do {
            try await capture.selectSourceAndWait(consentConfirmed: false)
            Issue.record("Source selection must require consent")
        } catch {
            guard let error = error as? MeetingAppAudioCapture.CaptureError,
                  case .consentRequired = error else {
                Issue.record("Expected consentRequired")
                return
            }
        }
        #expect(capture.state == .disabled)
        #expect(!capture.microphoneApproved)
        #expect(capture.selectedSourceDescription == nil)
        await capture.stop()
    }
}
