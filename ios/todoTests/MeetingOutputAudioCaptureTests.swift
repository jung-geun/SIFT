import Foundation
import AVFoundation
import Testing
@testable import todo

@MainActor
@Suite("Meeting output audio admission")
struct MeetingOutputAudioCaptureTests {
    @Test("Physical route identity includes its stream")
    func streamIdentity() {
        let first = MeetingOutputAudioRoute(uid: "speaker", streamIndex: 0, name: "Speaker", isDefault: true)
        let second = MeetingOutputAudioRoute(uid: "speaker", streamIndex: 1, name: "Speaker", isDefault: true)
        #expect(first.id != second.id)
        #expect(first.id == MeetingOutputAudioRoute(uid: "speaker", streamIndex: 0, name: "Renamed", isDefault: false).id)
    }

    @Test("No native tap starts before recording consent")
    func consentRequired() async {
        let bridge = OutputTapFixture()
        let capture = MeetingOutputAudioCapture(source: .application("output"), receive: { _, _, _ in }, changed: { _ in }, bridge: bridge)
        do {
            try await capture.start(route: nil, processID: nil, consentConfirmed: false)
            Issue.record("Capture started without consent")
        } catch { #expect(error is MeetingOutputAudioCapture.Failure) }
        #expect(bridge.startCount == 0)
    }

    @Test("Pause and cancellation reject queued output buffers; stale start cannot reopen")
    func outputDeliveryFence() {
        let output = MeetingCaptureSourceGate()
        let microphone = MeetingCaptureSourceGate()
        let outputTicket = output.replace()
        let microphoneTicket = microphone.replace()
        output.activate(outputTicket)
        microphone.activate(microphoneTicket)
        var outputCount = 0
        var microphoneCount = 0
        output.deliver(outputTicket) { outputCount += 1 }
        output.suspend(outputTicket)
        output.deliver(outputTicket) { outputCount += 1 }
        microphone.deliver(microphoneTicket) { microphoneCount += 1 }
        output.activate(outputTicket)
        output.deliver(outputTicket) { outputCount += 1 }
        _ = output.replace() // Device loss, cancel, or replacement invalidates the ticket.
        output.activate(outputTicket)
        output.deliver(outputTicket) { outputCount += 1 }
        #expect(outputCount == 2)
        #expect(microphoneCount == 1)
    }

    @Test("Stopping during native startup settles once and rejects late permission success")
    func stopDuringPermission() async {
        let bridge = OutputTapFixture()
        let capture = MeetingOutputAudioCapture(source: .application("output"), receive: { _, _, _ in }, changed: { _ in }, bridge: bridge)
        let started = Task {
            do {
                try await capture.start(route: nil, processID: 42, consentConfirmed: true)
                Issue.record("Stopped startup unexpectedly succeeded")
            } catch { #expect(error is CancellationError) }
        }
        while bridge.startCount == 0 { await Task.yield() }
        capture.stop()
        bridge.completeLate()
        await started.value
        #expect(capture.state == .disabled)
        #expect(bridge.requestedProcessID == 42)
    }
    @Test("Task cancellation closes a suspended output permission request")
    func cancellationDuringPermission() async {
        let bridge = OutputTapFixture()
        let capture = MeetingOutputAudioCapture(source: .application("output"), receive: { _, _, _ in }, changed: { _ in }, bridge: bridge)
        let startup = Task {
            do {
                try await capture.start(route: nil, processID: nil, consentConfirmed: true)
                Issue.record("Cancelled output startup unexpectedly succeeded")
            } catch { #expect(error is CancellationError) }
        }
        while bridge.startCount == 0 { await Task.yield() }
        startup.cancel()
        await startup.value
        bridge.completeLate()
        #expect(capture.state == .disabled)
    }

    @Test("A native startup that never replies cannot defeat the host deadline")
    func unresponsiveStartupDeadline() async {
        let bridge = OutputTapFixture() // Never completes and ignores native stop.
        let capture = MeetingOutputAudioCapture(source: .application("output"), receive: { _, _, _ in }, changed: { _ in }, bridge: bridge)
        do {
            try await capture.start(route: nil, processID: nil, consentConfirmed: true, startupTimeout: .milliseconds(1))
            Issue.record("Unresponsive native startup unexpectedly succeeded")
        } catch MeetingOutputAudioCapture.Failure.native(let error) {
            #expect(error.code == 5)
        } catch { Issue.record("Unexpected startup deadline error: \(error)") }
        guard case .unavailable = capture.state else {
            Issue.record("Deadline did not publish the unavailable state")
            return
        }
        bridge.completeLate()
        await Task.yield()
        guard case .unavailable = capture.state else {
            Issue.record("Late native success reopened the timed-out source")
            return
        }
    }


    @Test("Selected UID, stream and host-timed PCM reach only the approved output lane")
    func adapterPCMDelivery() async throws {
        let bridge = OutputTapFixture()
        let deliveries = OutputDeliveryCounter()
        let source = MeetingAudioSourceRouter.Source.application("output")
        let capture = MeetingOutputAudioCapture(source: source, receive: { buffer, hostTime, lane in
            #expect(buffer.frameLength == 16)
            #expect(hostTime == 12.5)
            #expect(lane == source)
            deliveries.increment()
        }, changed: { _ in }, bridge: bridge)
        let route = MeetingOutputAudioRoute(uid: "chosen-speaker", streamIndex: 2, name: "Speaker", isDefault: false)
        let startup = Task { try await capture.start(route: route, processID: nil, consentConfirmed: true) }
        while bridge.startCount == 0 { await Task.yield() }
        bridge.emitPCM()
        #expect(deliveries.value == 0)
        bridge.completeLate()
        try await startup.value
        bridge.emitPCM()
        capture.pause()
        bridge.emitPCM()
        capture.resume()
        bridge.emitPCM()
        capture.stop()
        bridge.emitPCM()
        bridge.completeLate()
        #expect(deliveries.value == 2)
        #expect(bridge.requestedRoute == "chosen-speaker#2")
        #expect(capture.state == .disabled)
    }
}

nonisolated private final class OutputTapFixture: NSObject, MeetingOutputAudioCaptureBridging, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var process: Int32 = 0
    private var completion: (@Sendable (NSError?) -> Void)?
    private var receive: (@Sendable (UnsafeRawPointer, UnsafeRawPointer, Double) -> Void)?
    private var route = ""
    var requestedRoute: String { lock.withLock { route } }
    var startCount: Int { lock.withLock { count } }
    var requestedProcessID: Int32 { lock.withLock { process } }
    required override init() { super.init() }
    func outputDevices() throws -> [[String: Any]] { [] }
    func start(deviceUID: String?, streamIndex: UInt32, processID: Int32,
               receive: @escaping @Sendable (UnsafeRawPointer, UnsafeRawPointer, Double) -> Void,
               failed: @escaping @Sendable (NSError) -> Void, completion: @escaping @Sendable (NSError?) -> Void) {
        lock.withLock {
            count += 1; process = processID; self.completion = completion; self.receive = receive
            route = "\(deviceUID ?? "default")#\(streamIndex)"
        }
    }
    func stop() {} // Deliberately retain a callback already queued by the OS.
    func completeLate() { lock.withLock { completion }?(nil) }
    func emitPCM() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        let callback = lock.withLock { receive }
        callback?(UnsafeRawPointer(buffer.audioBufferList), UnsafeRawPointer(format.streamDescription), 12.5)
    }
}

nonisolated private final class OutputDeliveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
