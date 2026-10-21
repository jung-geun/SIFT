import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Full iCloud data reconciliation", .serialized)
@MainActor
struct FullCloudSyncTests {
    @Test("A second installation restores updates and deletion without stale-cache resurrection")
    func restoreUpdatesDeletionAndRejoin() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let first = try fixture.peer("first")
        let second = try fixture.peer("second")
        let key = "Todo/\(UUID().uuidString.lowercased())"
        let original = Data("{\"title\":\"Local work\",\"notes\":\"Keep offline\"}".utf8)
        first.values[key] = original
        try await first.reconcile()
        try await second.reconcile()
        #expect(second.values[key] == original)
        let edited = Data("{\"title\":\"Edited locally\",\"notes\":\"Keep offline\"}".utf8)
        first.values[key] = edited
        try await first.reconcile()
        try await second.reconcile()
        #expect(second.values[key] == edited)
        first.values.removeValue(forKey: key)
        try await first.reconcile()
        // The receiver's data is still old when it next sees the remote deletion.
        try await second.reconcile()
        #expect(second.values[key] == nil)
        let fresh = try fixture.peer("fresh")
        fresh.values[key] = original
        try await fresh.reconcile()
        #expect(fresh.values[key] == nil)
        let remote = try ModelContext(fixture.cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(remote.filter { $0.itemKey == key }.allSatisfy { $0.isDeleted && $0.payload == nil })
        #expect(remote.filter { $0.itemKey == key }.count == 1)
    }

    @Test("A failed restore is not checkpointed and retries from the actual stored payload")
    func restoreFailureKeepsRevisionPending() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let first = try fixture.peer("first")
        let second = try fixture.peer("second")
        let key = "EmailMessage/account-message"
        let body = Data("Private original mail body".utf8)
        first.values[key] = body
        try await first.reconcile()
        second.failApply = true
        await #expect(throws: CloudFixtureError.self) { try await second.reconcile() }
        #expect(second.engine.journal.items[key] == nil)
        #expect(second.values[key] == nil)
        second.failApply = false
        try await second.reconcile()
        #expect(second.values[key] == body)
        #expect(second.engine.journal.items[key]?.digest == CloudFileStore.digest(body))
    }

    @Test("Changing content and invalid cloud bytes fail before replacing saved content")
    func corruptOrChangingContentDoesNotCommit() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let peer = try fixture.peer("peer")
        let key = "EmailMessage/account-message"
        peer.values[key] = Data("changed".utf8)
        peer.failLoad = true
        await #expect(throws: CloudFixtureError.self) { try await peer.reconcile() }
        #expect(try ModelContext(fixture.cloud).fetchCount(FetchDescriptor<CloudDataRevision>()) == 0)
        let context = ModelContext(fixture.cloud)
        let record = CloudDataRevision(itemKey: key, clock: 1,
            installationID: UUID().uuidString, payload: Data("original".utf8))
        record.contentDigest = "invalid"
        context.insert(record)
        try context.save()
        peer.failLoad = false
        await #expect(throws: FullCloudSyncError.self) { try await peer.reconcile() }
        #expect(peer.values[key] == Data("changed".utf8))
        #expect(peer.engine.journal.items[key]?.revisionID != record.revisionID)
    }

    @Test("Unchanged data is not uploaded again and restart resumes its durable baseline")
    func unchangedAndRestart() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let peer = try fixture.peer("peer")
        let key = "MeetingRecord/recording"
        let data = Data("saved transcript".utf8)
        peer.values[key] = data
        try await peer.reconcile()
        #expect(peer.engine.didEnqueueChanges)
        try await peer.reconcile()
        #expect(!peer.engine.didEnqueueChanges)
        let restarted = try fixture.peer("peer", installation: peer.installation)
        restarted.values[key] = data
        try await restarted.reconcile()
        #expect(!restarted.engine.didEnqueueChanges)
        #expect(try ModelContext(fixture.cloud).fetchCount(FetchDescriptor<CloudDataRevision>()) == 1)
    }

    @Test("Full scope requires consent in addition to the older task-only toggle")
    func scopeConsent() throws {
        let suite = "SIFTFullSyncPolicy-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: UserCloudSyncPolicy.syncKey)
        #expect(!UserCloudSyncPolicy.isRequested(defaults: defaults, supported: true))
        defaults.set(UserCloudSyncPolicy.consentVersion, forKey: UserCloudSyncPolicy.consentKey)
        #expect(UserCloudSyncPolicy.isRequested(defaults: defaults, supported: true))
        #expect(!UserCloudSyncPolicy.isRequested(defaults: defaults, supported: false))
        defaults.set("account-A", forKey: UserCloudSyncPolicy.accountKey)
        #expect(!UserCloudSyncPolicy.isAuthorized(defaults: defaults, supported: true, verifiedAccount: nil))
        #expect(!UserCloudSyncPolicy.isAuthorized(defaults: defaults, supported: true, verifiedAccount: "account-B"))
        #expect(UserCloudSyncPolicy.isAuthorized(defaults: defaults, supported: true, verifiedAccount: "account-A"))
        defaults.set(false, forKey: UserCloudSyncPolicy.syncKey)
        #expect(!UserCloudSyncPolicy.isAuthorized(defaults: defaults, supported: true, verifiedAccount: "account-A"))
        #expect(UserCloudSyncPolicy.isAccountAuthorized(defaults: defaults, supported: true, verifiedAccount: "account-A"))
        #expect(!UserCloudSyncPolicy.isAccountAuthorized(defaults: defaults, supported: true, verifiedAccount: "account-B"))
        #expect(!UserCloudSyncPolicy.isAccountAuthorized(defaults: defaults, supported: true, verifiedAccount: nil))
    }

    @Test("A file authorization cannot resume after account switching or re-enabling the same account",
          .enabled(if: SettingsStore.supportsICloud))
    func expiredAuthorizationStaysRevoked() async {
        await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let keys = [UserCloudSyncPolicy.syncKey, UserCloudSyncPolicy.consentKey, UserCloudSyncPolicy.accountKey]
            let previous = keys.map { ($0, defaults.object(forKey: $0)) }
            defer {
                UserCloudSyncPolicy.revokeAccountAuthorization()
                for (key, value) in previous {
                    if let value { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }
            defaults.set(false, forKey: UserCloudSyncPolicy.syncKey)
            defaults.set(UserCloudSyncPolicy.consentVersion, forKey: UserCloudSyncPolicy.consentKey)
            defaults.set("account-A", forKey: UserCloudSyncPolicy.accountKey)
            UserCloudSyncPolicy.authorizeAccount("account-A")
            let unauthorized = UserCloudSyncPolicy.captureAuthorization()
            let revocation = UserCloudSyncPolicy.captureAuthorization(forRevocation: true)
            #expect(!unauthorized() && revocation())
            defaults.set(true, forKey: UserCloudSyncPolicy.syncKey)
            #expect(!unauthorized())
            let first = UserCloudSyncPolicy.captureAuthorization()
            #expect(first())
            UserCloudSyncPolicy.revokeAccountAuthorization()
            UserCloudSyncPolicy.authorizeAccount("account-A")
            let renewed = UserCloudSyncPolicy.captureAuthorization()
            #expect(!first() && !revocation() && renewed())
            defaults.set("account-B", forKey: UserCloudSyncPolicy.accountKey)
            UserCloudSyncPolicy.authorizeAccount("account-B")
            let switched = UserCloudSyncPolicy.captureAuthorization()
            #expect(!first() && !renewed() && switched())
            defaults.set(false, forKey: UserCloudSyncPolicy.syncKey)
            #expect(!switched())
        }
    }

    @Test("Restored mail content and analysis survive the receiving device's first content migration")
    func restoredMailSurvivesFirstMigration() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        func context(_ schema: Schema) throws -> ModelContext {
            ModelContext(try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
        }
        let sourceApp = try context(AppDataContainer.appSchema)
        let sourceEmail = try context(AppDataContainer.emailSchema)
        let sourceMeeting = try context(AppDataContainer.meetingSchema)
        let targetApp = try context(AppDataContainer.appSchema)
        let targetEmail = try context(AppDataContainer.emailSchema)
        let targetMeeting = try context(AppDataContainer.meetingSchema)
        let account = "restored@example.invalid"
        let email = EmailMessage(id: "gmail-imap:9001", subject: "회의 준비", body: "확정된 원본 본문", sourceAccountNamespace: account)
        email.analysisState = .analyzed
        email.analysisSummary = "사용자가 보존한 요약"
        sourceEmail.insert(email)
        try sourceEmail.save()
        let suites = ["SIFTMailFormatSource-\(UUID())", "SIFTMailFormatTarget-\(UUID())"]
        let sourceDefaults = try #require(UserDefaults(suiteName: suites[0]))
        let targetDefaults = try #require(UserDefaults(suiteName: suites[1]))
        defer {
            sourceDefaults.removePersistentDomain(forName: suites[0])
            targetDefaults.removePersistentDomain(forName: suites[1])
        }
        sourceDefaults.set(GmailIMAPContentMigration.currentVersion, forKey: "pieroot.todo.gmailIMAP.contentVersion." + account)
        let source = try fixture.peer("source")
        source.values = try CloudModelCodec.capture(app: sourceApp, email: sourceEmail, meeting: sourceMeeting)
        source.values.merge(try CloudPreferenceStore.capture(defaults: sourceDefaults)) { _, value in value }
        try await source.reconcile()
        let receiver = try fixture.peer("receiver")
        let targetPreferences = try CloudPreferenceStore.capture(defaults: targetDefaults)
        let targetDigests = targetPreferences.mapValues(CloudFileStore.digest)
        try await receiver.engine.reconcile(digests: targetDigests, load: { targetPreferences[$0] }, apply: { key, payload in
            if CloudPreferenceStore.isPreferenceKey(key) {
                try CloudPreferenceStore.apply(key: key, payload: payload, expectedDigest: targetDigests[key], defaults: targetDefaults)
            } else {
                try CloudModelCodec.apply(key: key, payload: payload, app: targetApp, email: targetEmail, meeting: targetMeeting)
                if targetEmail.hasChanges { try targetEmail.save() }
            }
        })
        #expect(try !GmailIMAPContentMigration.migrateIfNeeded(account: account, context: targetEmail, defaults: targetDefaults))
        let restored = try #require(targetEmail.fetch(FetchDescriptor<EmailMessage>()).first)
        #expect(restored.body == "확정된 원본 본문")
        #expect(restored.analysisState == .analyzed)
        #expect(restored.analysisSummary == "사용자가 보존한 요약")
    }

    @Test("Preferences restore language, local model choice and learning data without granting device permissions")
    func preferenceRestoration() throws {
        let suites = ["SIFTCloudPrefsSource-\(UUID())", "SIFTCloudPrefsTarget-\(UUID())"]
        let source = try #require(UserDefaults(suiteName: suites[0]))
        let target = try #require(UserDefaults(suiteName: suites[1]))
        defer {
            source.removePersistentDomain(forName: suites[0])
            target.removePersistentDomain(forName: suites[1])
        }
        source.set("laya", forKey: SettingsStore.betaSelectedProviderKey)
        source.set("ko", forKey: AppLanguage.userOverrideKey)
        source.set(["sender@example.invalid": 3], forKey: "pieroot.todo.senderDeletionCounts")
        source.set(true, forKey: "pieroot.todo.imap.backgroundEnabled")
        source.set(true, forKey: "pieroot.todo.openai.consent.email")
        source.set(true, forKey: "pieroot.todo.health.connected.medication")
        source.set("local-slot", forKey: "pieroot.todo.imap.activeSlot.private")
        let captured = try CloudPreferenceStore.capture(defaults: source)
        let sourceOwner = CloudPreferenceStore.installationID(defaults: source)
        let beforeRestore = try CloudPreferenceStore.capture(defaults: target)
        for (key, payload) in captured {
            try CloudPreferenceStore.apply(key: key, payload: payload,
                expectedDigest: beforeRestore[key].map(CloudFileStore.digest), defaults: target)
        }
        #expect(target.string(forKey: SettingsStore.betaSelectedProviderKey) == "laya")
        #expect(target.string(forKey: AppLanguage.userOverrideKey) == "ko")
        #expect((target.dictionary(forKey: "pieroot.todo.senderDeletionCounts")?["sender@example.invalid"] as? Int) == 3)
        #expect(!target.bool(forKey: "pieroot.todo.imap.backgroundEnabled"))
        #expect(target.bool(forKey: CloudPreferenceStore.restoredPrefix + sourceOwner + "/pieroot.todo.imap.backgroundEnabled"))
        #expect(!target.bool(forKey: "pieroot.todo.openai.consent.email"))
        #expect(target.bool(forKey: CloudPreferenceStore.restoredPrefix + sourceOwner + "/pieroot.todo.openai.consent.email"))
        #expect(target.object(forKey: "pieroot.todo.health.connected.medication") == nil)
        #expect(target.object(forKey: "pieroot.todo.imap.activeSlot.private") == nil)
        target.set(false, forKey: "pieroot.todo.openai.consent.email")
        let targetSnapshot = try CloudPreferenceStore.capture(defaults: target)
        let originalHistory = CloudPreferenceStore.historyPrefix + sourceOwner + "/pieroot.todo.openai.consent.email"
        #expect(targetSnapshot[originalHistory] == captured[originalHistory])
    }

    @Test("Original audio and recovery journals are portable, models and health are not")
    func fileScopeAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SIFTCloudFiles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudFileStore(root: root)
        let id = UUID().uuidString.lowercased()
        let path = "Meetings/\(id)/audio/part-00.flac"
        let original = Data([0x66, 0x4c, 0x61, 0x43, 0x00, 0xff, 0x20])
        try await store.apply(key: "file/" + path, payload: original, expectedDigest: nil)
        let files = try await store.capture()
        let audio = try #require(files["file/" + path])
        #expect(try await store.load(audio) == original)
        #expect(!CloudFileStore.isPortablePath("LocalHealthHistory/history.json"))
        #expect(!CloudFileStore.isPortablePath("laya/revision/model.mlmodelc/weights.bin"))
        #expect(!CloudFileStore.isPortablePath("Meetings/meeting_local.store"))
        #expect(CloudFileStore.isPortablePath("Meetings/\(id)/capture-recovery.json"))
        try await store.apply(key: "file/" + path, payload: nil, expectedDigest: audio.digest)
        #expect(!FileManager.default.fileExists(atPath: audio.url.path))
    }

    @Test("A restored path cannot escape through traversal or an existing symlink")
    func fileRestorePathBoundary() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("SIFTCloudPath-\(UUID())")
        let root = parent.appendingPathComponent("root")
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Meetings"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let id = UUID().uuidString.lowercased()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Meetings/\(id)"), withDestinationURL: outside)
        let store = CloudFileStore(root: root)
        await #expect(throws: CloudFileError.self) {
            try await store.apply(key: "file/Meetings/\(id)/audio/part-00.flac", payload: Data([1]), expectedDigest: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("audio/part-00.flac").path))
        #expect(!CloudFileStore.isPortablePath("Meetings/../LocalHealthHistory/history.json"))
    }
}

private enum CloudFixtureError: Error { case load, apply }

@MainActor
private final class CloudSyncPeer {
    let engine: FullCloudSyncEngine
    let installation: String
    var values = [String: Data]()
    var failLoad = false
    var failApply = false

    init(cloud: ModelContainer, installation: String, journalURL: URL) throws {
        self.installation = installation
        engine = try FullCloudSyncEngine(cloud: ModelContext(cloud), installationID: installation, journalURL: journalURL)
    }

    func reconcile() async throws {
        try await engine.reconcile(digests: values.mapValues(CloudFileStore.digest), load: { key in
            if self.failLoad { throw CloudFixtureError.load }
            return self.values[key]
        }, apply: { key, payload in
            if self.failApply { throw CloudFixtureError.apply }
            self.values[key] = payload
        })
    }
}

@MainActor
private struct CloudSyncFixture {
    let cloud: ModelContainer
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SIFTCloudEngine-\(UUID())")

    init() throws {
        let schema = Schema([CloudDataRevision.self])
        cloud = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }

    func peer(_ name: String, installation: String = UUID().uuidString) throws -> CloudSyncPeer {
        try CloudSyncPeer(cloud: cloud, installation: installation, journalURL: root.appendingPathComponent(name + ".json"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
