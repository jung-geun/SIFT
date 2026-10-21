import CryptoKit
import Foundation

/// Runtime App Passwords stay in device-only ACL slots. Full-sync copies use
/// separate canonical records; see `IMAPPortableCredentials` for the OS contract.
nonisolated enum IMAPCredentialStore {
    static let service = "pieroot.todo.imap"
    private static let activeSlotPrefix = "pieroot.todo.imap.activeSlot."
    private static let rejectedCredentialPrefix = "pieroot.todo.imap.rejectedCredential."
    // Periodic reconciliation and connection actors can enter concurrently.
    // Serialize the entire slot/journal/portable transaction, not just each
    // Keychain call. Reentrant because reconciliation checks rejection state.
    private static let operationLock = NSRecursiveLock()
    typealias Slot = IMAPCredentialSlots.Slot

    static func canonicalAccount(_ email: String) -> String? {
        IMAPCredentialValidation.canonicalAccount(email)
    }

    private static func slots(for account: String) -> IMAPCredentialSlots {
        IMAPCredentialSlots(service: service, account: account, pointerKey: activeSlotKey(for: account))
    }

    private static var portable: IMAPPortableCredentials {
        IMAPPortableCredentials(service: service, preferenceKey: "pieroot.todo.imap.account",
                                backgroundKey: "pieroot.todo.imap.backgroundEnabled",
                                slots: slots(for:), isRejected: isCredentialRejected(for:))
    }

    /// Call after full-sync policy changes and on foreground/cloud reconciliation.
    /// Returns account candidates; never changes the selected account or background preference.
    static func applyFullSyncPolicy() throws -> [IMAPRestoredAccount] {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try portable.applyFullSyncPolicy()
    }

    static func save(
        appPassword: String,
        for email: String,
        backgroundEnabled: Bool,
        clearsRejectionLatch: Bool = false
    ) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let portable = Self.portable
        let authorization = portable.authorization()
        guard let account = canonicalAccount(email) else { throw IMAPCredentialError.invalidEmail }
        let password = try IMAPCredentialValidation.gmailAppPassword(appPassword)
        let data = Data(password.utf8)
        let publication = try portable.prepareSave(for: account, authorization: authorization)
        try slots(for: account).replace(data: data, backgroundEnabled: backgroundEnabled)
        try portable.didSaveLocally(for: account, preparation: publication)
        if clearsRejectionLatch {
            UserDefaults.standard.removeObject(forKey: rejectedCredentialKey(for: account))
        }
        if !isCredentialRejected(for: account) {
            try portable.publishSaved(data, for: account, preparation: publication,
                                      backgroundEnabled: backgroundEnabled, authorization: authorization)
        }
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

    /// A server-rejected App Password must not be retried automatically on every
    /// foreground activation or background refresh. A successful replacement clears
    /// this latch in `save`.
    static func isCredentialRejected(for email: String) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let account = canonicalAccount(email) else { return false }
        return UserDefaults.standard.bool(forKey: rejectedCredentialKey(for: account))
    }

    static func markCredentialRejected(for email: String) {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let account = canonicalAccount(email) else { return }
        UserDefaults.standard.set(true, forKey: rejectedCredentialKey(for: account))
    }

    static func delete(for email: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let account = canonicalAccount(email) else { return }
        try portable.delete(for: account)
        UserDefaults.standard.removeObject(forKey: rejectedCredentialKey(for: account))
    }

    static func migrateAccess(for email: String, toBackground backgroundEnabled: Bool) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let account = canonicalAccount(email) else { throw IMAPCredentialError.invalidEmail }
        let store = slots(for: account)
        guard let data = try store.credential() else { throw IMAPCredentialError.missingCredential }
        // Access migration must never normalize or otherwise change secret bytes.
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
        read: (String, String) throws -> Data? = { try KeychainStore.getDeviceOnly(service: $0, account: $1) },
        authorizeMutation: () throws -> Void = {}
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
            try authorizeMutation()
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
        remove: (String, String) throws -> Void = { try KeychainStore.deleteDeviceOnly(service: $0, account: $1) },
        authorizeMutation: () throws -> Void = {}
    ) throws {
        try IMAPCredentialValidation.validateStoredData(data)
        if activeSlot == nil { _ = try credential(read: read, authorizeMutation: authorizeMutation) }
        try authorizeMutation()
        let prior = activeSlot ?? .a
        let next = prior.other
        // Establish an authoritative pointer even on a failed first write.
        UserDefaults.standard.set(prior.rawValue, forKey: pointerKey)
        // Never let KeychainStore replace an occupied destination: its rollback
        // API cannot restore that item's original access-control policy.
        try remove(service, slotAccount(next))
        do {
            try authorizeMutation()
            try write(service, slotAccount(next), data,
                      backgroundEnabled ? .backgroundAfterFirstUnlock : .foregroundUserPresence)
            try authorizeMutation()
            UserDefaults.standard.set(next.rawValue, forKey: pointerKey)
            try authorizeMutation()
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

/// Main may offer/select these candidates using `preferenceKey`; the store does not
/// write that preference, request OS grants, enable background work, or clear rejection.
/// Only accounts with a successfully readable/restored local credential are returned.
nonisolated struct IMAPRestoredAccount: Equatable {
    let account: String
    let preferenceKey: String
}

/// The local slot transaction committed, but the checked portable publication failed.
/// Callers must not report full-sync success or assume the local save was rolled back.
nonisolated struct IMAPCredentialPublicationError: Error {
    let underlyingError: any Error
}

/// A pending explicit local save conflicts with a subsequently changed portable
/// registration/revocation. Both secrets are preserved; main must surface the
/// conflict rather than silently replacing either side. Explicit save/delete resolves it.
nonisolated struct IMAPCredentialPublicationConflictError: Error {
    let account: String
}

/// Explicit deletion attempts both sides, even if one fails. The local restore guard
/// is always retained. Retry deletion on failure; do not treat this as a completed disconnect.
nonisolated struct IMAPCredentialDeletionError: Error {
    let portableError: (any Error)?
    let localError: (any Error)?
    var localCredentialDeleted: Bool { localError == nil }
}

/// Canonical per-account synchronizable Keychain records form the portable manifest.
/// Synchronizable items cannot use ThisDeviceOnly protection or transfer a device's
/// user-presence ACL. They use AfterFirstUnlock, separately from runtime ACL slots.
/// iCloud Keychain must be enabled/provisioned by the OS; a successful write is a
/// local Keychain commit, NOT an acknowledgement of delivery to another device.
///
/// Reconciliation reads both the local preference account and all portable accounts.
/// Existing portable bytes win over unmodified local bytes, so a stale installation
/// never republishes over a newer restored secret. An explicit save journals its
/// pending revision locally before publication; failures retain that journal across
/// store reconstruction/restart. Reconciliation retries only against the observed
/// base revision/fence, and preserves both sides on conflict. Copy/restore never normalizes.
/// A separate deletion fence survives delayed delivery of an old credential record.
/// Each explicit deletion gets a fresh generation; reconnect authorization retains
/// exactly the observed generation, never a later revocation. Device-local receipts
/// bind successful synchronization to revision, slot, and local background policy.
/// An unchanged receipt plus noninteractive slot-presence probe avoids secret reads;
/// missing slots, changed revisions/policy, and pending publication still use checked
/// credential reads, with genuine failures propagated rather than hidden.
/// Keychain offers no cross-device CAS/order/delivery guarantee: concurrent explicit
/// saves/deletes can temporarily suppress restoration, and must be reconciled again.
/// Public provider gates serialize slot/journal transactions. Each save/reconcile
/// carries one captured authorization across blocking reads, portable mutations,
/// restored-slot mutations, and receipt/journal acknowledgement. Expiry cannot undo
/// a completed OS write; pending publication survives for retry/conflict handling.
/// Disabled reconciliation is a no-op; disabled explicit saves remain local/dirty.
nonisolated struct IMAPPortableCredentials {
    struct Record: Codable {
        let revision: UUID
        let secret: Data
    }

    struct DeletionFence: Codable, Equatable {
        let generation: UUID
        let allowedRevision: UUID?

        init(generation: UUID = UUID(), allowedRevision: UUID?) {
            self.generation = generation
            self.allowedRevision = allowedRevision
        }
    }

    struct SavePreparation: Codable, Equatable {
        let revision: UUID
        let previousRevision: UUID?
        let previousFence: DeletionFence?
    }

    /// One operation owns one epoch. A disabled capture never gains permission
    /// when policy is later re-enabled; a stale enabled capture fails closed.
    struct Authorization {
        let isAllowed: Bool
        let isCurrent: () -> Bool

        func check() throws {
            guard isAllowed, isCurrent() else { throw AuthorizationError.expired }
        }
    }

    enum AuthorizationError: Error { case expired }

    /// Device-local proof that this portable revision was committed into this
    /// active slot under this device's preference. Never contains a secret.
    private struct Receipt: Codable {
        let revision: UUID
        let slot: String
        let backgroundEnabled: Bool
        let fence: DeletionFence?
    }

    let service: String
    let preferenceKey: String
    let backgroundKey: String
    var defaults: UserDefaults = .standard
    let slots: (String) -> IMAPCredentialSlots
    var isRejected: (String) -> Bool = { _ in false }
    var enabled: () -> Bool = { UserCloudSyncPolicy.isEnabled }
    var mayRevokePortable: () -> Bool = {
        UserCloudSyncPolicy.canRevokePortableCredentials
    }
    // Factories, not Boolean snapshots: fixtures and production both capture
    // once and recheck the same epoch instead of accepting renewed consent.
    var captureAuthorization: () -> (() -> Bool) = { UserCloudSyncPolicy.captureAuthorization() }
    var captureRevocationAuthorization: () -> (() -> Bool) = {
        UserCloudSyncPolicy.captureAuthorization(forRevocation: true)
    }
    var list: (String) throws -> [String] = { try KeychainStore.synchronizableAccounts(service: $0) }
    var read: (String, String) throws -> Data? = { try KeychainStore.getSynchronizable(service: $0, account: $1) }
    var write: (String, String, Data) throws -> Void = {
        try KeychainStore.setSynchronizable(service: $0, account: $1, data: $2)
    }
    var remove: (String, String) throws -> Void = { try KeychainStore.deleteSynchronizable(service: $0, account: $1) }
    var localRead: (String, String) throws -> Data? = { try KeychainStore.getDeviceOnly(service: $0, account: $1) }
    var localWrite: (String, String, Data, DeviceOnlyCredentialAccess) throws -> Void = {
        try KeychainStore.setDeviceOnly(service: $0, account: $1, data: $2, access: $3)
    }
    var localRemove: (String, String) throws -> Void = { try KeychainStore.deleteDeviceOnly(service: $0, account: $1) }
    var localHasItem: (String, String) -> Bool = {
        KeychainStore.hasDeviceOnlyItem(service: $0, account: $1)
    }

    func authorization(forRevocation: Bool = false) -> Authorization {
        let lease = forRevocation ? captureRevocationAuthorization() : captureAuthorization()
        return Authorization(isAllowed: (forRevocation ? mayRevokePortable() : enabled()) && lease(),
                             isCurrent: lease)
    }

    var portableService: String { service + ".portable.v1" }
    func recordKey(_ account: String) -> String { "account/" + account }
    func fenceKey(_ account: String) -> String { "deletion/" + account }
    func deletionKey(_ account: String) -> String {
        let digest = SHA256.hash(data: Data(account.utf8))
        return service + ".explicitlyDeleted." + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func receiptKey(_ account: String) -> String { deletionKey(account) + ".portableReceipt.v1" }

    private func receipt(for account: String) throws -> Receipt? {
        try defaults.data(forKey: receiptKey(account)).map {
            try JSONDecoder().decode(Receipt.self, from: $0)
        }
    }

    private func noteSynchronized(_ revision: UUID, for account: String, backgroundEnabled: Bool? = nil,
                                  fence: DeletionFence? = nil, authorization: Authorization) throws {
        let store = slots(account)
        let slot = store.activeSlot
        let present = slot.map { localHasItem(service, store.slotAccount($0)) } ?? false
        try authorization.check()
        guard let slot, present else { return }
        let receipt = Receipt(revision: revision, slot: slot.rawValue,
                              backgroundEnabled: backgroundEnabled ?? defaults.bool(forKey: backgroundKey), fence: fence)
        let encoded = try JSONEncoder().encode(receipt)
        try authorization.check()
        defaults.set(encoded, forKey: receiptKey(account))
    }

    private func isSynchronized(_ revision: UUID, for account: String, receipt: Receipt?) -> Bool {
        guard let receipt, receipt.revision == revision,
              receipt.backgroundEnabled == defaults.bool(forKey: backgroundKey) else { return false }
        let store = slots(account)
        guard let slot = store.activeSlot, receipt.slot == slot.rawValue else { return false }
        return localHasItem(service, store.slotAccount(slot))
    }

    // Local metadata only: never copies secrets, ACLs, or this journal to iCloud.
    private var pendingKey: String { service + ".pendingPublications.v1" }

    private func pendingPublications() throws -> [String: SavePreparation] {
        guard let data = defaults.data(forKey: pendingKey) else { return [:] }
        return try JSONDecoder().decode([String: SavePreparation].self, from: data)
    }

    private func setPending(_ preparation: SavePreparation?, for account: String,
                            authorization: Authorization? = nil) throws {
        var pending = try pendingPublications()
        guard pending[account] != preparation else { return }
        pending[account] = preparation
        let encoded = try (pending.isEmpty ? nil : JSONEncoder().encode(pending))
        try authorization?.check()
        if let encoded { defaults.set(encoded, forKey: pendingKey) }
        else { defaults.removeObject(forKey: pendingKey) }
    }

    private func record(for account: String) throws -> Record? {
        guard let data = try read(portableService, recordKey(account)) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: data)
        try IMAPCredentialValidation.validateStoredData(record.secret)
        return record
    }

    private func fence(for account: String) throws -> DeletionFence? {
        try read(portableService, fenceKey(account)).map {
            try JSONDecoder().decode(DeletionFence.self, from: $0)
        }
    }

    /// Enabled saves preflight portable reads. Disabled saves retain their last
    /// known base locally without touching portable data; absence of a known base
    /// cannot authorize overwriting an existing shared credential on re-enable.
    func prepareSave(for account: String, authorization: Authorization) throws -> SavePreparation {
        let pending = try pendingPublications()[account]
        if !authorization.isAllowed {
            if let pending {
                return SavePreparation(revision: UUID(), previousRevision: pending.previousRevision,
                                       previousFence: pending.previousFence)
            }
            let previous = try receipt(for: account)
            return SavePreparation(revision: UUID(), previousRevision: previous?.revision,
                                   previousFence: previous?.fence)
        }
        try authorization.check()
        let previous = try record(for: account)
        try authorization.check()
        let previousFence = try fence(for: account)
        try authorization.check()
        return SavePreparation(revision: UUID(), previousRevision: previous?.revision,
                               previousFence: previousFence)
    }

    func didSaveLocally(for account: String, preparation: SavePreparation) throws {
        do { try setPending(preparation, for: account) }
        catch { throw IMAPCredentialPublicationError(underlyingError: error) }
        defaults.removeObject(forKey: deletionKey(account))
        defaults.removeObject(forKey: receiptKey(account))
    }

    func publishSaved(_ data: Data, for account: String, preparation: SavePreparation,
                      backgroundEnabled: Bool? = nil, authorization: Authorization) throws {
        do {
            // Persist before attempting a portable write, including a policy change
            // between preflight and commit. Failure must not make old cloud bytes authoritative.
            try setPending(preparation, for: account)
            guard authorization.isAllowed else { return }
            let record = Record(revision: preparation.revision, secret: data)
            let encoded = try JSONEncoder().encode(record)
            try authorization.check()
            try write(portableService, recordKey(account), encoded)
            let synchronizedFence = preparation.previousFence.map {
                DeletionFence(generation: $0.generation, allowedRevision: record.revision)
            }
            if let synchronizedFence {
                let encodedFence = try JSONEncoder().encode(synchronizedFence)
                try authorization.check()
                try write(portableService, fenceKey(account), encodedFence)
            }
            try noteSynchronized(record.revision, for: account, backgroundEnabled: backgroundEnabled,
                                 fence: synchronizedFence, authorization: authorization)
            try setPending(nil, for: account, authorization: authorization)
        } catch {
            // A receipt written just before expiry must not hide the dirty journal.
            defaults.removeObject(forKey: receiptKey(account))
            throw IMAPCredentialPublicationError(underlyingError: error)
        }
    }

    /// Explicit copy+restore API. No policy downgrade ever touches shared records.
    /// A later account can fail after earlier accounts committed: the thrown error
    /// signals incomplete reconciliation; retry is safe and does not rewrite equal slots.
    func applyFullSyncPolicy() throws -> [IMAPRestoredAccount] {
        let authorization = self.authorization()
        guard authorization.isAllowed else { return [] }
        let pending = try pendingPublications()
        var accounts = Set<String>()
        if let local = defaults.string(forKey: preferenceKey),
           let account = IMAPCredentialValidation.canonicalAccount(local) {
            accounts.insert(account)
        }
        for account in pending.keys {
            guard IMAPCredentialValidation.canonicalAccount(account) == account else {
                throw IMAPCredentialError.invalidEmail
            }
            accounts.insert(account)
        }
        for key in try list(portableService) {
            try authorization.check()
            let prefix: String
            if key.hasPrefix("account/") { prefix = "account/" }
            else if key.hasPrefix("deletion/") { prefix = "deletion/" }
            else { continue }
            let value = String(key.dropFirst(prefix.count))
            guard IMAPCredentialValidation.canonicalAccount(value) == value else {
                throw IMAPCredentialError.invalidEmail
            }
            accounts.insert(value)
        }
        try authorization.check()
        // Preflight all shared reads before changing any local secret or publishing.
        let candidates = try accounts.sorted().filter {
            !defaults.bool(forKey: deletionKey($0)) && !isRejected($0)
        }.map { account in
            try authorization.check()
            let remote = try record(for: account)
            try authorization.check()
            let fence = try fence(for: account)
            try authorization.check()
            return (account, remote, fence)
        }
        var restored: [IMAPRestoredAccount] = []
        for (account, remote, fence) in candidates {
            try authorization.check()
            if let publication = pending[account] {
                let unchangedBase = remote?.revision == publication.previousRevision
                    && fence == publication.previousFence
                let completedFence = publication.previousFence.map {
                    DeletionFence(generation: $0.generation, allowedRevision: publication.revision)
                }
                let partiallyPublished = remote?.revision == publication.revision
                    && (fence == publication.previousFence || fence == completedFence)
                guard unchangedBase || partiallyPublished else {
                    throw IMAPCredentialPublicationConflictError(account: account)
                }
                let local = try slots(account).credential(read: localRead, authorizeMutation: authorization.check)
                try authorization.check()
                guard let local else { throw IMAPCredentialError.missingCredential }
                try publishSaved(local, for: account, preparation: publication, authorization: authorization)
                restored.append(IMAPRestoredAccount(account: account, preferenceKey: preferenceKey))
                continue
            }
            if let fence, fence.allowedRevision == nil || fence.allowedRevision != remote?.revision { continue }
            let store = slots(account)
            let priorReceipt = try receipt(for: account)
            if let remote, isSynchronized(remote.revision, for: account, receipt: priorReceipt) {
                try authorization.check()
                restored.append(IMAPRestoredAccount(account: account, preferenceKey: preferenceKey))
                continue
            }
            let local = try store.credential(read: localRead, authorizeMutation: authorization.check)
            try authorization.check()
            if let remote {
                if local != remote.secret || priorReceipt?.backgroundEnabled != defaults.bool(forKey: backgroundKey) {
                    try store.replace(data: remote.secret, backgroundEnabled: defaults.bool(forKey: backgroundKey),
                                      read: localRead, write: localWrite, remove: localRemove,
                                      authorizeMutation: authorization.check)
                }
                try noteSynchronized(remote.revision, for: account, fence: fence, authorization: authorization)
            } else if let local, fence == nil {
                // Automatic first publication needs the same durable retry journal
                // as an explicit save if the lease expires after its record write.
                let preparation = SavePreparation(revision: UUID(), previousRevision: nil, previousFence: nil)
                try publishSaved(local, for: account, preparation: preparation, authorization: authorization)
            } else {
                continue
            }
            restored.append(IMAPRestoredAccount(account: account, preferenceKey: preferenceKey))
        }
        return restored
    }

    /// Prior full consent permits explicit shared revocation even after opt-out.
    /// Never create a shared fence for a never-consented/local-only connection.
    func delete(for account: String) throws {
        let authorization = self.authorization(forRevocation: true)
        defaults.set(true, forKey: deletionKey(account))
        defaults.removeObject(forKey: receiptKey(account))
        var portableError: (any Error)?
        var localError: (any Error)?
        if authorization.isAllowed {
            do {
                let fence = try JSONEncoder().encode(DeletionFence(allowedRevision: nil))
                try authorization.check()
                try write(portableService, fenceKey(account), fence)
                try authorization.check()
                try remove(portableService, recordKey(account))
            } catch { portableError = error }
        }
        do { try slots(account).delete(remove: localRemove) }
        catch { localError = error }
        if portableError != nil || localError != nil {
            throw IMAPCredentialDeletionError(portableError: portableError, localError: localError)
        }
    }
}
