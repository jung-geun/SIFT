import Foundation
import Security
import Testing
@testable import todo

@Suite("Explicit portable Keychain copies", .serialized)
struct KeychainCredentialPortabilityTests {
    @Test("portable CRUD never matches local ACL slots with the same identity")
    func independentStorageDomains() throws {
        let service = "test.portability.domains.\(UUID().uuidString)"
        let account = "person@example.com"
        let local = Data("local-secret".utf8)
        let portable = Data("portable-secret".utf8)
        defer { try? KeychainStore.deleteChecked(service: service) }

        try KeychainStore.setDeviceOnly(service: service, account: account, data: local,
                                       access: .foregroundUserPresence)
        try KeychainStore.setSynchronizable(service: service, account: account, data: portable)
        #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == local)
        #expect(try KeychainStore.getSynchronizable(service: service, account: account) == portable)
        #expect(KeychainStore.deviceOnlyAccessForTesting(service: service, account: account) == .foregroundUserPresence)

        try KeychainStore.deleteSynchronizable(service: service, account: account)
        #expect(try KeychainStore.getSynchronizable(service: service, account: account) == nil)
        #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == local)

        try KeychainStore.setSynchronizable(service: service, account: account, data: portable)
        try KeychainStore.deleteDeviceOnly(service: service, account: account)
        #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == nil)
        #expect(try KeychainStore.getSynchronizable(service: service, account: account) == portable)
    }

    @Test("portable manifest enumerates only synchronizable account registrations")
    func enumeratesPortableAccountsOnly() throws {
        let service = "test.portability.manifest.\(UUID().uuidString)"
        defer { try? KeychainStore.deleteChecked(service: service) }
        try KeychainStore.setDeviceOnly(service: service, account: "local-only@example.com", data: Data([1]))
        try KeychainStore.setSynchronizable(service: service, account: "second@example.com", data: Data([2]))
        try KeychainStore.setSynchronizable(service: service, account: "first@example.com", data: Data([3]))

        #expect(try KeychainStore.synchronizableAccounts(service: service) == ["first@example.com", "second@example.com"])
        #expect(try KeychainStore.synchronizableAccounts(service: service + ".missing").isEmpty)
    }

    @Test("read errors are distinguishable from absent secrets and never erase data")
    func checkedReadFailurePreservesData() throws {
        let service = "test.portability.read.\(UUID().uuidString)"
        let data = Data("keep-me".utf8)
        defer {
            KeychainStore.setReadFailureForTesting(service: service, status: nil)
            try? KeychainStore.deleteChecked(service: service)
        }
        try KeychainStore.setSynchronizable(service: service, account: "account", data: data)
        KeychainStore.setReadFailureForTesting(service: service, status: errSecInteractionNotAllowed)
        #expect(throws: KeychainStoreError.security(errSecInteractionNotAllowed)) {
            try KeychainStore.getSynchronizable(service: service, account: "account")
        }
        #expect(throws: KeychainStoreError.security(errSecInteractionNotAllowed)) {
            try KeychainStore.synchronizableAccounts(service: service)
        }
        KeychainStore.setReadFailureForTesting(service: service, status: nil)
        #expect(try KeychainStore.getSynchronizable(service: service, account: "account") == data)
    }

    @Test("failed updates and explicit deletion leave the prior portable value intact")
    func checkedMutationFailuresPreserveData() throws {
        let service = "test.portability.write.\(UUID().uuidString)"
        let data = Data("original".utf8)
        defer {
            KeychainStore.setWriteFailureForTesting(service: service, status: nil)
            KeychainStore.setDeleteFailureForTesting(service: service, status: nil)
            try? KeychainStore.deleteChecked(service: service)
        }
        try KeychainStore.setSynchronizable(service: service, account: "account", data: data)
        KeychainStore.setWriteFailureForTesting(service: service, status: errSecNotAvailable)
        #expect(throws: KeychainStoreError.security(errSecNotAvailable)) {
            try KeychainStore.setSynchronizable(service: service, account: "account", data: Data("replacement".utf8))
        }
        KeychainStore.setWriteFailureForTesting(service: service, status: nil)
        KeychainStore.setDeleteFailureForTesting(service: service, status: errSecNotAvailable)
        #expect(throws: KeychainStoreError.security(errSecNotAvailable)) {
            try KeychainStore.deleteSynchronizable(service: service, account: "account")
        }
        KeychainStore.setDeleteFailureForTesting(service: service, status: nil)
        #expect(try KeychainStore.getSynchronizable(service: service, account: "account") == data)
    }

    @Test("legacy generic reads see the same binary local and portable items")
    func legacyReadsShareStorageDomains() throws {
        let service = "test.portability.legacy.\(UUID().uuidString)"
        let encoded = Data(repeating: 7, count: 32).base64EncodedString()
        defer { try? KeychainStore.deleteChecked(service: service) }
        try KeychainStore.setDeviceOnly(service: service, account: "local", data: Data(encoded.utf8))
        try KeychainStore.setSynchronizable(service: service, account: "portable", data: Data(encoded.utf8))
        #expect(try KeychainStore.getChecked(service: service, account: "local") == encoded)
        #expect(try KeychainStore.getChecked(service: service, account: "portable") == encoded)
    }

    @Test("public IMAP APIs require full consent and rebuild this device's ACL slots")
    @MainActor
    func publicIMAPConsentAndRestore() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let keys = [UserCloudSyncPolicy.syncKey, UserCloudSyncPolicy.consentKey]
            let priorPreferences = keys.map { ($0, defaults.object(forKey: $0)) }
            let backgroundEnabled = false
            let account = "portability-\(UUID().uuidString.lowercased())@example.com"
            let gmailService = IMAPCredentialStore.service + ".portable.v1"
            let outlookService = OutlookIMAPCredentialStore.service + ".portable.v1"
            let record = "account/\(account)"
            defer {
                try? IMAPCredentialStore.delete(for: account)
                try? OutlookIMAPCredentialStore.delete(for: account)
                for (key, value) in priorPreferences {
                    if let value { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }

            // The legacy task-sync preference alone does not authorize connections.
            defaults.set(true, forKey: UserCloudSyncPolicy.syncKey)
            defaults.removeObject(forKey: UserCloudSyncPolicy.consentKey)
            try IMAPCredentialStore.save(appPassword: "abcd efgh ijkl mnop", for: account, backgroundEnabled: backgroundEnabled)
            try OutlookIMAPCredentialStore.save(appPassword: "outlook-password", for: account, backgroundEnabled: backgroundEnabled)
            #expect(try KeychainStore.getSynchronizable(service: gmailService, account: record) == nil)
            #expect(try KeychainStore.getSynchronizable(service: outlookService, account: record) == nil)
            #expect(try !IMAPCredentialStore.applyFullSyncPolicy().contains { $0.account == account })
            #expect(try !OutlookIMAPCredentialStore.applyFullSyncPolicy().contains { $0.account == account })

            guard SettingsStore.supportsICloud else { return }
            defaults.set(UserCloudSyncPolicy.consentVersion, forKey: UserCloudSyncPolicy.consentKey)
            try IMAPCredentialStore.save(appPassword: "abcd efgh ijkl mnop", for: account, backgroundEnabled: backgroundEnabled)
            try OutlookIMAPCredentialStore.save(appPassword: "outlook-password", for: account, backgroundEnabled: backgroundEnabled)
            let originalGmail = try #require(try KeychainStore.getSynchronizable(service: gmailService, account: record))
            let originalOutlook = try #require(try KeychainStore.getSynchronizable(service: outlookService, account: record))

            // Keep shared registrations but remove this unique account's local slots
            // and pointers. Never clear another suite's selected-account preferences.
            for service in [IMAPCredentialStore.service, OutlookIMAPCredentialStore.service] {
                for slot in ["a", "b"] {
                    try KeychainStore.deleteDeviceOnly(service: service, account: "\(account).imap-slot-\(slot)")
                }
            }
            defaults.removeObject(forKey: IMAPCredentialStore.activeSlotKey(for: account))
            defaults.removeObject(forKey: OutlookIMAPCredentialStore.activeSlotKey(for: account))
            #expect(try IMAPCredentialStore.applyFullSyncPolicy().contains {
                $0.account == account && $0.preferenceKey == "pieroot.todo.imap.account"
            })
            #expect(try OutlookIMAPCredentialStore.applyFullSyncPolicy().contains {
                $0.account == account && $0.preferenceKey == "pieroot.todo.outlook.account"
            })
            #expect(try IMAPCredentialStore.credential(for: account) == "abcdefghijklmnop")
            #expect(try OutlookIMAPCredentialStore.credential(for: account) == "outlook-password")
            let expectedGmailAccess: DeviceOnlyCredentialAccess = defaults.bool(forKey: "pieroot.todo.imap.backgroundEnabled")
                ? .backgroundAfterFirstUnlock : .foregroundUserPresence
            let expectedOutlookAccess: DeviceOnlyCredentialAccess = defaults.bool(forKey: "pieroot.todo.outlook.backgroundEnabled")
                ? .backgroundAfterFirstUnlock : .foregroundUserPresence
            let gmailSlot = IMAPCredentialStore.activeSlot(for: account).rawValue
            let outlookSlot = OutlookIMAPCredentialStore.activeSlot(for: account).rawValue
            #expect(KeychainStore.deviceOnlyAccessForTesting(service: IMAPCredentialStore.service,
                                                            account: "\(account).imap-slot-\(gmailSlot)") == expectedGmailAccess)
            #expect(KeychainStore.deviceOnlyAccessForTesting(service: OutlookIMAPCredentialStore.service,
                                                            account: "\(account).imap-slot-\(outlookSlot)") == expectedOutlookAccess)

            // Explicit saves under full consent publish replacement secrets as well.
            try IMAPCredentialStore.save(appPassword: "new-password", for: account, backgroundEnabled: backgroundEnabled)
            try OutlookIMAPCredentialStore.save(appPassword: "new-outlook-password", for: account, backgroundEnabled: backgroundEnabled)
            let publishedGmail = try #require(try KeychainStore.getSynchronizable(service: gmailService, account: record))
            let publishedOutlook = try #require(try KeychainStore.getSynchronizable(service: outlookService, account: record))
            #expect(publishedGmail != originalGmail)
            #expect(publishedOutlook != originalOutlook)
            defaults.set(false, forKey: UserCloudSyncPolicy.syncKey)
            #expect(try !IMAPCredentialStore.applyFullSyncPolicy().contains { $0.account == account })
            #expect(try !OutlookIMAPCredentialStore.applyFullSyncPolicy().contains { $0.account == account })
            #expect(try KeychainStore.getSynchronizable(service: gmailService, account: record) == publishedGmail)
            #expect(try KeychainStore.getSynchronizable(service: outlookService, account: record) == publishedOutlook)
        }
    }

    @Test("Gmail local refresh preserves shared tokens both before consent and after opt-out")
    @MainActor
    func gmailCopiesPreserveSharedOnOptOut() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let priorPreferences = [UserCloudSyncPolicy.syncKey, UserCloudSyncPolicy.consentKey].map {
                ($0, defaults.object(forKey: $0))
            }
            let service = "pieroot.todo.gmail"
            let account = "portability-test-\(UUID().uuidString)"
            defer {
                try? KeychainStore.deleteChecked(service: service, account: account)
                // Fixture cleanup can remove its uniquely owned synthetic record
                // even when production revocation is correctly unauthorized.
                try? KeychainStore.deleteSynchronizable(service: service, account: account)
                for (key, value) in priorPreferences {
                    if let value { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }

            // A legacy shared token is not permission to publish, downgrade, or
            // delete it while full-scope consent is absent, regardless of raw toggle.
            try KeychainStore.setSynchronizable(service: service, account: account, data: Data("legacy-shared".utf8))
            defaults.removeObject(forKey: UserCloudSyncPolicy.consentKey)
            defaults.set(true, forKey: UserCloudSyncPolicy.syncKey)
            try KeychainStore.setChecked(service: service, account: account, value: "preconsent-local")
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("legacy-shared".utf8))
            defaults.set(false, forKey: UserCloudSyncPolicy.syncKey)
            try KeychainStore.setChecked(service: service, account: account, value: "preconsent-refresh")
            KeychainStore.applySyncPolicy()
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("legacy-shared".utf8))
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == Data("preconsent-refresh".utf8))

            guard SettingsStore.supportsICloud else { return }
            defaults.set(UserCloudSyncPolicy.consentVersion, forKey: UserCloudSyncPolicy.consentKey)
            defaults.set(true, forKey: UserCloudSyncPolicy.syncKey)
            // With no observed portable base, enabling must preserve a conflict
            // rather than roll a newer shared credential back to a local refresh.
            #expect(throws: GmailCredentialPortabilityError.conflict) {
                try KeychainStore.reconcileFullScopeGmailCredential(account: account)
            }
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("legacy-shared".utf8))
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == Data("preconsent-refresh".utf8))
            try KeychainStore.setGmailAfterExplicitSignIn(account: account, value: "full-shared")
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == Data("full-shared".utf8))
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("full-shared".utf8))
            defaults.set(false, forKey: UserCloudSyncPolicy.syncKey)
            try KeychainStore.setChecked(service: service, account: account, value: "new-local-refresh")
            #expect(try KeychainStore.getChecked(service: service, account: account) == "new-local-refresh")
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("full-shared".utf8))
            // Only explicit disconnect removes both registrations.
            try KeychainStore.deleteChecked(service: service, account: account)
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == nil)
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == nil)
        }
    }

    @Test("checked Gmail migration is disabled without consent and surfaces checked read errors")
    @MainActor
    func checkedGmailMigrationFailures() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let priorPreferences = [UserCloudSyncPolicy.syncKey, UserCloudSyncPolicy.consentKey].map {
                ($0, defaults.object(forKey: $0))
            }
            let service = "pieroot.todo.gmail"
            defer {
                KeychainStore.setReadFailureForTesting(service: service, status: nil)
                for (key, value) in priorPreferences {
                    if let value { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }
            defaults.set(true, forKey: UserCloudSyncPolicy.syncKey)
            defaults.removeObject(forKey: UserCloudSyncPolicy.consentKey)
            KeychainStore.setReadFailureForTesting(service: service, status: errSecInteractionNotAllowed)
            // If the disabled path tries to read anything this test throws.
            try KeychainStore.applyFullSyncPolicyChecked()
            guard SettingsStore.supportsICloud else { return }
            defaults.set(UserCloudSyncPolicy.consentVersion, forKey: UserCloudSyncPolicy.consentKey)
            #expect(throws: KeychainStoreError.security(errSecInteractionNotAllowed)) {
                try KeychainStore.reconcileFullScopeGmailCredential(account: "checked-read-\(UUID().uuidString)")
            }
        }
    }

    @MainActor
    private func withFullGmailAccount(_ body: (String) throws -> Void) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard SettingsStore.supportsICloud else { return }
            let defaults = UserDefaults.standard
            let preferences = [UserCloudSyncPolicy.syncKey, UserCloudSyncPolicy.consentKey].map {
                ($0, defaults.object(forKey: $0))
            }
            let account = "two-device-\(UUID().uuidString)"
            defer {
                KeychainStore.setGmailAuthorizationCaptureForTesting(nil)
                KeychainStore.setReadFailureForTesting(service: "pieroot.todo.gmail", status: nil)
                KeychainStore.setWriteFailureForTesting(service: "pieroot.todo.gmail", status: nil)
                KeychainStore.setWriteFailureForTesting(service: "pieroot.todo.gmail.portability-state.v1", status: nil)
                KeychainStore.setSynchronizableWriteFailureForTesting(service: "pieroot.todo.gmail", status: nil)
                try? KeychainStore.deleteChecked(service: "pieroot.todo.gmail", account: account)
                for (key, value) in preferences {
                    if let value { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }
            defaults.set(true, forKey: UserCloudSyncPolicy.syncKey)
            defaults.set(UserCloudSyncPolicy.consentVersion, forKey: UserCloudSyncPolicy.consentKey)
            try body(account)
        }
    }

    @Test("clean Gmail caches follow another device's newer token and never resurrect its deletion")
    @MainActor
    func cleanGmailCacheFollowsPortable() async throws {
        try await withFullGmailAccount { account in
            let service = "pieroot.todo.gmail"
            let metadataService = "pieroot.todo.gmail.portability-state.v1"
            try KeychainStore.setChecked(service: service, account: account, value: "T1")
            let oldMetadata = try #require(try KeychainStore.getDeviceOnly(service: metadataService, account: account))
            // A publishes T2 while B still has a clean T1 runtime copy/receipt.
            try KeychainStore.setSynchronizable(service: service, account: account, data: Data("T2".utf8))
            try KeychainStore.reconcileFullScopeGmailCredential(account: account)
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("T2".utf8))
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == Data("T2".utf8))
            #expect(try KeychainStore.getChecked(service: service, account: account) == "T2")

            // Reconstruct B's stale clean cache across local opt-out/re-enable.
            try KeychainStore.setDeviceOnly(service: service, account: account, data: Data("T1".utf8))
            try KeychainStore.setDeviceOnly(service: metadataService, account: account, data: oldMetadata)
            UserDefaults.standard.set(false, forKey: UserCloudSyncPolicy.syncKey)
            #expect(try KeychainStore.getChecked(service: service, account: account) == "T1")
            UserDefaults.standard.set(true, forKey: UserCloudSyncPolicy.syncKey)
            // A canonical read must also notice T2 without waiting for a migration.
            #expect(try KeychainStore.getChecked(service: service, account: account) == "T2")
            try KeychainStore.reconcileFullScopeGmailCredential(account: account)
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("T2".utf8))

            try KeychainStore.deleteSynchronizable(service: service, account: account)
            #expect(throws: GmailCredentialPortabilityError.conflict) {
                try KeychainStore.reconcileFullScopeGmailCredential(account: account)
            }
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == nil)
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == Data("T2".utf8))
            #expect(try KeychainStore.getChecked(service: service, account: account) == nil)
        }
    }

    @Test("failed Gmail publication retries only against its unchanged portable base", arguments: [false, true])
    @MainActor
    func pendingGmailPublication(remoteChanged: Bool) async throws {
        try await withFullGmailAccount { account in
            let service = "pieroot.todo.gmail"
            try KeychainStore.setChecked(service: service, account: account, value: "T1")
            KeychainStore.setSynchronizableWriteFailureForTesting(service: service, status: errSecNotAvailable)
            #expect(throws: KeychainStoreError.security(errSecNotAvailable)) {
                try KeychainStore.setChecked(service: service, account: account, value: "T2")
            }
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == Data("T2".utf8))
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("T1".utf8))
            #expect(try KeychainStore.getChecked(service: service, account: account) == "T2")
            UserDefaults.standard.set(false, forKey: UserCloudSyncPolicy.syncKey)
            try KeychainStore.reconcileFullScopeGmailCredential(account: account)
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("T1".utf8))
            KeychainStore.setSynchronizableWriteFailureForTesting(service: service, status: nil)
            if remoteChanged {
                try KeychainStore.setSynchronizable(service: service, account: account, data: Data("T3".utf8))
            }
            UserDefaults.standard.set(true, forKey: UserCloudSyncPolicy.syncKey)
            if remoteChanged {
                #expect(throws: GmailCredentialPortabilityError.conflict) {
                    try KeychainStore.reconcileFullScopeGmailCredential(account: account)
                }
                #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("T3".utf8))
                #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == Data("T2".utf8))
            } else {
                try KeychainStore.reconcileFullScopeGmailCredential(account: account)
                #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("T2".utf8))
                // A clean unchanged cache must not be republished on later passes.
                KeychainStore.setSynchronizableWriteFailureForTesting(service: service, status: errSecNotAvailable)
                try KeychainStore.reconcileFullScopeGmailCredential(account: account)
            }
        }
    }

    @Test("Gmail writes made after opt-out preserve the shared record until consent returns")
    @MainActor
    func optedOutGmailWriteRemainsPending() async throws {
        try await withFullGmailAccount { account in
            let service = "pieroot.todo.gmail"
            try KeychainStore.setChecked(service: service, account: account, value: "T1")
            UserDefaults.standard.set(false, forKey: UserCloudSyncPolicy.syncKey)
            // Local writes after opt-out must not even require a portable read.
            KeychainStore.setReadFailureForTesting(service: service, status: errSecInteractionNotAllowed)
            try KeychainStore.setChecked(service: service, account: account, value: "T2")
            KeychainStore.setReadFailureForTesting(service: service, status: nil)
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("T1".utf8))
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == Data("T2".utf8))
            UserDefaults.standard.set(true, forKey: UserCloudSyncPolicy.syncKey)
            try KeychainStore.reconcileFullScopeGmailCredential(account: account)
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("T2".utf8))
        }
    }

    @Test("failed local Gmail writes restore the prior journal and leave T1 readable", arguments: [false, true])
    @MainActor
    func failedLocalGmailWriteRestoresJournal(existingLocal: Bool) async throws {
        try await withFullGmailAccount { account in
            let service = "pieroot.todo.gmail"
            let metadataService = "pieroot.todo.gmail.portability-state.v1"
            try KeychainStore.setChecked(service: service, account: account, value: "T1")
            if !existingLocal {
                try KeychainStore.deleteDeviceOnly(service: service, account: account)
                try KeychainStore.deleteDeviceOnly(service: metadataService, account: account)
            }
            KeychainStore.setWriteFailureForTesting(service: service, status: errSecNotAvailable)
            #expect(throws: KeychainStoreError.security(errSecNotAvailable)) {
                try KeychainStore.setChecked(service: service, account: account, value: "T2")
            }
            let expectedLocal: Data? = existingLocal ? Data("T1".utf8) : nil
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == expectedLocal)
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("T1".utf8))
            if !existingLocal {
                #expect(try KeychainStore.getDeviceOnly(service: metadataService, account: account) == nil)
            }
            KeychainStore.setWriteFailureForTesting(service: service, status: nil)
            // Every call reloads persistent metadata; a failed T2 write must not
            // strand the unchanged T1 behind a mismatched pending digest.
            #expect(try KeychainStore.getChecked(service: service, account: account) == "T1")
            try KeychainStore.reconcileFullScopeGmailCredential(account: account)
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == Data("T1".utf8))
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("T1".utf8))
        }
    }

    @Test("Gmail sign-out survives delayed old tokens and only explicit authorization clears it", arguments: [false, true])
    @MainActor
    func gmailRevocationSurvivesDelayedRestore(failedReconnect: Bool) async throws {
        try await withFullGmailAccount { account in
            let service = "pieroot.todo.gmail"
            try KeychainStore.setGmailAfterExplicitSignIn(account: account, value: "T1")
            try KeychainStore.deleteChecked(service: service, account: account)
            try KeychainStore.setSynchronizable(service: service, account: account, data: Data("T1".utf8))
            // Calls reload durable state; delayed iCloud delivery after a restart
            // must neither import old bytes nor let stale refresh persistence sign in.
            #expect(try KeychainStore.getChecked(service: service, account: account) == nil)
            try KeychainStore.reconcileFullScopeGmailCredential(account: account)
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == nil)
            #expect(throws: GmailCredentialPortabilityError.revoked) {
                try KeychainStore.setChecked(service: service, account: account, value: "stale-refresh")
            }
            // The Keychain fence independently survives loss of local preferences.
            UserDefaults.standard.removeObject(forKey: "pieroot.todo.gmail.revoked.v1." + account)
            #expect(try KeychainStore.getChecked(service: service, account: account) == nil)
            #expect(throws: GmailCredentialPortabilityError.revoked) {
                try KeychainStore.setChecked(service: service, account: account, value: "stale-refresh")
            }
            if failedReconnect {
                KeychainStore.setWriteFailureForTesting(service: service, status: errSecNotAvailable)
                #expect(throws: KeychainStoreError.security(errSecNotAvailable)) {
                    try KeychainStore.setGmailAfterExplicitSignIn(account: account, value: "T2")
                }
                KeychainStore.setWriteFailureForTesting(service: service, status: nil)
                #expect(try KeychainStore.getChecked(service: service, account: account) == nil)
            }
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("T1".utf8))
            try KeychainStore.setGmailAfterExplicitSignIn(account: account, value: "T2")
            #expect(try KeychainStore.getChecked(service: service, account: account) == "T2")
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == Data("T2".utf8))
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("T2".utf8))
        }
    }

    @Test("Gmail sign-out retains a local guard and deletes credentials when Keychain fencing fails")
    @MainActor
    func gmailDeletionFenceFailureStillRevokesLocally() async throws {
        try await withFullGmailAccount { account in
            let service = "pieroot.todo.gmail"
            let metadataService = "pieroot.todo.gmail.portability-state.v1"
            try KeychainStore.setGmailAfterExplicitSignIn(account: account, value: "T1")
            KeychainStore.setWriteFailureForTesting(service: metadataService, status: errSecNotAvailable)
            do {
                try KeychainStore.deleteChecked(service: service, account: account)
                Issue.record("expected Keychain fence failure")
            } catch let error as GmailCredentialDeletionError {
                #expect(error.fenceError != nil)
                #expect(error.credentialError == nil)
            }
            KeychainStore.setWriteFailureForTesting(service: metadataService, status: nil)
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == nil)
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == nil)
            try KeychainStore.setSynchronizable(service: service, account: account, data: Data("T1".utf8))
            #expect(try KeychainStore.getChecked(service: service, account: account) == nil)
            try KeychainStore.reconcileFullScopeGmailCredential(account: account)
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == nil)
        }
    }

    @Test("Gmail expired read and reconciliation leases cannot restore an old pass", arguments: ["read", "reconcile"])
    @MainActor
    func gmailExpiredRestoreLease(operation: String) async throws {
        try await withFullGmailAccount { account in
            let service = "pieroot.todo.gmail"
            try KeychainStore.setGmailAfterExplicitSignIn(account: account, value: "T1")
            try KeychainStore.setSynchronizable(service: service, account: account, data: Data("T2".utf8))
            var captures = 0
            KeychainStore.setGmailAuthorizationCaptureForTesting { _ in
                captures += 1
                var firstCheck = true
                return {
                    defer { firstCheck = false }
                    return firstCheck
                }
            }
            if operation == "read" {
                #expect(throws: KeychainStoreError.authorizationChanged) {
                    try KeychainStore.getChecked(service: service, account: account)
                }
            } else {
                #expect(throws: KeychainStoreError.authorizationChanged) {
                    try KeychainStore.reconcileFullScopeGmailCredential(account: account)
                }
            }
            #expect(captures == 1)
            #expect(UserCloudSyncPolicy.isEnabled)
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == Data("T1".utf8))
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("T2".utf8))
            KeychainStore.setGmailAuthorizationCaptureForTesting(nil)
            #expect(try KeychainStore.getChecked(service: service, account: account) == "T2")
        }
    }

    @Test("Gmail lease expiry during local or portable commit retains pending publication",
          arguments: ["local", "portable"])
    @MainActor
    func gmailExpiredPublicationLease(stage: String) async throws {
        try await withFullGmailAccount { account in
            let service = "pieroot.todo.gmail"
            let next = Data("T2".utf8)
            try KeychainStore.setGmailAfterExplicitSignIn(account: account, value: "T1")
            var captures = 0
            KeychainStore.setGmailAuthorizationCaptureForTesting { _ in
                captures += 1
                var invalidated = false
                return {
                    let value: Data?
                    if stage == "local" {
                        value = try? KeychainStore.getDeviceOnly(service: service, account: account)
                    } else {
                        value = try? KeychainStore.getSynchronizable(service: service, account: account)
                    }
                    if value == next { invalidated = true }
                    return !invalidated
                }
            }
            #expect(throws: KeychainStoreError.authorizationChanged) {
                try KeychainStore.setChecked(service: service, account: account, value: "T2")
            }
            #expect(captures == 1)
            #expect(UserCloudSyncPolicy.isEnabled)
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == next)
            let expectedPortable = stage == "local" ? Data("T1".utf8) : next
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == expectedPortable)
            let metadata = try #require(try KeychainStore.getDeviceOnly(service: "pieroot.todo.gmail.portability-state.v1", account: account))
            let state = try #require(try JSONSerialization.jsonObject(with: metadata) as? [String: Any])
            #expect(state["pending"] as? Bool == true)
            KeychainStore.setGmailAuthorizationCaptureForTesting(nil)
            if stage == "portable" {
                // A new pass may acknowledge the completed write without issuing
                // another portable mutation under the expired pass's authority.
                KeychainStore.setSynchronizableWriteFailureForTesting(service: service, status: errSecNotAvailable)
            }
            try KeychainStore.reconcileFullScopeGmailCredential(account: account)
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == next)
        }
    }

    @Test("Gmail opt-out revocation lease expiry still deletes locally without a shared delete")
    @MainActor
    func gmailExpiredDeletionLease() async throws {
        try await withFullGmailAccount { account in
            let service = "pieroot.todo.gmail"
            try KeychainStore.setGmailAfterExplicitSignIn(account: account, value: "T1")
            UserDefaults.standard.set(false, forKey: UserCloudSyncPolicy.syncKey)
            var revocationCapture = false
            KeychainStore.setGmailAuthorizationCaptureForTesting { forRevocation in
                revocationCapture = forRevocation
                var invalidated = false
                return {
                    if (try? KeychainStore.getDeviceOnly(service: service, account: account)) == nil { invalidated = true }
                    return !invalidated
                }
            }
            do {
                try KeychainStore.deleteChecked(service: service, account: account)
                Issue.record("expected captured authorization expiry")
            } catch let error as GmailCredentialDeletionError {
                #expect(error.credentialError as? KeychainStoreError == .authorizationChanged)
                #expect(error.fenceError == nil)
            }
            #expect(revocationCapture)
            #expect(UserCloudSyncPolicy.canRevokePortableCredentials)
            #expect(try KeychainStore.getDeviceOnly(service: service, account: account) == nil)
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == Data("T1".utf8))
            KeychainStore.setGmailAuthorizationCaptureForTesting(nil)
            try KeychainStore.deleteChecked(service: service, account: account)
            #expect(try KeychainStore.getSynchronizable(service: service, account: account) == nil)
        }
    }

    @Test("same-provider saves and access migration retain one committed local slot", arguments: [false, true])
    @MainActor
    func concurrentProviderTransactions(outlook: Bool) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let account = "concurrent-\(UUID().uuidString.lowercased())@example.com"
            let service = outlook ? OutlookIMAPCredentialStore.service : IMAPCredentialStore.service
            defer {
                if outlook { try? OutlookIMAPCredentialStore.delete(for: account) }
                else { try? IMAPCredentialStore.delete(for: account) }
            }
            if outlook {
                try OutlookIMAPCredentialStore.save(appPassword: "initial-secret", for: account, backgroundEnabled: false)
            } else {
                try IMAPCredentialStore.save(appPassword: "initial-secret", for: account, backgroundEnabled: false)
            }
            DispatchQueue.concurrentPerform(iterations: 24) { index in
                do {
                    switch index % 3 {
                    case 0:
                        if outlook {
                            try OutlookIMAPCredentialStore.save(appPassword: "secret-\(index)", for: account, backgroundEnabled: false)
                        } else {
                            try IMAPCredentialStore.save(appPassword: "secret-\(index)", for: account, backgroundEnabled: false)
                        }
                    case 1:
                        if outlook { try OutlookIMAPCredentialStore.migrateAccess(for: account, toBackground: index.isMultiple(of: 2)) }
                        else { try IMAPCredentialStore.migrateAccess(for: account, toBackground: index.isMultiple(of: 2)) }
                    default:
                        if outlook { _ = try OutlookIMAPCredentialStore.credential(for: account) }
                        else { _ = try IMAPCredentialStore.credential(for: account) }
                    }
                } catch {
                    Issue.record(error)
                }
            }
            let slot = outlook ? OutlookIMAPCredentialStore.activeSlot(for: account) : IMAPCredentialStore.activeSlot(for: account)
            #expect(try KeychainStore.getDeviceOnly(service: service, account: "\(account).imap-slot-\(slot.rawValue)") != nil)
            #expect(try KeychainStore.getDeviceOnly(service: service, account: "\(account).imap-slot-\(slot.other.rawValue)") == nil)
        }
    }
}
