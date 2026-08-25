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
}
