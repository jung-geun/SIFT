import Foundation
import OSLog

/// A privacy-minimal projection: no session ID, source identity, meter, audio or text.
nonisolated struct MeetingRecordingStatusItemPresentation: Equatable {
    let paused: Bool
    let elapsedSeconds: Int64

    init(_ snapshot: MeetingRecordingActivitySnapshot) {
        paused = snapshot.phase == .paused
        elapsedSeconds = min(max(0, snapshot.elapsedMilliseconds), 315_576_000_000) / 1_000
    }
}

/// Optional macOS presentation. The activity center remains the only owner arbiter.
/// Feed its aggregate `current`, including nil, after every owner update.
@MainActor
final class MeetingRecordingMacStatusItem {
    static let shared = MeetingRecordingMacStatusItem(
        loadBridge: loadNativeBridge,
        localizedText: { key in
            String(localized: String.LocalizationValue(key), table: "RecordingActivity", locale: AppLanguage.current.locale)
        },
        openRecording: {
            #if targetEnvironment(macCatalyst)
            guard let sessionID = MeetingRecordingActivityCenter.shared.current?.sessionID else { return }
            MeetingRecordingMacSceneRegistry.shared.openRecording(sessionID: sessionID)
            #else
            MeetingRecordingActivityCenter.shared.requestOpenRecording()
            #endif
        }
    )

    private let loadBridge: () -> (any MeetingRecordingStatusItemBridging)?
    private let localizedText: (String) -> String
    private let openRecording: () -> Void
    private var bridge: (any MeetingRecordingStatusItemBridging)?
    private var attemptedLoad = false
    private var invalidated = false
    private var lastPresentation: MeetingRecordingStatusItemPresentation?

    init(loadBridge: @escaping () -> (any MeetingRecordingStatusItemBridging)?,
         localizedText: @escaping (String) -> String,
         openRecording: @escaping () -> Void) {
        self.loadBridge = loadBridge
        self.localizedText = localizedText
        self.openRecording = openRecording
    }

    func update(_ snapshot: MeetingRecordingActivitySnapshot?) {
        guard !invalidated else { return }
        guard let snapshot else {
            if lastPresentation != nil { bridge?.clear() }
            lastPresentation = nil
            return
        }
        let presentation = MeetingRecordingStatusItemPresentation(snapshot)
        guard presentation != lastPresentation else { return }
        lastPresentation = presentation
        if !attemptedLoad {
            attemptedLoad = true
            bridge = loadBridge()
            bridge?.setOpenRecordingAction(openRecording)
        }
        bridge?.present(paused: presentation.paused, elapsedSeconds: presentation.elapsedSeconds,
                        phaseLabel: localizedText(presentation.paused ? "Paused" : "Recording"),
                        openRecordingLabel: localizedText("Open recording"))
    }

    /// Explicit process-lifecycle cleanup. A nil snapshot only ends presentation;
    /// invalidation additionally releases callbacks and forbids later resurrection.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        lastPresentation = nil
        bridge?.invalidate()
        bridge = nil
    }

    private static func loadNativeBridge() -> (any MeetingRecordingStatusItemBridging)? {
        #if targetEnvironment(macCatalyst)
        let logger = Logger(subsystem: "pieroot.sift-todo", category: "RecordingStatusItem")
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("RecordingStatusMacSupport.bundle"),
              let bundle = Bundle(url: url) else {
            logger.error("Native recording status bundle is missing")
            return nil
        }
        do {
            try bundle.loadAndReturnError()
            guard let bridgeClass = bundle.principalClass as? any MeetingRecordingStatusItemBridging.Type else {
                logger.error("Native recording status bundle has an incompatible principal class")
                return nil
            }
            return bridgeClass.init()
        } catch {
            // Presentation failure never starts/stops capture or replaces it with
            // a fake in-window status item. Do not log paths or capture metadata.
            logger.error("Unable to load native recording status bundle")
            return nil
        }
        #else
        return nil
        #endif
    }
}
