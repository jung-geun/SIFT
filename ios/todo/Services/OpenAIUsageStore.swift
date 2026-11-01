import Foundation
import Combine
import CryptoKit

/// Counts returned by one completed response. Cached input is a subset of input.
nonisolated struct OpenAIResponseUsage: Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cachedInputTokens: Int

    var isValid: Bool {
        inputTokens >= 0 && outputTokens >= 0
            && cachedInputTokens >= 0 && cachedInputTokens <= inputTokens
    }
}

nonisolated struct OpenAIUsageTotals: Codable, Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cachedInputTokens: Int
    let recordedResponses: Int
    let since: Date
}

/// Device-local, account-subject-scoped counts, not billing, quota, or account-wide usage.
/// The `openai.device` namespace is excluded by CloudPreferenceStore.isUserPreference.
/// No prompts, response text, email addresses, or credentials are retained here.
@MainActor final class OpenAIUsageStore: ObservableObject {
    static let shared = OpenAIUsageStore()
    nonisolated static let storageKey = "pieroot.todo.openai.device.responseUsage.v1"

    @Published private(set) var revision: UInt64 = 0
    private let defaults: UserDefaults
    private let now: () -> Date

    nonisolated private struct Account: Codable {
        var totals: OpenAIUsageTotals
        var responseIDs: Set<String>

        var isValid: Bool {
            OpenAIResponseUsage(inputTokens: totals.inputTokens, outputTokens: totals.outputTokens,
                                cachedInputTokens: totals.cachedInputTokens).isValid
                && totals.recordedResponses > 0
                && totals.recordedResponses == responseIDs.count
                && totals.since.timeIntervalSince1970.isFinite
                && responseIDs.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    nonisolated private struct State: Codable {
        let version: Int
        var accounts: [String: Account]
    }

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    func totals(for accountSubject: String) -> OpenAIUsageTotals? {
        guard let key = Self.accountKey(accountSubject) else { return nil }
        return load()?.accounts[key]?.totals
    }

    /// Returns false without changing persisted state for duplicates or invalid/overflowing counts.
    /// Corrupt storage is held unavailable rather than overwriting its deduplication history.
    @discardableResult
    func record(accountSubject: String, responseID: String, usage: OpenAIResponseUsage) -> Bool {
        guard usage.isValid, let key = Self.accountKey(accountSubject),
              !responseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var state = load() else { return false }
        let previous = state.accounts[key]
        guard previous?.responseIDs.contains(responseID) != true else { return false }
        let timestamp = previous?.totals.since ?? now()
        guard timestamp.timeIntervalSince1970.isFinite else { return false }
        let input = (previous?.totals.inputTokens ?? 0).addingReportingOverflow(usage.inputTokens)
        let output = (previous?.totals.outputTokens ?? 0).addingReportingOverflow(usage.outputTokens)
        let cached = (previous?.totals.cachedInputTokens ?? 0).addingReportingOverflow(usage.cachedInputTokens)
        let responses = (previous?.totals.recordedResponses ?? 0).addingReportingOverflow(1)
        guard !input.overflow, !output.overflow, !cached.overflow, !responses.overflow else { return false }
        var responseIDs = previous?.responseIDs ?? []
        responseIDs.insert(responseID)
        state.accounts[key] = Account(totals: OpenAIUsageTotals(
            inputTokens: input.partialValue, outputTokens: output.partialValue,
            cachedInputTokens: cached.partialValue, recordedResponses: responses.partialValue,
            since: timestamp), responseIDs: responseIDs)
        guard let data = try? JSONEncoder().encode(state) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        revision &+= 1
        return true
    }

    /// Explicit connection-history deletion only. Ordinary sign-out retains local counts.
    func clearAll() {
        defaults.removeObject(forKey: Self.storageKey)
        revision &+= 1
    }

    private func load() -> State? {
        guard let stored = defaults.object(forKey: Self.storageKey) else {
            return State(version: 1, accounts: [:])
        }
        guard let data = stored as? Data,
              let state = try? JSONDecoder().decode(State.self, from: data), state.version == 1,
              state.accounts.allSatisfy({ key, account in
                  key.count == 64 && key.allSatisfy { "0123456789abcdef".contains($0) } && account.isValid
              }) else { return nil }
        return state
    }

    nonisolated private static func accountKey(_ subject: String) -> String? {
        guard !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SHA256.hash(data: Data(subject.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
