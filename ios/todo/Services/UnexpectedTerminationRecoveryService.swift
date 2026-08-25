import Foundation
import Combine
import Darwin

/// Minimal, content-free state for detecting that a foreground app session did
/// not transition through the normal background path. This detects unexpected
/// foreground termination, not a definitive crash classification.
struct UnexpectedTerminationSessionStore {
    private enum Key {
        static let activeSessionBootEpoch = "pieroot.todo.unexpectedTermination.activeSessionBootEpoch.v1"
        static let activeSessionID = "pieroot.todo.unexpectedTermination.activeSessionID.v1"
        static let activeSessionUptime = "pieroot.todo.unexpectedTermination.activeSessionUptime.v1"
        static let presentedSessionID = "pieroot.todo.unexpectedTermination.presentedSessionID.v1"
    }

    static func currentBootEpoch() -> TimeInterval? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 else {
            return nil
        }
        return TimeInterval(bootTime.tv_sec) + TimeInterval(bootTime.tv_usec) / 1_000_000
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Starts a foreground session and returns whether the preceding session
    /// ended without being marked clean during the same system boot.
    func beginForegroundSession(
        id: String = UUID().uuidString,
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        systemBootEpoch: TimeInterval? = nil
    ) -> Bool {
        let currentBootEpoch = systemBootEpoch ?? Self.currentBootEpoch()
        let previousID = defaults.string(forKey: Key.activeSessionID)
        let previousUptime = defaults.object(forKey: Key.activeSessionUptime) as? TimeInterval
        let previousBootEpoch = defaults.object(forKey: Key.activeSessionBootEpoch) as? TimeInterval
        let alreadyPresentedID = defaults.string(forKey: Key.presentedSessionID)
        let sameBoot = currentBootEpoch.flatMap { currentBootEpoch in
            previousBootEpoch.map { abs($0 - currentBootEpoch) < 1 }
        } ?? false
        let shouldPrompt = previousID != nil
            && previousID != alreadyPresentedID
            && sameBoot
            && (previousUptime ?? systemUptime) <= systemUptime

        if shouldPrompt, let previousID {
            defaults.set(previousID, forKey: Key.presentedSessionID)
        }
        defaults.set(id, forKey: Key.activeSessionID)
        defaults.set(systemUptime, forKey: Key.activeSessionUptime)
        if let currentBootEpoch {
            defaults.set(currentBootEpoch, forKey: Key.activeSessionBootEpoch)
        } else {
            defaults.removeObject(forKey: Key.activeSessionBootEpoch)
        }
        return shouldPrompt
    }

    /// A normal background transition makes the current foreground session
    /// ineligible for recovery prompting on a future cold launch.
    func finishForegroundSession() {
        defaults.removeObject(forKey: Key.activeSessionID)
        defaults.removeObject(forKey: Key.activeSessionUptime)
        defaults.removeObject(forKey: Key.activeSessionBootEpoch)
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
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains("-ui-test-suppress-crash-prompt")
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

    func enterBackground() {
        guard foregroundSessionActive else { return }
        foregroundSessionActive = false
        guard !isSuppressed else { return }
        store.finishForegroundSession()
    }

}
