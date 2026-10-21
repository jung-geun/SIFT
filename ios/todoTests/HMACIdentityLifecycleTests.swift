import CryptoKit
import Foundation
import Security
import SwiftData
import Testing
@testable import todo

@Suite("Portable HMAC identities", .serialized)
@MainActor
struct HMACIdentityLifecycleTests {
    private let vocabularyService = "pieroot.todo.vocabulary"
    private let ledgerService = "pieroot.todo.mail-analysis-ledger"
    private let primaryAccount = "hmac-key-v1"
    private let policyPreference = "pieroot.todo.iCloudSyncEnabled"

    private func memberAccount(_ data: Data) -> String {
        primaryAccount + ".member-v1." + HMACIdentityKeyFamily.identifier(data)
    }

    private func digest(_ raw: String, key: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(raw.utf8), using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private func reset() throws {
        for service in [vocabularyService, ledgerService] {
            KeychainStore.setReadFailureForTesting(service: service, status: nil)
            KeychainStore.setWriteFailureForTesting(service: service, status: nil)
            KeychainStore.setDeleteFailureForTesting(service: service, status: nil)
            try KeychainStore.deleteChecked(service: service)
        }
        UserDefaults.standard.set(false, forKey: policyPreference)
        UserDefaults.standard.removeObject(forKey: UserCloudSyncPolicy.consentKey)
    }

    private func savedPolicy() -> [String: Any] {
        let defaults = UserDefaults.standard
        var values: [String: Any] = [:]
        values[policyPreference] = defaults.object(forKey: policyPreference)
        values[UserCloudSyncPolicy.consentKey] = defaults.object(forKey: UserCloudSyncPolicy.consentKey)
        return values
    }

    private func enableFullSync() {
        UserDefaults.standard.set(UserCloudSyncPolicy.consentVersion, forKey: UserCloudSyncPolicy.consentKey)
        UserDefaults.standard.set(true, forKey: policyPreference)
    }

    private func restore(_ preference: [String: Any]) {
        try? reset()
        for key in [policyPreference, UserCloudSyncPolicy.consentKey] {
            if let value = preference[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func removeLocalFamily(service: String) throws {
        try KeychainStore.deleteDeviceOnly(service: service, account: primaryAccount)
        try KeychainStore.deleteDeviceOnly(service: service, account: primaryAccount + ".family-v1")
    }

    @Test("vocabulary publishes only on opt-in and opt-out never deletes or rotates",
          .enabled(if: SettingsStore.supportsICloud))
    func vocabularyPublishing() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer { restore(preference) }
            try reset()
            let store = VocabularyHMACKeyStore()
            let original = try await store.readOrCreate()
            try await store.applyFullSyncPolicy()
            #expect(try KeychainStore.synchronizableAccounts(service: vocabularyService).isEmpty)
            // Legacy task-only iCloud consent does not authorize publishing HMAC keys.
            UserDefaults.standard.set(true, forKey: policyPreference)
            #expect(UserCloudSyncPolicy.isEnabled == false)
            try await store.applyFullSyncPolicy()
            try MailAnalysisLedgerKeyStore.applyFullSyncPolicy()
            #expect(try KeychainStore.synchronizableAccounts(service: vocabularyService).isEmpty)
            #expect(try KeychainStore.synchronizableAccounts(service: ledgerService).isEmpty)
            enableFullSync()
            try await store.applyFullSyncPolicy()
            #expect(try KeychainStore.getSynchronizable(service: vocabularyService, account: memberAccount(original)) == original)
            UserDefaults.standard.set(false, forKey: policyPreference)
            KeychainStore.setDeleteFailureForTesting(service: vocabularyService, status: errSecAuthFailed)
            try await store.applyFullSyncPolicy()
            #expect(try await store.readOrCreate() == original)
            #expect(try KeychainStore.getSynchronizable(service: vocabularyService, account: memberAccount(original)) == original)
        }
    }

    @Test("portable family retains differing originals and selects a stored verifier after restore",
          .enabled(if: SettingsStore.supportsICloud))
    func vocabularyFamilyRestore() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer { restore(preference) }
            try reset()
            let first = Data(repeating: 1, count: 32)
            let second = Data(repeating: 2, count: 32)
            try KeychainStore.setDeviceOnly(service: vocabularyService, account: primaryAccount, data: first)
            enableFullSync()
            let store = VocabularyHMACKeyStore()
            try await store.applyFullSyncPolicy()
            // A second preexisting device identity joins the same cloud family.
            try removeLocalFamily(service: vocabularyService)
            try KeychainStore.setDeviceOnly(service: vocabularyService, account: primaryAccount, data: second)
            try await store.applyFullSyncPolicy()
            #expect(try KeychainStore.synchronizableAccounts(service: vocabularyService).count == 2)
            let selected = try await store.keys(matching: [VocabularyHMACKeyStore.verifier(first)])
            #expect(selected.first == first)
            #expect(Set(selected) == Set([first, second]))
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount) == second)
            try removeLocalFamily(service: vocabularyService)
            let restored = try await VocabularyHMACKeyStore().keys(matching: [VocabularyHMACKeyStore.verifier(second)])
            #expect(restored.first == second)
            #expect(Set(restored) == Set([first, second]))
            #expect(try KeychainStore.synchronizableAccounts(service: vocabularyService).count == 2)
        }
    }

    private func vocabularyContainer(verifier: String, sourceKey: String, evidenceKey: String) throws -> ModelContainer {
        let schema = Schema([VocabularyStoreMetadata.self, VocabularySourceState.self,
                             VocabularyObservation.self, MeetingGlossaryTerm.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let metadata = VocabularyStoreMetadata()
        metadata.schemaRepairVersion = 1
        metadata.hmacVerifier = verifier
        context.insert(metadata)
        let state = VocabularySourceState()
        state.sourceKey = sourceKey
        state.evidenceGroupKey = evidenceKey
        state.contentFingerprint = "unchanged"
        state.extractorVersion = UserVocabularyExtractor.version
        state.enrichmentStatusRaw = VocabularyEnrichmentStatus.completed.rawValue
        context.insert(state)
        let observation = VocabularyObservation()
        observation.canonicalKey = "learned"
        observation.canonicalDisplay = "Learned"
        observation.sourceKey = sourceKey
        observation.evidenceGroupKey = evidenceKey
        observation.sourceGeneration = state.generation
        context.insert(observation)
        let term = MeetingGlossaryTerm(canonical: "Learned")
        term.canonicalKey = "learned"
        term.rejectedAt = Date(timeIntervalSince1970: 123)
        context.insert(term)
        let unconfirmed = MeetingGlossaryTerm(canonical: "Unconfirmed")
        unconfirmed.canonicalKey = "unconfirmed"
        context.insert(unconfirmed)
        try context.save()
        return container
    }

    @Test("foreign metadata preserves learned rows, decisions, verifier and local original")
    func foreignMetadataPreservation() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer { restore(preference) }
            try reset()
            let local = Data(repeating: 3, count: 32)
            let foreign = Data(repeating: 4, count: 32)
            try KeychainStore.setDeviceOnly(service: vocabularyService, account: primaryAccount, data: local)
            let verifier = VocabularyHMACKeyStore.verifier(foreign)
            let container = try vocabularyContainer(verifier: verifier, sourceKey: "foreign-source", evidenceKey: "foreign-evidence")
            let service = UserVocabularyService(modelContainer: container)
            _ = try await service.list()
            try await service.applyFullSyncPolicy()
            let context = ModelContext(container)
            #expect(try context.fetch(FetchDescriptor<VocabularyStoreMetadata>()).first?.hmacVerifier == verifier)
            #expect(try context.fetch(FetchDescriptor<VocabularySourceState>()).first?.sourceKey == "foreign-source")
            #expect(try context.fetch(FetchDescriptor<VocabularyObservation>()).first?.evidenceGroupKey == "foreign-evidence")
            let terms = try context.fetch(FetchDescriptor<MeetingGlossaryTerm>())
            #expect(terms.count == 2)
            #expect(terms.first { $0.canonicalKey == "learned" }?.rejectedAt == Date(timeIntervalSince1970: 123))
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount) == local)
            #expect(try KeychainStore.synchronizableAccounts(service: vocabularyService).isEmpty)
        }
    }

    @Test("provenance matches every family key without duplicating restored sources",
          .enabled(if: SettingsStore.supportsICloud))
    func provenanceFamilyMatching() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer { restore(preference) }
            try reset()
            let active = Data(repeating: 5, count: 32)
            let original = Data(repeating: 6, count: 32)
            let sourceKey = digest("source-id", key: original)
            let evidenceKey = digest("evidence-id", key: original)
            try KeychainStore.setDeviceOnly(service: vocabularyService, account: primaryAccount, data: active)
            try KeychainStore.setSynchronizable(service: vocabularyService, account: memberAccount(original), data: original)
            enableFullSync()
            let container = try vocabularyContainer(verifier: VocabularyHMACKeyStore.verifier(active), sourceKey: sourceKey, evidenceKey: evidenceKey)
            // Merged stores can retain more than one metadata verifier, without a schema change.
            let mergedContext = ModelContext(container)
            let otherMetadata = VocabularyStoreMetadata()
            otherMetadata.schemaRepairVersion = 1
            otherMetadata.hmacVerifier = VocabularyHMACKeyStore.verifier(original)
            mergedContext.insert(otherMetadata)
            try mergedContext.save()
            let service = UserVocabularyService(modelContainer: container)
            let document = VocabularySourceDocument(source: .todo, stableID: "source-id", evidenceGroupID: "evidence-id",
                                                    contentFingerprint: "unchanged", fields: [])
            #expect(try await service.observe(document) == nil)
            let context = ModelContext(container)
            #expect(try context.fetch(FetchDescriptor<VocabularySourceState>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<VocabularyObservation>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<VocabularySourceState>()).first?.evidenceGroupKey == evidenceKey)
            #expect(try context.fetch(FetchDescriptor<VocabularyStoreMetadata>()).count == 2)
        }
    }

    @Test("missing restored original does not generate a replacement key")
    func missingOriginalPreservesMetadata() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer { restore(preference) }
            try reset()
            let container = try vocabularyContainer(verifier: "not-yet-delivered", sourceKey: "source", evidenceKey: "evidence")
            let service = UserVocabularyService(modelContainer: container)
            await #expect(throws: VocabularyServiceError.originalKeyUnavailable) { _ = try await service.list() }
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount) == nil)
            let context = ModelContext(container)
            #expect(try context.fetch(FetchDescriptor<VocabularyObservation>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<MeetingGlossaryTerm>()).count == 2)
        }
    }

    @Test("vocabulary read and publication failures retain original bytes",
          .enabled(if: SettingsStore.supportsICloud))
    func vocabularyKeychainFailures() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer { restore(preference) }
            try reset()
            let original = Data(repeating: 7, count: 32)
            try KeychainStore.setDeviceOnly(service: vocabularyService, account: primaryAccount, data: original)
            let store = VocabularyHMACKeyStore()
            KeychainStore.setReadFailureForTesting(service: vocabularyService, status: errSecInteractionNotAllowed)
            await #expect(throws: KeychainStoreError.security(errSecInteractionNotAllowed)) { _ = try await store.readOrCreate() }
            KeychainStore.setReadFailureForTesting(service: vocabularyService, status: nil)
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount) == original)
            _ = try await store.readOrCreate()
            enableFullSync()
            KeychainStore.setWriteFailureForTesting(service: vocabularyService, status: errSecAuthFailed)
            await #expect(throws: KeychainStoreError.security(errSecAuthFailed)) { try await store.applyFullSyncPolicy() }
            KeychainStore.setWriteFailureForTesting(service: vocabularyService, status: nil)
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount) == original)
            #expect(try KeychainStore.synchronizableAccounts(service: vocabularyService).isEmpty)
            try await store.applyFullSyncPolicy()
            #expect(try KeychainStore.getSynchronizable(service: vocabularyService, account: memberAccount(original)) == original)
        }
    }

    @Test("ledger opt-in retains legacy identity, restores it, and opt-out leaves remote entries",
          .enabled(if: SettingsStore.supportsICloud))
    func ledgerPublishingAndRestore() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer { restore(preference) }
            try reset()
            let original = Data(repeating: 8, count: 32)
            try KeychainStore.setDeviceOnly(service: ledgerService, account: "key", data: Data(original.base64EncodedString().utf8))
            #expect(try bytes(MailAnalysisLedgerKeyStore.key()) == original)
            let schema = Schema([MailAnalysisLedgerRecord.self])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let ledger = MailAnalysisLedgerStore(container: container)
            let fingerprint = MailAnalysisFingerprint.make(provider: "gmail-imap", canonicalAccount: "a@example.com",
                                                           gmailMessageID: "message", key: try MailAnalysisLedgerKeyStore.key())
            #expect(try ledger.claim(fingerprint, revision: 1))
            try ledger.markAnalyzed(fingerprint, revision: 1)
            try MailAnalysisLedgerKeyStore.applyFullSyncPolicy()
            #expect(try KeychainStore.synchronizableAccounts(service: ledgerService).isEmpty)
            enableFullSync()
            try MailAnalysisLedgerKeyStore.applyFullSyncPolicy()
            #expect(try KeychainStore.getSynchronizable(service: ledgerService, account: memberAccount(original)) == original)
            try removeLocalFamily(service: ledgerService)
            try KeychainStore.deleteDeviceOnly(service: ledgerService, account: "key")
            #expect(try bytes(MailAnalysisLedgerKeyStore.key()) == original)
            let restoredFingerprint = MailAnalysisFingerprint.make(provider: "gmail-imap", canonicalAccount: "a@example.com",
                                                                   gmailMessageID: "message", key: try MailAnalysisLedgerKeyStore.key())
            #expect(restoredFingerprint == fingerprint)
            #expect(try ledger.claimOutcome(restoredFingerprint, revision: 1) == .alreadyAnalyzed)
            UserDefaults.standard.set(false, forKey: policyPreference)
            KeychainStore.setDeleteFailureForTesting(service: ledgerService, status: errSecAuthFailed)
            try MailAnalysisLedgerKeyStore.applyFullSyncPolicy()
            #expect(try bytes(MailAnalysisLedgerKeyStore.key()) == original)
            #expect(try KeychainStore.getSynchronizable(service: ledgerService, account: memberAccount(original)) == original)
        }
    }

    @Test("ledger never generates or overwrites after read errors or malformed legacy values")
    func ledgerReadAndDecodeFailures() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer { restore(preference) }
            try reset()
            let original = Data(repeating: 9, count: 32)
            let encoded = original.base64EncodedString()
            try KeychainStore.setDeviceOnly(service: ledgerService, account: "key", data: Data(encoded.utf8))
            KeychainStore.setReadFailureForTesting(service: ledgerService, status: errSecInteractionNotAllowed)
            #expect(throws: KeychainStoreError.security(errSecInteractionNotAllowed)) { _ = try MailAnalysisLedgerKeyStore.key() }
            KeychainStore.setReadFailureForTesting(service: ledgerService, status: nil)
            #expect(try KeychainStore.getDeviceOnly(service: ledgerService, account: "key") == Data(encoded.utf8))
            #expect(try KeychainStore.getDeviceOnly(service: ledgerService, account: primaryAccount) == nil)
            try KeychainStore.setDeviceOnly(service: ledgerService, account: "key", data: Data("corrupt".utf8))
            #expect(throws: VocabularyServiceError.invalidKey) { _ = try MailAnalysisLedgerKeyStore.key() }
            #expect(try KeychainStore.getDeviceOnly(service: ledgerService, account: "key") == Data("corrupt".utf8))
            #expect(try KeychainStore.getDeviceOnly(service: ledgerService, account: primaryAccount) == nil)
        }
    }

    @Test("ledger failed writes preserve legacy and local original keys",
          .enabled(if: SettingsStore.supportsICloud))
    func ledgerWriteFailures() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer { restore(preference) }
            try reset()
            let original = Data(repeating: 10, count: 32)
            let encoded = original.base64EncodedString()
            try KeychainStore.setDeviceOnly(service: ledgerService, account: "key", data: Data(encoded.utf8))
            KeychainStore.setWriteFailureForTesting(service: ledgerService, status: errSecAuthFailed)
            #expect(throws: KeychainStoreError.security(errSecAuthFailed)) { _ = try MailAnalysisLedgerKeyStore.key() }
            #expect(try KeychainStore.getDeviceOnly(service: ledgerService, account: "key") == Data(encoded.utf8))
            KeychainStore.setWriteFailureForTesting(service: ledgerService, status: nil)
            #expect(try bytes(MailAnalysisLedgerKeyStore.key()) == original)
            enableFullSync()
            KeychainStore.setWriteFailureForTesting(service: ledgerService, status: errSecAuthFailed)
            #expect(throws: KeychainStoreError.security(errSecAuthFailed)) { try MailAnalysisLedgerKeyStore.applyFullSyncPolicy() }
            KeychainStore.setWriteFailureForTesting(service: ledgerService, status: nil)
            #expect(try KeychainStore.getDeviceOnly(service: ledgerService, account: primaryAccount) == original)
            #expect(try KeychainStore.getDeviceOnly(service: ledgerService, account: "key") == Data(encoded.utf8))
            #expect(try KeychainStore.synchronizableAccounts(service: ledgerService).isEmpty)
            try MailAnalysisLedgerKeyStore.applyFullSyncPolicy()
            #expect(try KeychainStore.getSynchronizable(service: ledgerService, account: memberAccount(original)) == original)
        }
    }

    @Test("ledger preserves a foreign family without replacing its local original",
          .enabled(if: SettingsStore.supportsICloud))
    func ledgerFamilyPreservation() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer { restore(preference) }
            try reset()
            let local = Data(repeating: 11, count: 32)
            let foreign = Data(repeating: 12, count: 32)
            try KeychainStore.setDeviceOnly(service: ledgerService, account: primaryAccount, data: local)
            try KeychainStore.setSynchronizable(service: ledgerService, account: memberAccount(foreign), data: foreign)
            enableFullSync()
            try MailAnalysisLedgerKeyStore.applyFullSyncPolicy()
            #expect(try bytes(MailAnalysisLedgerKeyStore.key()) == local)
            #expect(try Set(MailAnalysisLedgerKeyStore.keysChecked().map(bytes)) == Set([local, foreign]))
            #expect(try KeychainStore.getSynchronizable(service: ledgerService, account: memberAccount(foreign)) == foreign)
            #expect(try KeychainStore.getSynchronizable(service: ledgerService, account: memberAccount(local)) == local)
            UserDefaults.standard.set(false, forKey: policyPreference)
            try MailAnalysisLedgerKeyStore.applyFullSyncPolicy()
            #expect(try Set(MailAnalysisLedgerKeyStore.keysChecked().map(bytes)) == Set([local, foreign]))
        }
    }

    @Test("malformed portable family fails without altering original or remote entries",
          .enabled(if: SettingsStore.supportsICloud))
    func malformedFamilyPreservation() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer { restore(preference) }
            try reset()
            let original = Data(repeating: 13, count: 32)
            let foreign = Data(repeating: 14, count: 32)
            try KeychainStore.setDeviceOnly(service: vocabularyService, account: primaryAccount, data: original)
            let badAccount = memberAccount(original)
            try KeychainStore.setSynchronizable(service: vocabularyService, account: badAccount, data: foreign)
            enableFullSync()
            await #expect(throws: VocabularyServiceError.invalidKey) { try await VocabularyHMACKeyStore().applyFullSyncPolicy() }
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount) == original)
            #expect(try KeychainStore.getSynchronizable(service: vocabularyService, account: badAccount) == foreign)
            #expect(try KeychainStore.synchronizableAccounts(service: vocabularyService).count == 1)
        }
    }

    @Test("ledger migrates both differing legacy local and cloud keys without overwriting either",
          .enabled(if: SettingsStore.supportsICloud))
    func divergentLegacyLedgerKeys() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer { restore(preference) }
            try reset()
            let local = Data(repeating: 15, count: 32)
            let portable = Data(repeating: 16, count: 32)
            let localEncoded = Data(local.base64EncodedString().utf8)
            let portableEncoded = Data(portable.base64EncodedString().utf8)
            try KeychainStore.setDeviceOnly(service: ledgerService, account: "key", data: localEncoded)
            try KeychainStore.setSynchronizable(service: ledgerService, account: "key", data: portableEncoded)
            enableFullSync()
            try MailAnalysisLedgerKeyStore.applyFullSyncPolicy()
            #expect(try bytes(MailAnalysisLedgerKeyStore.key()) == local)
            #expect(try Set(MailAnalysisLedgerKeyStore.keysChecked().map(bytes)) == Set([local, portable]))
            #expect(try KeychainStore.getDeviceOnly(service: ledgerService, account: "key") == localEncoded)
            #expect(try KeychainStore.getSynchronizable(service: ledgerService, account: "key") == portableEncoded)
            #expect(try KeychainStore.getSynchronizable(service: ledgerService, account: memberAccount(local)) == local)
            #expect(try KeychainStore.getSynchronizable(service: ledgerService, account: memberAccount(portable)) == portable)
        }
    }

    @Test("cloud-only legacy ledger identity requires full-policy consent",
          .enabled(if: SettingsStore.supportsICloud))
    func cloudOnlyLegacyLedgerPolicyGate() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer { restore(preference) }
            try reset()
            let portable = Data(repeating: 17, count: 32)
            let encoded = Data(portable.base64EncodedString().utf8)
            try KeychainStore.setSynchronizable(service: ledgerService, account: "key", data: encoded)
            // The legacy task-only toggle is insufficient, even with a remote key.
            UserDefaults.standard.set(true, forKey: policyPreference)
            #expect(UserCloudSyncPolicy.isEnabled == false)
            try MailAnalysisLedgerKeyStore.applyFullSyncPolicy()
            #expect(try KeychainStore.getDeviceOnly(service: ledgerService, account: primaryAccount) == nil)
            let local = try bytes(MailAnalysisLedgerKeyStore.key())
            #expect(local != portable)
            #expect(try MailAnalysisLedgerKeyStore.keysChecked().count == 1)
            #expect(try KeychainStore.getSynchronizable(service: ledgerService, account: "key") == encoded)
            #expect(try KeychainStore.synchronizableAccounts(service: ledgerService) == ["key"])
            enableFullSync()
            try MailAnalysisLedgerKeyStore.applyFullSyncPolicy()
            #expect(try bytes(MailAnalysisLedgerKeyStore.key()) == local)
            #expect(try Set(MailAnalysisLedgerKeyStore.keysChecked().map(bytes)) == Set([local, portable]))
            #expect(try KeychainStore.getSynchronizable(service: ledgerService, account: "key") == encoded)
        }
    }

    /// Injects an epoch change at a precise lease check, without timing or sleeps.
    /// The real captured lease must stay revoked even after the same account and
    /// full policy are restored before the interrupted operation resumes.
    private nonisolated final class RevocationInterleaving: @unchecked Sendable {
        private static let account = "hmac-lifecycle-test-account"
        private let lock = NSLock()
        private let revokeAtCheck: Int
        private var checks = 0
        private var captures = 0

        init(revokeAtCheck: Int) {
            self.revokeAtCheck = revokeAtCheck
            UserCloudSyncPolicy.authorizeAccount(Self.account)
        }

        var captureCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return captures
        }

        func capture() -> @Sendable () -> Bool {
            lock.lock()
            captures += 1
            lock.unlock()
            let lease = UserCloudSyncPolicy.captureAuthorization()
            return { self.check(lease) }
        }

        private func check(_ lease: @Sendable () -> Bool) -> Bool {
            lock.lock()
            checks += 1
            let shouldRevoke = checks == revokeAtCheck
            lock.unlock()
            if shouldRevoke {
                UserDefaults.standard.set(false, forKey: UserCloudSyncPolicy.syncKey)
                UserCloudSyncPolicy.revokeAccountAuthorization()
                UserDefaults.standard.set(UserCloudSyncPolicy.consentVersion, forKey: UserCloudSyncPolicy.consentKey)
                UserDefaults.standard.set(true, forKey: UserCloudSyncPolicy.syncKey)
                UserCloudSyncPolicy.authorizeAccount(Self.account)
            }
            return lease()
        }
    }

    @Test("vocabulary full reconciliation carries one lease across actor refreshes",
          .enabled(if: SettingsStore.supportsICloud))
    func vocabularyServiceUsesOneAuthorization() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer {
                HMACIdentityKeyFamily.captureAuthorizationForTesting = nil
                UserCloudSyncPolicy.revokeAccountAuthorization()
                restore(preference)
            }
            try reset()
            let original = Data(repeating: 44, count: 32)
            try KeychainStore.setDeviceOnly(service: vocabularyService, account: primaryAccount, data: original)
            try KeychainStore.setDeviceOnly(service: vocabularyService, account: primaryAccount + ".family-v1",
                                          data: JSONEncoder().encode([original]))
            try KeychainStore.setSynchronizable(service: vocabularyService, account: memberAccount(original), data: original)
            let verifier = VocabularyHMACKeyStore.verifier(original)
            let container = try vocabularyContainer(verifier: verifier, sourceKey: "retained-source", evidenceKey: "retained-evidence")
            let service = UserVocabularyService(modelContainer: container)
            enableFullSync()
            let interleaving = RevocationInterleaving(revokeAtCheck: Int.max)
            HMACIdentityKeyFamily.captureAuthorizationForTesting = { interleaving.capture() }
            try await service.applyFullSyncPolicy()
            #expect(interleaving.captureCount == 1)
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount) == original)
            #expect(try ModelContext(container).fetch(FetchDescriptor<VocabularyStoreMetadata>()).first?.hmacVerifier == verifier)
        }
    }

    @Test("disabled vocabulary reconciliation neither creates an identity nor changes learned metadata")
    func disabledVocabularyServiceIsNoOp() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer { restore(preference) }
            try reset()
            let container = try vocabularyContainer(verifier: "", sourceKey: "retained-source", evidenceKey: "retained-evidence")
            let service = UserVocabularyService(modelContainer: container)
            try await service.applyFullSyncPolicy()
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount) == nil)
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount + ".family-v1") == nil)
            let context = ModelContext(container)
            #expect(try context.fetch(FetchDescriptor<VocabularyStoreMetadata>()).first?.hmacVerifier == "")
            #expect(try context.fetch(FetchDescriptor<MeetingGlossaryTerm>()).count == 2)
        }
    }

    @Test("revoked portable read preserves local family, learned rows and verifier",
          .enabled(if: SettingsStore.supportsICloud))
    func revokedPortableReadPreservesVocabulary() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer {
                HMACIdentityKeyFamily.captureAuthorizationForTesting = nil
                UserCloudSyncPolicy.revokeAccountAuthorization()
                restore(preference)
            }
            try reset()
            let local = Data(repeating: 18, count: 32)
            let foreign = Data(repeating: 19, count: 32)
            let cached = try JSONEncoder().encode([local])
            try KeychainStore.setDeviceOnly(service: vocabularyService, account: primaryAccount, data: local)
            try KeychainStore.setDeviceOnly(service: vocabularyService, account: primaryAccount + ".family-v1", data: cached)
            try KeychainStore.setSynchronizable(service: vocabularyService, account: memberAccount(foreign), data: foreign)
            let verifier = VocabularyHMACKeyStore.verifier(local)
            let container = try vocabularyContainer(verifier: verifier, sourceKey: "retained-source", evidenceKey: "retained-evidence")
            let service = UserVocabularyService(modelContainer: container)
            _ = try await service.list()
            enableFullSync()
            // Initial capture, enumeration guard, member-read guard, then the
            // read-complete check: revoke after portable bytes were collected.
            let interleaving = RevocationInterleaving(revokeAtCheck: 4)
            HMACIdentityKeyFamily.captureAuthorizationForTesting = { interleaving.capture() }
            await #expect(throws: KeychainStoreError.authorizationChanged) { try await service.applyFullSyncPolicy() }
            #expect(interleaving.captureCount == 1)
            #expect(UserCloudSyncPolicy.isEnabled)
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount) == local)
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount + ".family-v1") == cached)
            #expect(try KeychainStore.synchronizableAccounts(service: vocabularyService) == [memberAccount(foreign)])
            #expect(try KeychainStore.getSynchronizable(service: vocabularyService, account: memberAccount(foreign)) == foreign)
            let context = ModelContext(container)
            #expect(try context.fetch(FetchDescriptor<VocabularyStoreMetadata>()).first?.hmacVerifier == verifier)
            #expect(try context.fetch(FetchDescriptor<VocabularySourceState>()).first?.sourceKey == "retained-source")
            #expect(try context.fetch(FetchDescriptor<VocabularyObservation>()).first?.evidenceGroupKey == "retained-evidence")
            let terms = try context.fetch(FetchDescriptor<MeetingGlossaryTerm>())
            #expect(terms.count == 2)
            #expect(terms.first { $0.canonicalKey == "learned" }?.rejectedAt == Date(timeIntervalSince1970: 123))
            // A later operation may use the restored authority, retaining both
            // original keys rather than replacing either identity.
            HMACIdentityKeyFamily.captureAuthorizationForTesting = nil
            let restored = try await VocabularyHMACKeyStore().keys()
            #expect(Set(restored) == Set([local, foreign]))
        }
    }

    @Test("revocation between member writes stops publication without changing local originals",
          .enabled(if: SettingsStore.supportsICloud))
    func revokedMemberPublication() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer {
                HMACIdentityKeyFamily.captureAuthorizationForTesting = nil
                UserCloudSyncPolicy.revokeAccountAuthorization()
                restore(preference)
            }
            try reset()
            let first = Data(repeating: 20, count: 32)
            let second = Data(repeating: 21, count: 32)
            let cached = try JSONEncoder().encode([first, second])
            try KeychainStore.setDeviceOnly(service: vocabularyService, account: primaryAccount, data: first)
            try KeychainStore.setDeviceOnly(service: vocabularyService, account: primaryAccount + ".family-v1", data: cached)
            enableFullSync()
            // Capture, enumeration, read-complete, first write, second write.
            let interleaving = RevocationInterleaving(revokeAtCheck: 5)
            HMACIdentityKeyFamily.captureAuthorizationForTesting = { interleaving.capture() }
            await #expect(throws: KeychainStoreError.authorizationChanged) { try await VocabularyHMACKeyStore().applyFullSyncPolicy() }
            #expect(interleaving.captureCount == 1)
            #expect(UserCloudSyncPolicy.isEnabled)
            #expect(try KeychainStore.synchronizableAccounts(service: vocabularyService) == [memberAccount(first)])
            #expect(try KeychainStore.getSynchronizable(service: vocabularyService, account: memberAccount(first)) == first)
            #expect(try KeychainStore.getSynchronizable(service: vocabularyService, account: memberAccount(second)) == nil)
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount) == first)
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount + ".family-v1") == cached)
        }
    }

    @Test("revocation after the last member write is not a successful policy acknowledgement",
          .enabled(if: SettingsStore.supportsICloud))
    func revokedFinalAcknowledgement() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer {
                HMACIdentityKeyFamily.captureAuthorizationForTesting = nil
                UserCloudSyncPolicy.revokeAccountAuthorization()
                restore(preference)
            }
            try reset()
            let original = Data(repeating: 22, count: 32)
            let cached = try JSONEncoder().encode([original])
            try KeychainStore.setDeviceOnly(service: vocabularyService, account: primaryAccount, data: original)
            try KeychainStore.setDeviceOnly(service: vocabularyService, account: primaryAccount + ".family-v1", data: cached)
            enableFullSync()
            // No cache/primary write is needed. Check five closes the family
            // operation; check six must still reject a stale policy completion.
            let interleaving = RevocationInterleaving(revokeAtCheck: 6)
            HMACIdentityKeyFamily.captureAuthorizationForTesting = { interleaving.capture() }
            await #expect(throws: KeychainStoreError.authorizationChanged) { try await VocabularyHMACKeyStore().applyFullSyncPolicy() }
            #expect(interleaving.captureCount == 1)
            #expect(UserCloudSyncPolicy.isEnabled)
            #expect(try KeychainStore.getSynchronizable(service: vocabularyService, account: memberAccount(original)) == original)
            #expect(try KeychainStore.synchronizableAccounts(service: vocabularyService) == [memberAccount(original)])
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount) == original)
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount + ".family-v1") == cached)
        }
    }

    @Test("legacy ledger cloud import uses the original operation lease for every throwing API",
          .enabled(if: SettingsStore.supportsICloud))
    func revokedLegacyLedgerImport() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer {
                HMACIdentityKeyFamily.captureAuthorizationForTesting = nil
                UserCloudSyncPolicy.revokeAccountAuthorization()
                restore(preference)
            }
            try reset()
            let local = Data(repeating: 23, count: 32)
            let portable = Data(repeating: 24, count: 32)
            let localEncoded = Data(local.base64EncodedString().utf8)
            let portableEncoded = Data(portable.base64EncodedString().utf8)
            try KeychainStore.setDeviceOnly(service: ledgerService, account: "key", data: localEncoded)
            #expect(try bytes(MailAnalysisLedgerKeyStore.key()) == local)
            let cached = try KeychainStore.getDeviceOnly(service: ledgerService, account: primaryAccount + ".family-v1")
            try KeychainStore.setSynchronizable(service: ledgerService, account: "key", data: portableEncoded)
            enableFullSync()
            for operation in 0..<3 {
                // Capture, legacy read guard, then legacy read-complete guard.
                let interleaving = RevocationInterleaving(revokeAtCheck: 3)
                HMACIdentityKeyFamily.captureAuthorizationForTesting = { interleaving.capture() }
                #expect(throws: KeychainStoreError.authorizationChanged) {
                    switch operation {
                    case 0: _ = try MailAnalysisLedgerKeyStore.key()
                    case 1: _ = try MailAnalysisLedgerKeyStore.keysChecked()
                    default: try MailAnalysisLedgerKeyStore.applyFullSyncPolicy()
                    }
                }
                #expect(interleaving.captureCount == 1)
                #expect(UserCloudSyncPolicy.isEnabled)
                #expect(try KeychainStore.getDeviceOnly(service: ledgerService, account: "key") == localEncoded)
                #expect(try KeychainStore.getDeviceOnly(service: ledgerService, account: primaryAccount) == local)
                #expect(try KeychainStore.getDeviceOnly(service: ledgerService, account: primaryAccount + ".family-v1") == cached)
                #expect(try KeychainStore.getSynchronizable(service: ledgerService, account: "key") == portableEncoded)
                #expect(try KeychainStore.synchronizableAccounts(service: ledgerService) == ["key"])
            }
            HMACIdentityKeyFamily.captureAuthorizationForTesting = nil
            #expect(try Set(MailAnalysisLedgerKeyStore.keysChecked().map(bytes)) == Set([local, portable]))
        }
    }

    @Test("revoked cloud-only restore never creates a replacement local identity",
          .enabled(if: SettingsStore.supportsICloud))
    func revokedCloudOnlyRestore() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let preference = savedPolicy()
            defer {
                HMACIdentityKeyFamily.captureAuthorizationForTesting = nil
                UserCloudSyncPolicy.revokeAccountAuthorization()
                restore(preference)
            }
            try reset()
            let portable = Data(repeating: 25, count: 32)
            try KeychainStore.setSynchronizable(service: vocabularyService, account: memberAccount(portable), data: portable)
            enableFullSync()
            let interleaving = RevocationInterleaving(revokeAtCheck: 4)
            HMACIdentityKeyFamily.captureAuthorizationForTesting = { interleaving.capture() }
            await #expect(throws: KeychainStoreError.authorizationChanged) { _ = try await VocabularyHMACKeyStore().readOrCreate() }
            #expect(interleaving.captureCount == 1)
            #expect(UserCloudSyncPolicy.isEnabled)
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount) == nil)
            #expect(try KeychainStore.getDeviceOnly(service: vocabularyService, account: primaryAccount + ".family-v1") == nil)
            #expect(try KeychainStore.getSynchronizable(service: vocabularyService, account: memberAccount(portable)) == portable)
            #expect(try KeychainStore.synchronizableAccounts(service: vocabularyService) == [memberAccount(portable)])
        }
    }
}
