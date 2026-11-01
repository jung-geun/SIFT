#if os(macOS)
import AppKit
import CoreAudio

/// Metadata observation never creates a process tap, audio device, stream, or microphone session.
@MainActor
@objc(SIFTMeetingDetectionPlugin)
final class MeetingDetectionPlugin: NSObject, MeetingDetectionBridging {
    private var snapshotHandler: ((NSArray) -> Void)?
    private var lifecycleHandler: ((String) -> Void)?
    private var decisionHandler: ((String, String) -> Void)?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var panel: NSPanel?
    private var promptToken: String?
    private var promptDeadline: Date?
    private var monitoring = false
    private var metadataAvailable = false
    private var sleeping = false
    private var invalidated = false

    var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    required override init() {
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshMetadata() }
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true
                self.removeAudioListeners()
                self.dismissSuggestion()
                self.lifecycleHandler?("sleep")
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                self.lifecycleHandler?("wake")
                self.refreshMetadata()
            }
        })
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate), name: NSApplication.willTerminateNotification, object: nil)
    }

    func setHandlers(snapshot: @escaping (NSArray) -> Void, lifecycle: @escaping (String) -> Void,
                     decision: @escaping (String, String) -> Void) {
        snapshotHandler = snapshot
        lifecycleHandler = lifecycle
        decisionHandler = decision
    }

    func startMonitoring() -> Bool {
        guard isSupported, !invalidated else { return false }
        guard !monitoring else { return metadataAvailable }
        monitoring = true
        refreshMetadata()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let deadline = self.promptDeadline, Date() >= deadline { self.finishPrompt("expired") }
                self.refreshMetadata()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return metadataAvailable
    }

    func stopMonitoring() {
        monitoring = false
        timer?.invalidate()
        timer = nil
        removeAudioListeners()
        dismissSuggestion()
    }

    func refreshMetadata() {
        guard monitoring, !sleeping, !invalidated else { return }
        if #available(macOS 14.2, *) { readProcesses() }
    }

    @available(macOS 14.2, *)
    private func readProcesses() {
        var address = property(kAudioHardwarePropertyProcessObjectList)
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount) == noErr else {
            metadataAvailable = false
            lifecycleHandler?("unavailable")
            return
        }
        var objects = [AudioObjectID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioObjectID>.size)
        let status: OSStatus = objects.isEmpty ? noErr : objects.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, bytes.baseAddress!)
        }
        guard status == noErr else {
            metadataAvailable = false
            lifecycleHandler?("unavailable")
            return
        }
        metadataAvailable = true
        lifecycleHandler?("available")
        let wanted = Set(objects)
        let observed = Set(listeners.filter { $0.0 != AudioObjectID(kAudioObjectSystemObject) }.map { $0.0 })
        if wanted != observed || listeners.isEmpty {
            removeAudioListeners()
            listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)
            for object in objects {
                listen(object, selector: kAudioProcessPropertyIsRunningInput)
                listen(object, selector: kAudioProcessPropertyIsRunningOutput)
                listen(object, selector: kAudioProcessPropertyIsRunning)
            }
        }
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> (NSRunningApplication, MeetingOutputProcessOwnership.Application)? in
            guard let bundle = app.bundleIdentifier, allowedApplication(bundle) == bundle,
                  bundle != Bundle.main.bundleIdentifier,
                  let identity = MeetingOutputProcessMetadata.application(app.processIdentifier) else { return nil }
            return (app, identity)
        }
        var rows: [[String: Any]] = []
        // Keep idle running apps in the snapshot so a mute/disconnected audio client
        // cannot look like process termination and reset same-session suppression.
        for (app, identity) in applications {
            let bundle = identity.bundleIdentifier
            let launch = app.launchDate?.timeIntervalSince1970 ?? 0
            rows.append(["sessionID": "\(bundle):\(app.processIdentifier):\(launch)",
                         "processID": app.processIdentifier, "bundleIdentifier": bundle,
                         "displayName": app.localizedName ?? bundle, "isBrowser": browserIDs.contains(bundle),
                         "runningInput": false, "runningOutput": false])
        }
        for object in objects {
            guard let pid: Int32 = scalar(object, selector: kAudioProcessPropertyPID), pid != getpid(),
                  let process = MeetingOutputProcessMetadata.process(pid) else { continue }
            var bundleAddress = property(kAudioProcessPropertyBundleID)
            var bundle: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &size, &bundle) == noErr,
                  let bundleReference = bundle?.takeRetainedValue() else { continue }
            let bundleID = bundleReference as String
            let audio = MeetingOutputProcessOwnership.AudioProcess(objectID: object, bundleIdentifier: bundleID,
                                                                   process: process)
            // A bundle-name prefix is not proof that an audio client belongs to
            // this running app. Use the same launch/path/ancestry proof as the tap.
            guard let match = applications.first(where: {
                MeetingOutputProcessOwnership.owned(audio, by: $0.1, readProcess: MeetingOutputProcessMetadata.process) != nil
            }) else { continue }
            let (app, identity) = match
            let allowed = identity.bundleIdentifier
            let mainPID = identity.process.pid
            let launch = app.launchDate?.timeIntervalSince1970 ?? 0
            rows.append(["sessionID": "\(allowed):\(mainPID):\(launch)", "processID": mainPID,
                         "bundleIdentifier": allowed, "displayName": app.localizedName ?? allowed,
                         "isBrowser": browserIDs.contains(allowed),
                         "runningInput": (scalar(object, selector: kAudioProcessPropertyIsRunningInput) as UInt32? ?? 0) != 0,
                         "runningOutput": (scalar(object, selector: kAudioProcessPropertyIsRunningOutput) as UInt32? ?? 0) != 0])
        }
        snapshotHandler?(rows as NSArray)
    }

    private let knownIDs = ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.hnc.Discord"]
    private let browserIDs = ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "org.mozilla.firefox", "company.thebrowser.Browser"]

    private func allowedApplication(_ bundle: String) -> String? {
        knownIDs.first { bundle == $0 || bundle.hasPrefix($0 + ".") }
            ?? browserIDs.first { bundle == $0 || bundle.hasPrefix($0 + ".") }
    }

    private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func scalar<T: FixedWidthInteger>(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> T? {
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        var address = property(selector)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func listen(_ object: AudioObjectID, selector: AudioObjectPropertySelector) {
        var address = property(selector)
        let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshMetadata() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, callback) == noErr else { return }
        listeners.append((object, address, callback))
    }

    private func removeAudioListeners() {
        for listener in listeners {
            var address = listener.1
            AudioObjectRemovePropertyListenerBlock(listener.0, &address, .main, listener.2)
        }
        listeners.removeAll()
    }

    func presentSuggestion(token: String, title: String, message: String,
                           startLabel: String, skipLabel: String, expiresAt: Date) {
        dismissSuggestion()
        guard monitoring, !sleeping, expiresAt > Date() else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 384, height: 210),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let start = NSButton(title: startLabel, target: self, action: #selector(startPressed))
        start.bezelStyle = .rounded
        start.setAccessibilityIdentifier("meeting.detection.start")
        let skip = NSButton(title: skipLabel, target: self, action: #selector(skipPressed))
        skip.bezelStyle = .rounded
        skip.setAccessibilityIdentifier("meeting.detection.skip")
        let buttons = NSStackView(views: [skip, start])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [heading, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = panel.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                                     stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                                     stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16)])
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 404, y: frame.maxY - 230))
        }
        self.panel = panel
        promptToken = token
        promptDeadline = expiresAt
        panel.orderFrontRegardless()
    }

    func dismissSuggestion() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        promptToken = nil
        promptDeadline = nil
    }

    private func finishPrompt(_ decision: String) {
        guard let token = promptToken else { return }
        let valid = promptDeadline.map { Date() < $0 } == true
        dismissSuggestion()
        decisionHandler?(token, decision == "start" && !valid ? "expired" : decision)
    }

    @objc private func startPressed() { finishPrompt("start") }
    @objc private func skipPressed() { finishPrompt("skip") }
    @objc private func willTerminate() { invalidate() }

    func invalidate() {
        guard !invalidated else { return }
        stopMonitoring()
        invalidated = true
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        NotificationCenter.default.removeObserver(self)
        snapshotHandler = nil
        lifecycleHandler = nil
        decisionHandler = nil
    }
}
#endif
