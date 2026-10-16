import Foundation
import Combine

/// Minimal, content-free state for detecting that a foreground app session did
/// not transition through the normal background path. This detects unexpected
/// foreground termination, not a definitive crash classification.
struct UnexpectedTerminationSessionStore {
    private enum Key {
        // Removed on every write/clear; never read for recovery classification.
        static let obsoleteBootEpoch = "pieroot.todo.unexpectedTermination.activeSessionBootEpoch.v1"
        static let activeSessionID = "pieroot.todo.unexpectedTermination.activeSessionID.v1"
        static let activeSessionUptime = "pieroot.todo.unexpectedTermination.activeSessionUptime.v1"
        static let activeSessionWallEventTime = "pieroot.todo.unexpectedTermination.activeSessionWallEventTime.v1"
        static let activeSessionVersion = "pieroot.todo.unexpectedTermination.activeSessionVersion.v1"
        static let presentedSessionID = "pieroot.todo.unexpectedTermination.presentedSessionID.v1"
    }
    private static let activeSessionVersion = 3


    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Compares elapsed time between foreground events using uptime and wall
    /// time. Disagreement conservatively suppresses reboot/clock-change prompts;
    /// this is a termination signal, not proof of a crash or boot identity.
    func beginForegroundSession(
        id: String = UUID().uuidString,
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        wallEventTime: Date = Date()
    ) -> Bool {
        let currentWallEventTime = wallEventTime.timeIntervalSince1970
        let previousID = defaults.string(forKey: Key.activeSessionID)
        let previousUptime = defaults.object(forKey: Key.activeSessionUptime) as? TimeInterval
        let previousWallEventTime = defaults.object(forKey: Key.activeSessionWallEventTime) as? TimeInterval
        let alreadyPresentedID = defaults.string(forKey: Key.presentedSessionID)
        let previousVersion = defaults.integer(forKey: Key.activeSessionVersion)
        let elapsedTimesAgree: Bool
        if let previousUptime, let previousWallEventTime {
            let uptimeElapsed = systemUptime - previousUptime
            let wallElapsed = currentWallEventTime - previousWallEventTime
            elapsedTimesAgree = previousUptime.isFinite && previousUptime >= 0
                && uptimeElapsed.isFinite && wallElapsed.isFinite
                && uptimeElapsed >= 0 && wallElapsed >= 0
                && abs(uptimeElapsed - wallElapsed) <= 2
        } else {
            elapsedTimesAgree = false
        }
        let shouldPrompt = previousVersion == Self.activeSessionVersion
            && previousID != nil
            && previousID != alreadyPresentedID
            && elapsedTimesAgree

        if shouldPrompt, let previousID {
            defaults.set(previousID, forKey: Key.presentedSessionID)
        }
        defaults.set(id, forKey: Key.activeSessionID)
        if systemUptime.isFinite, systemUptime >= 0, currentWallEventTime.isFinite {
            defaults.set(systemUptime, forKey: Key.activeSessionUptime)
            defaults.set(currentWallEventTime, forKey: Key.activeSessionWallEventTime)
        } else {
            defaults.removeObject(forKey: Key.activeSessionUptime)
            defaults.removeObject(forKey: Key.activeSessionWallEventTime)
        }
        defaults.set(Self.activeSessionVersion, forKey: Key.activeSessionVersion)
        defaults.removeObject(forKey: Key.obsoleteBootEpoch)
        return shouldPrompt
    }

    /// A normal background transition makes the current foreground session
    /// ineligible for recovery prompting on a future cold launch.
    func finishForegroundSession() {
        defaults.removeObject(forKey: Key.activeSessionID)
        defaults.removeObject(forKey: Key.activeSessionUptime)
        defaults.removeObject(forKey: Key.activeSessionWallEventTime)
        defaults.removeObject(forKey: Key.obsoleteBootEpoch)
        defaults.removeObject(forKey: Key.activeSessionVersion)
        defaults.removeObject(forKey: Key.presentedSessionID)
    }
}

struct UnexpectedTerminationDiagnosticError: Error, Sendable {}

struct UnexpectedTerminationPrompt: Identifiable {
    let id = UUID()
    let error = UnexpectedTerminationDiagnosticError()
}

@MainActor
final class UnexpectedTerminationRecoveryService: ObservableObject {
    private static var defaultSuppression: Bool {
        #if DEBUG
        // Xcode's Stop command sends SIGKILL without a UIKit lifecycle callback.
        // A development session must never create a user-facing crash candidate.
        return true
        #else
        return false
        #endif
    }

    static let shared = UnexpectedTerminationRecoveryService()

    @Published var pendingPrompt: UnexpectedTerminationPrompt?

    private let store: UnexpectedTerminationSessionStore
    private var foregroundSessionActive = false
    private let isSuppressed: Bool

    init(
        store: UnexpectedTerminationSessionStore? = nil,
        isSuppressed: Bool? = nil
    ) {
        self.store = store ?? UnexpectedTerminationSessionStore()
        self.isSuppressed = isSuppressed ?? Self.defaultSuppression
    }

    func enterForeground() {
        guard !foregroundSessionActive else { return }
        foregroundSessionActive = true
        guard !isSuppressed, store.beginForegroundSession() else { return }
        pendingPrompt = UnexpectedTerminationPrompt()
    }

    /// Leaving `.active` is a normal lifecycle transition. A later process
    /// termination must not be presented as an unexpected active-session exit.
    func enterInactive() {
        guard foregroundSessionActive else { return }
        foregroundSessionActive = false
        guard !isSuppressed else { return }
        store.finishForegroundSession()
    }

    func enterBackground() {
        enterInactive()
    }

}
