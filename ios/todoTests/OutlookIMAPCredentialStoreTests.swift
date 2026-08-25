import Foundation
import Testing
@testable import todo

@Suite("Outlook IMAP credential store", .serialized)
struct OutlookIMAPCredentialStoreTests {
    private let email = "user@outlook.com"

    private func reset() throws {
        try OutlookIMAPCredentialStore.delete(for: email)
    }

    @Test("stores an App Password in the device-only store for Outlook")
    func storesDeviceOnlyCredential() throws {
        try reset()
        defer { try? reset() }

        try OutlookIMAPCredentialStore.save(
            appPassword: "abcd efgh ijkl mnop",
            for: " User@Outlook.COM ",
            backgroundEnabled: false
        )

        #expect(try OutlookIMAPCredentialStore.credential(for: email) == "abcdefghijklmnop")
    }

    @Test("probes device-only credential presence without reading the password")
    func probesStoredCredentialPresence() throws {
        try reset()
        defer { try? reset() }

        #expect(!OutlookIMAPCredentialStore.hasCredential(for: email))
        try OutlookIMAPCredentialStore.save(
            appPassword: "abcd efgh ijkl mnop",
            for: email,
            backgroundEnabled: false
        )
        #expect(OutlookIMAPCredentialStore.hasCredential(for: email))
    }

    @Test("recovers when the active-slot pointer is missing or corrupt")
    func recoversFromPointerLoss() throws {
        try reset()
        defer { try? reset() }

        try OutlookIMAPCredentialStore.save(appPassword: "first-password", for: email, backgroundEnabled: false)
        let key = OutlookIMAPCredentialStore.activeSlotKey(for: email)
        UserDefaults.standard.removeObject(forKey: key)
        #expect(try OutlookIMAPCredentialStore.credential(for: email) == "first-password")

        UserDefaults.standard.set("invalid", forKey: key)
        #expect(try OutlookIMAPCredentialStore.credential(for: email) == "first-password")
    }

    @Test("rejects invalid account and empty password")
    func validatesInput() {
        #expect(throws: IMAPCredentialError.invalidEmail) {
            try OutlookIMAPCredentialStore.save(appPassword: "abcd", for: "invalid", backgroundEnabled: false)
        }
        #expect(throws: IMAPCredentialError.emptyPassword) {
            try OutlookIMAPCredentialStore.save(appPassword: "   ", for: email, backgroundEnabled: false)
        }
    }

    @Test("canonicalizes email address correctly")
    func canonicalAccountFormat() {
        #expect(OutlookIMAPCredentialStore.canonicalAccount(" USER@outlook.com ") == "user@outlook.com")
        #expect(OutlookIMAPCredentialStore.canonicalAccount("invalid-email") == nil)
    }
}
