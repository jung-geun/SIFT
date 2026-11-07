import Combine
import Foundation
import Testing
@testable import todo

@Suite("Full-cloud preference safety")
struct CloudPreferenceSafetyTests {
    @Test("A local model choice edited during an awaited sync is not overwritten")
    func changedChoiceSurvivesRestore() throws {
        let suite = "SIFTCloudPreferenceRace-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "preference/selectedAIProvider"
        defaults.set("laya", forKey: "selectedAIProvider")
        let before = try #require(CloudPreferenceStore.capture(defaults: defaults)[key])
        defaults.set("onDevice", forKey: "selectedAIProvider")
        let remote = try JSONEncoder().encode(CloudPreferenceValue.string("foundationModels"))
        #expect(throws: CloudPreferenceError.self) {
            try CloudPreferenceStore.apply(key: key, payload: remote,
                expectedDigest: CloudFileStore.digest(before), defaults: defaults)
        }
        #expect(defaults.string(forKey: "selectedAIProvider") == "onDevice")
    }

    @Test("Credential deletion, retry and restore receipts never become another device's live state")
    func credentialSafetyMetadataIsNotPortable() throws {
        let suite = "SIFTCloudCredentialMetadata-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = [
            "pieroot.todo.imap.explicitlyDeleted.a@example.invalid",
            "pieroot.todo.outlook.imap.explicitlyDeleted.a@example.invalid",
            "pieroot.todo.imap.portableReceipt.v1.a@example.invalid",
            "pieroot.todo.outlook.imap.portableReceipt.v1.a@example.invalid",
            "pieroot.todo.gmail.revoked.v1.oauth_tokens",
            "pieroot.todo.imap.pendingPublications.v1",
            "pieroot.todo.outlook.imap.pendingPublications.v1"
        ]
        for key in keys { defaults.set("device-private-state", forKey: key) }
        let snapshot = try CloudPreferenceStore.capture(defaults: defaults)
        let replacement = try JSONEncoder().encode(CloudPreferenceValue.string("foreign-state"))
        for key in keys {
            #expect(snapshot["preference/" + key] == nil)
            #expect(throws: CloudPreferenceError.self) {
                try CloudPreferenceStore.apply(key: "preference/" + key, payload: replacement,
                    expectedDigest: nil, defaults: defaults)
            }
            #expect(defaults.string(forKey: key) == "device-private-state")
        }
    }

    @Test("Meeting language and automatic-mode choices remain local during cloud capture and restore")
    func meetingLanguageMemoryIsNotPortable() throws {
        let suite = "SIFTCloudMeetingLanguages-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let local: [String: CloudPreferenceValue] = [
            "pieroot.todo.meeting.sourceLanguageTag": .string("ko-KR"),
            "pieroot.todo.meeting.summaryLanguageTag": .string("ja"),
            "pieroot.todo.meeting.automaticLanguageDetection": .boolean(false)
        ]
        for (key, value) in local { defaults.set(value.value, forKey: key) }
        let snapshot = try CloudPreferenceStore.capture(defaults: defaults)
        for (key, value) in local {
            #expect(snapshot["preference/" + key] == nil)
            let foreign = try JSONEncoder().encode(CloudPreferenceValue.string("en-US"))
            #expect(throws: CloudPreferenceError.self) {
                try CloudPreferenceStore.apply(key: "preference/" + key, payload: foreign,
                    expectedDigest: nil, defaults: defaults)
            }
            #expect(try CloudPreferenceValue(try #require(defaults.object(forKey: key))) == value)
        }
    }

    @Test("Retired local support identifiers and keepsakes never enter cloud preferences")
    func retiredSupportDataIsNotPortable() throws {
        let suite = "SIFTCloudRetiredSupport-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["123456"], forKey: "pieroot.todo.support.coffeeTransactions")
        defaults.set(4, forKey: "pieroot.todo.support.starlightStamps")
        let snapshot = try CloudPreferenceStore.capture(defaults: defaults)
        #expect(snapshot[CloudPreferenceStore.prefix + "pieroot.todo.support.coffeeTransactions"] == nil)
        #expect(snapshot[CloudPreferenceStore.prefix + "pieroot.todo.support.starlightStamps"] == nil)
    }
}

@Suite("CloudSyncMonitor completion deduplication", .serialized)
@MainActor
struct CloudSyncMonitorDeduplicationTests {
    @Test("Identical true-nil completion emissions from idle do not re-enter completed phase")
    func monitorDoesNotReenterCompletedFromIdle() async throws {
        let previousSync = UserDefaults.standard.bool(forKey: UserCloudSyncPolicy.syncKey)
        let previousAccount = UserDefaults.standard.string(forKey: UserCloudSyncPolicy.accountKey)
        let previousConsent = UserDefaults.standard.integer(forKey: UserCloudSyncPolicy.consentKey)
        defer {
            UserDefaults.standard.set(previousSync, forKey: UserCloudSyncPolicy.syncKey)
            UserDefaults.standard.set(previousAccount, forKey: UserCloudSyncPolicy.accountKey)
            UserDefaults.standard.set(previousConsent, forKey: UserCloudSyncPolicy.consentKey)
        }
        UserDefaults.standard.set(true, forKey: UserCloudSyncPolicy.syncKey)
        UserDefaults.standard.set("test-account", forKey: UserCloudSyncPolicy.accountKey)
        UserDefaults.standard.set(UserCloudSyncPolicy.consentVersion, forKey: UserCloudSyncPolicy.consentKey)

        // Polling with a generous bound: a slow machine can only delay, never fail.
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(condition())
        }
        // Lets any queued RunLoop deliveries run; used only for negative assertions,
        // where extra delay can hide a bug but can never cause a false failure.
        func settle() async throws {
            for _ in 0..<20 { try await Task.sleep(for: .milliseconds(5)) }
        }

        // Phase 1: a long banner keeps .completed stable while duplicates arrive.
        let longSubject = CurrentValueSubject<(Bool, String?), Never>((false, nil))
        let longMonitor = CloudSyncMonitor(
            statusPublisher: longSubject.eraseToAnyPublisher(),
            completionDuration: .seconds(60)
        )
        var longPhases = [CloudSyncPhase]()
        let longCancellable = longMonitor.$phase.sink { longPhases.append($0) }
        defer { longCancellable.cancel(); longMonitor.stopObserving() }
        #expect(longMonitor.phase == .idle)
        longMonitor.startObserving(initialCount: 0)
        #expect(longMonitor.phase == .importing)
        longSubject.send((false, nil))
        longSubject.send((false, nil))
        try await settle()
        #expect(longMonitor.phase == .importing)
        longSubject.send((true, nil))
        try await waitUntil { longMonitor.phase == .completed }
        for _ in 0..<5 { longSubject.send((true, nil)) }
        try await settle()
        #expect(longMonitor.phase == .completed)
        #expect(longPhases == [.idle, .importing, .completed])
        #expect(longPhases.filter { $0 == .completed }.count == 1)

        // Phase 2: after auto-dismissal, identical re-emissions, foreground
        // restarts and error->nil recovery never produce another banner.
        let shortSubject = CurrentValueSubject<(Bool, String?), Never>((false, nil))
        let shortMonitor = CloudSyncMonitor(
            statusPublisher: shortSubject.eraseToAnyPublisher(),
            completionDuration: .milliseconds(30)
        )
        var shortPhases = [CloudSyncPhase]()
        let shortCancellable = shortMonitor.$phase.sink { shortPhases.append($0) }
        defer { shortCancellable.cancel(); shortMonitor.stopObserving() }
        shortMonitor.startObserving(initialCount: 0)
        shortSubject.send((true, nil))
        shortSubject.send((true, nil))
        try await waitUntil { shortPhases == [.idle, .importing, .completed, .idle] }
        for _ in 0..<5 { shortSubject.send((true, nil)) }
        shortMonitor.startObserving(initialCount: 3)
        shortSubject.send((true, "sync warning"))
        shortSubject.send((true, nil))
        shortSubject.send((true, nil))
        try await settle()
        #expect(shortMonitor.phase == .idle)
        #expect(shortPhases.filter { $0 == .completed }.count == 1)
        #expect(shortPhases == [.idle, .importing, .completed, .idle])

        shortMonitor.stopObserving()
        #expect(shortMonitor.phase == .idle)
    }
}
