#if targetEnvironment(macCatalyst)
import OSLog
import SwiftUI
import UIKit

/// Routes an explicit menu action to the scene that actually hosted capture.
/// Entries retain only UIKit scene sessions, never a view, coordinator or audio owner.
@MainActor
final class MeetingRecordingMacSceneRegistry {
    static let shared = MeetingRecordingMacSceneRegistry()

    private struct Entry {
        let session: UISceneSession
        let anchorID: UUID
    }
    private var captures: [String: Entry] = [:]
    private var navigationSessionID: String?

    /// Persists across scene activation tasks until user navigation or capture end.
    var hasPendingRecordingNavigation: Bool { navigationSessionID != nil }

    func clearNavigationIntent() {
        navigationSessionID = nil
    }

    func register(sessionID: String, sceneSession: UISceneSession, anchorID: UUID) {
        if let existing = captures[sessionID], existing.anchorID == anchorID,
           existing.session.persistentIdentifier == sceneSession.persistentIdentifier { return }
        captures[sessionID] = Entry(session: sceneSession, anchorID: anchorID)
    }

    /// An old/remounted view must not erase a newer anchor's mapping.
    func clear(sessionID: String, anchorID: UUID) {
        guard captures[sessionID]?.anchorID == anchorID else { return }
        clear(sessionID: sessionID)
    }

    /// The activity center calls this when the owning capture ends or changes ID.
    /// It also covers captures whose tab/view was dismantled before Stop.
    func clear(sessionID: String) {
        captures.removeValue(forKey: sessionID)
        if navigationSessionID == sessionID { clearNavigationIntent() }
    }

    func clearAll() {
        captures.removeAll()
        clearNavigationIntent()
    }

    func openRecording(sessionID: String) {
        guard let entry = captures[sessionID] else {
            Logger(subsystem: "pieroot.sift-todo", category: "RecordingStatusItem")
                .error("Recording scene is not registered")
            return
        }
        // Set before requesting activation: foreground routing can run before
        // the notification below, and must not restore a fixed launch tab.
        navigationSessionID = sessionID
        // This targets the exact registered main/recording session, including a
        // minimized or disconnected scene, not a Settings scene or arbitrary first.
        let request = UISceneSessionActivationRequest(session: entry.session, userActivity: nil, options: nil)
        UIApplication.shared.activateSceneSession(for: request) { _ in
            Logger(subsystem: "pieroot.sift-todo", category: "RecordingStatusItem")
                .error("Unable to activate recording scene")
        }
        MeetingRecordingActivityCenter.shared.requestOpenRecording()
    }
}

/// Transparent anchor in MeetingView; `windowScene` supplies authoritative identity.
/// A tab going offscreen detaches its UIView but does not end the recording.
struct MeetingRecordingMacSceneAnchor: UIViewRepresentable {
    let sessionID: String?

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.configure(sessionID: sessionID)
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        uiView.configure(sessionID: sessionID)
    }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Void) {
        // A SwiftUI tab can be dismantled while its StateObject capture survives.
        // The registry retains no view; authoritative owner-clear in the activity
        // center removes the entry even when this view never receives nil again.
        uiView.detach()
    }

    final class AnchorView: UIView {
        private let anchorID = UUID()
        private var sessionID: String?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { return nil }

        func configure(sessionID: String?) {
            if let previous = self.sessionID, previous != sessionID {
                MeetingRecordingMacSceneRegistry.shared.clear(sessionID: previous, anchorID: anchorID)
            }
            self.sessionID = sessionID
            registerIfAttached()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // In particular, nil window during a tab switch does NOT unregister.
            registerIfAttached()
        }

        func detach() {
            sessionID = nil
        }

        private func registerIfAttached() {
            guard let sessionID, let sceneSession = window?.windowScene?.session else { return }
            MeetingRecordingMacSceneRegistry.shared.register(sessionID: sessionID,
                                                            sceneSession: sceneSession, anchorID: anchorID)
        }
    }
}
#endif
