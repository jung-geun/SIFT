import CryptoKit
import Foundation

/// Device-only Outlook App Passwords. Secrets retain their exact bytes, including
/// spaces; access migration uses the same rollback-safe two-slot transaction as
/// Gmail without applying Gmail's provider-specific grouping normalization.
nonisolated enum OutlookIMAPCredentialStore {
    static let service = "pieroot.todo.outlook.imap"
    private static let activeSlotPrefix = "pieroot.todo.outlook.imap.activeSlot."

    typealias Slot = IMAPCredentialSlots.Slot

    static func canonicalAccount(_ email: String) -> String? {
        IMAPCredentialValidation.canonicalAccount(email)
    }

    private static func slots(for account: String) -> IMAPCredentialSlots {
        IMAPCredentialSlots(service: service, account: account, pointerKey: activeSlotKey(for: account))
    }

    static func save(appPassword: String, for email: String, backgroundEnabled: Bool) throws {
        guard let account = canonicalAccount(email) else { throw IMAPCredentialError.invalidEmail }
        let password = try IMAPCredentialValidation.appPassword(appPassword)
        try slots(for: account).replace(data: Data(password.utf8), backgroundEnabled: backgroundEnabled)
    }

    static func credential(for email: String) throws -> String? {
        guard let account = canonicalAccount(email) else { return nil }
        return try slots(for: account).credential().map { String(decoding: $0, as: UTF8.self) }
    }

    /// Probes for a stored App Password without reading its secret bytes.
    static func hasCredential(for email: String) -> Bool {
        guard let account = canonicalAccount(email) else { return false }
        return slots(for: account).hasCredential()
    }

    static func delete(for email: String) throws {
        guard let account = canonicalAccount(email) else { return }
        try slots(for: account).delete()
    }

    static func migrateAccess(for email: String, toBackground backgroundEnabled: Bool) throws {
        guard let account = canonicalAccount(email) else { throw IMAPCredentialError.invalidEmail }
        let store = slots(for: account)
        guard let data = try store.credential() else { throw IMAPCredentialError.missingCredential }
        try store.replace(data: data, backgroundEnabled: backgroundEnabled)
    }

    static func activeSlot(for account: String) -> Slot {
        slots(for: account).activeSlot ?? .a
    }

    static func activeSlotKey(for account: String) -> String {
        let digest = SHA256.hash(data: Data(account.utf8))
        return activeSlotPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }
}
