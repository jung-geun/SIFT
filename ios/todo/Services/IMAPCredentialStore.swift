import CryptoKit
import Foundation

/// Device-only Gmail App Passwords. Replacement stages an empty inactive slot,
/// commits its pointer, and rolls back if old-policy cleanup fails. A valid pointer
/// is authoritative: a missing active item never resurrects an older slot.
nonisolated enum IMAPCredentialStore {
    static let service = "pieroot.todo.imap"
    private static let activeSlotPrefix = "pieroot.todo.imap.activeSlot."
    private static let rejectedCredentialPrefix = "pieroot.todo.imap.rejectedCredential."
    typealias Slot = IMAPCredentialSlots.Slot

    static func canonicalAccount(_ email: String) -> String? {
        IMAPCredentialValidation.canonicalAccount(email)
    }

    private static func slots(for account: String) -> IMAPCredentialSlots {
        IMAPCredentialSlots(service: service, account: account, pointerKey: activeSlotKey(for: account))
    }

    static func save(
        appPassword: String,
        for email: String,
        backgroundEnabled: Bool,
        clearsRejectionLatch: Bool = false
    ) throws {
        guard let account = canonicalAccount(email) else { throw IMAPCredentialError.invalidEmail }
        let password = try IMAPCredentialValidation.gmailAppPassword(appPassword)
        try slots(for: account).replace(data: Data(password.utf8), backgroundEnabled: backgroundEnabled)
        if clearsRejectionLatch {
            UserDefaults.standard.removeObject(forKey: rejectedCredentialKey(for: account))
        }
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
        try slots(for: account).delete()
        UserDefaults.standard.removeObject(forKey: rejectedCredentialKey(for: account))
    }

    static func migrateAccess(for email: String, toBackground backgroundEnabled: Bool) throws {
        guard let account = canonicalAccount(email) else { throw IMAPCredentialError.invalidEmail }
        let store = slots(for: account)
        guard let data = try store.credential() else { throw IMAPCredentialError.missingCredential }
        // Access migration must never normalize or otherwise change secret bytes.
        try store.replace(data: data, backgroundEnabled: backgroundEnabled)
    }

    static func activeSlot(for account: String) -> Slot {
        slots(for: account).activeSlot ?? .a
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
    case invalidPassword
    case invalidStoredCredential
    case missingCredential
}

/// Shared with IMAP transports: reject raw command controls before trimming or
/// quoting, rather than silently changing the credentials sent to the server.
nonisolated enum IMAPCredentialValidation {
    static func containsCommandControl(_ value: String) -> Bool {
        value.utf8.contains { $0 < 0x20 || $0 == 0x7f }
    }

    static func validateCommandValue(_ value: String) throws {
        guard !containsCommandControl(value) else { throw IMAPCredentialError.invalidPassword }
    }

    static func canonicalAccount(_ email: String) -> String? {
        guard !containsCommandControl(email) else { return nil }
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.contains("@"), !value.contains(where: { $0.isWhitespace }) else { return nil }
        return value
    }

    static func appPassword(_ password: String) throws -> String {
        try validateCommandValue(password)
        let cleaned = password.replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw IMAPCredentialError.emptyPassword
        }
        return cleaned
    }

    static func gmailAppPassword(_ password: String) throws -> String {
        try validateCommandValue(password)
        return try appPassword(password.replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func validateStoredData(_ data: Data) throws {
        guard let password = String(data: data, encoding: .utf8) else {
            throw IMAPCredentialError.invalidStoredCredential
        }
        _ = try appPassword(password)
    }
}

/// Retains both errors when Keychain refuses cleanup; callers must not report
/// a completed policy migration in this case.
nonisolated struct IMAPCredentialRollbackError: Error {
    let operationError: any Error
    let rollbackError: any Error
}

/// Common two-slot transaction using only the existing Keychain APIs. Closure
/// parameters let regressions exercise real failure ordering without changing
/// the shared KeychainStore or introducing global mutable test hooks.
nonisolated struct IMAPCredentialSlots {
    enum Slot: String {
        case a, b
        var other: Slot { self == .a ? .b : .a }
    }

    let service: String
    let account: String
    let pointerKey: String

    var activeSlot: Slot? {
        UserDefaults.standard.string(forKey: pointerKey).flatMap(Slot.init(rawValue:))
    }

    func slotAccount(_ slot: Slot) -> String { "\(account).imap-slot-\(slot.rawValue)" }

    func credential(
        read: (String, String) throws -> Data? = { try KeychainStore.getDeviceOnly(service: $0, account: $1) }
    ) throws -> Data? {
        if let slot = activeSlot {
            guard let data = try read(service, slotAccount(slot)) else { return nil }
            try IMAPCredentialValidation.validateStoredData(data)
            return data
        }
        // Recover only absent/corrupt metadata, never a missing committed item.
        for slot in [Slot.a, .b] {
            guard let data = try read(service, slotAccount(slot)) else { continue }
            try IMAPCredentialValidation.validateStoredData(data)
            UserDefaults.standard.set(slot.rawValue, forKey: pointerKey)
            return data
        }
        return nil
    }

    func hasCredential() -> Bool {
        if let slot = activeSlot {
            return KeychainStore.hasDeviceOnlyItem(service: service, account: slotAccount(slot))
        }
        return [Slot.a, .b].contains {
            KeychainStore.hasDeviceOnlyItem(service: service, account: slotAccount($0))
        }
    }

    func replace(
        data: Data,
        backgroundEnabled: Bool,
        read: (String, String) throws -> Data? = { try KeychainStore.getDeviceOnly(service: $0, account: $1) },
        write: (String, String, Data, DeviceOnlyCredentialAccess) throws -> Void = {
            try KeychainStore.setDeviceOnly(service: $0, account: $1, data: $2, access: $3)
        },
        remove: (String, String) throws -> Void = { try KeychainStore.deleteDeviceOnly(service: $0, account: $1) }
    ) throws {
        try IMAPCredentialValidation.validateStoredData(data)
        if activeSlot == nil { _ = try credential(read: read) }
        let prior = activeSlot ?? .a
        let next = prior.other
        // Establish an authoritative pointer even on a failed first write.
        UserDefaults.standard.set(prior.rawValue, forKey: pointerKey)
        // Never let KeychainStore replace an occupied destination: its rollback
        // API cannot restore that item's original access-control policy.
        try remove(service, slotAccount(next))
        do {
            try write(service, slotAccount(next), data,
                      backgroundEnabled ? .backgroundAfterFirstUnlock : .foregroundUserPresence)
            UserDefaults.standard.set(next.rawValue, forKey: pointerKey)
            try remove(service, slotAccount(prior))
        } catch {
            UserDefaults.standard.set(prior.rawValue, forKey: pointerKey)
            do {
                try remove(service, slotAccount(next))
            } catch let rollbackError {
                throw IMAPCredentialRollbackError(operationError: error, rollbackError: rollbackError)
            }
            throw error
        }
    }

    func delete(
        remove: (String, String) throws -> Void = { try KeychainStore.deleteDeviceOnly(service: $0, account: $1) }
    ) throws {
        let prior = activeSlot ?? .a
        // Keep the pointer if either deletion fails; never promote a stale item.
        try remove(service, slotAccount(prior.other))
        try remove(service, slotAccount(prior))
        UserDefaults.standard.removeObject(forKey: pointerKey)
    }
}
