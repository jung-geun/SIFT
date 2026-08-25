import Foundation
import Testing
@testable import todo

@Suite("Unexpected termination recovery")
struct UnexpectedTerminationRecoveryServiceTests {
    @Test("an unclosed foreground session prompts once on the next same-boot launch")
    func unclosedForegroundSessionPromptsOnce() {
        let suiteName = "UnexpectedTerminationRecoveryServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UnexpectedTerminationSessionStore(defaults: defaults)

        #expect(!store.beginForegroundSession(id: "first", systemUptime: 100, systemBootEpoch: 1_000))
        #expect(store.beginForegroundSession(id: "second", systemUptime: 101, systemBootEpoch: 1_000.5))

        store.finishForegroundSession()
        #expect(!store.beginForegroundSession(id: "third", systemUptime: 102, systemBootEpoch: 1_000))
    }

    @Test("normal background and a changed boot identity do not prompt")
    func cleanBackgroundAndChangedBootDoNotPrompt() {
        let suiteName = "UnexpectedTerminationRecoveryServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UnexpectedTerminationSessionStore(defaults: defaults)

        #expect(!store.beginForegroundSession(id: "backgrounded", systemUptime: 100, systemBootEpoch: 1_000))
        store.finishForegroundSession()
        #expect(!store.beginForegroundSession(id: "resumed", systemUptime: 101, systemBootEpoch: 1_000))
        #expect(store.beginForegroundSession(id: "before-reboot", systemUptime: 200, systemBootEpoch: 1_000))
        #expect(!store.beginForegroundSession(id: "after-reboot", systemUptime: 300, systemBootEpoch: 2_000))
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

        #expect(!store.beginForegroundSession(id: "first", systemUptime: 100, systemBootEpoch: 1_000))
        #expect(store.beginForegroundSession(id: "second", systemUptime: 101, systemBootEpoch: 1_000))
        #expect(store.beginForegroundSession(id: "second", systemUptime: 102, systemBootEpoch: 1_000))
        #expect(!store.beginForegroundSession(id: "third", systemUptime: 103, systemBootEpoch: 1_000))
    }
}
