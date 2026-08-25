import CryptoKit
import Foundation

/// Stores a Gmail App Password only in this device's Keychain.
/// Two slots make credential replacement loss-safe: an inactive slot is fully
/// written before a non-secret active-slot pointer is changed.
nonisolated enum IMAPCredentialStore {
    static let service = "pieroot.todo.imap"
    private static let activeSlotPrefix = "pieroot.todo.imap.activeSlot."
    private static let rejectedCredentialPrefix = "pieroot.todo.imap.rejectedCredential."
    enum Slot: String {
        case a
        case b

        var other: Slot { self == .a ? .b : .a }
    }

    static func canonicalAccount(_ email: String) -> String? {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.contains("@"), !value.contains(where: { $0.isWhitespace }) else { return nil }
        return value
    }

    static func save(
        appPassword: String,
        for email: String,
        backgroundEnabled: Bool,
        clearsRejectionLatch: Bool = false
    ) throws {
        guard let account = canonicalAccount(email) else { throw IMAPCredentialError.invalidEmail }
        let password = appPassword.replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { throw IMAPCredentialError.emptyPassword }

        let next = activeSlot(for: account).other
        try KeychainStore.setDeviceOnly(
            service: service,
            account: slotAccount(account, slot: next),
            data: Data(password.utf8),
            access: backgroundEnabled ? .backgroundAfterFirstUnlock : .foregroundUserPresence
        )
        UserDefaults.standard.set(next.rawValue, forKey: activeSlotKey(for: account))
        if clearsRejectionLatch {
            UserDefaults.standard.removeObject(forKey: rejectedCredentialKey(for: account))
        }
        try? KeychainStore.deleteDeviceOnly(
            service: service,
            account: slotAccount(account, slot: next.other)
        )
    }

    static func credential(for email: String) throws -> String? {
        guard let account = canonicalAccount(email) else { return nil }
        let preferred = activeSlot(for: account)
        let candidates = [preferred, preferred.other]
        for slot in candidates {
            guard let data = try KeychainStore.getDeviceOnly(
                service: service,
                account: slotAccount(account, slot: slot)
            ) else { continue }
            if slot != preferred {
                UserDefaults.standard.set(slot.rawValue, forKey: activeSlotKey(for: account))
            }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    /// Probes for a stored App Password without reading its secret bytes.
    static func hasCredential(for email: String) -> Bool {
        guard let account = canonicalAccount(email) else { return false }
        return [activeSlot(for: account), activeSlot(for: account).other].contains { slot in
            KeychainStore.hasDeviceOnlyItem(
                service: service,
                account: slotAccount(account, slot: slot)
            )
        }
    }

    /// A server-rejected App Password must not be retried automatically on every
    /// foreground activation or background refresh. A successful replacement clears
    /// this latch in `save`.
    static func isCredentialRejected(for email: String) -> Bool {
        guard let account = canonicalAccount(email) else { return false }
        return UserDefaults.standard.bool(forKey: rejectedCredentialKey(for: account))
    }

    static func markCredentialRejected(for email: String) {
        guard let account = canonicalAccount(email) else { return }
        UserDefaults.standard.set(true, forKey: rejectedCredentialKey(for: account))
    }

    static func delete(for email: String) throws {
        guard let account = canonicalAccount(email) else { return }
        try KeychainStore.deleteDeviceOnly(service: service, account: slotAccount(account, slot: .a))
        try KeychainStore.deleteDeviceOnly(service: service, account: slotAccount(account, slot: .b))
        UserDefaults.standard.removeObject(forKey: activeSlotKey(for: account))
        UserDefaults.standard.removeObject(forKey: rejectedCredentialKey(for: account))
    }

    static func migrateAccess(for email: String, toBackground backgroundEnabled: Bool) throws {
        guard let password = try credential(for: email) else { throw IMAPCredentialError.missingCredential }
        try save(appPassword: password, for: email, backgroundEnabled: backgroundEnabled)
    }

    static func activeSlot(for account: String) -> Slot {
        Slot(rawValue: UserDefaults.standard.string(forKey: activeSlotKey(for: account)) ?? "") ?? .a
    }

    private static func slotAccount(_ account: String, slot: Slot) -> String {
        "\(account).imap-slot-\(slot.rawValue)"
    }

    static func activeSlotKey(for account: String) -> String {
        let digest = SHA256.hash(data: Data(account.utf8))
        return activeSlotPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func rejectedCredentialKey(for account: String) -> String {
        let digest = SHA256.hash(data: Data(account.utf8))
        return rejectedCredentialPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum IMAPCredentialError: Error, Equatable {
    case invalidEmail
    case emptyPassword
    case missingCredential
}
