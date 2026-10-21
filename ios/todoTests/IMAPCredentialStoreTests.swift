import Foundation
import Testing
@testable import todo

@Suite("IMAP credential store", .serialized)
struct IMAPCredentialStoreTests {
    private let email = "person@example.com"

    private func reset() throws {
        try IMAPCredentialStore.delete(for: email)
    }

    @Test("stores an App Password in the device-only store")
    func storesDeviceOnlyCredential() throws {
        try reset()
        defer { try? reset() }

        try IMAPCredentialStore.save(
            appPassword: "abcd efgh ijkl mnop",
            for: " Person@Example.COM ",
            backgroundEnabled: false
        )

        #expect(try IMAPCredentialStore.credential(for: email) == "abcdefghijklmnop")
    }

    @Test("probes device-only credential presence without reading the password")
    func probesStoredCredentialPresence() throws {
        try reset()
        defer { try? reset() }

        #expect(!IMAPCredentialStore.hasCredential(for: email))
        try IMAPCredentialStore.save(
            appPassword: "abcd efgh ijkl mnop",
            for: email,
            backgroundEnabled: false
        )
        #expect(IMAPCredentialStore.hasCredential(for: email))
    }

    @Test("successful App Password replacement clears a rejection latch")
    func successfulReplacementClearsRejectionLatch() throws {
        try reset()
        defer { try? reset() }

        IMAPCredentialStore.markCredentialRejected(for: email)
        #expect(IMAPCredentialStore.isCredentialRejected(for: email))
        try IMAPCredentialStore.save(
            appPassword: "abcd efgh ijkl mnop",
            for: email,
            backgroundEnabled: false,
            clearsRejectionLatch: true
        )

        #expect(!IMAPCredentialStore.isCredentialRejected(for: email))
    }

    @Test("rejection latch is account-scoped and survives access migration")
    func rejectionLatchIsScopedAndMigrationSafe() throws {
        let secondEmail = "second@example.com"
        try reset()
        try IMAPCredentialStore.delete(for: secondEmail)
        defer {
            try? reset()
            try? IMAPCredentialStore.delete(for: secondEmail)
        }

        IMAPCredentialStore.markCredentialRejected(for: email)
        try IMAPCredentialStore.save(
            appPassword: "abcd efgh ijkl mnop",
            for: email,
            backgroundEnabled: false
        )

        #expect(IMAPCredentialStore.isCredentialRejected(for: email))
        #expect(!IMAPCredentialStore.isCredentialRejected(for: secondEmail))

        try IMAPCredentialStore.migrateAccess(for: email, toBackground: true)
        #expect(IMAPCredentialStore.isCredentialRejected(for: email))

        try IMAPCredentialStore.delete(for: email)
        #expect(!IMAPCredentialStore.isCredentialRejected(for: email))
    }

    @Test("recovers when the active-slot pointer is missing or corrupt")
    func recoversFromPointerLoss() throws {
        try reset()
        defer { try? reset() }

        try IMAPCredentialStore.save(appPassword: "first-password", for: email, backgroundEnabled: false)
        let key = IMAPCredentialStore.activeSlotKey(for: email)
        UserDefaults.standard.removeObject(forKey: key)
        #expect(try IMAPCredentialStore.credential(for: email) == "first-password")

        UserDefaults.standard.set("invalid", forKey: key)
        #expect(try IMAPCredentialStore.credential(for: email) == "first-password")
    }

    @Test("rejects invalid account and empty password")
    func validatesInput() {
        #expect(throws: IMAPCredentialError.invalidEmail) {
            try IMAPCredentialStore.save(appPassword: "abcd", for: "invalid", backgroundEnabled: false)
        }
        #expect(throws: IMAPCredentialError.emptyPassword) {
            try IMAPCredentialStore.save(appPassword: "   ", for: email, backgroundEnabled: false)
        }
    }

    @Test("rejects every C0/DEL control before account or Gmail password normalization",
          arguments: (0...31).map { UInt8($0) } + [UInt8(127)])
    func rejectsCommandControls(_ byte: UInt8) throws {
        try reset()
        defer { try? reset() }
        let control = String(decoding: [byte], as: UTF8.self)
        for invalidEmail in [control + email, email + control, "person\(control)@example.com"] {
            #expect(IMAPCredentialStore.canonicalAccount(invalidEmail) == nil)
            #expect(throws: IMAPCredentialError.invalidEmail) {
                try IMAPCredentialStore.save(appPassword: "safe", for: invalidEmail, backgroundEnabled: false)
            }
        }
        for password in [control + "safe", "safe" + control, "sa\(control)fe"] {
            #expect(throws: IMAPCredentialError.invalidPassword) {
                try IMAPCredentialStore.save(appPassword: password, for: email, backgroundEnabled: false)
            }
        }
        #expect(!IMAPCredentialStore.hasCredential(for: email))
    }

    @Test("access migration preserves legacy bytes, deletes the old policy slot, and keeps rejection")
    func migrationPreservesSecretBytesAndRejectionLatch() throws {
        try reset()
        defer { try? reset() }
        let data = Data("  legacy spaced e\u{301} secret  ".utf8)
        try KeychainStore.setDeviceOnly(service: IMAPCredentialStore.service,
                                      account: "\(email).imap-slot-a", data: data,
                                      access: .backgroundAfterFirstUnlock)
        UserDefaults.standard.set("a", forKey: IMAPCredentialStore.activeSlotKey(for: email))
        IMAPCredentialStore.markCredentialRejected(for: email)

        for backgroundEnabled in [false, true] {
            let prior = IMAPCredentialStore.activeSlot(for: email)
            try IMAPCredentialStore.migrateAccess(for: email, toBackground: backgroundEnabled)
            let current = IMAPCredentialStore.activeSlot(for: email)
            #expect(current == prior.other)
            #expect(try KeychainStore.getDeviceOnly(service: IMAPCredentialStore.service,
                                                   account: "\(email).imap-slot-\(current.rawValue)") == data)
            #expect(try KeychainStore.getDeviceOnly(service: IMAPCredentialStore.service,
                                                   account: "\(email).imap-slot-\(prior.rawValue)") == nil)
            #expect(IMAPCredentialStore.isCredentialRejected(for: email))
        }
    }

    @Test("a missing committed item never resurrects an older access-policy slot")
    func missingActiveCredentialDoesNotResurrectStaleSlot() throws {
        try reset()
        defer { try? reset() }
        try KeychainStore.setDeviceOnly(service: IMAPCredentialStore.service,
                                      account: "\(email).imap-slot-a", data: Data("stale".utf8),
                                      access: .backgroundAfterFirstUnlock)
        UserDefaults.standard.set("b", forKey: IMAPCredentialStore.activeSlotKey(for: email))
        #expect(try IMAPCredentialStore.credential(for: email) == nil)
        #expect(!IMAPCredentialStore.hasCredential(for: email))
        #expect(throws: IMAPCredentialError.missingCredential) {
            try IMAPCredentialStore.migrateAccess(for: email, toBackground: false)
        }
        #expect(IMAPCredentialStore.activeSlot(for: email) == .b)
    }

    @Test("unsafe legacy bytes are rejected before pointer recovery or migration")
    func rejectsUnsafeStoredCredentialWithoutPromotingSlot() throws {
        try reset()
        defer { try? reset() }
        let key = IMAPCredentialStore.activeSlotKey(for: email)
        for data in [Data("safe\r\nA2 LOGOUT".utf8), Data([0xff]), Data()] {
            try KeychainStore.setDeviceOnly(service: IMAPCredentialStore.service,
                                          account: "\(email).imap-slot-a", data: data,
                                          access: .backgroundAfterFirstUnlock)
            UserDefaults.standard.removeObject(forKey: key)
            #expect(throws: (any Error).self) { try IMAPCredentialStore.credential(for: email) }
            #expect(UserDefaults.standard.object(forKey: key) == nil)
            #expect(throws: (any Error).self) {
                try IMAPCredentialStore.migrateAccess(for: email, toBackground: false)
            }
            #expect(try KeychainStore.getDeviceOnly(service: IMAPCredentialStore.service,
                                                   account: "\(email).imap-slot-a") == data)
            #expect(try KeychainStore.getDeviceOnly(service: IMAPCredentialStore.service,
                                                   account: "\(email).imap-slot-b") == nil)
        }
    }

    @Test("invalid replacement does not clear Gmail rejection or change its committed credential")
    func invalidReplacementPreservesCredentialAndRejectionLatch() throws {
        try reset()
        defer { try? reset() }
        try IMAPCredentialStore.save(appPassword: "original", for: email, backgroundEnabled: false)
        IMAPCredentialStore.markCredentialRejected(for: email)
        let prior = IMAPCredentialStore.activeSlot(for: email)
        #expect(throws: IMAPCredentialError.invalidPassword) {
            try IMAPCredentialStore.save(appPassword: "new\nsecret", for: email,
                                         backgroundEnabled: true, clearsRejectionLatch: true)
        }
        #expect(try IMAPCredentialStore.credential(for: email) == "original")
        #expect(IMAPCredentialStore.activeSlot(for: email) == prior)
        #expect(IMAPCredentialStore.isCredentialRejected(for: email))
    }

    private enum Failure: Error, Equatable {
        case destinationCleanup, write, oldCleanup, rollback, read
    }

    @Test("both providers restore the pointer and secret on transaction failures",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service],
          ["destinationCleanup", "write", "oldCleanup", "rollback"])
    func replacementFailureIsLossSafe(service: String, failure: String) throws {
        let key = "credential-transaction-test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let slots = IMAPCredentialSlots(service: service, account: email, pointerKey: key)
        let prior = slots.slotAccount(.a)
        let next = slots.slotAccount(.b)
        let original = Data("original bytes".utf8)
        let replacement = Data("new bytes".utf8)
        let stale = Data("stale bytes".utf8)
        var values = [prior: original, next: stale]
        var nextDeletes = 0
        var didWrite = false
        UserDefaults.standard.set("a", forKey: key)

        let operation = {
            try slots.replace(data: replacement, backgroundEnabled: false,
                              read: { _, account in values[account] },
                              write: { _, account, data, access in
                #expect(account == next)
                #expect(values[next] == nil)
                #expect(values[prior] == original)
                switch access {
                case .foregroundUserPresence: break
                case .backgroundAfterFirstUnlock: Issue.record("incorrect access policy")
                }
                didWrite = true
                values[account] = data // Model a partially completed write as well.
                if failure == "write" { throw Failure.write }
            }, remove: { _, account in
                if account == next {
                    nextDeletes += 1
                    if failure == "destinationCleanup" && nextDeletes == 1 { throw Failure.destinationCleanup }
                    if failure == "rollback" && nextDeletes == 2 { throw Failure.rollback }
                } else {
                    #expect(slots.activeSlot == .b)
                    throw Failure.oldCleanup
                }
                values.removeValue(forKey: account)
            })
        }
        if failure == "rollback" {
            do {
                try operation()
                Issue.record("expected rollback failure")
            } catch let error as IMAPCredentialRollbackError {
                #expect(error.operationError as? Failure == .oldCleanup)
                #expect(error.rollbackError as? Failure == .rollback)
            }
        } else {
            let expected: Failure = failure == "write" ? .write
                : failure == "destinationCleanup" ? .destinationCleanup : .oldCleanup
            #expect(throws: expected) { try operation() }
        }
        #expect(slots.activeSlot == .a)
        #expect(values[prior] == original)
        #expect(try slots.credential(read: { _, account in values[account] }) == original)
        if failure == "destinationCleanup" {
            #expect(!didWrite)
            #expect(values[next] == stale)
        } else if failure == "rollback" {
            #expect(values[next] == replacement)
        } else {
            #expect(values[next] == nil)
        }
    }

    @Test("replacement empties its destination, applies policy, commits, then deletes the old slot",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service], [false, true])
    func replacementCommitsOnlyAfterStaging(service: String, backgroundEnabled: Bool) throws {
        let key = "credential-transaction-test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let slots = IMAPCredentialSlots(service: service, account: email, pointerKey: key)
        let prior = slots.slotAccount(.a)
        let next = slots.slotAccount(.b)
        var values = [prior: Data("original".utf8), next: Data("stale".utf8)]
        var events: [String] = []
        UserDefaults.standard.set("a", forKey: key)
        let data = Data("unchanged secret bytes".utf8)
        try slots.replace(data: data, backgroundEnabled: backgroundEnabled,
                          write: { _, account, secret, access in
            #expect(values[account] == nil)
            #expect(slots.activeSlot == .a)
            #expect(secret == data)
            switch access {
            case .foregroundUserPresence: #expect(!backgroundEnabled)
            case .backgroundAfterFirstUnlock: #expect(backgroundEnabled)
            }
            events.append("write")
            values[account] = secret
        }, remove: { _, account in
            if account == prior { #expect(slots.activeSlot == .b) }
            events.append(account == next ? "empty destination" : "delete old")
            values.removeValue(forKey: account)
        })
        #expect(events == ["empty destination", "write", "delete old"])
        #expect(slots.activeSlot == .b)
        #expect(values[prior] == nil)
        #expect(values[next] == data)
    }

    @Test("read failure never falls back to or promotes an older credential")
    func readFailureDoesNotPromoteStaleSlot() throws {
        let key = "credential-read-test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let slots = IMAPCredentialSlots(service: IMAPCredentialStore.service, account: email, pointerKey: key)
        UserDefaults.standard.set("b", forKey: key)
        var reads: [String] = []
        #expect(throws: Failure.read) {
            try slots.credential(read: { _, account in
                reads.append(account)
                throw Failure.read
            })
        }
        #expect(reads == [slots.slotAccount(.b)])
        #expect(slots.activeSlot == .b)
    }

    @Test("failed deletion retains the authoritative pointer and active secret",
          arguments: [false, true])
    func deletionFailureDoesNotLoseActiveCredential(failInactive: Bool) throws {
        let key = "credential-delete-test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let slots = IMAPCredentialSlots(service: IMAPCredentialStore.service, account: email, pointerKey: key)
        let prior = slots.slotAccount(.b)
        let inactive = slots.slotAccount(.a)
        var values = [prior: Data("original".utf8), inactive: Data("stale".utf8)]
        UserDefaults.standard.set("b", forKey: key)
        #expect(throws: Failure.oldCleanup) {
            try slots.delete(remove: { _, account in
                if account == (failInactive ? inactive : prior) { throw Failure.oldCleanup }
                values.removeValue(forKey: account)
            })
        }
        #expect(slots.activeSlot == .b)
        #expect(values[prior] == Data("original".utf8))
    }

    @Test("portable policy is opt-in only and disabled preserves every shared record")
    func portableOptInAndOptOut() throws {
        let h = IMAPPortableTestHarness()
        h.defaults.set(" Person@Example.COM ", forKey: h.preferenceKey)
        h.local[h.slots(email).slotAccount(.a)] = Data("legacy bytes".utf8)
        h.enabled = false
        #expect(try h.store.applyFullSyncPolicy().isEmpty)
        #expect(h.events.isEmpty)
        h.enabled = true
        #expect(try h.store.applyFullSyncPolicy() == [IMAPRestoredAccount(account: email, preferenceKey: h.preferenceKey)])
        let shared = h.shared
        #expect(try h.remote(email)?.secret == Data("legacy bytes".utf8))
        h.events.removeAll()
        h.enabled = false
        #expect(try h.store.applyFullSyncPolicy().isEmpty)
        let authorization = h.store.authorization()
        let preparation = try h.store.prepareSave(for: email, authorization: authorization)
        try h.store.publishSaved(Data("legacy bytes".utf8), for: email, preparation: preparation, authorization: authorization)
        #expect(h.events.isEmpty)
        #expect(h.shared == shared)
    }

    @Test("manifest and local preference accounts restore with independent device ACLs",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service], [false, true])
    func portableRestoresDevicePolicy(service: String, background: Bool) throws {
        let h = IMAPPortableTestHarness(service: service)
        let other = "other@example.com"
        h.defaults.set(email, forKey: h.preferenceKey)
        h.defaults.set(background, forKey: h.backgroundKey)
        let bytes = Data("  preserved e\u{301} bytes  ".utf8)
        try h.seed(email, secret: bytes)
        try h.seed(other, secret: Data("second".utf8))
        #expect(try h.store.applyFullSyncPolicy().map(\.account) == [other, email])
        for account in [email, other] {
            let slot = try #require(h.slots(account).activeSlot)
            #expect(h.access[h.slots(account).slotAccount(slot)] ==
                    (background ? .backgroundAfterFirstUnlock : .foregroundUserPresence))
        }
        #expect(try h.slots(email).credential(read: h.store.localRead) == bytes)
        #expect(h.defaults.string(forKey: h.preferenceKey) == email)
        #expect(h.defaults.bool(forKey: h.backgroundKey) == background)
        #expect(h.shared.keys.allSatisfy { $0.hasPrefix("account/") })
        #expect(h.events.filter { $0 == "portable write" }.isEmpty)
    }

    @Test("newer portable bytes win over stale local bytes without republishing")
    func staleLocalDoesNotOverwritePortable() throws {
        let h = IMAPPortableTestHarness()
        h.defaults.set(email, forKey: h.preferenceKey)
        h.local[h.slots(email).slotAccount(.a)] = Data("stale".utf8)
        try h.seed(email, secret: Data("new".utf8))
        let shared = h.shared
        _ = try h.store.applyFullSyncPolicy()
        #expect(try h.slots(email).credential(read: h.store.localRead) == Data("new".utf8))
        #expect(h.shared == shared)
        #expect(!h.events.contains("portable write"))
    }

    @Test("explicit disconnect fences delayed stale delivery and preserves a local deletion guard",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service])
    func portableDeletionFence(service: String) throws {
        let h = IMAPPortableTestHarness(service: service)
        try h.seed(email, secret: Data("old".utf8))
        let stale = try #require(h.shared[h.store.recordKey(email)])
        h.local[h.slots(email).slotAccount(.a)] = Data("old".utf8)
        h.enabled = false // Explicit disconnect, unlike opting out, revokes portable registration.
        try h.store.delete(for: email)
        #expect(h.local.isEmpty)
        #expect(h.shared[h.store.recordKey(email)] == nil)
        #expect(h.shared[h.store.fenceKey(email)] != nil)
        #expect(h.defaults.bool(forKey: h.store.deletionKey(email)))
        h.shared[h.store.recordKey(email)] = stale
        h.enabled = true
        #expect(try h.store.applyFullSyncPolicy().isEmpty)
        h.defaults.removeObject(forKey: h.store.deletionKey(email)) // Simulate a different device.
        #expect(try h.store.applyFullSyncPolicy().isEmpty)
        let authorization = h.store.authorization()
        let preparation = try h.store.prepareSave(for: email, authorization: authorization)
        try h.store.publishSaved(Data("reconnected".utf8), for: email, preparation: preparation, authorization: authorization)
        #expect(try h.store.applyFullSyncPolicy().map(\.account) == [email])
        // The old revision remains revoked even after deliberate reconnection.
        h.shared[h.store.recordKey(email)] = stale
        #expect(try h.store.applyFullSyncPolicy().isEmpty)
    }

    @Test("never-consented local disconnect creates no portable metadata",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service])
    func neverConsentedLocalDeletion(service: String) throws {
        let h = IMAPPortableTestHarness(service: service)
        h.enabled = false
        h.portableRevocationAllowed = false
        h.local[h.slots(email).slotAccount(.a)] = Data("local only".utf8)
        h.failure = "portable write"
        try h.store.delete(for: email)
        #expect(h.shared.isEmpty)
        #expect(h.local.isEmpty)
        #expect(h.defaults.bool(forKey: h.store.deletionKey(email)))
        #expect(!h.events.contains { $0.hasPrefix("portable") || $0 == "list" })
    }

    @Test("rejection and explicit-deletion guards prevent copy and restore")
    func portableGuards() throws {
        let h = IMAPPortableTestHarness()
        h.defaults.set(email, forKey: h.preferenceKey)
        h.local[h.slots(email).slotAccount(.a)] = Data("local".utf8)
        try h.seed(email, secret: Data("portable".utf8))
        h.rejected = true
        #expect(try h.store.applyFullSyncPolicy().isEmpty)
        h.rejected = false
        h.defaults.set(true, forKey: h.store.deletionKey(email))
        #expect(try h.store.applyFullSyncPolicy().isEmpty)
        #expect(h.local[h.slots(email).slotAccount(.a)] == Data("local".utf8))
        #expect(!h.events.contains("portable write"))
    }

    @Test("portable and local read failures do not replace or publish secrets",
          arguments: ["list", "portable read", "local read"])
    func portableReadFailureSafety(operation: String) throws {
        let h = IMAPPortableTestHarness()
        h.defaults.set(email, forKey: h.preferenceKey)
        h.local[h.slots(email).slotAccount(.a)] = Data("valid local".utf8)
        try h.seed(email, secret: Data("valid remote".utf8))
        let shared = h.shared
        let local = h.local
        h.failure = operation
        #expect(throws: IMAPPortableTestHarness.Failure.injected) { try h.store.applyFullSyncPolicy() }
        #expect(h.shared == shared)
        #expect(h.local == local)
        #expect(!h.events.contains("portable write"))
        #expect(!h.events.contains("local write"))
    }

    @Test("opted-out IMAP saves retain their portable base through restart without losing new local bytes",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service], ["unchanged", "new revision", "deletion"])
    func optedOutSavePreservesNewCredential(service: String, remoteChange: String) throws {
        let h = IMAPPortableTestHarness(service: service)
        try h.seed(email, secret: Data("old-shared-password".utf8))
        let old = try #require(try h.remote(email))
        let initialFence = IMAPPortableCredentials.DeletionFence(allowedRevision: old.revision)
        h.shared[h.store.fenceKey(email)] = try JSONEncoder().encode(initialFence)
        _ = try h.store.applyFullSyncPolicy()
        let shared = h.shared
        h.enabled = false
        h.events.removeAll()

        let firstAuthorization = h.store.authorization()
        let first = try h.store.prepareSave(for: email, authorization: firstAuthorization)
        try h.slots(email).replace(data: Data("first-local-password".utf8), backgroundEnabled: false,
                                  read: h.store.localRead, write: h.store.localWrite, remove: h.store.localRemove)
        try h.store.didSaveLocally(for: email, preparation: first)
        try h.store.publishSaved(Data("first-local-password".utf8), for: email, preparation: first, authorization: firstAuthorization)
        // A second disabled save must retain the original portable base even though
        // the clean receipt was removed by the first successful local commit.
        let secondAuthorization = h.store.authorization()
        let second = try h.store.prepareSave(for: email, authorization: secondAuthorization)
        #expect(second.previousRevision == old.revision)
        #expect(second.previousFence == initialFence)
        #expect(second.revision != first.revision)
        let newest = Data("newest-local-password".utf8)
        try h.slots(email).replace(data: newest, backgroundEnabled: false,
                                  read: h.store.localRead, write: h.store.localWrite, remove: h.store.localRemove)
        try h.store.didSaveLocally(for: email, preparation: second)
        try h.store.publishSaved(newest, for: email, preparation: second, authorization: secondAuthorization)
        #expect(h.shared == shared)
        #expect(!h.events.contains { $0.hasPrefix("portable") || $0 == "list" })

        var restarted = h.store
        restarted.defaults = try #require(UserDefaults(suiteName: "imap-portable-tests." + h.id))
        if remoteChange == "new revision" {
            try h.seed(email, secret: Data("another-device-password".utf8))
            let newer = try #require(try h.remote(email))
            h.shared[h.store.fenceKey(email)] = try JSONEncoder().encode(
                IMAPPortableCredentials.DeletionFence(generation: initialFence.generation, allowedRevision: newer.revision))
        } else if remoteChange == "deletion" {
            h.shared.removeValue(forKey: h.store.recordKey(email))
            h.shared[h.store.fenceKey(email)] = try JSONEncoder().encode(
                IMAPPortableCredentials.DeletionFence(allowedRevision: nil))
        }
        h.enabled = true
        h.events.removeAll()
        if remoteChange == "unchanged" {
            #expect(try restarted.applyFullSyncPolicy() == [IMAPRestoredAccount(account: email, preferenceKey: h.preferenceKey)])
            #expect(try h.remote(email)?.secret == newest)
            h.events.removeAll()
            _ = try restarted.applyFullSyncPolicy()
            #expect(!h.events.contains("portable write"))
        } else {
            let currentShared = h.shared
            #expect(throws: IMAPCredentialPublicationConflictError.self) {
                try restarted.applyFullSyncPolicy()
            }
            #expect(h.shared == currentShared)
            #expect(!h.events.contains("portable write"))
            #expect(!h.events.contains("local write"))
        }
        #expect(try h.slots(email).credential(read: restarted.localRead) == newest)
    }

    @Test("failed publication preserves committed local bytes through reconciliation and restart",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service], [false, true])
    func portablePublicationFailureSafety(service: String, existingRemote: Bool) throws {
        let h = IMAPPortableTestHarness(service: service)
        if existingRemote { try h.seed(email, secret: Data("shared".utf8)) }
        let shared = h.shared
        let authorization = h.store.authorization()
        let preparation = try h.store.prepareSave(for: email, authorization: authorization)
        let data = Data("new local".utf8)
        try h.slots(email).replace(data: data, backgroundEnabled: false,
                                  read: h.store.localRead, write: h.store.localWrite, remove: h.store.localRemove)
        try h.store.didSaveLocally(for: email, preparation: preparation)
        h.failure = "portable write"
        #expect(throws: IMAPCredentialPublicationError.self) {
            try h.store.publishSaved(data, for: email, preparation: preparation, authorization: authorization)
        }
        #expect(h.shared == shared)
        #expect(try h.slots(email).credential(read: h.store.localRead) == data)

        // Reconstruct the store and UserDefaults handle; only persisted metadata
        // and the Keychain fixture survive. No preference account was selected.
        var restarted = h.store
        restarted.defaults = try #require(UserDefaults(suiteName: "imap-portable-tests." + h.id))
        #expect(throws: IMAPCredentialPublicationError.self) { try restarted.applyFullSyncPolicy() }
        #expect(h.shared == shared)
        #expect(try h.slots(email).credential(read: restarted.localRead) == data)
        h.enabled = false
        #expect(try restarted.applyFullSyncPolicy().isEmpty)
        #expect(h.shared == shared)
        h.enabled = true
        h.failure = nil
        #expect(try restarted.applyFullSyncPolicy() == [IMAPRestoredAccount(account: email, preferenceKey: h.preferenceKey)])
        #expect(try h.remote(email)?.secret == data)
        #expect(try h.slots(email).credential(read: restarted.localRead) == data)
        h.events.removeAll()
        _ = try h.store.applyFullSyncPolicy()
        #expect(!h.events.contains("portable write"))
    }

    @Test("pending explicit publication never overwrites a newer portable secret or deletion",
          arguments: ["new revision", "deletion"])
    func pendingPublicationConflictSafety(change: String) throws {
        let h = IMAPPortableTestHarness()
        try h.seed(email, secret: Data("old shared".utf8))
        let authorization = h.store.authorization()
        let preparation = try h.store.prepareSave(for: email, authorization: authorization)
        let data = Data("committed local".utf8)
        try h.slots(email).replace(data: data, backgroundEnabled: false,
                                  read: h.store.localRead, write: h.store.localWrite, remove: h.store.localRemove)
        h.failure = "portable write"
        #expect(throws: IMAPCredentialPublicationError.self) {
            try h.store.publishSaved(data, for: email, preparation: preparation, authorization: authorization)
        }
        h.failure = nil
        if change == "new revision" {
            try h.seed(email, secret: Data("newer portable".utf8))
        } else {
            h.shared[h.store.fenceKey(email)] = try JSONEncoder().encode(
                IMAPPortableCredentials.DeletionFence(allowedRevision: nil))
        }
        let shared = h.shared
        h.events.removeAll()
        #expect(throws: IMAPCredentialPublicationConflictError.self) { try h.store.applyFullSyncPolicy() }
        #expect(!h.events.contains("local read"))
        #expect(h.shared == shared)
        #expect(try h.slots(email).credential(read: h.store.localRead) == data)
        #expect(!h.events.contains("portable write"))
        #expect(!h.events.contains("local write"))
    }

    @Test("a new deletion generation cannot be mistaken for a failed reconnect's old fence")
    func failedReconnectDoesNotAuthorizeNewDeletion() throws {
        let h = IMAPPortableTestHarness()
        let first = IMAPPortableCredentials.DeletionFence(allowedRevision: nil)
        h.shared[h.store.fenceKey(email)] = try JSONEncoder().encode(first)
        let authorization = h.store.authorization()
        let preparation = try h.store.prepareSave(for: email, authorization: authorization)
        let data = Data("explicit reconnect".utf8)
        try h.slots(email).replace(data: data, backgroundEnabled: false,
                                  read: h.store.localRead, write: h.store.localWrite, remove: h.store.localRemove)
        h.failureWriteAccount = h.store.fenceKey(email)
        #expect(throws: IMAPCredentialPublicationError.self) {
            try h.store.publishSaved(data, for: email, preparation: preparation, authorization: authorization)
        }
        // Credential publication succeeded, but authorizing revision against F1 failed.
        let published = try #require(try h.remote(email))
        #expect(published.revision == preparation.revision)
        let second = IMAPPortableCredentials.DeletionFence(allowedRevision: nil)
        #expect(first.generation != second.generation)
        h.shared[h.store.fenceKey(email)] = try JSONEncoder().encode(second)
        h.failureWriteAccount = nil
        let shared = h.shared
        h.events.removeAll()
        #expect(throws: IMAPCredentialPublicationConflictError.self) { try h.store.applyFullSyncPolicy() }
        #expect(!h.events.contains("local read"))
        #expect(h.shared == shared)
        #expect(try h.slots(email).credential(read: h.store.localRead) == data)
        #expect(!h.events.contains("portable write"))
    }

    @Test("unchanged reconciliation probes presence without reading or rewriting foreground secrets",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service])
    func unchangedReceiptAvoidsAuthenticationReads(service: String) throws {
        let h = IMAPPortableTestHarness(service: service)
        try h.seed(email, secret: Data("foreground secret".utf8))
        _ = try h.store.applyFullSyncPolicy()
        let active = try #require(h.slots(email).activeSlot)
        #expect(h.access[h.slots(email).slotAccount(active)] == .foregroundUserPresence)
        var restarted = h.store
        restarted.defaults = try #require(UserDefaults(suiteName: "imap-portable-tests." + h.id))
        h.failure = "local read"
        h.events.removeAll()
        #expect(try restarted.applyFullSyncPolicy().map(\.account) == [email])
        #expect(h.events.contains("local presence"))
        #expect(!h.events.contains("local read"))
        #expect(!h.events.contains("local write"))
        #expect(!h.events.contains("portable write"))

        // A changed portable revision must still read/restore and propagate errors.
        try h.seed(email, secret: Data("new revision".utf8))
        let shared = h.shared
        #expect(throws: IMAPPortableTestHarness.Failure.injected) { try restarted.applyFullSyncPolicy() }
        #expect(h.shared == shared)
        h.failure = nil
        _ = try restarted.applyFullSyncPolicy()
        #expect(try h.slots(email).credential(read: restarted.localRead) == Data("new revision".utf8))

        // Presence loss must not be hidden by an old receipt.
        let current = try #require(h.slots(email).activeSlot)
        h.local.removeValue(forKey: h.slots(email).slotAccount(current))
        h.failure = "local read"
        #expect(throws: IMAPPortableTestHarness.Failure.injected) { try restarted.applyFullSyncPolicy() }
        h.failure = nil
        _ = try restarted.applyFullSyncPolicy()
        #expect(try h.slots(email).credential(read: restarted.localRead) == Data("new revision".utf8))

        // Device preference changes invalidate the receipt and stage the new ACL.
        h.defaults.set(true, forKey: h.backgroundKey)
        h.failure = "local read"
        #expect(throws: IMAPPortableTestHarness.Failure.injected) { try restarted.applyFullSyncPolicy() }
        h.failure = nil
        _ = try restarted.applyFullSyncPolicy()
        let backgroundSlot = try #require(h.slots(email).activeSlot)
        #expect(h.access[h.slots(email).slotAccount(backgroundSlot)] == .backgroundAfterFirstUnlock)
        h.failure = "local read"
        h.events.removeAll()
        _ = try restarted.applyFullSyncPolicy()
        #expect(!h.events.contains("local read"))
        #expect(!h.events.contains("local write"))
    }

    @Test("failed local restore rolls back without mutating the portable record")
    func portableRestoreWriteFailureSafety() throws {
        let h = IMAPPortableTestHarness()
        h.local[h.slots(email).slotAccount(.a)] = Data("original".utf8)
        try h.seed(email, secret: Data("remote".utf8))
        let shared = h.shared
        h.failure = "local write"
        #expect(throws: IMAPPortableTestHarness.Failure.injected) { try h.store.applyFullSyncPolicy() }
        #expect(try h.slots(email).credential(read: h.store.localRead) == Data("original".utf8))
        #expect(h.shared == shared)
    }

    @Test("failed revocation still deletes locally and retains the restore guard")
    func portableDeleteFailureSafety() throws {
        let h = IMAPPortableTestHarness()
        try h.seed(email, secret: Data("shared".utf8))
        h.local[h.slots(email).slotAccount(.a)] = Data("local".utf8)
        let shared = h.shared
        h.failure = "portable write"
        do {
            try h.store.delete(for: email)
            Issue.record("expected deletion failure")
        } catch let error as IMAPCredentialDeletionError {
            #expect(error.localCredentialDeleted)
            #expect(error.portableError != nil)
        }
        #expect(h.shared == shared)
        #expect(h.local.isEmpty)
        #expect(h.defaults.bool(forKey: h.store.deletionKey(email)))
    }

    @Test("malformed portable records propagate without replacing valid local secrets")
    func malformedPortableReadSafety() throws {
        let h = IMAPPortableTestHarness()
        h.local[h.slots(email).slotAccount(.a)] = Data("valid local".utf8)
        h.shared[h.store.recordKey(email)] = Data("not a credential record".utf8)
        let local = h.local
        let shared = h.shared
        #expect(throws: (any Error).self) { try h.store.applyFullSyncPolicy() }
        #expect(throws: (any Error).self) { try h.store.prepareSave(for: email, authorization: h.store.authorization()) }
        #expect(h.local == local)
        #expect(h.shared == shared)
    }

    @Test("partial deletion retains the fence and reports the actual local outcome",
          arguments: ["portable delete", "local delete"])
    func partialPortableDeletion(operation: String) throws {
        let h = IMAPPortableTestHarness()
        try h.seed(email, secret: Data("shared".utf8))
        h.local[h.slots(email).slotAccount(.a)] = Data("local".utf8)
        h.failure = operation
        do {
            try h.store.delete(for: email)
            Issue.record("expected partial deletion failure")
        } catch let error as IMAPCredentialDeletionError {
            #expect(error.localCredentialDeleted == (operation != "local delete"))
            #expect((error.portableError != nil) == (operation == "portable delete"))
        }
        #expect(h.shared[h.store.fenceKey(email)] != nil)
        #expect(h.defaults.bool(forKey: h.store.deletionKey(email)))
        h.failure = nil
        #expect(try h.store.applyFullSyncPolicy().isEmpty)
    }

    @Test("save preflight cannot cross an expired epoch, even with the same policy re-enabled",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service], [false, true])
    func savePreflightRejectsExpiredEpoch(service: String, reenable: Bool) throws {
        let h = IMAPPortableTestHarness(service: service)
        try h.seed(email, secret: Data("shared".utf8))
        let shared = h.shared
        h.local[h.slots(email).slotAccount(.a)] = Data("original local".utf8)
        let local = h.local
        h.invalidate(after: "portable read", reenable: reenable)

        #expect(throws: IMAPPortableCredentials.AuthorizationError.self) {
            try h.save(Data("replacement".utf8), for: email)
        }
        #expect(h.captures == [false])
        #expect(h.shared == shared)
        #expect(h.local == local)
        #expect(h.events.filter { $0 == "portable read" }.count == 1)
        #expect(h.mutationsAfterExpiry.isEmpty)
        #expect(try h.pending(email) == nil) // No local save committed.
        #expect(!h.hasReceipt(email))
    }

    @Test("a committed save retains its preparation when its original lease expires",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service],
          ["local read", "portable write", "local presence"])
    func committedSaveRetainsExpiredPreparation(service: String, operation: String) throws {
        let h = IMAPPortableTestHarness(service: service)
        try h.seed(email, secret: Data("old remote".utf8))
        let previous = try #require(try h.remote(email))
        let fence = IMAPPortableCredentials.DeletionFence(allowedRevision: previous.revision)
        let encodedFence = try JSONEncoder().encode(fence)
        h.shared[h.store.fenceKey(email)] = encodedFence
        h.local[h.slots(email).slotAccount(.a)] = Data("old local".utf8)
        let replacement = Data("committed replacement".utf8)
        h.invalidate(after: operation)

        #expect(throws: IMAPCredentialPublicationError.self) { try h.save(replacement, for: email) }
        #expect(h.captures == [false])
        let pending = try #require(try h.pending(email))
        #expect(pending.previousRevision == previous.revision)
        #expect(pending.previousFence == fence)
        #expect(!h.hasReceipt(email))
        #expect(try h.slots(email).credential(read: h.store.localRead) == replacement)
        // Explicit local replacement is allowed to finish after the local read;
        // no subsequent portable record/fence mutation is authorized by it.
        #expect(!h.mutationsAfterExpiry.contains { $0.hasPrefix("portable") })
        let writes = h.events.filter { $0 == "portable write" }.count
        #expect(writes == (operation == "local read" ? 0 : operation == "portable write" ? 1 : 2))
        if operation != "local presence" {
            #expect(h.shared[h.store.fenceKey(email)] == encodedFence)
        }

        var restarted = h.store
        restarted.defaults = try #require(UserDefaults(suiteName: "imap-portable-tests." + h.id))
        #expect(try restarted.applyFullSyncPolicy().map(\.account) == [email])
        #expect(try h.pending(email) == nil)
        #expect(h.hasReceipt(email))
        #expect(try h.remote(email)?.secret == replacement)
    }

    @Test("pending reconciliation uses one lease and preserves retry or conflict metadata",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service],
          ["portable read", "local read", "portable write", "local presence"])
    func pendingReconcileRejectsExpiredEpoch(service: String, operation: String) throws {
        for conflict in [false, true] {
            let h = IMAPPortableTestHarness(service: service)
            try h.seed(email, secret: Data("old shared".utf8))
            let old = try #require(try h.remote(email))
            h.shared[h.store.fenceKey(email)] = try JSONEncoder().encode(
                IMAPPortableCredentials.DeletionFence(allowedRevision: old.revision))
            _ = try h.store.applyFullSyncPolicy()
            h.enabled = false
            let replacement = Data("pending local".utf8)
            try h.save(replacement, for: email)
            let pending = try #require(try h.pending(email))
            h.enabled = true
            h.captures.removeAll()
            h.events.removeAll()
            h.invalidate(after: operation)

            #expect(throws: (any Error).self) { try h.store.applyFullSyncPolicy() }
            #expect(h.captures == [false])
            #expect(h.events.contains("authorization expired"))
            #expect(h.mutationsAfterExpiry.isEmpty)
            #expect(try h.pending(email) == pending)
            #expect(!h.hasReceipt(email))
            #expect(try h.slots(email).credential(read: h.store.localRead) == replacement)

            var restarted = h.store
            restarted.defaults = try #require(UserDefaults(suiteName: "imap-portable-tests." + h.id))
            if conflict {
                try h.seed(email, secret: Data("newer remote".utf8))
                let shared = h.shared
                #expect(throws: IMAPCredentialPublicationConflictError.self) {
                    try restarted.applyFullSyncPolicy()
                }
                #expect(h.shared == shared)
                #expect(try h.pending(email) == pending)
                #expect(!h.hasReceipt(email))
            } else {
                #expect(try restarted.applyFullSyncPolicy().map(\.account) == [email])
                #expect(try h.pending(email) == nil)
                #expect(h.hasReceipt(email))
                #expect(try h.remote(email)?.secret == replacement)
            }
        }
    }

    @Test("expired restore reads cannot promote pointers or mutate local ACL slots",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service],
          ["portable read", "local read"])
    func restoreReadExpiryPreventsLocalMutation(service: String, operation: String) throws {
        let h = IMAPPortableTestHarness(service: service)
        try h.seed(email, secret: Data("remote".utf8))
        let slots = h.slots(email)
        h.local[slots.slotAccount(.a)] = Data("local".utf8)
        let shared = h.shared
        let local = h.local
        h.invalidate(after: operation)

        #expect(throws: IMAPPortableCredentials.AuthorizationError.self) { try h.store.applyFullSyncPolicy() }
        #expect(h.captures == [false])
        #expect(h.events.contains("authorization expired"))
        #expect(h.mutationsAfterExpiry.isEmpty)
        #expect(slots.activeSlot == nil)
        #expect(h.shared == shared)
        #expect(h.local == local)
        #expect(!h.hasReceipt(email))
        #expect(try h.store.applyFullSyncPolicy().map(\.account) == [email])
    }

    @Test("automatic first publication journals expiry and stops the rest of reconciliation",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service])
    func automaticPublicationExpiryRetainsPending(service: String) throws {
        let h = IMAPPortableTestHarness(service: service)
        h.defaults.set(email, forKey: h.preferenceKey)
        h.local[h.slots(email).slotAccount(.a)] = Data("local only".utf8)
        let later = "z-later@example.com"
        try h.seed(later, secret: Data("later remote".utf8))
        h.invalidate(after: "portable write")

        #expect(throws: IMAPCredentialPublicationError.self) { try h.store.applyFullSyncPolicy() }
        #expect(h.captures == [false])
        #expect(h.events.filter { $0 == "portable write" }.count == 1)
        #expect(h.mutationsAfterExpiry.isEmpty)
        let pending = try #require(try h.pending(email))
        #expect(try h.remote(email)?.revision == pending.revision)
        #expect(pending.previousRevision == nil && pending.previousFence == nil)
        #expect(!h.hasReceipt(email))
        #expect(h.slots(later).activeSlot == nil)
        #expect(!h.hasReceipt(later))
        #expect(try h.store.applyFullSyncPolicy().map(\.account) == [email, later])
        #expect(try h.pending(email) == nil)
    }

    @Test("expiry between receipt and journal clear removes the receipt and preserves pending publication",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service])
    func journalAcknowledgementRechecksOriginalLease(service: String) throws {
        let h = IMAPPortableTestHarness(service: service)
        var store = h.store
        let capture = store.captureAuthorization
        store.captureAuthorization = {
            let lease = capture()
            return {
                // Deterministically interleave an epoch change at the first
                // lease check after the receipt has been persisted.
                if h.hasReceipt(self.email) {
                    h.epoch += 1
                    h.events.append("authorization expired")
                }
                return lease()
            }
        }
        let authorization = store.authorization()
        let preparation = try store.prepareSave(for: email, authorization: authorization)
        let replacement = Data("saved local".utf8)
        try h.slots(email).replace(data: replacement, backgroundEnabled: false,
                                  read: store.localRead, write: store.localWrite, remove: store.localRemove)
        try store.didSaveLocally(for: email, preparation: preparation)

        #expect(throws: IMAPCredentialPublicationError.self) {
            try store.publishSaved(replacement, for: email, preparation: preparation, authorization: authorization)
        }
        #expect(h.captures == [false])
        #expect(h.events.contains("authorization expired"))
        #expect(h.mutationsAfterExpiry.isEmpty)
        #expect(!h.hasReceipt(email))
        #expect(try h.pending(email) == preparation)
        #expect(try h.remote(email)?.revision == preparation.revision)
        #expect(try h.store.applyFullSyncPolicy().map(\.account) == [email])
        #expect(try h.pending(email) == nil)
        #expect(h.hasReceipt(email))
    }
}

/// In-memory Keychain operations with real slot/pointer transactions and isolated
/// preferences. No fixture contacts iCloud or changes the app's global sync policy.
nonisolated final class IMAPPortableTestHarness {
    enum Failure: Error, Equatable { case injected }
    let id = UUID().uuidString
    let service: String
    let defaults: UserDefaults
    var preferenceKey: String { service == OutlookIMAPCredentialStore.service ? "pieroot.todo.outlook.account" : "pieroot.todo.imap.account" }
    var backgroundKey: String { service == OutlookIMAPCredentialStore.service ? "pieroot.todo.outlook.backgroundEnabled" : "pieroot.todo.imap.backgroundEnabled" }
    var enabled = true
    var portableRevocationAllowed = true
    var rejected = false
    var shared: [String: Data] = [:]
    var local: [String: Data] = [:]
    var access: [String: DeviceOnlyCredentialAccess] = [:]
    var events: [String] = []
    var failure: String?
    var failureWriteAccount: String?
    var epoch = 0
    var captures: [Bool] = []
    var afterOperation: ((String) -> Void)?
    private var pointerKeys = Set<String>()

    init(service: String = IMAPCredentialStore.service) {
        self.service = service
        defaults = UserDefaults(suiteName: "imap-portable-tests." + id)!
    }

    deinit {
        defaults.removePersistentDomain(forName: "imap-portable-tests." + id)
        for key in pointerKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func slots(_ account: String) -> IMAPCredentialSlots {
        let key = "imap-portable-tests." + id + "." + account
        pointerKeys.insert(key)
        return IMAPCredentialSlots(service: service, account: account, pointerKey: key)
    }

    func step(_ name: String) throws {
        events.append(name)
        if failure == name { throw Failure.injected }
    }

    /// Invalidate the captured epoch after a completed fixture operation, not
    /// before it. Re-enabling the identical policy must not revive that lease.
    func invalidate(after operation: String, reenable: Bool = true) {
        afterOperation = { [unowned self] name in
            guard name == operation else { return }
            self.afterOperation = nil
            self.enabled = false
            self.epoch += 1
            if reenable { self.enabled = true }
            self.events.append("authorization expired")
        }
    }

    func capture(forRevocation: Bool) -> () -> Bool {
        captures.append(forRevocation)
        let captured = epoch
        return { [unowned self] in
            captured == self.epoch && (forRevocation ? self.portableRevocationAllowed : self.enabled)
        }
    }

    func pending(_ account: String) throws -> IMAPPortableCredentials.SavePreparation? {
        guard let data = defaults.data(forKey: service + ".pendingPublications.v1") else { return nil }
        return try JSONDecoder().decode([String: IMAPPortableCredentials.SavePreparation].self, from: data)[account]
    }

    func hasReceipt(_ account: String) -> Bool {
        defaults.data(forKey: store.deletionKey(account) + ".portableReceipt.v1") != nil
    }

    /// Mirrors the providers' local-save contract: a lost portable lease must
    /// never roll back an explicit device-local credential replacement.
    func save(_ data: Data, for account: String, backgroundEnabled: Bool = false) throws {
        let store = self.store
        let authorization = store.authorization()
        let preparation = try store.prepareSave(for: account, authorization: authorization)
        try slots(account).replace(data: data, backgroundEnabled: backgroundEnabled,
                                   read: store.localRead, write: store.localWrite, remove: store.localRemove)
        try store.didSaveLocally(for: account, preparation: preparation)
        try store.publishSaved(data, for: account, preparation: preparation,
                               backgroundEnabled: backgroundEnabled, authorization: authorization)
    }

    var mutationsAfterExpiry: [String] {
        events.drop(while: { $0 != "authorization expired" }).filter {
            $0.hasSuffix("write") || $0.hasSuffix("delete")
        }
    }

    var store: IMAPPortableCredentials {
        IMAPPortableCredentials(service: service, preferenceKey: preferenceKey, backgroundKey: backgroundKey,
                                defaults: defaults, slots: slots, isRejected: { _ in self.rejected },
                                enabled: { self.enabled }, mayRevokePortable: { self.portableRevocationAllowed },
                                captureAuthorization: { self.capture(forRevocation: false) },
                                captureRevocationAuthorization: { self.capture(forRevocation: true) }, list: { _ in
            try self.step("list")
            defer { self.afterOperation?("list") }
            return Array(self.shared.keys)
        }, read: { _, account in
            try self.step("portable read")
            defer { self.afterOperation?("portable read") }
            return self.shared[account]
        }, write: { _, account, data in
            try self.step("portable write")
            if account == self.failureWriteAccount { throw Failure.injected }
            self.shared[account] = data
            self.afterOperation?("portable write")
        }, remove: { _, account in
            try self.step("portable delete")
            self.shared.removeValue(forKey: account)
            self.afterOperation?("portable delete")
        }, localRead: { _, account in
            try self.step("local read")
            defer { self.afterOperation?("local read") }
            return self.local[account]
        }, localWrite: { _, account, data, access in
            try self.step("local write")
            self.local[account] = data
            self.access[account] = access
            self.afterOperation?("local write")
        }, localRemove: { _, account in
            try self.step("local delete")
            self.local.removeValue(forKey: account)
            self.access.removeValue(forKey: account)
            self.afterOperation?("local delete")
        }, localHasItem: { _, account in
            self.events.append("local presence")
            defer { self.afterOperation?("local presence") }
            return self.local[account] != nil
        })
    }

    func seed(_ account: String, secret: Data) throws {
        shared[store.recordKey(account)] = try JSONEncoder().encode(
            IMAPPortableCredentials.Record(revision: UUID(), secret: secret))
    }

    func remote(_ account: String) throws -> IMAPPortableCredentials.Record? {
        try shared[store.recordKey(account)].map {
            try JSONDecoder().decode(IMAPPortableCredentials.Record.self, from: $0)
        }
    }
}
