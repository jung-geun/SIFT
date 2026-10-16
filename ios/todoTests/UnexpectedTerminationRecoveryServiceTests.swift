import Foundation
import Testing
@testable import todo

@Suite("Unexpected termination recovery")
struct UnexpectedTerminationRecoveryServiceTests {
    @Test("an unclosed foreground session prompts once when elapsed event times agree")
    func unclosedForegroundSessionPromptsOnce() {
        let suiteName = "UnexpectedTerminationRecoveryServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UnexpectedTerminationSessionStore(defaults: defaults)

        #expect(!store.beginForegroundSession(id: "first", systemUptime: 100, wallEventTime: Date(timeIntervalSince1970: 1_000)))
        #expect(store.beginForegroundSession(id: "second", systemUptime: 101, wallEventTime: Date(timeIntervalSince1970: 1_001.5)))

        store.finishForegroundSession()
        #expect(!store.beginForegroundSession(id: "third", systemUptime: 102, wallEventTime: Date(timeIntervalSince1970: 1_002)))
    }

    @Test("normal background and reboot-like elapsed disagreement do not prompt")
    func cleanBackgroundAndChangedTimelineDoNotPrompt() {
        let suiteName = "UnexpectedTerminationRecoveryServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UnexpectedTerminationSessionStore(defaults: defaults)

        #expect(!store.beginForegroundSession(id: "backgrounded", systemUptime: 100, wallEventTime: Date(timeIntervalSince1970: 1_000)))
        store.finishForegroundSession()
        #expect(!store.beginForegroundSession(id: "resumed", systemUptime: 101, wallEventTime: Date(timeIntervalSince1970: 1_001)))
        #expect(store.beginForegroundSession(id: "before-reboot", systemUptime: 200, wallEventTime: Date(timeIntervalSince1970: 1_100)))
        // Uptime can exceed the old value after a long post-reboot delay. Its
        // elapsed interval must still agree with the interval between app events.
        #expect(!store.beginForegroundSession(id: "after-reboot", systemUptime: 300, wallEventTime: Date(timeIntervalSince1970: 2_200)))
    }

    @Test("a pre-classifier foreground marker does not prompt after the update")
    func legacyForegroundMarkerDoesNotPrompt() {
        let suiteName = "UnexpectedTerminationRecoveryServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("legacy", forKey: "pieroot.todo.unexpectedTermination.activeSessionID.v1")
        defaults.set(100.0, forKey: "pieroot.todo.unexpectedTermination.activeSessionUptime.v1")
        defaults.set(1_000.0, forKey: "pieroot.todo.unexpectedTermination.activeSessionBootEpoch.v1")

        let store = UnexpectedTerminationSessionStore(defaults: defaults)
        #expect(!store.beginForegroundSession(id: "current", systemUptime: 101, wallEventTime: Date(timeIntervalSince1970: 1_001)))
        #expect(defaults.object(forKey: "pieroot.todo.unexpectedTermination.activeSessionBootEpoch.v1") == nil)
    }

    @Test("an inactive transition clears the foreground termination candidate")
    @MainActor
    func inactiveTransitionClearsForegroundTerminationCandidate() {
        let suiteName = "UnexpectedTerminationRecoveryServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UnexpectedTerminationSessionStore(defaults: defaults)
        let first = UnexpectedTerminationRecoveryService(store: store, isSuppressed: false)
        first.enterForeground()
        first.enterInactive()

        let resumed = UnexpectedTerminationRecoveryService(store: store, isSuppressed: false)
        resumed.enterForeground()
        #expect(resumed.pendingPrompt == nil)
    }

    @Test("suppressed recovery leaves an existing marker untouched")
    @MainActor
    func suppressedRecoveryDoesNotMutateMarkers() {
        let suiteName = "UnexpectedTerminationRecoveryServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UnexpectedTerminationSessionStore(defaults: defaults)
        let uptime = ProcessInfo.processInfo.systemUptime
        #expect(!store.beginForegroundSession(id: "stale", systemUptime: uptime))

        let suppressed = UnexpectedTerminationRecoveryService(store: store, isSuppressed: true)
        suppressed.enterForeground()
        suppressed.enterBackground()
        #expect(suppressed.pendingPrompt == nil)

        let unsuppressed = UnexpectedTerminationRecoveryService(store: store, isSuppressed: false)
        unsuppressed.enterForeground()
        #expect(unsuppressed.pendingPrompt != nil)
    }

    @Test("foreground re-entry does not replace an existing recovery prompt")
    @MainActor
    func foregroundReentryDoesNotCreateSecondPrompt() {
        let suiteName = "UnexpectedTerminationRecoveryServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UnexpectedTerminationSessionStore(defaults: defaults)
        let uptime = ProcessInfo.processInfo.systemUptime
        #expect(!store.beginForegroundSession(id: "stale", systemUptime: uptime))

        let recovery = UnexpectedTerminationRecoveryService(store: store, isSuppressed: false)
        recovery.enterForeground()
        let firstPromptID = recovery.pendingPrompt?.id
        recovery.enterForeground()
        #expect(firstPromptID != nil)
        #expect(recovery.pendingPrompt?.id == firstPromptID)
    }

    @Test("an already-presented session marker does not prompt again")
    func alreadyPresentedSessionDoesNotPromptAgain() {
        let suiteName = "UnexpectedTerminationRecoveryServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UnexpectedTerminationSessionStore(defaults: defaults)

        #expect(!store.beginForegroundSession(id: "first", systemUptime: 100, wallEventTime: Date(timeIntervalSince1970: 1_000)))
        #expect(store.beginForegroundSession(id: "second", systemUptime: 101, wallEventTime: Date(timeIntervalSince1970: 1_001)))
        #expect(store.beginForegroundSession(id: "second", systemUptime: 102, wallEventTime: Date(timeIntervalSince1970: 1_002)))
        #expect(!store.beginForegroundSession(id: "third", systemUptime: 103, wallEventTime: Date(timeIntervalSince1970: 1_003)))
    }

    @Test("version 2 boot markers cannot classify a version 3 event interval")
    func oldVersionMarkerDoesNotPrompt() {
        let suiteName = "UnexpectedTerminationRecoveryServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("old", forKey: "pieroot.todo.unexpectedTermination.activeSessionID.v1")
        defaults.set(100.0, forKey: "pieroot.todo.unexpectedTermination.activeSessionUptime.v1")
        defaults.set(1_000.0, forKey: "pieroot.todo.unexpectedTermination.activeSessionWallEventTime.v1")
        defaults.set(900.0, forKey: "pieroot.todo.unexpectedTermination.activeSessionBootEpoch.v1")
        defaults.set(2, forKey: "pieroot.todo.unexpectedTermination.activeSessionVersion.v1")
        let store = UnexpectedTerminationSessionStore(defaults: defaults)

        #expect(!store.beginForegroundSession(id: "new", systemUptime: 101, wallEventTime: Date(timeIntervalSince1970: 1_001)))
        #expect(defaults.integer(forKey: "pieroot.todo.unexpectedTermination.activeSessionVersion.v1") == 3)
        #expect(defaults.object(forKey: "pieroot.todo.unexpectedTermination.activeSessionBootEpoch.v1") == nil)
    }

    @Test("reboot, clock changes, and mismatching sleep intervals suppress recovery")
    func disagreeingElapsedTimesDoNotPrompt() {
        let cases: [(uptime: TimeInterval, wallTime: TimeInterval)] = [
            (99, 1_001),       // uptime moved backwards
            (101, 999),        // wall clock moved backwards
            (101, 1_010),      // forward clock adjustment or sleep
            (110, 1_001),      // backward clock adjustment with a positive interval
            (101, 1_003.01),   // outside the two-second tolerance
            (.nan, 1_001),
            (.infinity, 1_001),
            (101, .infinity)
        ]
        for current in cases {
            let suiteName = "UnexpectedTerminationRecoveryServiceTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = UnexpectedTerminationSessionStore(defaults: defaults)
            #expect(!store.beginForegroundSession(id: "previous", systemUptime: 100, wallEventTime: Date(timeIntervalSince1970: 1_000)))
            #expect(!store.beginForegroundSession(id: "current", systemUptime: current.uptime, wallEventTime: Date(timeIntervalSince1970: current.wallTime)))
        }
    }

    @Test("elapsed event agreement permits two seconds of sampling tolerance")
    func matchingIntervalsWithinTolerancePrompt() {
        let suiteName = "UnexpectedTerminationRecoveryServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UnexpectedTerminationSessionStore(defaults: defaults)
        #expect(!store.beginForegroundSession(id: "previous", systemUptime: 100, wallEventTime: Date(timeIntervalSince1970: 1_000)))
        #expect(store.beginForegroundSession(id: "current", systemUptime: 101, wallEventTime: Date(timeIntervalSince1970: 1_003)))
    }

    @Test("an incomplete foreground interval cannot classify a termination")
    func missingIntervalMarkerDoesNotPrompt() {
        for missingKey in [
            "pieroot.todo.unexpectedTermination.activeSessionUptime.v1",
            "pieroot.todo.unexpectedTermination.activeSessionWallEventTime.v1"
        ] {
            let suiteName = "UnexpectedTerminationRecoveryServiceTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = UnexpectedTerminationSessionStore(defaults: defaults)
            #expect(!store.beginForegroundSession(id: "previous", systemUptime: 100, wallEventTime: Date(timeIntervalSince1970: 1_000)))
            defaults.removeObject(forKey: missingKey)
            #expect(!store.beginForegroundSession(id: "current", systemUptime: 101, wallEventTime: Date(timeIntervalSince1970: 1_001)))
        }
    }
}
