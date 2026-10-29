#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// Loaded in-process by Catalyst. Owns presentation only, never an audio session.
@MainActor
@objc(SIFTMeetingRecordingStatusItemPlugin)
final class MeetingRecordingStatusItemPlugin: NSObject, MeetingRecordingStatusItemBridging {
    private var statusItem: NSStatusItem?
    private var phaseItem: NSMenuItem?
    private var openItem: NSMenuItem?
    private var openRecordingAction: (() -> Void)?
    private var recordingImage: NSImage?
    private var pausedImage: NSImage?
    private var invalidated = false

    required override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate(_:)),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    func setOpenRecordingAction(_ action: @escaping () -> Void) {
        guard !invalidated else { return }
        openRecordingAction = action
    }

    func present(paused: Bool, elapsedSeconds: Int64, phaseLabel: String, openRecordingLabel: String) {
        guard !invalidated else { return }
        // No ticking clock: the capture owner's canonical, pause-aware snapshots
        // are the only authority for elapsed media time.
        let seconds = min(max(0, elapsedSeconds), 315_576_000)
        let elapsed: String
        if seconds >= 3_600 {
            elapsed = String(format: "%lld:%02lld:%02lld", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
        } else {
            elapsed = String(format: "%lld:%02lld", seconds / 60, seconds % 60)
        }
        if statusItem == nil { createStatusItem() }
        guard let statusItem, let button = statusItem.button else { return }
        button.image = paused ? pausedImage : recordingImage
        button.title = " " + elapsed
        button.toolTip = phaseLabel + " — " + elapsed
        button.setAccessibilityLabel(phaseLabel + " — " + elapsed)
        phaseItem?.title = phaseLabel + " — " + elapsed
        openItem?.title = openRecordingLabel
    }

    func clear() {
        guard let statusItem else { return }
        statusItem.menu?.cancelTracking()
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        phaseItem = nil
        openItem = nil
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        clear()
        openRecordingAction = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func createStatusItem() {
        if recordingImage == nil {
            recordingImage = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)
            recordingImage?.isTemplate = true
            pausedImage = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
            pausedImage?.isTemplate = true
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.imagePosition = .imageLeading
            button.setAccessibilityIdentifier("meeting.recordingStatusItem")
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let phase = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        phase.isEnabled = false
        let open = NSMenuItem(title: "", action: #selector(openRecording(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(phase)
        menu.addItem(.separator())
        menu.addItem(open)
        item.menu = menu
        statusItem = item
        phaseItem = phase
        openItem = open
    }

    @objc private func openRecording(_ sender: NSMenuItem) {
        // This is our own target-action selector; no private UIKit/AppKit lookup.
        NSApplication.shared.activate()
        openRecordingAction?()
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        invalidate()
    }
}

/// The existing native support bundle also hosts the system file panel. It
/// returns only the user's selected URL and never reads or changes its contents.
@MainActor
@objc(SIFTMeetingAudioFilePickerPlugin)
final class MeetingAudioFilePickerPlugin: NSObject, MeetingAudioFilePickerBridging {
    private var panel: NSOpenPanel?

    required override init() { super.init() }

    func chooseAudioFile(_ completion: @escaping (URL?, NSError?) -> Void) {
        guard panel == nil else { return }
        guard let window = NSApplication.shared.keyWindow, window.isVisible else {
            completion(nil, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        self.panel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.panel = nil
            completion(response == .OK ? panel.url : nil, nil)
        }
    }

    func cancelAudioFilePicker() { panel?.cancel(nil) }
}
#endif
