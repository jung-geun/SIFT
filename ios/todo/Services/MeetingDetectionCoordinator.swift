#if targetEnvironment(macCatalyst)
import Combine
import SwiftUI
import UIKit

/// Process metadata and suggestion state remain local and in-memory. This object cannot start audio.
@MainActor
final class MeetingDetectionCoordinator: ObservableObject {
    static let shared = MeetingDetectionCoordinator()
    static let applications: [(id: String, name: String, browser: Bool)] = [
        ("us.zoom.xos", "Zoom", false), ("com.microsoft.teams2", "Microsoft Teams", false),
        ("com.microsoft.teams", "Microsoft Teams (classic)", false), ("com.hnc.Discord", "Discord", false),
        ("com.google.Chrome", "Google Chrome", true), ("com.apple.Safari", "Safari", true),
        ("com.microsoft.edgemac", "Microsoft Edge", true), ("org.mozilla.firefox", "Firefox", true),
        ("company.thebrowser.Browser", "Arc", true)
    ]

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isSupported = false
    @Published private(set) var pendingIntent: MeetingDetectedStartIntent?
    @Published private(set) var monitoringUnavailable = false
    private var bridge: (any MeetingDetectionBridging)?
    private var machine = MeetingDetectionStateMachine()
    private var candidates: [MeetingDetectionCandidate] = []
    private var presentedToken: UUID?
    private var targetSceneID: String?
    private var navigationSceneID: String?
    private var setupReservationUntil: Date?
    private var invalidated = false
    private var activityObserver: AnyCancellable?
    private var languageObserver: AnyCancellable?
    private struct SceneEntry {
        let session: UISceneSession
        let route: () -> Void
    }
    private var scenes: [UUID: SceneEntry] = [:]

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: MeetingDetectionPreferenceKey.enabled)
        if let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("RecordingStatusMacSupport.bundle"),
           let bundle = Bundle(url: url), (try? bundle.loadAndReturnError()) != nil,
           let type = NSClassFromString("SIFTMeetingDetectionPlugin") as? any MeetingDetectionBridging.Type {
            bridge = type.init()
        }
        isSupported = bridge?.isSupported == true
        bridge?.setHandlers(snapshot: { [weak self] rows in self?.receive(rows) },
                            lifecycle: { [weak self] event in self?.lifecycle(event) },
                            decision: { [weak self] token, decision in self?.decide(token: token, decision: decision) })
        activityObserver = MeetingRecordingActivityCenter.shared.$current.sink { [weak self] current in
            guard current != nil else { return }
            self?.pendingIntent = nil
            self?.targetSceneID = nil
            self?.refreshState(recordingActive: true)
        }
        languageObserver = NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification).sink { [weak self] _ in
            guard let self else { return }
            self.presentedToken = nil
            self.refreshState()
        }
        startIfEnabled()
    }

    func setEnabled(_ enabled: Bool) {
        guard !invalidated, isSupported else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: MeetingDetectionPreferenceKey.enabled)
        UIMenuSystem.main.setNeedsRebuild()
        if enabled { startIfEnabled() } else {
            bridge?.stopMonitoring()
            reset()
        }
    }

    func isAllowed(_ bundleID: String) -> Bool {
        let key = MeetingDetectionPreferenceKey.allowedApplication(bundleID)
        if UserDefaults.standard.object(forKey: key) != nil { return UserDefaults.standard.bool(forKey: key) }
        return Self.applications.first { $0.id == bundleID }?.browser == false
    }

    func setAllowed(_ allowed: Bool, bundleID: String) {
        guard Self.applications.contains(where: { $0.id == bundleID }) else { return }
        objectWillChange.send()
        UserDefaults.standard.set(allowed, forKey: MeetingDetectionPreferenceKey.allowedApplication(bundleID))
        candidates.removeAll { !isAllowed($0.bundleIdentifier) }
        refreshState()
        bridge?.refreshMetadata()
    }

    func startIfEnabled() {
        guard !invalidated, isEnabled, isSupported else { return }
        monitoringUnavailable = bridge?.startMonitoring() != true
    }

    private func receive(_ rows: NSArray) {
        guard isEnabled, !invalidated else { return }
        var grouped: [String: MeetingDetectionCandidate] = [:]
        for case let row as [String: Any] in rows {
            guard let id = row["sessionID"] as? String, let pid = row["processID"] as? NSNumber,
                  let bundle = row["bundleIdentifier"] as? String, isAllowed(bundle),
                  bundle != Bundle.main.bundleIdentifier, pid.int32Value != ProcessInfo.processInfo.processIdentifier,
                  let name = row["displayName"] as? String else { continue }
            let previous = grouped[id]
            grouped[id] = MeetingDetectionCandidate(sessionID: id, processID: pid.int32Value,
                bundleIdentifier: bundle, displayName: name, isBrowser: row["isBrowser"] as? Bool ?? false,
                runningInput: (row["runningInput"] as? Bool ?? false) || previous?.runningInput == true,
                runningOutput: (row["runningOutput"] as? Bool ?? false) || previous?.runningOutput == true)
        }
        candidates = Array(grouped.values)
        refreshState()
        if let intent = pendingIntent,
           Date() >= intent.expiresAt || !candidates.contains(where: { $0.processID == intent.processID && $0.bundleIdentifier == intent.bundleIdentifier && $0.isCallLike }) {
            pendingIntent = nil
            targetSceneID = nil
        }
    }

    private func refreshState(recordingActive: Bool? = nil) {
        guard !scenes.isEmpty else {
            bridge?.dismissSuggestion()
            presentedToken = nil
            return
        }
        let active = recordingActive ?? (MeetingRecordingActivityCenter.shared.current != nil)
        let reserved = setupReservationUntil.map { Date() < $0 } == true
        let prompt = machine.observe(candidates, at: Date(), recordingActive: active || pendingIntent != nil || reserved || monitoringUnavailable)
        guard let prompt else {
            if presentedToken != nil { bridge?.dismissSuggestion() }
            presentedToken = nil
            return
        }
        guard prompt.token != presentedToken else { return }
        presentedToken = prompt.token
        let title = text("meeting.detection.prompt.title", "회의를 녹음할까요?", "Record this meeting?")
        let message: String
        if prompt.candidate.isBrowser {
            message = String(format: text("meeting.detection.prompt.browser", "%@에서 통화 중일 수 있습니다. 오디오 활동만 감지했으며 사이트는 확인하지 않습니다. 제안은 30초 후 사라집니다.", "%@ may be in a browser call. Only audio activity was detected; the website is unknown. This suggestion expires in 30 seconds."), prompt.candidate.displayName)
        } else {
            message = String(format: text("meeting.detection.prompt.app", "%@에서 입력·출력 오디오 활동이 감지되었습니다. 시작을 누른 후 녹음 권한을 확인합니다. 제안은 30초 후 사라집니다.", "Input and output audio activity detected in %@. Start opens recording setup and permission checks. This suggestion expires in 30 seconds."), prompt.candidate.displayName)
        }
        bridge?.presentSuggestion(token: prompt.token.uuidString, title: title, message: message,
            startLabel: text("meeting.detection.start", "시작", "Start"),
            skipLabel: text("meeting.detection.skip", "건너뛰기", "Skip"), expiresAt: prompt.expiresAt)
    }

    private func decide(token: String, decision: String) {
        guard let id = UUID(uuidString: token), isEnabled, !invalidated else { return }
        // Synchronous metadata refresh revalidates current process activity before consuming a click.
        bridge?.refreshMetadata()
        guard decision == "start" else {
            machine.dismiss(token: id)
            presentedToken = nil
            return
        }
        guard !monitoringUnavailable, pendingIntent == nil,
              let scene = preferredScene(),
              let candidate = machine.accept(token: id, at: Date(), recordingActive: MeetingRecordingActivityCenter.shared.current != nil) else { return }
        presentedToken = nil
        targetSceneID = scene.session.persistentIdentifier
        navigationSceneID = scene.session.persistentIdentifier
        pendingIntent = MeetingDetectedStartIntent(id: UUID(), processID: candidate.processID,
            bundleIdentifier: candidate.bundleIdentifier, displayName: candidate.displayName,
            expiresAt: Date().addingTimeInterval(30))
        scene.route()
        let request = UISceneSessionActivationRequest(session: scene.session, userActivity: nil, options: nil)
        UIApplication.shared.activateSceneSession(for: request) { [weak self] _ in
            Task { @MainActor in self?.clearNavigationIntent() }
        }
    }

    private func preferredScene() -> SceneEntry? {
        let connected = UIApplication.shared.connectedScenes
        return scenes.values.sorted {
            func rank(_ entry: SceneEntry) -> Int {
                switch connected.first(where: { $0.session.persistentIdentifier == entry.session.persistentIdentifier })?.activationState {
                case .foregroundActive: return 0
                case .foregroundInactive: return 1
                default: return 2
                }
            }
            let left = rank($0), right = rank($1)
            return left == right ? $0.session.persistentIdentifier < $1.session.persistentIdentifier : left < right
        }.first
    }

    func registerScene(anchorID: UUID, session: UISceneSession, route: @escaping () -> Void) {
        let isNew = scenes[anchorID]?.session.persistentIdentifier != session.persistentIdentifier
        scenes[anchorID] = SceneEntry(session: session, route: route)
        if isNew, navigationSceneID == session.persistentIdentifier {
            DispatchQueue.main.async { [weak self] in
                guard self?.navigationSceneID == session.persistentIdentifier else { return }
                route()
            }
        }
    }

    func unregisterScene(anchorID: UUID) {
        scenes.removeValue(forKey: anchorID)
        if scenes.isEmpty {
            bridge?.dismissSuggestion()
            presentedToken = nil
            machine.reset()
            clearNavigationIntent()
        }
    }

    var hasPendingNavigation: Bool { navigationSceneID != nil }

    func clearNavigationIntent() {
        navigationSceneID = nil
        cancelPendingIntent()
    }

    /// Atomic main-actor claim: only the selected, foreground main scene can consume it, once.
    func claimStartIntent(sceneSessionID: String) -> MeetingDetectedStartIntent? {
        guard !monitoringUnavailable, let intent = pendingIntent, targetSceneID == sceneSessionID,
              Date() < intent.expiresAt, MeetingRecordingActivityCenter.shared.current == nil,
              UIApplication.shared.connectedScenes.contains(where: { $0.session.persistentIdentifier == sceneSessionID && $0.activationState == .foregroundActive }),
              candidates.contains(where: { $0.processID == intent.processID && $0.bundleIdentifier == intent.bundleIdentifier && $0.isCallLike }) else { return nil }
        setupReservationUntil = intent.expiresAt
        cancelPendingIntent()
        return intent
    }

    private func cancelPendingIntent() {
        pendingIntent = nil
        targetSceneID = nil
    }

    private func lifecycle(_ event: String) {
        if event == "sleep" { reset() }
        if event == "wake" { machine.reset() }
        if event == "unavailable" {
            if !monitoringUnavailable { monitoringUnavailable = true }
            cancelPendingIntent()
            refreshState(recordingActive: true)
        }
        if event == "available", monitoringUnavailable { monitoringUnavailable = false }
    }

    private func reset() {
        machine.reset()
        candidates.removeAll()
        presentedToken = nil
        cancelPendingIntent()
        navigationSceneID = nil
        setupReservationUntil = nil
        bridge?.dismissSuggestion()
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        reset()
        bridge?.invalidate()
        bridge = nil
        scenes.removeAll()
        activityObserver = nil
        languageObserver = nil
    }

    private func text(_ key: String, _ korean: String, _ english: String) -> String {
        AppLanguage.localized(key, defaultValue: AppLanguage.current == .english ? english : korean, language: .current)
    }
}

/// Installed only in main app scenes, never the separate Settings window.
struct MeetingDetectionSceneAnchor: UIViewRepresentable {
    let route: () -> Void
    func makeUIView(context: Context) -> AnchorView { AnchorView(route: route) }
    func updateUIView(_ view: AnchorView, context: Context) { view.route = route; view.register() }
    static func dismantleUIView(_ view: AnchorView, coordinator: Void) {
        MeetingDetectionCoordinator.shared.unregisterScene(anchorID: view.anchorID)
    }
    final class AnchorView: UIView {
        let anchorID = UUID()
        var route: () -> Void
        init(route: @escaping () -> Void) {
            self.route = route
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { nil }
        override func didMoveToWindow() { super.didMoveToWindow(); register() }
        func register() {
            guard let session = window?.windowScene?.session else { return }
            MeetingDetectionCoordinator.shared.registerScene(anchorID: anchorID, session: session, route: route)
        }
    }
}

/// MeetingView owns capture setup; this modifier delivers an explicit click, not an automatic start.
struct MeetingDetectionIntentHandler: ViewModifier {
    let action: (MeetingDetectedStartIntent) -> Void
    @ObservedObject private var detection = MeetingDetectionCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneID: String?

    func body(content: Content) -> some View {
        content
            .background(MeetingDetectionIntentSceneReader { sceneID = $0; consume() })
            .onChange(of: detection.pendingIntent?.id) { _, _ in consume() }
            .onChange(of: scenePhase) { _, _ in consume() }
            .onAppear { consume() }
    }
    private func consume() {
        guard let sceneID, let intent = detection.claimStartIntent(sceneSessionID: sceneID) else { return }
        action(intent)
    }
}

private struct MeetingDetectionIntentSceneReader: UIViewRepresentable {
    let update: (String) -> Void
    func makeUIView(context: Context) -> Reader { Reader(update: update) }
    func updateUIView(_ view: Reader, context: Context) { view.update = update }
    final class Reader: UIView {
        var update: (String) -> Void
        init(update: @escaping (String) -> Void) {
            self.update = update
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let id = window?.windowScene?.session.persistentIdentifier else { return }
            DispatchQueue.main.async { [weak self] in self?.update(id) }
        }
    }
}
#endif
