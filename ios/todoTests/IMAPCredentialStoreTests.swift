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
}
