import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

/// One initial selection owns one immutable track. Stream updates close the
/// decision; they never authorize replacement audio under the same identity.
nonisolated final class MeetingAppAudioPickerDecisionGate: @unchecked Sendable {
    enum Update: Equatable { case ignored, selected, revoked }
    private enum Decision { case pending, selected, closed }
    private let lock = NSLock()
    private var decision: Decision = .pending
    private var streamID: ObjectIdentifier?
    var hasSelection: Bool { lock.withLock { decision == .selected } }

    func update(streamID: ObjectIdentifier?, ownsPresentation: Bool) -> Update {
        lock.withLock {
            guard decision != .closed else { return .ignored }
            if let streamID {
                guard decision == .selected, self.streamID == streamID else { return .ignored }
                decision = .closed
                return .revoked
            }
            guard ownsPresentation, decision == .pending else { return .ignored }
            decision = .selected
            return .selected
        }
    }

    func bind(streamID: ObjectIdentifier) {
        lock.withLock { if decision == .selected { self.streamID = streamID } }
    }

    func cancel(streamID: ObjectIdentifier?, ownsPresentation: Bool) -> Bool {
        lock.withLock {
            // Dismissing an existing-stream picker does not change its selection.
            guard streamID == nil, ownsPresentation, decision == .pending else { return false }
            decision = .closed
            return true
        }
    }

    func invalidate() { lock.withLock { decision = .closed; streamID = nil } }
}

/// The SDK broadcasts nil-stream results to every observer. Only one pending
/// presentation can own those callbacks, while up to four Mac streams stay live.
nonisolated final class MeetingAppAudioPickerSessions: @unchecked Sendable {
    static let shared = MeetingAppAudioPickerSessions()
    private let lock = NSLock()
    private var owners: Set<String> = []
    private var pending: String?

    func reserve(_ id: String, supportsMultipleSources: Bool) -> Bool {
        lock.withLock {
            guard pending == nil, !owners.contains(id),
                  owners.count < (supportsMultipleSources ? 4 : 1) else { return false }
            owners.insert(id)
            pending = id
            return true
        }
    }

    func ownsPresentation(_ id: String) -> Bool { lock.withLock { pending == id } }
    func finishPresentation(_ id: String) { lock.withLock { if pending == id { pending = nil } } }
    @discardableResult
    func release(_ id: String) -> Bool {
        lock.withLock {
            owners.remove(id)
            if pending == id { pending = nil }
            return owners.isEmpty
        }
    }
}

/// Synchronously invalidates queued samples and suspended starts before a source
/// replacement. An old ticket can never reopen delivery after cancellation.
nonisolated final class MeetingCaptureSourceGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var generation = 0
    private var active = false
    func replace() -> Int {
        lock.withLock {
            generation += 1
            active = false
            return generation
        }
    }
    func currentTicket() -> Int { lock.withLock { generation } }
    func isCurrent(_ ticket: Int) -> Bool { lock.withLock { generation == ticket } }
    func activate(_ ticket: Int) {
        lock.withLock { if generation == ticket { active = true } }
    }
    func deliver(_ ticket: Int, _ body: () -> Void) {
        lock.withLock { if generation == ticket && active { body() } }
    }
}

/// Muting a lane changes delivery, not the SDK's registered output topology.
/// Revocation is terminal, including when a delayed start completes afterward.
nonisolated struct MeetingAppAudioDeliveryState {
    private var started = false
    private(set) var enabled = true
    private var revoked = false
    private(set) var ticket = 0
    var acceptsSamples: Bool { started && enabled && !revoked }
    mutating func activate() { if !revoked { started = true } }
    func acceptsSamples(for ticket: Int) -> Bool { acceptsSamples && self.ticket == ticket }
    mutating func setEnabled(_ enabled: Bool) {
        guard !revoked, !enabled || self.enabled != enabled else { return }
        ticket += 1
        self.enabled = enabled
    }
    mutating func enable(ifCurrent ticket: Int) {
        if self.ticket == ticket { setEnabled(true) }
    }
    mutating func revoke() { ticket += 1; revoked = true }
}

/// One raw start must settle before one stop. The shutdown task owns the SDK
/// outputs/delegate until stop completes, even if the source owner goes away.
@MainActor
final class MeetingAppAudioStreamLifecycle {
    var startup: Task<Void, Error>?
    private var shutdown: Task<Void, Never>?

    func stop(operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        if let shutdown { return shutdown }
        let startup = startup
        self.startup = nil
        let task = Task { @MainActor in
            // The start owner reports its error; teardown still has to run.
            if let startup { _ = await startup.result }
            await operation()
        }
        shutdown = task
        return task
    }
}

/// On iOS 27 an audio-only SCStream can have no synchronizationClock even
/// while its PCM PTS is already in the host-clock domain. Do not discard that
/// source; reject unrelated clock domains rather than guessing an offset.
nonisolated enum MeetingAppAudioTimestamp {
    static func hostTime(_ pts: CMTime, sourceClock: CMClock?, hostClock: CMClock) -> Double? {
        guard pts.isValid, !pts.isIndefinite else { return nil }
        if let sourceClock {
            let converted = CMSyncConvertTime(pts, from: sourceClock, to: hostClock).seconds
            return converted.isFinite ? converted : nil
        }
        let seconds = pts.seconds
        let now = CMClockGetTime(hostClock).seconds
        guard seconds.isFinite, now.isFinite, abs(seconds - now) < 5 else { return nil }
        return seconds
    }
}

/// Carries framework identity across startup cleanup and late diagnostic consent.
/// Framework descriptions and arbitrary userInfo can contain app/window names.
nonisolated struct MeetingAppAudioFailure: LocalizedError, CustomNSError, Sendable {
    enum Stage: String, Sendable {
        case picker = "appAudioPickerStart"
        case audioOutput = "appAudioOutputRegistration"
        case screenOutput = "appAudioScreenOutputRegistration"
        case microphoneOutput = "appAudioMicrophoneOutputRegistration"
        case streamStart = "appAudioStreamStart"
        case streamStopped = "appAudioStreamStopped"
        case sample = "appAudioSample"
    }

    let stage: Stage
    let cause: NSError

    init(_ error: Error, stage: Stage) {
        self.stage = stage
        cause = Self.safeCause(error as NSError, depth: 0)
    }

    static var errorDomain: String { "todo.MeetingAppAudioFailure" }
    var errorCode: Int { cause.code }
    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? "",
         NSLocalizedFailureReasonErrorKey: stage.rawValue,
         NSUnderlyingErrorKey: cause]
    }

    var authorizationDenied: Bool {
        cause.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && cause.code == -3801
    }

    var errorDescription: String? {
        let detail: String
        if authorizationDenied {
            #if targetEnvironment(macCatalyst)
            detail = MeetingAppAudioCapture.message("meeting.appAudio.error.authorizationDenied.mac",
                "macOS did not authorize system audio capture. Check SIFT in System Settings → Privacy & Security → Screen & System Audio Recording. If you change permission, quit and reopen SIFT, then select the source again.",
                "macOS가 시스템 오디오 캡처를 허용하지 않았습니다. 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 SIFT 권한을 확인하세요. 권한을 변경했다면 SIFT를 종료한 뒤 다시 열고 소스를 선택하세요.")
            #else
            detail = MeetingAppAudioCapture.message("meeting.appAudio.error.authorizationDenied",
                "The system did not authorize audio capture. Select the source again and approve sharing in the system picker.",
                "시스템이 오디오 캡처를 허용하지 않았습니다. 소스를 다시 선택하고 시스템 선택창에서 공유를 허용하세요.")
            #endif
        } else {
            switch stage {
            case .picker:
                detail = MeetingAppAudioCapture.message("meeting.appAudio.error.selectionFailed", "System content selection failed. Select a new source to retry.", "시스템 콘텐츠 선택에 실패했습니다. 새 소스를 선택하여 다시 시도하세요.")
            case .streamStopped:
                detail = MeetingAppAudioCapture.message("meeting.appAudio.error.captureStopped", "System audio capture stopped. Select a new source to continue.", "시스템 오디오 캡처가 중지되었습니다. 계속하려면 새 소스를 선택하세요.")
            case .sample:
                detail = MeetingAppAudioCapture.message("meeting.appAudio.error.decodeFailed", "App audio could not be decoded or synchronized. Select the source again.", "앱 오디오를 디코딩하거나 동기화할 수 없습니다. 소스를 다시 선택하세요.")
            default:
                detail = MeetingAppAudioCapture.message("meeting.appAudio.error.startFailed", "System audio capture could not start. Select a new source to retry.", "시스템 오디오 캡처를 시작할 수 없습니다. 새 소스를 선택하여 다시 시도하세요.")
            }
        }
        return "\(detail)\n\(stage.rawValue) · \(cause.domain) (\(cause.code))"
    }

    private static func safeCause(_ error: NSError, depth: Int) -> NSError {
        var info: [String: Any] = [:]
        if depth < 3, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            info[NSUnderlyingErrorKey] = safeCause(underlying, depth: depth + 1)
        }
        return NSError(domain: error.domain, code: error.code, userInfo: info)
    }
}

/// Captures only audio. Every stream has a minimal screen discard output;
/// no pixels leave that callback and no video or clip is persisted.
@MainActor
final class MeetingAppAudioCapture {
    nonisolated enum State: Equatable, Sendable {
        case disabled
        case selecting
        case waitingForAudio
        case receivingAudio
        case unavailable(String)
    }

    nonisolated enum Availability: Equatable, Sendable {
        case available
        case unavailable(String)
    }

    enum CaptureError: LocalizedError {
        case consentRequired
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .consentRequired: MeetingAppAudioCapture.message("meeting.appAudio.error.consentRequired", "Confirm consent before selecting app audio.", "앱 오디오를 선택하기 전에 녹음 동의를 확인하세요.")
            case .unavailable(let reason): reason
            }
        }
    }

    nonisolated static func message(_ key: String, _ english: String, _ korean: String) -> String {
        AppLanguage.localized(key, defaultValue: AppLanguage.current == .korean ? korean : english,
                              language: .current, comment: "App audio source label or capture status.")
    }

    static var systemSelectedContent: String {
        #if targetEnvironment(macCatalyst)
        message("meeting.appAudio.source.systemSelected", "System-selected content", "시스템에서 선택한 콘텐츠")
        #else
        message("meeting.appAudio.source.entireScreen", "Entire screen audio", "전체 화면 오디오")
        #endif
    }

    typealias Receive = @Sendable (AVAudioPCMBuffer, Double, MeetingAudioSourceRouter.Source) -> Void
    private let receive: Receive
    private let stateChanged: @MainActor (State) -> Void
    private var generation = 0
    private var session: (any AppAudioCaptureSession)?
    private var readinessWaiter: CheckedContinuation<Void, Error>?
    private var readinessToken: UUID?
    private(set) var lastFailure: MeetingAppAudioFailure?
    /// A capture instance is a source identity, never a reselectable track.
    let sourceID: String
    private(set) var sourceKind: MeetingAudioTrackKind = .screen
    private var selectionAttempted = false
    private(set) var selectedSourceDescription: String?
    private(set) var microphoneApproved = false
    var microphoneRequested = false
    private let microphoneFailed: @MainActor (String) -> Void
    private(set) var state: State = .disabled {
        didSet {
            stateChanged(state)
            switch state {
            case .waitingForAudio, .receivingAudio: settleReadiness(.success(()))
            case .unavailable(let reason):
                let error: Error
                if let lastFailure { error = lastFailure }
                else { error = CaptureError.unavailable(reason) }
                settleReadiness(.failure(error))
            case .disabled: settleReadiness(.failure(CancellationError()))
            case .selecting: break
            }
        }
    }

    init(sourceID: String = UUID().uuidString.lowercased(), receive: @escaping Receive, stateChanged: @escaping @MainActor (State) -> Void,
         microphoneFailed: @escaping @MainActor (String) -> Void) {
        self.sourceID = sourceID
        self.receive = receive
        self.stateChanged = stateChanged
        self.microphoneFailed = microphoneFailed
    }

    static var supportsMultipleSources: Bool {
        #if targetEnvironment(macCatalyst) && canImport(ScreenCaptureKit) && !targetEnvironment(simulator)
        if #available(macCatalyst 18.2, *), case .available = availability { return true }
        #endif
        return false
    }

    static var availability: Availability {
        #if targetEnvironment(simulator)
        return .unavailable(message("meeting.appAudio.error.physicalDevice", "App audio capture requires a supported physical device.", "앱 오디오 캡처에는 지원되는 실제 기기가 필요합니다."))
        #elseif canImport(ScreenCaptureKit) && os(iOS)
        if #available(iOS 27.0, macCatalyst 18.2, *) {
            // The picker exposes isAvailable only on Catalyst 27+, not 18.2–26.
            #if targetEnvironment(macCatalyst)
            if #available(macCatalyst 27.0, *), !SCContentSharingPicker.shared.isAvailable {
                return .unavailable(message("meeting.appAudio.error.sharingUnavailable", "System content sharing is unavailable on this device.", "이 기기에서는 시스템 콘텐츠 공유를 사용할 수 없습니다."))
            }
            #else
            if !SCContentSharingPicker.shared.isAvailable {
                return .unavailable(message("meeting.appAudio.error.sharingUnavailable", "System content sharing is unavailable on this device.", "이 기기에서는 시스템 콘텐츠 공유를 사용할 수 없습니다."))
            }
            #endif
            return .available
        }
        return .unavailable(message("meeting.appAudio.error.osVersion", "App audio capture requires iOS 27 or supported Mac Catalyst.", "앱 오디오 캡처에는 iOS 27 또는 지원되는 Mac Catalyst가 필요합니다."))
        #else
        return .unavailable(message("meeting.appAudio.error.platform", "ScreenCaptureKit app audio is unavailable on this platform.", "이 플랫폼에서는 ScreenCaptureKit 앱 오디오를 사용할 수 없습니다."))
        #endif
    }

    /// Waits for a successful picker selection and a running audio-only stream. Samples
    /// cannot reach `receive` until the start succeeds and `waitingForAudio` is published.
    func selectSourceAndWait(consentConfirmed: Bool) async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            let (request, capture) = try await prepareSelection(consentConfirmed: consentConfirmed)
            do {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard generation == request else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    readinessToken = token
                    readinessWaiter = continuation // Register before the picker can call back.
                    capture.presentPicker()
                }
                try Task.checkCancellation()
            } catch {
                if error is CancellationError, generation == request { await stop() }
                throw error
            }
        } onCancel: {
            Task { @MainActor in
                if self.readinessToken == token { await self.stop() }
            }
        }
    }

    private func prepareSelection(consentConfirmed: Bool) async throws -> (Int, any AppAudioCaptureSession) {
        guard consentConfirmed else { throw CaptureError.consentRequired }
        guard !selectionAttempted else {
            throw CaptureError.unavailable(Self.message("meeting.appAudio.error.newSourceRequired", "Add a new source to select different content.", "다른 콘텐츠를 선택하려면 새 소스를 추가하세요."))
        }
        let available = Self.availability
        guard case .available = available else {
            if case .unavailable(let reason) = available { throw CaptureError.unavailable(reason) }
            throw CaptureError.unavailable(Self.message("meeting.appAudio.error.unavailable", "App audio capture is unavailable.", "앱 오디오 캡처를 사용할 수 없습니다."))
        }
        selectionAttempted = true
        let request = generation + 1
        await stop()
        guard generation == request else { throw CancellationError() }
        try Task.checkCancellation()
        #if canImport(ScreenCaptureKit) && os(iOS) && !targetEnvironment(simulator)
        if #available(iOS 27.0, macCatalyst 18.2, *) {
            let capture = ScreenCaptureSession(sourceID: sourceID, receive: receive, microphoneWanted: microphoneRequested,
                                               microphoneFailed: microphoneFailed) { [weak self] change in
                guard let self, self.generation == request else { return }
                self.selectedSourceDescription = change.description
                self.sourceKind = change.sourceKind
                self.microphoneApproved = change.microphoneApproved
                self.lastFailure = change.error
                self.state = change.state
            }
            session = capture
            state = .selecting
            return (request, capture)
        }
        #endif
        throw CaptureError.unavailable(Self.message("meeting.appAudio.error.platform", "ScreenCaptureKit app audio is unavailable on this platform.", "이 플랫폼에서는 ScreenCaptureKit 앱 오디오를 사용할 수 없습니다."))
    }

    private func settleReadiness(_ result: Result<Void, Error>) {
        let waiter = readinessWaiter
        readinessWaiter = nil
        readinessToken = nil
        waiter?.resume(with: result)
    }

    func revokeMicrophone() {
        microphoneApproved = false
        session?.revokeMicrophone()
    }
    func disableAppAudioRetainingMicrophone() {
        guard microphoneApproved, let session else { return }
        selectedSourceDescription = nil
        session.disableAppAudio()
        state = .disabled
    }
    func resumeAppAudio() throws {
        guard microphoneApproved, let session else { throw CaptureError.unavailable(Self.message("meeting.appAudio.error.sharingEnded", "Screen sharing has ended.", "화면 공유가 종료되었습니다.")) }
        try session.resumeAppAudio()
        selectedSourceDescription = Self.systemSelectedContent
        state = .waitingForAudio
    }


    func stop() async {
        generation += 1
        let previous = session
        session = nil
        selectedSourceDescription = nil
        microphoneApproved = false
        // Revoke synchronous delivery before suspending for the system's asynchronous stop.
        previous?.revoke()
        state = .disabled
        settleReadiness(.failure(CancellationError()))
        await previous?.stop()
    }
}

@MainActor
private protocol AppAudioCaptureSession: AnyObject {
    func revoke()
    func revokeMicrophone()
    func disableAppAudio()
    func resumeAppAudio() throws
    func presentPicker()
    func stop() async
}

#if canImport(ScreenCaptureKit) && os(iOS) && !targetEnvironment(simulator)
@available(iOS 27.0, macCatalyst 18.2, *)
private final class ScreenCaptureSession: AppAudioCaptureSession {
    struct Change {
        let state: MeetingAppAudioCapture.State
        let description: String?
        var sourceKind: MeetingAudioTrackKind = .screen
        var microphoneApproved = false
        var error: MeetingAppAudioFailure?
    }

    private let receive: MeetingAppAudioCapture.Receive
    private let change: @MainActor (Change) -> Void
    private let microphoneFailed: @MainActor (String) -> Void
    private let microphoneWanted: Bool
    private let delivery = MeetingCaptureSourceGate()
    private let sampleQueue = DispatchQueue(label: "pieroot.todo.meeting.appAudio")
    private let screenQueue = DispatchQueue(label: "pieroot.todo.meeting.screenDiscard")
    private var registeredOutputs: [(any SCStreamOutput, SCStreamOutputType)] = []
    private var observer: AppAudioPickerObserver?
    private var stream: SCStream?
    private var delegate: AppAudioStreamDelegate?
    private var output: AppAudioOutput?
    private var microphoneOutput: AppAudioOutput?
    private var description: String?
    private var sourceKind: MeetingAudioTrackKind = .screen
    private let sourceID: String
    private var pickerReserved = false
    private var microphoneApproved = false
    private let lifecycle = MeetingAppAudioStreamLifecycle()

    init(sourceID: String, receive: @escaping MeetingAppAudioCapture.Receive, microphoneWanted: Bool,
         microphoneFailed: @escaping @MainActor (String) -> Void,
         change: @escaping @MainActor (Change) -> Void) {
        self.sourceID = sourceID
        self.receive = receive
        self.microphoneWanted = microphoneWanted
        self.microphoneFailed = microphoneFailed
        self.change = change
    }

    isolated deinit {
        revoke()
        _ = beginStop()
    }

    func presentPicker() {
        guard MeetingAppAudioPickerSessions.shared.reserve(sourceID, supportsMultipleSources: MeetingAppAudioCapture.supportsMultipleSources) else {
            change(Change(state: .unavailable(MeetingAppAudioCapture.message("meeting.appAudio.error.sourceLimit", "Another source is being selected or the source limit has been reached.", "다른 소스를 선택 중이거나 소스 제한에 도달했습니다.")), description: nil))
            return
        }
        pickerReserved = true
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        #if targetEnvironment(macCatalyst)
        configuration.allowedPickerModes = [.singleApplication, .singleWindow, .singleDisplay]
        configuration.allowsChangingSelectedContent = false
        picker.maximumStreamCount = 4
        #else
        configuration.showsMicrophoneControl = true
        #endif
        picker.defaultConfiguration = configuration
        let observer = AppAudioPickerObserver(
            sourceID: sourceID,
            selected: { [weak self, delivery] filter in
                let ticket = delivery.replace()
                Task { @MainActor in await self?.start(filter: filter, ticket: ticket) }
            },
            selectionChanged: { [weak self, delivery] in
                // Revoke on the SDK callback thread before any actor hop.
                let ticket = delivery.replace()
                Task { @MainActor in
                    await self?.fail(MeetingAppAudioCapture.message("meeting.appAudio.error.contentChanged", "The selected content changed. Add or select a new source to continue.", "선택한 콘텐츠가 변경되었습니다. 계속하려면 새 소스를 추가하거나 선택하세요."), ticket: ticket)
                }
            },
            cancelled: { [weak self, delivery] in
                let ticket = delivery.replace()
                Task { @MainActor in await self?.fail(nil, ticket: ticket) }
            },
            failed: { [weak self, delivery] error in
                let failure = MeetingAppAudioFailure(error, stage: .picker)
                DiagnosticRecorder.shared.record(error: failure, component: "meeting.capture", operation: failure.stage.rawValue)
                let ticket = delivery.replace()
                Task { @MainActor in await self?.fail(failure.errorDescription, ticket: ticket, error: failure) }
            }
        )
        self.observer = observer
        picker.add(observer)
        picker.isActive = true
        picker.present()
    }

    private nonisolated static func recordSystemFailure(_ error: Error, operation: String) {
        DiagnosticRecorder.shared.record(error: MeetingAppAudioFailure(error, stage: .streamStopped).cause,
                                         component: "meeting.capture", operation: operation)
    }

    private func start(filter: SCContentFilter, ticket: Int) async {
        guard delivery.isCurrent(ticket), let observer, observer.hasSelection, stream == nil else { return }
        #if targetEnvironment(macCatalyst)
        let names = filter.includedApplications.map(\.applicationName).filter { !$0.isEmpty }
        description = names.isEmpty ? MeetingAppAudioCapture.systemSelectedContent : names.joined(separator: ", ")
        sourceKind = filter.style == .display ? .screen : .application
        #else
        description = MeetingAppAudioCapture.systemSelectedContent
        sourceKind = .screen
        microphoneApproved = microphoneWanted && filter.isMicrophoneEnabled
        #endif
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // A screen stream still delivers video even when only audio is stored.
        // Register its discard output on Catalyst too; use a tiny surface.
        config.width = 64
        config.height = 64
        #if targetEnvironment(macCatalyst)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        #endif
        config.excludesCurrentProcessAudio = true
        #if targetEnvironment(macCatalyst)
        config.captureMicrophone = false // Chosen Mac mic remains AVCaptureDeviceInput.
        #endif
        let receive: MeetingAppAudioCapture.Receive = { [receive, delivery] buffer, time, source in
            delivery.deliver(ticket) { receive(buffer, time, source) }
        }
        let sink = AppAudioOutput(source: .appAudio, receive: receive) { [weak self] failure in
            Task { @MainActor [weak self] in
                let error = MeetingAppAudioFailure(failure, stage: .sample)
                DiagnosticRecorder.shared.record(error: error, component: "meeting.capture", operation: error.stage.rawValue)
                await self?.fail(error.errorDescription, ticket: ticket, error: error)
            }
        } firstAudio: { [weak self] output, laneTicket in
            guard let owner = self else { return }
            Task { @MainActor in
                guard owner.delivery.isCurrent(ticket), output.acceptsSamples(for: laneTicket) else { return }
                owner.change(Change(state: .receivingAudio, description: owner.description,
                                    sourceKind: owner.sourceKind, microphoneApproved: owner.microphoneApproved))
            }
        }
        let micSink: AppAudioOutput? = microphoneApproved ? AppAudioOutput(source: .microphone, receive: receive, failure: { [weak self] _ in
            guard let owner = self else { return }
            Task { @MainActor in
                guard owner.delivery.isCurrent(ticket) else { return }
                owner.revokeMicrophone()
                owner.microphoneFailed(MeetingAppAudioCapture.message("meeting.appAudio.error.microphoneStopped", "Microphone capture stopped. Enable it again using the system picker.", "마이크 캡처가 중지되었습니다. 시스템 선택기를 사용하여 다시 켜주세요."))
            }
        }, firstAudio: { _, _ in }) : nil
        let delegate = AppAudioStreamDelegate(revoke: { [delivery] in _ = delivery.replace(); sink.revoke(); micSink?.revoke() }) { [weak self] error in
            let failure = MeetingAppAudioFailure(error, stage: .streamStopped)
            DiagnosticRecorder.shared.record(error: failure, component: "meeting.capture", operation: failure.stage.rawValue)
            Task { @MainActor [weak self] in
                guard let self, self.stream != nil else { return }
                await self.fail(failure.errorDescription, ticket: self.delivery.currentTicket(), error: failure)
            }
        }
        let candidate = SCStream(filter: filter, configuration: config, delegate: delegate)
        observer.bind(stream: candidate)
        #if targetEnvironment(macCatalyst)
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowsChangingSelectedContent = false
        configuration.allowedPickerModes = [.singleApplication, .singleWindow, .singleDisplay]
        SCContentSharingPicker.shared.setConfiguration(configuration, for: candidate)
        #endif
        stream = candidate
        self.delegate = delegate
        output = sink
        microphoneOutput = micSink
        var stage = MeetingAppAudioFailure.Stage.audioOutput
        do {
            try candidate.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sampleQueue)
            registeredOutputs.append((sink, .audio))
            let screenSink = DiscardedScreenOutput()
            stage = .screenOutput
            try candidate.addStreamOutput(screenSink, type: .screen, sampleHandlerQueue: screenQueue)
            registeredOutputs.append((screenSink, .screen))
            if let micSink {
                stage = .microphoneOutput
                try candidate.addStreamOutput(micSink, type: .microphone, sampleHandlerQueue: sampleQueue)
                registeredOutputs.append((micSink, .microphone))
            }
            stage = .streamStart
            // Own only the raw SDK operation. Shutdown can await it without
            // waiting on this enclosing method, which may itself await failure cleanup.
            let startup = Task { @MainActor in try await candidate.startCapture() }
            lifecycle.startup = startup
            try await startup.value
            guard delivery.isCurrent(ticket), observer.hasSelection, stream === candidate else {
                sink.revoke()
                micSink?.revoke()
                // The callback/cancellation owner stops this session. Do not
                // invalidate its ticket or race its unavailable publication.
                return
            }
            MeetingAppAudioPickerSessions.shared.finishPresentation(sourceID)
            change(Change(state: .waitingForAudio, description: description, sourceKind: sourceKind, microphoneApproved: microphoneApproved))
            sampleQueue.async { [delivery] in
                sink.activate()
                micSink?.activate()
                delivery.activate(ticket)
            }
        } catch {
            let failure = MeetingAppAudioFailure(error, stage: stage)
            DiagnosticRecorder.shared.record(error: failure, component: "meeting.capture", operation: stage.rawValue)
            sink.revoke()
            micSink?.revoke()
            await fail(failure.errorDescription, ticket: ticket, error: failure)
        }
    }

    private func fail(_ reason: String?, ticket: Int, error: MeetingAppAudioFailure? = nil) async {
        guard delivery.isCurrent(ticket) else { return }
        // Publish closure before suspending in stopCapture.
        _ = delivery.replace()
        change(Change(state: reason.map(MeetingAppAudioCapture.State.unavailable) ?? .disabled, description: nil, sourceKind: sourceKind, error: error))
        await stop()
    }

    func revokeMicrophone() {
        microphoneApproved = false
        // Keep registration stable; revocation closes delivery synchronously.
        microphoneOutput?.revoke()
    }
    func disableAppAudio() {
        output?.setEnabled(false)
    }
    func resumeAppAudio() throws {
        guard stream != nil, let output, microphoneApproved else {
            throw MeetingAppAudioCapture.CaptureError.unavailable(MeetingAppAudioCapture.message("meeting.appAudio.error.sharingEnded", "Screen sharing has ended.", "화면 공유가 종료되었습니다."))
        }
        output.resume(on: sampleQueue)
    }


    func revoke() {
        observer?.invalidate()
        _ = delivery.replace()
        output?.revoke()
        revokeMicrophone()
    }

    func stop() async {
        revoke()
        await beginStop().value
    }

    private func beginStop() -> Task<Void, Never> {
        let previous = stream
        // Keep every registered sink and delegate strongly owned through stop.
        let sinks = registeredOutputs
        registeredOutputs.removeAll()
        let previousDelegate = delegate
        stream = nil
        output = nil
        microphoneOutput = nil
        delegate = nil
        description = nil
        let picker = SCContentSharingPicker.shared
        if let observer {
            picker.remove(observer)
            self.observer = nil
        }
        if let previous { picker.setConfiguration(nil, for: previous) }
        let reserved = pickerReserved
        pickerReserved = false
        let sourceID = sourceID
        return lifecycle.stop {
            if let previous {
                do {
                    try await previous.stopCapture()
                    // Only successful registrations are removed, after start
                    // and stop settle; no live output topology changes.
                    for (sink, type) in sinks {
                        do { try previous.removeStreamOutput(sink, type: type) }
                        catch { Self.recordSystemFailure(error, operation: "appAudioOutputRemoval") }
                    }
                } catch {
                    Self.recordSystemFailure(error, operation: "appAudioStreamStop")
                }
            }
            if reserved {
                // Keep the slot until the real stream has stopped. Concurrent
                // stop calls share this task and cannot free capacity early.
                picker.isActive = !MeetingAppAudioPickerSessions.shared.release(sourceID)
            }
            withExtendedLifetime(previousDelegate) {}
        }
    }
}

@available(iOS 27.0, macCatalyst 18.2, *)
private nonisolated final class AppAudioPickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private let decision = MeetingAppAudioPickerDecisionGate()
    private let sourceID: String
    let selected: @Sendable (SCContentFilter) -> Void
    let selectionChanged: @Sendable () -> Void
    let cancelled: @Sendable () -> Void
    let failed: @Sendable (Error) -> Void

    init(sourceID: String, selected: @escaping @Sendable (SCContentFilter) -> Void,
         selectionChanged: @escaping @Sendable () -> Void,
         cancelled: @escaping @Sendable () -> Void,
         failed: @escaping @Sendable (Error) -> Void) {
        self.sourceID = sourceID
        self.selected = selected
        self.selectionChanged = selectionChanged
        self.cancelled = cancelled
        self.failed = failed
    }

    var hasSelection: Bool { decision.hasSelection }
    func bind(stream: SCStream) { decision.bind(streamID: ObjectIdentifier(stream)) }
    func invalidate() { decision.invalidate() }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        switch decision.update(streamID: stream.map(ObjectIdentifier.init),
                               ownsPresentation: MeetingAppAudioPickerSessions.shared.ownsPresentation(sourceID)) {
        case .selected: selected(filter)
        case .revoked: selectionChanged()
        case .ignored: break
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        if decision.cancel(streamID: stream.map(ObjectIdentifier.init),
                           ownsPresentation: MeetingAppAudioPickerSessions.shared.ownsPresentation(sourceID)) { cancelled() }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        if decision.cancel(streamID: nil, ownsPresentation: MeetingAppAudioPickerSessions.shared.ownsPresentation(sourceID)) { failed(error) }
    }
}

@available(iOS 27.0, macCatalyst 18.2, *)
private nonisolated final class AppAudioStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    let revoke: @Sendable () -> Void
    let failed: @Sendable (Error) -> Void

    init(revoke: @escaping @Sendable () -> Void, failed: @escaping @Sendable (Error) -> Void) {
        self.revoke = revoke
        self.failed = failed
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        revoke()
        failed(error)
    }
}

@available(iOS 27.0, macCatalyst 18.2, *)
private nonisolated final class DiscardedScreenOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        // SCStream's screen lane is registered for the entire capture lifetime.
        // No frame data enters the audio pipeline or persistent storage.
    }
}

@available(iOS 27.0, macCatalyst 18.2, *)
private nonisolated final class AppAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    enum Failure: Int, Error, Sendable {
        case invalidPCMDescription = 1
        case unsupportedPCMFormat
        case bufferAllocation
        case pcmCopy
        case timestampDomain
    }
    private let lock = NSLock()
    private var delivery = MeetingAppAudioDeliveryState()
    private var reportedAudio = false
    private var cachedASBD: AudioStreamBasicDescription?
    private var cachedFormat: AVAudioFormat?
    private let receive: MeetingAppAudioCapture.Receive
    private let source: MeetingAudioSourceRouter.Source
    private let failure: @Sendable (Failure) -> Void
    private let firstAudio: @Sendable (AppAudioOutput, Int) -> Void

    init(source: MeetingAudioSourceRouter.Source, receive: @escaping MeetingAppAudioCapture.Receive,
         failure: @escaping @Sendable (Failure) -> Void,
         firstAudio: @escaping @Sendable (AppAudioOutput, Int) -> Void) {
        self.source = source
        self.receive = receive
        self.failure = failure
        self.firstAudio = firstAudio
    }

    func acceptsSamples(for ticket: Int) -> Bool {
        lock.withLock { delivery.acceptsSamples(for: ticket) }
    }

    func revoke() {
        lock.lock()
        delivery.revoke()
        lock.unlock()
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        delivery.setEnabled(enabled)
        if !enabled { reportedAudio = false }
        lock.unlock()
    }

    func resume(on queue: DispatchQueue) {
        lock.lock()
        let ticket = delivery.ticket
        lock.unlock()
        // Drain samples queued while muted before opening this lane. A later
        // disable/revoke invalidates this command even if it has not run yet.
        queue.async { [self] in
            lock.lock()
            delivery.enable(ifCurrent: ticket)
            lock.unlock()
        }
    }

    // Called on the serial sample queue after startCapture has completed successfully.
    func activate() {
        lock.lock()
        delivery.activate()
        lock.unlock()
    }

    private func abort(_ reason: Failure, ticket: Int) {
        lock.lock()
        let report = delivery.acceptsSamples(for: ticket)
        if report { delivery.revoke() }
        lock.unlock()
        if report { failure(reason) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        let expectedType: SCStreamOutputType = source == .microphone ? .microphone : .audio
        guard type == expectedType, CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample) else { return }
        lock.lock()
        let accepting = delivery.acceptsSamples
        let ticket = delivery.ticket
        lock.unlock()
        guard accepting else { return }
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate > 0,
              (1...8).contains(Int(asbd.mChannelsPerFrame)) else { abort(.invalidPCMDescription, ticket: ticket); return }
        guard let frames = Int32(exactly: CMSampleBufferGetNumSamples(sample)), frames > 0 else { return }
        let format: AVAudioFormat
        if let cachedASBD, cachedASBD.mSampleRate == asbd.mSampleRate,
           cachedASBD.mChannelsPerFrame == asbd.mChannelsPerFrame,
           cachedASBD.mFormatFlags == asbd.mFormatFlags,
           cachedASBD.mBitsPerChannel == asbd.mBitsPerChannel,
           cachedASBD.mBytesPerFrame == asbd.mBytesPerFrame,
           cachedASBD.mFramesPerPacket == asbd.mFramesPerPacket,
           let cachedFormat {
            format = cachedFormat
        } else {
            var source = asbd
            guard let made = AVAudioFormat(streamDescription: &source) else { abort(.unsupportedPCMFormat, ticket: ticket); return }
            cachedASBD = asbd
            cachedFormat = made
            format = made
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { abort(.bufferAllocation, ticket: ticket); return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: frames, into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { abort(.pcmCopy, ticket: ticket); return }
        guard let time = MeetingAppAudioTimestamp.hostTime(
            CMSampleBufferGetPresentationTimeStamp(sample),
            sourceClock: stream.synchronizationClock,
            hostClock: CMClockGetHostTimeClock()
        ) else { abort(.timestampDomain, ticket: ticket); return }
        lock.lock()
        if delivery.acceptsSamples(for: ticket) {
            if !reportedAudio { reportedAudio = true; firstAudio(self, ticket) }
            receive(buffer, time, source)
        }
        lock.unlock()
    }
}
#endif
