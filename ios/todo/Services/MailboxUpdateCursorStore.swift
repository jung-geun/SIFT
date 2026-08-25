import Foundation

/// Durable per-account list-metadata sync cursor. This store tracks the newer-sync
/// continuation used by `MailboxPagingProvider.fetchInboxUpdates(newerThan:)` only —
/// it is deliberately separate from the UI's older-page `MailboxPagingState.nextCursor`
/// and from Gmail's background-analysis ingestion cursor, so loading the mail list
/// can never suppress or advance analysis state.
nonisolated struct MailboxUpdateCursorStore {
    static let live = MailboxUpdateCursorStore(defaults: .standard)

    private let defaults: UserDefaults
    private let keyPrefix = "pieroot.todo.mailbox.updateCursor.v1."

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func cursor(for provider: MailProvider, namespace: String) -> String? {
        defaults.string(forKey: key(provider: provider, namespace: namespace))
    }

    func setCursor(_ cursor: String, for provider: MailProvider, namespace: String) {
        defaults.set(cursor, forKey: key(provider: provider, namespace: namespace))
    }

    func clearCursor(for provider: MailProvider, namespace: String) {
        defaults.removeObject(forKey: key(provider: provider, namespace: namespace))
    }

    private func key(provider: MailProvider, namespace: String) -> String {
        keyPrefix + provider.rawValue + "." + namespace.lowercased()
    }
}
