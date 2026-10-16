import AVFoundation
import CoreAudio
import Foundation
import CoreMedia
import AudioToolbox

struct MeetingMicrophoneRoute: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let portType: String
}

struct MeetingMicrophoneRoutes: Sendable {
    let available: [MeetingMicrophoneRoute]
    let selectedID: String?
}

final class MeetingAudioSessionController: @unchecked Sendable {
    static let shared = MeetingAudioSessionController()
    private let queue = DispatchQueue(label: "pieroot.todo.meeting.audio-session", qos: .userInitiated)

    /// - Parameter voiceProcessing: when true, configures the session for Apple
    ///   Voice Processing I/O (AEC + noise suppression + AGC) via
    ///   `.playAndRecord`/`.voiceChat`; when false, uses `.measurement`.
    /// - Parameter coexistWithAppAudio: enables non-ducking `.mixWithOthers`
    ///   on the supported multi-source path. The iOS 26 mic-only path retains
    ///   its existing `.record` category when voice processing is disabled.
    func activateForRecording(voiceProcessing: Bool, coexistWithAppAudio: Bool = false) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    if voiceProcessing {
                        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
                        if coexistWithAppAudio { options.insert(.mixWithOthers) }
                        try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
                    } else if coexistWithAppAudio {
                        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .mixWithOthers])
                    } else {
                        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
                    }
                    try session.setActive(true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func activateForPlayback() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .default, options: [])
                    try session.setActive(true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The system may expose no selectable inputs until a recording session is active.
    func microphoneRoutes() async -> MeetingMicrophoneRoutes {
        await withCheckedContinuation { continuation in
            queue.async {
                #if targetEnvironment(macCatalyst)
                let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
                continuation.resume(returning: MeetingMicrophoneRoutes(
                    available: devices.filter(\.isConnected).map {
                        MeetingMicrophoneRoute(id: $0.uniqueID, name: $0.localizedName, portType: $0.deviceType.rawValue)
                    }, selectedID: AVCaptureDevice.default(for: .audio)?.uniqueID
                ))
                #else
                let session = AVAudioSession.sharedInstance()
                continuation.resume(returning: MeetingMicrophoneRoutes(
                    available: (session.availableInputs ?? []).map {
                        MeetingMicrophoneRoute(id: $0.uid, name: $0.portName, portType: $0.portType.rawValue)
                    },
                    selectedID: session.currentRoute.inputs.first?.uid
                ))
                #endif
            }
        }
    }

    /// nil restores system selection; UIDs must come from the current route snapshot.
    func selectMicrophoneRoute(id: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    #if targetEnvironment(macCatalyst)
                    if let id {
                        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
                        guard devices.contains(where: { $0.uniqueID == id && $0.isConnected }) else { throw RouteError.unavailable }
                    }
                    #else
                    let session = AVAudioSession.sharedInstance()
                    let input = id.flatMap { id in session.availableInputs?.first { $0.uid == id } }
                    if id != nil && input == nil { throw RouteError.unavailable }
                    try session.setPreferredInput(input)
                    #endif
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    enum RouteError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            AppLanguage.localized(
                "meeting.capture.microphoneRouteUnavailable",
                defaultValue: AppLanguage.current == .english
                    ? "This microphone is unavailable. Refresh inputs and select an available microphone."
                    : "이 마이크를 사용할 수 없습니다. 입력 목록을 새로 고친 후 사용할 마이크를 선택하세요.",
                language: .current,
                comment: "Selected microphone route is no longer available."
            )
        }
    }

    func deactivate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                defer { continuation.resume() }
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}

#if targetEnvironment(macCatalyst)
/// Captures the explicitly selected Mac input rather than AVAudioSession's system
/// microphone. This never feeds audio until the coordinator opens the source gate.
nonisolated final class MeetingCatalystMicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum CaptureError: Error { case unavailableDevice, unsupportedInput, startFailed, missingClock, invalidPCM, interrupted, disconnected }
    private static let sessionQueue = DispatchQueue(label: "pieroot.todo.meeting.mac-microphone", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "pieroot.todo.meeting.mac-microphone.samples", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let lock = NSLock()
    private let receive: @Sendable (AVAudioPCMBuffer, Double) -> Void
    private let failed: @Sendable (Error) -> Void
    private var accepting = false
    private var ready = false
    private var paused = false
    private var stopped = false
    private var failureReported = false
    // Session queue owns configuration and observer registration.
    private var observers = [NSObjectProtocol]()
    // Sample queue owns format caching.
    private var cachedASBD: AudioStreamBasicDescription?
    private var cachedFormat: AVAudioFormat?

    init(receive: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void,
         failed: @escaping @Sendable (Error) -> Void) {
        self.receive = receive
        self.failed = failed
        super.init()
    }

    func start(deviceID: String?, running: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Self.sessionQueue.async { [self] in
                do {
                    guard lock.withLock({ !stopped && !ready }) else { throw CancellationError() }
                    let device: AVCaptureDevice?
                    if let deviceID {
                        device = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
                            .devices.first { $0.uniqueID == deviceID }
                    } else {
                        device = AVCaptureDevice.default(for: .audio)
                    }
                    guard let device, device.isConnected else { throw CaptureError.unavailableDevice }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    // The chosen AVCaptureDeviceInput owns routing; don't let the
                    // application's AVAudioSession substitute the system microphone.
                    session.usesApplicationAudioSession = false
                    session.beginConfiguration()
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        throw CaptureError.unsupportedInput
                    }
                    session.addInput(input)
                    guard session.canAddOutput(output) else {
                        session.removeInput(input)
                        session.commitConfiguration()
                        throw CaptureError.unsupportedInput
                    }
                    session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: sampleQueue)
                    session.commitConfiguration()
                    observeLoss(of: device)
                    lock.withLock { paused = !running }
                    if running { session.startRunning() }
                    guard lock.withLock({ !stopped && !failureReported }), !running || session.isRunning else {
                        throw CaptureError.startFailed
                    }
                    lock.withLock { ready = true }
                    continuation.resume(returning: device.uniqueID)
                } catch {
                    stop()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func activate() {
        lock.withLock {
            guard ready, !stopped, !paused, !failureReported else { return }
            accepting = true
        }
    }

    func pause() {
        lock.withLock { accepting = false; paused = true }
        Self.sessionQueue.async { [self] in session.stopRunning() }
    }

    func resume() {
        let shouldResume = lock.withLock {
            guard ready, !stopped, !failureReported else { return false }
            paused = false
            return true
        }
        guard shouldResume else { return }
        Self.sessionQueue.async { [self] in
            guard lock.withLock({ !stopped && !paused && !failureReported }) else { return }
            session.startRunning()
            guard session.isRunning else { fail(CaptureError.startFailed); return }
            activate()
        }
    }

    func stop() {
        let first = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            accepting = false
            return true
        }
        guard first else { return }
        // Shared queue orders teardown before any replacement capture's start.
        Self.sessionQueue.async { [self] in
            session.stopRunning()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            session.beginConfiguration()
            for output in session.outputs {
                (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                session.removeOutput(output)
            }
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
        }
    }

    private func observeLoss(of device: AVCaptureDevice) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
            self?.fail(CaptureError.disconnected)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            self?.fail((note.userInfo?[AVCaptureSessionErrorKey] as? Error) ?? CaptureError.startFailed)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.fail(CaptureError.interrupted)
        })
    }

    private func fail(_ error: Error) {
        let first = lock.withLock {
            guard !stopped, !failureReported else { return false }
            failureReported = true
            accepting = false
            return true
        }
        guard first else { return }
        stop()
        failed(error)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard lock.withLock({ accepting }) else { return }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate.isFinite, (8_000...192_000).contains(asbd.mSampleRate),
              (1...8).contains(Int(asbd.mChannelsPerFrame)),
              let frames = Int32(exactly: CMSampleBufferGetNumSamples(sampleBuffer)), frames > 0,
              Double(frames) / asbd.mSampleRate <= 0.5 else { fail(CaptureError.invalidPCM); return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let clock = session.synchronizationClock, pts.isValid, !pts.isIndefinite else { fail(CaptureError.missingClock); return }
        let hostTime = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()).seconds
        guard hostTime.isFinite else { fail(CaptureError.missingClock); return }
        let format: AVAudioFormat
        if let old = cachedASBD, let cachedFormat,
           old.mSampleRate == asbd.mSampleRate, old.mChannelsPerFrame == asbd.mChannelsPerFrame,
           old.mFormatID == asbd.mFormatID, old.mFormatFlags == asbd.mFormatFlags,
           old.mBitsPerChannel == asbd.mBitsPerChannel, old.mBytesPerFrame == asbd.mBytesPerFrame,
           old.mBytesPerPacket == asbd.mBytesPerPacket, old.mFramesPerPacket == asbd.mFramesPerPacket {
            format = cachedFormat
        } else {
            var source = asbd
            guard let made = AVAudioFormat(streamDescription: &source) else { fail(CaptureError.invalidPCM); return }
            cachedASBD = asbd
            cachedFormat = made
            format = made
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { fail(CaptureError.invalidPCM); return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let bytes = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).reduce(0) { $0 + Int($1.mDataByteSize) }
        guard bytes <= 1_048_576,
              CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: frames, into: buffer.mutableAudioBufferList) == noErr else {
            fail(CaptureError.invalidPCM)
            return
        }
        lock.withLock {
            guard accepting else { return }
            receive(buffer, hostTime)
        }
    }
}
#endif
