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

    @Test("Outlook portable restore preserves legacy bytes and returns Outlook metadata")
    func portableRestorePreservesProviderBytes() throws {
        let h = IMAPPortableTestHarness(service: OutlookIMAPCredentialStore.service)
        let legacy = Data("  Outlook legacy spaced secret  ".utf8)
        try h.seed(email, secret: legacy)
        let restored = try h.store.applyFullSyncPolicy()
        #expect(restored == [IMAPRestoredAccount(account: email, preferenceKey: "pieroot.todo.outlook.account")])
        #expect(try h.slots(email).credential(read: h.store.localRead) == legacy)
        #expect(h.defaults.object(forKey: "pieroot.todo.outlook.account") == nil)
        #expect(h.defaults.object(forKey: "pieroot.todo.outlook.backgroundEnabled") == nil)
        let active = try #require(h.slots(email).activeSlot)
        #expect(h.access[h.slots(email).slotAccount(active)] == .foregroundUserPresence)
    }

    @Test("explicit portable save publishes only while opted in")
    func publishesSavedCredentialOnlyWhenEnabled() throws {
        let h = IMAPPortableTestHarness(service: OutlookIMAPCredentialStore.service)
        h.enabled = false
        try h.save(Data("local only".utf8), for: email)
        #expect(h.shared.isEmpty)
        #expect(!h.events.contains { $0.hasPrefix("portable") || $0 == "list" })
        #expect(try h.slots(email).credential(read: h.store.localRead) == Data("local only".utf8))
        h.enabled = true
        let normalized = try IMAPCredentialValidation.appPassword("abcd efgh ijkl mnop")
        try h.save(Data(normalized.utf8), for: email)
        #expect(try h.remote(email)?.secret == Data("abcdefghijklmnop".utf8))
    }

    @Test("an initially disabled save stays local when the identical policy is re-enabled mid-transaction",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service])
    func disabledSaveDoesNotAcquireLaterAuthorization(service: String) throws {
        let h = IMAPPortableTestHarness(service: service)
        try h.seed(email, secret: Data("old shared".utf8))
        _ = try h.store.applyFullSyncPolicy()
        let old = try #require(try h.remote(email))
        let shared = h.shared
        h.enabled = false
        h.events.removeAll()
        h.captures.removeAll()
        h.invalidate(after: "local write")
        let replacement = Data("new local".utf8)

        try h.save(replacement, for: email)
        #expect(h.enabled)
        #expect(h.captures == [false])
        #expect(h.shared == shared)
        #expect(!h.events.contains { $0.hasPrefix("portable") || $0 == "list" })
        let pending = try #require(try h.pending(email))
        #expect(pending.previousRevision == old.revision)
        #expect(!h.hasReceipt(email))
        #expect(try h.slots(email).credential(read: h.store.localRead) == replacement)
        #expect(try h.store.applyFullSyncPolicy().map(\.account) == [email])
        #expect(try h.pending(email) == nil)
        #expect(try h.remote(email)?.secret == replacement)
    }

    @Test("opt-out explicit deletion keeps local revocation when the remote lease expires after its fence write",
          arguments: [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service], [false, true])
    func optedOutDeleteRetainsLocalRevocation(service: String, reenable: Bool) throws {
        let h = IMAPPortableTestHarness(service: service)
        try h.seed(email, secret: Data("shared".utf8))
        _ = try h.store.applyFullSyncPolicy()
        let record = try #require(h.shared[h.store.recordKey(email)])
        h.enabled = false
        h.events.removeAll()
        h.captures.removeAll()
        h.invalidate(after: "portable write", reenable: reenable)

        do {
            try h.store.delete(for: email)
            Issue.record("expected expired remote revocation")
        } catch let error as IMAPCredentialDeletionError {
            #expect(error.localCredentialDeleted)
            #expect(error.portableError is IMAPPortableCredentials.AuthorizationError)
        }
        #expect(h.captures == [true])
        #expect(h.events.filter { $0 == "portable write" }.count == 1)
        #expect(!h.events.contains("portable delete"))
        #expect(h.shared[h.store.recordKey(email)] == record)
        let fenceData = try #require(h.shared[h.store.fenceKey(email)])
        let fence = try JSONDecoder().decode(IMAPPortableCredentials.DeletionFence.self, from: fenceData)
        #expect(fence.allowedRevision == nil)
        #expect(h.local.isEmpty)
        #expect(h.slots(email).activeSlot == nil)
        #expect(h.defaults.bool(forKey: h.store.deletionKey(email)))
        #expect(!h.hasReceipt(email))
        #expect(!h.mutationsAfterExpiry.contains { $0.hasPrefix("portable") })

        // Local revocation prevents restoration even after authorization renews.
        h.enabled = true
        #expect(try h.store.applyFullSyncPolicy().isEmpty)
        try h.store.delete(for: email)
        #expect(h.shared[h.store.recordKey(email)] == nil)
        #expect(h.local.isEmpty)
        #expect(h.defaults.bool(forKey: h.store.deletionKey(email)))
    }
}
