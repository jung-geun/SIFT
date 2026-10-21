import CryptoKit
import Foundation

/// Outlook keeps its existing provider normalization on save, and preserves exact
/// stored bytes on copy/restore. Runtime reads always use device-only ACL slots.
/// Save captures one portable authorization before preflight and keeps it across
/// the device-local transaction; expiry leaves that local save dirty, not undone.
nonisolated enum OutlookIMAPCredentialStore {
    static let service = "pieroot.todo.outlook.imap"
    private static let activeSlotPrefix = "pieroot.todo.outlook.imap.activeSlot."
    // Keep the full local-slot/portable transaction atomic within this process;
    // Gmail uses a different gate so unrelated providers remain independent.
    private static let operationLock = NSRecursiveLock()

    typealias Slot = IMAPCredentialSlots.Slot

    static func canonicalAccount(_ email: String) -> String? {
        IMAPCredentialValidation.canonicalAccount(email)
    }

    private static func slots(for account: String) -> IMAPCredentialSlots {
        IMAPCredentialSlots(service: service, account: account, pointerKey: activeSlotKey(for: account))
    }

    private static var portable: IMAPPortableCredentials {
        IMAPPortableCredentials(service: service, preferenceKey: "pieroot.todo.outlook.account",
                                backgroundKey: "pieroot.todo.outlook.backgroundEnabled",
                                slots: slots(for:))
    }

    /// Returns canonical account candidates without selecting an account or enabling background access.
    static func applyFullSyncPolicy() throws -> [IMAPRestoredAccount] {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try portable.applyFullSyncPolicy()
    }

    static func save(appPassword: String, for email: String, backgroundEnabled: Bool) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let portable = Self.portable
        let authorization = portable.authorization()
        guard let account = canonicalAccount(email) else { throw IMAPCredentialError.invalidEmail }
        let password = try IMAPCredentialValidation.appPassword(appPassword)
        let data = Data(password.utf8)
        let publication = try portable.prepareSave(for: account, authorization: authorization)
        try slots(for: account).replace(data: data, backgroundEnabled: backgroundEnabled)
        try portable.didSaveLocally(for: account, preparation: publication)
        try portable.publishSaved(data, for: account, preparation: publication,
                                  backgroundEnabled: backgroundEnabled, authorization: authorization)
    }

    static func credential(for email: String) throws -> String? {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let account = canonicalAccount(email) else { return nil }
        return try slots(for: account).credential().map { String(decoding: $0, as: UTF8.self) }
    }

    /// Probes for a stored App Password without reading its secret bytes.
    static func hasCredential(for email: String) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let account = canonicalAccount(email) else { return false }
        return slots(for: account).hasCredential()
    }

    static func delete(for email: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let account = canonicalAccount(email) else { return }
        try portable.delete(for: account)
    }

    static func migrateAccess(for email: String, toBackground backgroundEnabled: Bool) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let account = canonicalAccount(email) else { throw IMAPCredentialError.invalidEmail }
        let store = slots(for: account)
        guard let data = try store.credential() else { throw IMAPCredentialError.missingCredential }
        try store.replace(data: data, backgroundEnabled: backgroundEnabled)
    }

    static func activeSlot(for account: String) -> Slot {
        operationLock.lock()
        defer { operationLock.unlock() }
        return slots(for: account).activeSlot ?? .a
    }

    static func activeSlotKey(for account: String) -> String {
        let digest = SHA256.hash(data: Data(account.utf8))
        return activeSlotPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }
}
