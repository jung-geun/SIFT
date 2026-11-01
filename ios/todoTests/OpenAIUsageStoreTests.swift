import Foundation
import CryptoKit
import Testing
@testable import todo

@Suite("Device-local OpenAI response usage")
@MainActor struct OpenAIUsageStoreTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "OpenAIUsageStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func missingUsageIsUnavailableAndReportedZeroIsCounted() throws {
        try withDefaults { defaults in
            let store = OpenAIUsageStore(defaults: defaults, now: { start })
            #expect(store.totals(for: "person-a") == nil)
            #expect(store.record(accountSubject: "person-a", responseID: "response-1",
                                 usage: .init(inputTokens: 0, outputTokens: 0, cachedInputTokens: 0)))
            let totals = try #require(store.totals(for: "person-a"))
            #expect(totals.inputTokens == 0)
            #expect(totals.outputTokens == 0)
            #expect(totals.cachedInputTokens == 0)
            #expect(totals.recordedResponses == 1)
            #expect(totals.since == start)
        }
    }

    @Test func duplicateResponseIsIgnoredEvenWithDifferentCounts() throws {
        try withDefaults { defaults in
            let store = OpenAIUsageStore(defaults: defaults, now: { start })
            #expect(store.record(accountSubject: "person-a", responseID: "response-1",
                                 usage: .init(inputTokens: 40, outputTokens: 12, cachedInputTokens: 30)))
            let data = defaults.data(forKey: OpenAIUsageStore.storageKey)
            let revision = store.revision
            #expect(!store.record(accountSubject: "person-a", responseID: "response-1",
                                  usage: .init(inputTokens: 100, outputTokens: 100, cachedInputTokens: 0)))
            #expect(defaults.data(forKey: OpenAIUsageStore.storageKey) == data)
            #expect(store.revision == revision)
            #expect(store.totals(for: "person-a")?.recordedResponses == 1)
        }
    }

    @Test func accountsAreExactAndResponseIDsAreScopedToEachAccount() throws {
        try withDefaults { defaults in
            let store = OpenAIUsageStore(defaults: defaults, now: { start })
            #expect(store.record(accountSubject: "Person-a", responseID: "same-response",
                                 usage: .init(inputTokens: 40, outputTokens: 12, cachedInputTokens: 30)))
            #expect(store.record(accountSubject: "person-a", responseID: "same-response",
                                 usage: .init(inputTokens: 9, outputTokens: 2, cachedInputTokens: 0)))
            #expect(store.totals(for: "Person-a")?.inputTokens == 40)
            #expect(store.totals(for: "person-a")?.inputTokens == 9)
            #expect(store.totals(for: "person-a ") == nil)
            #expect(store.totals(for: "person-b") == nil)
        }
    }

    @Test func recreationPreservesTotalsDedupAndFirstTimestamp() throws {
        try withDefaults { defaults in
            let store = OpenAIUsageStore(defaults: defaults, now: { start })
            let first = OpenAIResponseUsage(inputTokens: 40, outputTokens: 12, cachedInputTokens: 30)
            #expect(store.record(accountSubject: "person-a", responseID: "response-1", usage: first))
            let restarted = OpenAIUsageStore(defaults: defaults, now: { start.addingTimeInterval(500) })
            #expect(!restarted.record(accountSubject: "person-a", responseID: "response-1", usage: first))
            #expect(restarted.record(accountSubject: "person-a", responseID: "response-2",
                                     usage: .init(inputTokens: 20, outputTokens: 3, cachedInputTokens: 5)))
            let totals = try #require(restarted.totals(for: "person-a"))
            #expect(totals.inputTokens == 60)
            #expect(totals.outputTokens == 15)
            #expect(totals.cachedInputTokens == 35)
            #expect(totals.recordedResponses == 2)
            #expect(totals.since == start)
            // An older store instance must not overwrite a newer instance's receipts.
            #expect(!store.record(accountSubject: "person-a", responseID: "response-2", usage: first))
            #expect(store.totals(for: "person-a") == totals)
        }
    }

    @Test(arguments: [
        OpenAIResponseUsage(inputTokens: -1, outputTokens: 1, cachedInputTokens: 0),
        OpenAIResponseUsage(inputTokens: 1, outputTokens: -1, cachedInputTokens: 0),
        OpenAIResponseUsage(inputTokens: 1, outputTokens: 1, cachedInputTokens: -1),
        OpenAIResponseUsage(inputTokens: 1, outputTokens: 1, cachedInputTokens: 2)
    ]) func malformedCountsDoNotMutateOrConsumeResponseID(_ invalid: OpenAIResponseUsage) throws {
        try withDefaults { defaults in
            let store = OpenAIUsageStore(defaults: defaults, now: { start })
            #expect(!store.record(accountSubject: "person-a", responseID: "response-1", usage: invalid))
            #expect(defaults.object(forKey: OpenAIUsageStore.storageKey) == nil)
            #expect(store.revision == 0)
            #expect(store.record(accountSubject: "person-a", responseID: "response-1",
                                 usage: .init(inputTokens: 1, outputTokens: 1, cachedInputTokens: 1)))
        }
    }

    @Test(arguments: ["", " ", "\n\t"])
    func missingIdentifiersDoNotCreateCounts(_ identifier: String) throws {
        try withDefaults { defaults in
            let store = OpenAIUsageStore(defaults: defaults, now: { start })
            let usage = OpenAIResponseUsage(inputTokens: 1, outputTokens: 1, cachedInputTokens: 0)
            #expect(!store.record(accountSubject: identifier, responseID: "response-1", usage: usage))
            #expect(!store.record(accountSubject: "person-a", responseID: identifier, usage: usage))
            #expect(defaults.object(forKey: OpenAIUsageStore.storageKey) == nil)
        }
    }

    @Test(arguments: [true, false])
    func overflowIsAtomicAndDoesNotConsumeResponseID(_ overflowInput: Bool) throws {
        try withDefaults { defaults in
            let store = OpenAIUsageStore(defaults: defaults, now: { start })
            #expect(store.record(accountSubject: "person-a", responseID: "response-1", usage: .init(
                inputTokens: overflowInput ? Int.max : 10,
                outputTokens: overflowInput ? 10 : Int.max,
                cachedInputTokens: overflowInput ? Int.max : 10)))
            let data = defaults.data(forKey: OpenAIUsageStore.storageKey)
            let totals = store.totals(for: "person-a")
            #expect(!store.record(accountSubject: "person-a", responseID: "response-2",
                                  usage: .init(inputTokens: 1, outputTokens: 1, cachedInputTokens: 1)))
            #expect(defaults.data(forKey: OpenAIUsageStore.storageKey) == data)
            #expect(store.totals(for: "person-a") == totals)
            #expect(store.record(accountSubject: "person-a", responseID: "response-2",
                                 usage: .init(inputTokens: 0, outputTokens: 0, cachedInputTokens: 0)))
            #expect(store.totals(for: "person-a")?.recordedResponses == 2)
        }
    }

    @Test(arguments: ["not-json", "{\"version\":2,\"accounts\":{}}", "{\"version\":1,\"accounts\":{\"invalid\":{}}}"])
    func malformedPersistenceIsHeldWithoutResettingReceipts(_ invalid: String) throws {
        try withDefaults { defaults in
            let data = Data(invalid.utf8)
            defaults.set(data, forKey: OpenAIUsageStore.storageKey)
            let store = OpenAIUsageStore(defaults: defaults, now: { start })
            #expect(store.totals(for: "person-a") == nil)
            #expect(!store.record(accountSubject: "person-a", responseID: "response-1",
                                  usage: .init(inputTokens: 1, outputTokens: 1, cachedInputTokens: 0)))
            #expect(defaults.data(forKey: OpenAIUsageStore.storageKey) == data)
            #expect(store.revision == 0)
        }
    }

    @Test func invalidPersistedTotalsAndDedupMismatchAreUnavailable() throws {
        try withDefaults { defaults in
            let key = SHA256.hash(data: Data("person-a".utf8)).map { String(format: "%02x", $0) }.joined()
            let store = OpenAIUsageStore(defaults: defaults, now: { start })
            for (input, cached, count) in [(1, 2, 1), (-1, 0, 1), (1, 0, 2)] {
                let payload: [String: Any] = ["version": 1, "accounts": [key: [
                    "totals": ["inputTokens": input, "outputTokens": 0, "cachedInputTokens": cached,
                               "recordedResponses": count, "since": 0], "responseIDs": ["response-1"]
                ]]]
                let data = try JSONSerialization.data(withJSONObject: payload)
                defaults.set(data, forKey: OpenAIUsageStore.storageKey)
                #expect(store.totals(for: "person-a") == nil)
                #expect(!store.record(accountSubject: "person-a", responseID: "response-2",
                                      usage: .init(inputTokens: 0, outputTokens: 0, cachedInputTokens: 0)))
                #expect(defaults.data(forKey: OpenAIUsageStore.storageKey) == data)
            }
        }
    }

    @Test func persistenceContainsOnlyHashedIdentityAndUsageAndIsExcludedFromCloud() throws {
        try withDefaults { defaults in
            let store = OpenAIUsageStore(defaults: defaults, now: { start })
            #expect(store.record(accountSubject: "private-subject@example.invalid", responseID: "response-1",
                                 usage: .init(inputTokens: 40, outputTokens: 12, cachedInputTokens: 30)))
            let data = try #require(defaults.data(forKey: OpenAIUsageStore.storageKey))
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(!text.contains("private-subject"))
            #expect(!text.contains("example.invalid"))
            #expect(!CloudPreferenceStore.isUserPreference(OpenAIUsageStore.storageKey))
            let captured = try CloudPreferenceStore.capture(defaults: defaults)
            #expect(captured.keys.allSatisfy { !$0.contains(OpenAIUsageStore.storageKey) })
        }
    }

    @Test func explicitDeletionClearsEveryAccountAndReceipts() throws {
        try withDefaults { defaults in
            let store = OpenAIUsageStore(defaults: defaults, now: { start })
            let usage = OpenAIResponseUsage(inputTokens: 1, outputTokens: 1, cachedInputTokens: 0)
            #expect(store.record(accountSubject: "person-a", responseID: "response-1", usage: usage))
            #expect(store.record(accountSubject: "person-b", responseID: "response-1", usage: usage))
            store.clearAll()
            #expect(defaults.object(forKey: OpenAIUsageStore.storageKey) == nil)
            let restarted = OpenAIUsageStore(defaults: defaults, now: { start.addingTimeInterval(500) })
            #expect(restarted.totals(for: "person-a") == nil)
            #expect(restarted.totals(for: "person-b") == nil)
            #expect(restarted.record(accountSubject: "person-a", responseID: "response-1", usage: usage))
            #expect(restarted.totals(for: "person-a")?.since == start.addingTimeInterval(500))
        }
    }
}
