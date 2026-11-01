@preconcurrency import AVFoundation
import CoreAudio
import Foundation

nonisolated struct MeetingOutputAudioRoute: Identifiable, Equatable, Sendable {
    let uid: String
    let streamIndex: UInt32
    let name: String
    let isDefault: Bool
    var id: String { "\(uid)#\(streamIndex)" }
}

/// Route identity stays pinned for a capture; default changes require a new approval.
@MainActor
final class MeetingOutputAudioCapture {
    nonisolated enum Failure: LocalizedError {
        case unavailable, consentRequired, invalidPCM
        case native(NSError)
        var errorDescription: String? {
            switch self {
            case .unavailable: return MeetingAppAudioCapture.message("meeting.output.unavailable", "Output audio capture is unavailable. Select an available Mac output device.", "출력 오디오 캡처를 사용할 수 없습니다. 사용 가능한 Mac 출력 장치를 선택하세요.")
            case .consentRequired: return MeetingAppAudioCapture.message("meeting.output.consent", "Confirm recording consent before capturing output audio.", "출력 오디오를 캡처하기 전에 녹음 동의를 확인하세요.")
            case .invalidPCM: return MeetingAppAudioCapture.message("meeting.output.invalidPCM", "The selected output returned an unsupported audio format. Select another stream.", "선택한 출력에서 지원하지 않는 오디오 형식을 반환했습니다. 다른 스트림을 선택하세요.")
            case .native(let error): return MeetingOutputAudioCapture.message(for: error)
            }
        }
    }
    nonisolated static func message(for error: NSError) -> String {
        switch error.domain == "SIFT.OutputAudioCapture" ? error.code : 0 {
        case 2:
            return MeetingAppAudioCapture.message("meeting.output.routeUnavailable", "The selected output device or stream is unavailable. Choose an available output; playback has not been changed.", "선택한 출력 장치 또는 스트림을 사용할 수 없습니다. 사용 가능한 출력을 선택하세요. 재생 장치는 변경되지 않았습니다.")
        case 3:
            return MeetingAppAudioCapture.message("meeting.output.appUnavailable", "The detected meeting app is no longer producing audio. Select the meeting source again.", "감지된 회의 앱에서 더 이상 오디오가 나오지 않습니다. 회의 소스를 다시 선택하세요.")
        case 4:
            return Failure.invalidPCM.localizedDescription
        case 6:
            return MeetingAppAudioCapture.message("meeting.output.routeChanged", "The output device, stream, or meeting app changed. This source stopped; explicitly enable it again after checking the route. Playback has not been changed.", "출력 장치, 스트림 또는 회의 앱이 변경되었습니다. 이 소스는 중지되었습니다. 경로를 확인한 후 직접 다시 켜주세요. 재생 장치는 변경되지 않았습니다.")
        default:
            return MeetingAppAudioCapture.message("meeting.output.permission", "Output capture could not start or deliver audio. Check SIFT in System Settings → Privacy & Security → Screen & System Audio Recording, then select the output again.", "출력 캡처를 시작하거나 오디오를 받을 수 없습니다. 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 SIFT 권한을 확인한 후 출력을 다시 선택하세요.")
        }
    }
    private let gate = MeetingCaptureSourceGate()
    nonisolated(unsafe) private let bridge: (any MeetingOutputAudioCaptureBridging)?
    private var generation = UUID()
    private var waiter: CheckedContinuation<Void, Error>?
    private var startupDeadline: Task<Void, Never>?
    private(set) var state: MeetingAppAudioCapture.State = .disabled
    private let changed: @MainActor (MeetingAppAudioCapture.State) -> Void
    private let receive: MeetingAppAudioCapture.Receive
    private var activeTicket: Int?
    let source: MeetingAudioSourceRouter.Source

    init(source: MeetingAudioSourceRouter.Source, receive: @escaping MeetingAppAudioCapture.Receive,
         changed: @escaping @MainActor (MeetingAppAudioCapture.State) -> Void,
         bridge: (any MeetingOutputAudioCaptureBridging)? = nil) {
        self.source = source
        self.receive = receive
        self.changed = changed
        self.bridge = bridge ?? Self.loadBridge()
    }
    deinit {
        startupDeadline?.cancel()
        _ = gate.replace()
        bridge?.stop()
    }
    static func routes() throws -> [MeetingOutputAudioRoute] {
        guard let bridge = loadBridge() else { throw Failure.unavailable }
        return try bridge.outputDevices().compactMap { value in
            guard let uid = value["uid"] as? String, let name = value["name"] as? String,
                  let stream = value["stream"] as? NSNumber else { return nil }
            return MeetingOutputAudioRoute(uid: uid, streamIndex: stream.uint32Value, name: name,
                                           isDefault: value["default"] as? Bool == true)
        }
    }
    private static func loadBridge() -> (any MeetingOutputAudioCaptureBridging)? {
        #if targetEnvironment(macCatalyst)
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("RecordingStatusMacSupport.bundle"),
              let bundle = Bundle(url: url) else { return nil }
        do {
            try bundle.loadAndReturnError()
            guard let type = bundle.classNamed("SIFTMeetingOutputAudioCapturePlugin") as? any MeetingOutputAudioCaptureBridging.Type else { return nil }
            return type.init()
        } catch { return nil }
        #else
        return nil
        #endif
    }
    func start(route: MeetingOutputAudioRoute?, processID: Int32?, consentConfirmed: Bool,
               startupTimeout: Duration = .seconds(8)) async throws {
        guard consentConfirmed else { throw Failure.consentRequired }
        guard let bridge else { throw Failure.unavailable }
        stop()
        let generation = self.generation
        let ticket = gate.currentTicket()
        activeTicket = ticket
        let gate = gate
        let source = source
        let receive = receive
        let decoder = MeetingOutputAudioPCMDecoder()
        setState(.selecting)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            defer {
                if self.generation == generation {
                    startupDeadline?.cancel()
                    startupDeadline = nil
                }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiter = continuation
                // The deadline runs on the app actor, never the potentially blocking HAL queue.
                startupDeadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: startupTimeout) } catch { return }
                    guard let self, self.generation == generation, self.waiter != nil else { return }
                    _ = gate.replace()
                    let error = NSError(domain: "SIFT.OutputAudioCapture", code: 5)
                    let pending = self.waiter
                    self.waiter = nil
                    self.startupDeadline = nil
                    self.bridge?.stop() // Schedules native teardown; never waits for HAL.
                    self.setState(.unavailable(Self.message(for: error)))
                    pending?.resume(throwing: Failure.native(error))
                }
                bridge.start(deviceUID: route?.uid, streamIndex: route?.streamIndex ?? 0, processID: processID ?? 0,
                    receive: { [weak self] listPointer, formatPointer, hostTime in
                        gate.deliver(ticket) {
                            do { receive(try decoder.copy(listPointer, formatPointer), hostTime, source) }
                            catch {
                                _ = gate.replace()
                                Task { @MainActor [weak self] in
                                    guard let self, self.generation == generation else { return }
                                    self.bridge?.stop()
                                    self.setState(.unavailable(Failure.invalidPCM.localizedDescription))
                                    let pending = self.waiter
                                    self.waiter = nil
                                    pending?.resume(throwing: Failure.invalidPCM)
                                }
                            }
                        }
                    }, failed: { [weak self] error in
                        _ = gate.replace()
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == generation else { return }
                            self.setState(.unavailable(Self.message(for: error)))
                            let pending = self.waiter
                            self.waiter = nil
                            pending?.resume(throwing: Failure.native(error))
                        }
                    }, completion: { [weak self] error in
                        if error == nil { gate.activate(ticket) }
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == generation else { return }
                            let pending = self.waiter
                            self.waiter = nil
                            if let error {
                                self.setState(.unavailable(Self.message(for: error)))
                                pending?.resume(throwing: Failure.native(error))
                            } else if gate.isCurrent(ticket), self.state != .disabled {
                                self.setState(.receivingAudio)
                                pending?.resume()
                            } else {
                                pending?.resume(throwing: CancellationError())
                            }
                        }
                    })
            }
            try Task.checkCancellation()
        } onCancel: {
            _ = gate.replace()
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.stop()
            }
        }
    }
    func pause() { if let activeTicket { gate.suspend(activeTicket) } }
    func resume() { if state == .receivingAudio, let activeTicket { gate.activate(activeTicket) } }
    private func setState(_ state: MeetingAppAudioCapture.State) { self.state = state; changed(state) }
    func stop() {
        startupDeadline?.cancel()
        startupDeadline = nil
        _ = gate.replace()
        activeTicket = nil
        generation = UUID()
        let pending = waiter
        waiter = nil
        bridge?.stop()
        setState(.disabled)
        pending?.resume(throwing: CancellationError())
    }
}

/// Native IO callbacks are serial; only the owned PCM buffer crosses to the router.
nonisolated private final class MeetingOutputAudioPCMDecoder: @unchecked Sendable {
    private var format: AVAudioFormat?
    func copy(_ listPointer: UnsafeRawPointer, _ formatPointer: UnsafeRawPointer) throws -> AVAudioPCMBuffer {
        var description = formatPointer.assumingMemoryBound(to: AudioStreamBasicDescription.self).pointee
        if format == nil { format = AVAudioFormat(streamDescription: &description) }
        guard let format, description.mBytesPerFrame > 0,
              format.sampleRate == description.mSampleRate,
              format.channelCount == description.mChannelsPerFrame,
              format.streamDescription.pointee.mFormatFlags == description.mFormatFlags,
              format.commonFormat != .otherFormat else { throw MeetingOutputAudioCapture.Failure.invalidPCM }
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: listPointer.assumingMemoryBound(to: AudioBufferList.self)))
        guard let first = input.first else { throw MeetingOutputAudioCapture.Failure.invalidPCM }
        let frames = first.mDataByteSize / description.mBytesPerFrame
        guard frames > 0, frames <= 262_144,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw MeetingOutputAudioCapture.Failure.invalidPCM }
        buffer.frameLength = frames
        let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard output.count == input.count else { throw MeetingOutputAudioCapture.Failure.invalidPCM }
        for index in input.indices {
            guard let from = input[index].mData, let to = output[index].mData,
                  input[index].mDataByteSize == output[index].mDataByteSize else { throw MeetingOutputAudioCapture.Failure.invalidPCM }
            memcpy(to, from, Int(input[index].mDataByteSize))
        }
        return buffer
    }
}
