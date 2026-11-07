import Foundation
import SwiftData
import LocalAuthentication
import Security
import Testing
@testable import todo

@Suite("Full iCloud data reconciliation", .serialized)
@MainActor
struct FullCloudSyncTests {
    @MainActor
    private final class SaveProbe {
        var changes = FullCloudModelChanges()
        let cache = CloudModelCodec.CaptureCache()
        let fence = FullCloudSaveFence(entities: CloudModelCodec.entityNames)
        var notifications = 0
        var observer: NSObjectProtocol?

        func observe(_ context: ModelContext) {
            let fence = self.fence
            observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave,
                object: context, queue: nil) { [weak self] note in
                fence.observe(note)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.notifications += 1
                    _ = self.changes.record(note, cache: self.cache)
                }
            }
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }

    @Test("Actual shared-store save metadata attributes inserts, updates and deletes to mail ledger identifiers")
    func sdkSaveIdentifierShapesAndNoOpFallback() throws {
        let schema = AppDataContainer.appSchema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let probe = SaveProbe()
        probe.observe(context)
        defer { probe.stop() }
        let version = probe.changes.generations
        let ledger = MailAnalysisLedgerRecord(fingerprintData: Data("shape-ledger".utf8),
            revision: 0, stateRawValue: "pending")
        context.insert(ledger)
        try context.save()
        let id = ledger.persistentModelID
        let inserted = probe.fence.drain()
        #expect(inserted.identifiers.contains(id))
        #expect(!inserted.needsFullCapture)
        #expect(probe.changes.isCurrent(key: "Todo/", snapshot: version))
        ledger.revision = 1
        try context.save()
        let updated = probe.fence.drain()
        #expect(updated.identifiers.contains(id))
        #expect(!updated.needsFullCapture)
        #expect(probe.changes.isCurrent(key: "Todo/", snapshot: version))
        context.delete(ledger)
        try context.save()
        let deleted = probe.fence.drain()
        #expect(deleted.identifiers.contains(id))
        #expect(!deleted.needsFullCapture)
        #expect(probe.changes.isCurrent(key: "Todo/", snapshot: version))
        let notifications = probe.notifications
        try context.save()
        let noOp = probe.fence.drain()
        // Some SDKs omit no-op events; any event without identifiers must take
        // the conservative full-store fallback, never invent a changed item ID.
        if probe.notifications == notifications { #expect(!noOp.hasChanges) }
        else if noOp.identifiers.isEmpty { #expect(noOp.needsFullCapture) }
        else { #expect(noOp.identifiers.allSatisfy { $0.entityName == "MailAnalysisLedgerRecord" }) }
    }

    @Test("A background context save fences its family before the MainActor invalidation callback can run")
    func backgroundSaveFencesBeforeActorHop() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let schema = AppDataContainer.emailSchema
        let source = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: fixture.root.appendingPathComponent("mail.store"),
                cloudKitDatabase: .none)])
        let context = ModelContext(source)
        let message = EmailMessage(id: "background-save")
        message.body = "old body"
        context.insert(message)
        try context.save()
        let id = message.persistentModelID
        let fence = FullCloudSaveFence(entities: CloudModelCodec.entityNames)
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave,
            object: nil, queue: nil) { note in
                guard let context = note.object as? ModelContext, context.container === source else { return }
                fence.observe(note)
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        let version = fence.snapshot()
        try await Task.detached {
            let background = ModelContext(source)
            let row = try #require(background.fetch(FetchDescriptor<EmailMessage>()).first)
            row.body = "saved on the background context"
            try background.save()
        }.value
        #expect(!fence.isCurrent(key: "EmailMessage/stale", snapshot: version))
        #expect(fence.isCurrent(key: "Todo/independent", snapshot: version))
        let pending = fence.drain()
        #expect(pending.identifiers.contains(id))
        #expect(pending.entities == ["EmailMessage"])
        let peer = try fixture.peer("background-fence")
        let stale = ["EmailMessage/stale": Data("old cached bytes".utf8),
            "Todo/independent": Data("independent task".utf8)]
        try await peer.engine.reconcile(digests: stale.mapValues(CloudFileStore.digest),
            isKeyValid: { fence.isCurrent(key: $0, snapshot: version) },
            load: { stale[$0] }, apply: { _, _ in Issue.record("Stale snapshots must never restore") })
        #expect(peer.engine.deferredKeys == ["EmailMessage/stale"])
        #expect(peer.engine.journal.items["Todo/independent"] != nil)
        #expect(peer.engine.journal.items["EmailMessage/stale"] == nil)
        #expect(try ModelContext(source).fetch(FetchDescriptor<EmailMessage>()).first?.body
            == "saved on the background context")
    }

    @Test("Repeated actual mail saves cannot cancel task restore or publication, and replay never restores the same task again",
          arguments: [false, true])
    func repeatedMailSavesDoNotStarveTaskProgress(usesLedger: Bool) async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let emailSchema = usesLedger ? AppDataContainer.appSchema : AppDataContainer.emailSchema
        let emailStore = try ModelContainer(for: emailSchema, configurations: [
            ModelConfiguration(schema: emailSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let email = ModelContext(emailStore)
        email.autosaveEnabled = false
        let message = EmailMessage(id: "synthetic-changing-mail")
        let ledger = MailAnalysisLedgerRecord(fingerprintData: Data("synthetic-ledger".utf8),
            revision: 0, stateRawValue: "pending")
        if usesLedger { email.insert(ledger) } else { email.insert(message) }
        try email.save()
        let probe = SaveProbe()
        probe.observe(email)
        defer { probe.stop() }
        let incoming = "Todo/incoming"
        let outgoing = "Todo/outgoing"
        let mail = usesLedger ? "MailAnalysisLedgerRecord/changing" : "EmailMessage/changing"
        let cloud = ModelContext(fixture.cloud)
        cloud.insert(CloudDataRevision(itemKey: incoming, clock: 1,
            installationID: UUID().uuidString, payload: Data("remote task".utf8)))
        try cloud.save()
        let peer = try fixture.peer("busy-mail")
        var values = [outgoing: Data("local task".utf8), mail: Data("mail before save".utf8)]
        let versions = probe.changes.generations
        let savedVersion = probe.fence.snapshot()
        var applyCount = 0
        var mailSaves = 0
        func saveMail() throws {
            mailSaves += 1
            if usesLedger { ledger.revision = mailSaves }
            else { message.body = "body revision \(mailSaves)" }
            try email.save()
            values[mail] = Data("mail revision \(mailSaves)".utf8)
        }
        try await peer.engine.reconcile(digests: values.mapValues(CloudFileStore.digest),
            isKeyValid: { probe.changes.isCurrent(key: $0, snapshot: versions)
                && probe.fence.isCurrent(key: $0, snapshot: savedVersion) }, load: { key in
                let captured = values[key]
                try saveMail()
                return captured
            }, apply: { key, payload in
                try saveMail()
                values[key] = payload
                applyCount += 1
            })
        #expect(probe.notifications >= 3)
        #expect(probe.changes.isCurrent(key: outgoing, snapshot: versions))
        #expect(!probe.changes.isCurrent(key: mail, snapshot: versions))
        #expect(values[incoming] == Data("remote task".utf8))
        #expect(applyCount == 1)
        #expect(peer.engine.didCompleteInventory)
        #expect(peer.engine.deferredKeys == [mail])
        #expect(peer.engine.journal.items[outgoing] != nil)
        #expect(peer.engine.journal.pendingPublications[mail] != nil)
        #expect(peer.engine.journal.items[mail] == nil)
        let published = try ModelContext(fixture.cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(published.contains { $0.itemKey == outgoing && $0.payload == values[outgoing] })
        #expect(!published.contains { $0.itemKey == mail })

        // A restarted foreground/background pass uses the durable same journal,
        // not a fake completion or another initial-restore overwrite.
        let restarted = try fixture.peer("busy-mail")
        try await restarted.engine.reconcile(digests: values.mapValues(CloudFileStore.digest),
            load: { values[$0] }, apply: { key, payload in values[key] = payload; applyCount += 1 })
        #expect(applyCount == 1)
        #expect(restarted.engine.deferredKeys.isEmpty)
        #expect(restarted.engine.journal.pendingPublications.isEmpty)
        let replayed = try ModelContext(fixture.cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(replayed.count == 3)
        #expect(replayed.first { $0.itemKey == mail }?.payload == values[mail])
    }

    @Test("A mail edit invalidating an already staged publication rebuilds only the bounded batch")
    func stagedMailChangePreservesIndependentTaskBatch() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let peer = try fixture.peer("staged-mail")
        let mail = "EmailMessage/staged"
        let task = "Todo/independent"
        var mailCurrent = true
        let values = [mail: Data("stale mail".utf8), task: Data("durable task".utf8)]
        try await peer.engine.reconcile(digests: values.mapValues(CloudFileStore.digest),
            isKeyValid: { $0 != mail || mailCurrent }, load: { key in
                if key == task { mailCurrent = false }
                return values[key]
            }, apply: { _, _ in Issue.record("Local publications must not restore") })
        let saved = try ModelContext(fixture.cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(saved.count == 1)
        #expect(saved.first?.itemKey == task)
        #expect(saved.first?.payload == values[task])
        #expect(peer.engine.journal.items[task] != nil)
        #expect(peer.engine.journal.pendingPublications[mail] != nil)
        #expect(peer.engine.journal.items[mail] == nil)
        #expect(peer.engine.deferredKeys == [mail])
    }

    @Test("A held absent family is not deletion and cannot erase its checkpoint or pending intent")
    func unavailableInventoryDoesNotManufactureTombstone() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let peer = try fixture.peer("held-inventory")
        let mail = "EmailMessage/retained"
        peer.values[mail] = Data("retained body".utf8)
        try await peer.reconcile()
        let checkpoint = peer.engine.journal.items[mail]
        let task = "Todo/continues"
        let data = Data("task continues".utf8)
        try await peer.engine.reconcile(digests: [task: CloudFileStore.digest(data)],
            isKeyValid: { $0 != mail }, load: { _ in data },
            apply: { _, _ in Issue.record("An unavailable inventory cannot authorize restore") })
        #expect(peer.engine.journal.items[mail] == checkpoint)
        #expect(peer.engine.deferredKeys == [mail])
        let saved = try ModelContext(fixture.cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(saved.first { $0.itemKey == mail }?.payload == peer.values[mail])
        #expect(saved.first { $0.itemKey == task }?.payload == data)
    }

    @Test("A failed model apply keeps its recovery intent and real error while later task keys complete")
    func rejectedMailApplyDoesNotStarveTaskRestore() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let peer = try fixture.peer("rejected-mail")
        let context = ModelContext(fixture.cloud)
        for key in ["EmailMessage/rejected", "Todo/restored"] {
            context.insert(CloudDataRevision(itemKey: key, clock: 1,
                installationID: UUID().uuidString, payload: Data(key.utf8)))
        }
        try context.save()
        var applied = Set<String>()
        await #expect(throws: CloudFixtureError.apply) {
            try await peer.engine.reconcile(digests: [:], load: { _ in nil }, apply: { key, _ in
                if key.hasPrefix("EmailMessage/") { throw CloudFixtureError.apply }
                applied.insert(key)
            })
        }
        #expect(applied == ["Todo/restored"])
        #expect(peer.engine.didCompleteInventory)
        #expect(peer.engine.deferredKeys == ["EmailMessage/rejected"])
        #expect(peer.engine.journal.pendingApplies["EmailMessage/rejected"] != nil)
        #expect(peer.engine.journal.items["EmailMessage/rejected"] == nil)
        #expect(peer.engine.journal.items["Todo/restored"] != nil)
        #expect(FullCloudSyncProgress.tasksRestored(completedInventory: peer.engine.didCompleteInventory,
            heldKeys: peer.engine.deferredKeys, unavailableEntities: [], isCurrent: { _ in true }))
        #expect(!FullCloudSyncProgress.tasksRestored(completedInventory: peer.engine.didCompleteInventory,
            heldKeys: ["Todo/deferred"], unavailableEntities: [], isCurrent: { _ in true }))
    }

    @Test("A previously completed pass cannot acknowledge task readiness for a later revoked inventory")
    func revokedInventoryClearsCompletionEvidence() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let peer = try fixture.peer("revoked-inventory")
        peer.values["Todo/local"] = Data("original".utf8)
        try await peer.reconcile()
        #expect(peer.engine.didCompleteInventory)
        let checkpoint = peer.engine.journal.items["Todo/local"]
        var authorized = true
        let values = ["Todo/local": Data("new uncommitted edit".utf8), "file/later": Data("later asset".utf8)]
        await #expect(throws: CancellationError.self) {
            try await peer.engine.reconcile(digests: values.mapValues(CloudFileStore.digest),
                isValid: { authorized }, load: { key in
                    if key == "file/later" { authorized = false }
                    return values[key]
                }, apply: { _, _ in Issue.record("Local edits must not restore") })
        }
        #expect(!peer.engine.didCompleteInventory)
        #expect(!peer.engine.didEnqueueChanges)
        #expect(peer.engine.journal.items["Todo/local"] == checkpoint)
        #expect(peer.engine.journal.pendingPublications["Todo/local"] != nil)
        let saved = try ModelContext(fixture.cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(saved.count == 1)
        #expect(saved.first?.payload == Data("original".utf8))
        #expect(!FullCloudSyncProgress.tasksRestored(completedInventory: peer.engine.didCompleteInventory,
            heldKeys: peer.engine.deferredKeys, unavailableEntities: [], isCurrent: { _ in true }))
    }

    @Test("Scoped meeting inventories preserve active originals and remote-only namespaces while unrelated audio syncs")
    func scopedMeetingFilesMakeIndependentProgress() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let store = CloudFileStore(root: fixture.root)
        let rootID = UUID().uuidString.lowercased()
        let childID = UUID().uuidString.lowercased()
        let otherID = UUID().uuidString.lowercased()
        let remoteID = UUID().uuidString.lowercased()
        func key(_ id: String) -> String { "file/Meetings/\(id)/audio/part-00.flac" }
        for id in [rootID, childID, otherID] {
            try await store.apply(key: key(id), payload: Data(("original " + id).utf8), expectedDigest: nil)
        }
        let original = try await store.capture()
        let peer = try fixture.peer("scoped-files")
        for (key, file) in original { peer.values[key] = try await store.load(file) }
        try await peer.reconcile()
        let rootCheckpoint = peer.engine.journal.items[key(rootID)]
        let context = ModelContext(fixture.cloud)
        context.insert(CloudDataRevision(itemKey: key(remoteID), clock: 10,
            installationID: UUID().uuidString, payload: Data("remote-only original".utf8)))
        try context.save()
        let otherData = Data("unrelated audio edit".utf8)
        try await store.apply(key: key(otherID), payload: otherData, expectedDigest: original[key(otherID)]?.digest)

        let scope = MeetingCloudSyncProtection.begin(meetingIDs: [rootID, childID])
        defer { MeetingCloudSyncProtection.end(scope) }
        let namespaces = MeetingCaptureCoordinator.captureCloudSyncNamespaceAuthorization()
        let family: Set<String> = [rootID, childID]
        let productionScope = FullCloudFileScope(graph: [rootID: family, childID: family, otherID: [otherID]],
            heldMeetingIDs: [], modelUnavailable: false, namespaceAuthorization: namespaces)
        let scoped: @Sendable (String) -> Bool = { productionScope.authorizes($0) }
        let inventory = try await store.captureInventory(isMeetingAuthorized: scoped)
        #expect(inventory.unavailableMeetingIDs == [rootID, childID])
        #expect(inventory.authoritativeMeetingIDs == [otherID])
        #expect(inventory.files.keys.sorted() == [key(otherID)])
        #expect(inventory.firstError == nil)
        var restores = 0
        try await peer.engine.reconcile(digests: inventory.files.mapValues(\.digest),
            isKeyValid: { value in CloudFileStore.meetingID(for: value).map(scoped) ?? true },
            load: { value in
                guard let file = inventory.files[value] else { return nil }
                return try await store.load(file)
            }, apply: { value, payload in
                guard let id = CloudFileStore.meetingID(for: value) else { throw CloudFileError.invalidPath }
                try await store.apply(key: value, payload: payload, expectedDigest: inventory.files[value]?.digest,
                    isAuthorized: { scoped(id) })
                restores += 1
            })
        #expect(restores == 0)
        #expect(peer.engine.deferredKeys == [key(rootID), key(childID), key(remoteID)])
        #expect(peer.engine.journal.items[key(rootID)] == rootCheckpoint)
        #expect(peer.engine.journal.items[key(remoteID)] == nil)
        let saved = try ModelContext(fixture.cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(saved.first { $0.itemKey == key(rootID) }?.payload == peer.values[key(rootID)])
        #expect(saved.first { $0.itemKey == key(childID) }?.payload == peer.values[key(childID)])
        #expect(saved.first { $0.itemKey == key(otherID) }?.payload == otherData)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Meetings/\(remoteID)").path))

        MeetingCloudSyncProtection.end(scope)
        let ready = MeetingCaptureCoordinator.captureCloudSyncNamespaceAuthorization()
        // The next model inventory now establishes the remote namespace's ownership.
        let readyScope = FullCloudFileScope(graph: [rootID: family, childID: family,
            otherID: [otherID], remoteID: [remoteID]], heldMeetingIDs: [],
            modelUnavailable: false, namespaceAuthorization: ready)
        let readyNamespaces: @Sendable (String) -> Bool = { readyScope.authorizes($0) }
        let fresh = try await store.captureInventory(isMeetingAuthorized: readyNamespaces)
        try await peer.engine.reconcile(digests: fresh.files.mapValues(\.digest),
            isKeyValid: { value in CloudFileStore.meetingID(for: value).map(readyNamespaces) ?? true },
            load: { value in
                guard let file = fresh.files[value] else { return nil }
                return try await store.load(file)
            }, apply: { value, payload in
                try await store.apply(key: value, payload: payload, expectedDigest: fresh.files[value]?.digest)
                restores += 1
            })
        #expect(restores == 1)
        let restored = try await store.capture()
        let remoteFile = try #require(restored[key(remoteID)])
        #expect(try await store.load(remoteFile) == Data("remote-only original".utf8))
        #expect(peer.engine.deferredKeys.isEmpty)
    }

    @Test("An unreadable file invalidates its entire namespace, never the independent inventory or original cloud bytes")
    func partialFileNamespaceCannotAuthorizeDeletion() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let store = CloudFileStore(root: fixture.root)
        let brokenID = UUID().uuidString.lowercased()
        let healthyID = UUID().uuidString.lowercased()
        let originalKey = "file/Meetings/\(brokenID)/audio/part-00.flac"
        let healthyKey = "file/Meetings/\(healthyID)/audio/part-00.flac"
        try await store.apply(key: originalKey, payload: Data("original retained".utf8), expectedDigest: nil)
        try await store.apply(key: healthyKey, payload: Data("independent".utf8), expectedDigest: nil)
        let before = try await store.capture()
        let peer = try fixture.peer("partial-files")
        for (key, file) in before { peer.values[key] = try await store.load(file) }
        try await peer.reconcile()
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent(
            "Meetings/\(brokenID)/audio/part-01.flac"), withIntermediateDirectories: true)
        let inventory = try await store.captureInventory()
        #expect(inventory.unavailableMeetingIDs == [brokenID])
        #expect(!inventory.authoritativeMeetingIDs.contains(brokenID))
        #expect(inventory.files[originalKey] == nil)
        #expect(inventory.files[healthyKey] != nil)
        #expect(inventory.firstError != nil)
        let originalCheckpoint = peer.engine.journal.items[originalKey]
        try await peer.engine.reconcile(digests: inventory.files.mapValues(\.digest),
            isKeyValid: { CloudFileStore.meetingID(for: $0) != brokenID },
            load: { value in
                guard let file = inventory.files[value] else { return nil }
                return try await store.load(file)
            }, apply: { _, _ in Issue.record("Partial inventory is not a local deletion") })
        #expect(peer.engine.journal.items[originalKey] == originalCheckpoint)
        #expect(peer.engine.deferredKeys == [originalKey])
        let saved = try ModelContext(fixture.cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(saved.first { $0.itemKey == originalKey }?.payload == peer.values[originalKey])
    }

    @Test("A transient meeting-work scope revokes an actor file write even after the scope has ended")
    func transientMeetingScopeFencesActorFileMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SIFTFileFence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudFileStore(root: root)
        let id = UUID().uuidString.lowercased()
        let key = "file/Meetings/\(id)/audio/part-00.flac"
        let bytes = Data("do not overwrite original".utf8)
        try await store.apply(key: key, payload: bytes, expectedDigest: nil)
        let authorization = MeetingCaptureCoordinator.captureCloudSyncNamespaceAuthorization()
        #expect(authorization(id))
        let scope = MeetingCloudSyncProtection.begin(meetingIDs: [id])
        MeetingCloudSyncProtection.end(scope)
        #expect(!authorization(id))
        await #expect(throws: CancellationError.self) {
            try await store.apply(key: key, payload: Data("forbidden mutation".utf8),
                expectedDigest: CloudFileStore.digest(bytes), isAuthorized: { authorization(id) })
        }
        let restored = try await store.capture()
        let original = try #require(restored[key])
        #expect(try await store.load(original) == bytes)
    }

    @Test("Marker-only children inherit an active parent's actor fence, including an incoming remote-only marker")
    func markerParentProtectsModelAbsentChildNamespaces() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SIFTMarkerFence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingRoot = root.appendingPathComponent("Meetings")
        let store = CloudFileStore(root: root)
        let parentID = UUID().uuidString.lowercased()
        let childID = UUID().uuidString.lowercased()
        let remoteChildID = UUID().uuidString.lowercased()
        let key = "file/Meetings/\(childID)/audio/part-00.flac"
        let bytes = Data("original child audio".utf8)
        try await store.apply(key: key, payload: bytes, expectedDigest: nil)
        let childDirectory = meetingRoot.appendingPathComponent(childID).appendingPathComponent("audio")
        try MeetingCaptureRecoveryStore.markActive(meetingID: childID, parentMeetingID: parentID,
            sourceKind: .microphone, sourceLabel: nil, sessionStartSample: 0,
            languageTag: "en-US", timezoneIdentifier: "UTC", directoryURL: childDirectory, rootURL: meetingRoot)
        let sourceRoot = root.appendingPathComponent("remote-source")
        let remoteDirectory = sourceRoot.appendingPathComponent(remoteChildID).appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        try MeetingCaptureRecoveryStore.markActive(meetingID: remoteChildID, parentMeetingID: parentID,
            sourceKind: .microphone, sourceLabel: nil, sessionStartSample: 0,
            languageTag: "en-US", timezoneIdentifier: "UTC", directoryURL: remoteDirectory, rootURL: sourceRoot)
        let incomingMarker = try Data(contentsOf: remoteDirectory.deletingLastPathComponent().appendingPathComponent("active-capture.json"))
        let before = try await store.capture()
        let original = try #require(before[key])
        let authorization = MeetingCaptureCoordinator.captureCloudSyncNamespaceAuthorization()
        let scope = MeetingCloudSyncProtection.begin(meetingIDs: [parentID])
        defer { MeetingCloudSyncProtection.end(scope) }
        #expect(authorization(childID))
        #expect(!authorization(parentID))
        let scoped = try await store.captureInventory(isMeetingAuthorized: authorization)
        #expect(scoped.unavailableMeetingIDs == [childID])
        #expect(scoped.files[key] == nil)
        await #expect(throws: CloudFileError.changingFile) {
            _ = try await store.load(original, isMeetingAuthorized: authorization)
        }
        await #expect(throws: CloudFileError.changingFile) {
            try await store.apply(key: key, payload: nil, expectedDigest: original.digest,
                isMeetingAuthorized: authorization)
        }
        await #expect(throws: CloudFileError.changingFile) {
            try await store.apply(key: "file/Meetings/\(remoteChildID)/active-capture.json",
                payload: incomingMarker, expectedDigest: nil, isMeetingAuthorized: authorization)
        }
        #expect(try Data(contentsOf: original.url) == bytes)
        #expect(!FileManager.default.fileExists(atPath: meetingRoot.appendingPathComponent(remoteChildID).path))
    }

    @Test("A permanently excluded legacy routines key does not prevent completion of the authoritative inventory")
    func staticLegacyExclusionDoesNotBecomePendingWork() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let peer = try fixture.peer("legacy-exclusion")
        let key = "file/LocalRoutines/routines.json"
        let context = ModelContext(fixture.cloud)
        context.insert(CloudDataRevision(itemKey: key, clock: 1,
            installationID: UUID().uuidString, payload: Data("retained legacy routines".utf8)))
        try context.save()
        try await peer.engine.reconcile(digests: [:], temporarilyUnavailable: [key],
            load: { _ in Issue.record("Excluded legacy content cannot publish"); return nil },
            apply: { _, _ in Issue.record("Excluded legacy content cannot restore") })
        #expect(peer.engine.didCompleteInventory)
        #expect(peer.engine.deferredKeys.isEmpty)
        #expect(peer.engine.journal.pendingApplies.isEmpty)
        #expect(try ModelContext(fixture.cloud).fetchCount(FetchDescriptor<CloudDataRevision>()) == 1)
    }

    @Test("Additive migration uses the persisted legacy bit, not its colliding getter or absent bytes")
    func additiveLegacyStoreMigrationUsesSQLDeletionProof() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SIFTLegacyCloud-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("cloud.store")
        let deletedID = UUID()
        let liveData = Data("preserved legacy live bytes".utf8)
        try autoreleasepool {
            let schema = Schema([LegacyFullCloudSchema.CloudDataRevision.self])
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
                url: url, cloudKitDatabase: .none)])
            let context = ModelContext(old)
            let deletion = LegacyFullCloudSchema.CloudDataRevision(key: "Todo/a-deleted", payload: nil)
            deletion.revisionID = deletedID
            context.insert(deletion)
            context.insert(LegacyFullCloudSchema.CloudDataRevision(key: "Todo/b-live", payload: liveData))
            let unproven = LegacyFullCloudSchema.CloudDataRevision(key: "Todo/z-unproven", payload: nil)
            unproven.isDeleted = false
            context.insert(unproven)
            try context.save()
        }
        let schema = Schema([CloudDataRevision.self])
        let store = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
            url: url, cloudKitDatabase: .none)])
        let context = ModelContext(store)
        let rows = try context.fetch(FetchDescriptor<CloudDataRevision>())
        let deletion = try #require(rows.first { $0.revisionID == deletedID })
        #expect(!deletion.isTombstone)
        let legacyIDs = try CloudDataRevision.persistedLegacyTombstoneIDs(in: context)
        #expect(legacyIDs == [deletion.persistentModelID])
        let engine = try FullCloudSyncEngine(cloud: context, installationID: UUID().uuidString,
            journalURL: root.appendingPathComponent("new-device-journal.json"))
        var local = ["Todo/a-deleted": Data("stale local value".utf8), "Todo/b-live": liveData,
            "Todo/z-unproven": Data("protected unproven value".utf8)]
        var enqueues = 0
        await #expect(throws: FullCloudSyncError.revisionValidation(.missingPayload)) {
            try await engine.reconcile(digests: local.mapValues(CloudFileStore.digest),
                didEnqueue: { enqueues += 1 }, load: { local[$0] }, apply: { local[$0] = $1 })
        }
        #expect(enqueues == 1)
        #expect(local["Todo/a-deleted"] == nil)
        #expect(local["Todo/b-live"] == liveData)
        #expect(local["Todo/z-unproven"] == Data("protected unproven value".utf8))
        let saved = try ModelContext(store).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(saved.count == 3)
        #expect(saved.first { $0.revisionID == deletedID }?.isTombstone == true)
        #expect(saved.first { $0.itemKey == "Todo/z-unproven" }?.isTombstone == false)
        #expect(saved.first { $0.itemKey == "Todo/b-live" }?.payload == liveData)
    }

    @Test("Durable deletion checkpoints repair the same legacy revision without manufacturing a newer one",
        arguments: ["items", "pendingPublications", "pendingApplies"])
    func provenLegacyTombstoneKeepsItsIdentity(proofSource: String) async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let key = "Todo/synthetic-legacy"
        let installation = UUID().uuidString
        let context = ModelContext(fixture.cloud)
        let legacy = CloudDataRevision(itemKey: key, clock: 5, installationID: installation, payload: nil)
        legacy.isTombstone = false
        context.insert(legacy)
        try context.save()
        let proof = CloudSyncCheckpoint(digest: nil, revisionID: legacy.revisionID,
            logicalClock: 5, installationID: installation)
        var journal = CloudSyncJournal()
        switch proofSource {
        case "items": journal.items[key] = proof
        case "pendingPublications": journal.pendingPublications[key] = proof
        default: journal.pendingApplies[key] = CloudSyncPendingApply(sourceDigest: nil, target: proof)
        }
        let url = fixture.root.appendingPathComponent("trusted.json")
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        let engine = try FullCloudSyncEngine(cloud: ModelContext(fixture.cloud), installationID: installation, journalURL: url)
        var enqueues = 0
        try await engine.reconcile(digests: [:], didEnqueue: { enqueues += 1 }, load: { _ in nil },
            apply: { _, payload in #expect(payload == nil) })
        #expect(enqueues == 1)
        #expect(engine.didEnqueueChanges)
        #expect(engine.journal.items[key] == proof)
        let saved = try ModelContext(fixture.cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(saved.count == 1)
        #expect(saved.first?.revisionID == proof.revisionID)
        #expect(saved.first?.logicalClock == proof.logicalClock)
        #expect(saved.first?.installationID == proof.installationID)
        #expect(saved.first?.isTombstone == true)
        #expect(saved.first?.payload == nil)

        let joining = try fixture.peer("joining")
        joining.values[key] = Data("stale local content".utf8)
        try await joining.reconcile()
        #expect(joining.values[key] == nil)
        #expect(!joining.engine.didEnqueueChanges)
        #expect(joining.engine.journal.items[key] == proof)
    }

    @Test("Persisted tombstone state survives save and reopen independently from object lifecycle state")
    func diskTombstoneFlagSurvivesSaveAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SIFTTombstone-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("cloud.store")
        let schema = Schema([CloudDataRevision.self])
        func container() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
                url: url, cloudKitDatabase: .none)])
        }
        let id = UUID()
        try autoreleasepool {
            let store = try container()
            let context = ModelContext(store)
            let tombstone = CloudDataRevision(itemKey: "Todo/deleted", clock: 1,
                installationID: UUID().uuidString, payload: nil)
            tombstone.revisionID = id
            #expect(tombstone.isTombstone)
            context.insert(tombstone)
            try context.save()
            #expect(tombstone.isTombstone)
        }
        let reopened = try container()
        let rows = try ModelContext(reopened).fetch(FetchDescriptor<CloudDataRevision>())
        let tombstone = try #require(rows.first)
        #expect(tombstone.revisionID == id)
        #expect(tombstone.isTombstone)
        #expect(tombstone.payload == nil)
    }

    @Test("Exact durable deletion proof repairs only its flag and preserves a newer pending live write")
    func provenLegacyTombstonePreservesNewerPublication() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let key = "permission-history/synthetic-choice"
        let installation = UUID().uuidString
        let context = ModelContext(fixture.cloud)
        let legacy = CloudDataRevision(itemKey: key, clock: 5, installationID: installation, payload: nil)
        legacy.isTombstone = false
        context.insert(legacy)
        try context.save()
        let originalID = legacy.revisionID
        let deletion = CloudSyncCheckpoint(digest: nil, revisionID: originalID,
            logicalClock: 5, installationID: installation)
        let live = Data("newer explicit choice".utf8)
        let publication = CloudSyncCheckpoint(digest: CloudFileStore.digest(live), revisionID: UUID(),
            logicalClock: 6, installationID: installation)
        var journal = CloudSyncJournal()
        journal.items[key] = deletion
        journal.pendingPublications[key] = publication
        let url = fixture.root.appendingPathComponent("trusted.json")
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        let engine = try FullCloudSyncEngine(cloud: ModelContext(fixture.cloud), installationID: installation, journalURL: url)
        var enqueues = 0
        try await engine.reconcile(digests: [key: CloudFileStore.digest(live)], didEnqueue: { enqueues += 1 },
            load: { _ in live }, apply: { _, _ in Issue.record("Repair cannot delete the newer local choice") })
        #expect(enqueues == 2) // one flag repair, one existing intended publication
        #expect(engine.didEnqueueChanges)
        #expect(engine.journal.items[key] == publication)
        #expect(engine.journal.pendingPublications[key] == nil)
        let saved = try ModelContext(fixture.cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(saved.count == 1)
        #expect(saved.first?.revisionID == publication.revisionID)
        #expect(saved.first?.logicalClock == publication.logicalClock)
        #expect(saved.first?.payload == live)
        #expect(saved.first?.isTombstone == false)
    }

    @Test("Legacy tombstone repair requires exact durable identity and absent bytes",
        arguments: ["unproven", "revision", "clock", "installation", "digest", "payload", "revoked", "held"])
    func unprovenLegacyTombstoneIsNotRepaired(mismatch: String) async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let key = "Todo/synthetic-legacy"
        let installation = UUID().uuidString
        let context = ModelContext(fixture.cloud)
        let legacy = CloudDataRevision(itemKey: key, clock: 5, installationID: installation, payload: nil)
        legacy.isTombstone = false
        if mismatch == "payload" { legacy.payload = Data("present protected bytes".utf8) }
        context.insert(legacy)
        try context.save()
        var proof = CloudSyncCheckpoint(digest: nil, revisionID: legacy.revisionID,
            logicalClock: 5, installationID: installation)
        switch mismatch {
        case "revision": proof.revisionID = UUID()
        case "clock": proof.logicalClock = 4
        case "installation": proof.installationID = UUID().uuidString
        case "digest": proof.digest = "non-deletion fingerprint"
        default: break
        }
        var journal = CloudSyncJournal()
        if mismatch != "unproven" { journal.items[key] = proof }
        let url = fixture.root.appendingPathComponent("untrusted.json")
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        let engine = try FullCloudSyncEngine(cloud: ModelContext(fixture.cloud), installationID: installation, journalURL: url)
        let operation = {
            try await engine.reconcile(digests: [:], temporarilyUnavailable: mismatch == "held" ? [key] : [],
                isValid: { mismatch != "revoked" }, load: { _ in nil },
                apply: { _, _ in Issue.record("Unproven repair cannot delete local content") })
        }
        if mismatch == "held" {
            _ = try await operation()
        } else if mismatch == "revoked" {
            await #expect(throws: CancellationError.self) { try await operation() }
        } else {
            await #expect(throws: FullCloudSyncError.self) { try await operation() }
        }
        #expect(!engine.didEnqueueChanges)
        let saved = try ModelContext(fixture.cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(saved.count == 1)
        #expect(saved.first?.revisionID == legacy.revisionID)
        #expect(saved.first?.isTombstone == false)
        #expect(saved.first?.contentDigest == "")
        #expect(saved.first?.payload == legacy.payload)
    }

    @Test("Reader validation identifies the exact invariant without disclosing cloud content",
        arguments: CloudRevisionValidation.Failure.allCases)
    func preciseRevisionValidationFailure(reason: CloudRevisionValidation.Failure) throws {
        let original = Data("private valid payload".utf8)
        let installation = UUID().uuidString
        let expected = CloudSyncCheckpoint(digest: CloudFileStore.digest(original), revisionID: UUID(),
            logicalClock: 5, installationID: installation)
        var key = "private/key"
        var clock: Int64 = 5
        var writer = installation
        var deleted = false
        var digest = try #require(expected.digest)
        var payload: Data? = original
        switch reason {
        case .itemKeyMismatch: key = "different/private/key"
        case .logicalClockMismatch: clock = 4
        case .installationMismatch: writer = UUID().uuidString
        case .missingPayload: payload = nil
        case .unexpectedDeletedPayload: deleted = true
        case .digestMetadataMismatch: digest = "mismatched metadata"
        case .payloadDigestMismatch: payload = Data("private changed payload".utf8)
        }
        #expect(throws: FullCloudSyncError.revisionValidation(reason)) {
            try CloudRevisionValidation.validate(key: key, clock: clock, installation: writer,
                isDeleted: deleted, contentDigest: digest, payload: payload,
                expectedKey: "private/key", expected: expected)
        }
        let error = FullCloudSyncError.revisionValidation(reason) as NSError
        #expect(error.domain == "SIFT.FullCloudSync")
        #expect(error.code == 100 + reason.rawValue)
        #expect(error.userInfo.isEmpty)
        #expect(!error.localizedDescription.contains("private"))
    }

    @Test("Valid payload, empty data and deletion retain their distinct meanings")
    func validRevisionPayloadAndDeletion() throws {
        let installation = UUID().uuidString
        let payloads: [Data?] = [Data("valid".utf8), Data(), nil]
        for payload in payloads {
            let expected = CloudSyncCheckpoint(digest: payload.map(CloudFileStore.digest), revisionID: UUID(),
                logicalClock: 5, installationID: installation)
            try CloudRevisionValidation.validate(key: "Todo/synthetic", clock: 5, installation: installation,
                isDeleted: payload == nil, contentDigest: expected.digest ?? "", payload: payload,
                expectedKey: "Todo/synthetic", expected: expected)
        }
    }

    @Test("A prepared store and deferred content cannot erase a failed content reconciliation")
    func deferredContentRetainsFailure() {
        var state = FullCloudSyncFailureState()
        state.record(FullCloudSyncError.invalidRevision, channel: .reconciliation)
        let original = state.failures[.reconciliation]
        state.prepared()
        state.reconciledContent(completed: false)
        #expect(state.failures[.reconciliation] == original)
        state.reconciledContent(completed: true)
        #expect(state.failures.isEmpty)
    }

    @Test("A successful app-data export cannot resolve an independent import or reconciliation failure")
    func exportRetainsIndependentFailures() {
        var state = FullCloudSyncFailureState()
        let failure = NSError(domain: "SyntheticCloud", code: 17)
        state.record(failure, channel: .transport(.appData, .export))
        state.record(failure, channel: .transport(.appData, .import))
        state.record(FullCloudSyncError.invalidRevision, channel: .reconciliation)
        state.recoveredTransport(store: .appData, event: .export)
        #expect(state.failures[.transport(.appData, .export)] == nil)
        #expect(state.failures[.transport(.appData, .import)] != nil)
        #expect(state.failures[.reconciliation] != nil)
        state.reconciledContent(completed: true)
        #expect(state.failures.count == 1)
        state.recoveredTransport(store: .appData, event: .import)
        #expect(state.failures.isEmpty)
    }

    @Test("Transport recovery is specific to both the store and event type")
    func transportRecoveryIsStoreAndEventSpecific() {
        var state = FullCloudSyncFailureState()
        let failure = NSError(domain: "SyntheticCloud", code: 23)
        state.record(failure, channel: .transport(.legacy, .import))
        state.record(failure, channel: .transport(.appData, .setup))
        state.recoveredTransport(store: .appData, event: .import)
        state.recoveredTransport(store: .appData, event: .export)
        #expect(state.failures.count == 2)
        state.recoveredTransport(store: .legacy, event: .import)
        #expect(state.failures.count == 1)
        #expect(state.failures[.transport(.appData, .setup)] != nil)
        state.recoveredTransport(store: .appData, event: .setup)
        #expect(state.failures.isEmpty)
    }

    @Test("Preparation recovery does not hide content or transport failures")
    func preparationRecoveryIsIndependent() {
        var state = FullCloudSyncFailureState()
        let failure = NSError(domain: "SyntheticCloud", code: 29)
        state.record(failure, channel: .preparation)
        state.record(failure, channel: .reconciliation)
        state.record(failure, channel: .transport(.appData, .export))
        state.prepared()
        #expect(state.failures[.preparation] == nil)
        #expect(state.failures.count == 2)
    }

    @Test("Cancellation preserves the real error and failure details omit private descriptions")
    func cancellationPreservesSafeFailureDetails() {
        var state = FullCloudSyncFailureState()
        state.record(NSError(domain: "SyntheticCloud", code: 31,
            userInfo: [NSLocalizedDescriptionKey: "private record and credential text"]), channel: .reconciliation)
        let original = state.failures[.reconciliation]
        state.record(CancellationError(), channel: .reconciliation)
        #expect(state.failures[.reconciliation] == original)
        #expect(original?.domain == "SyntheticCloud")
        #expect(original?.code == 31)
        #expect(original?.isIdentityConflict == false)
        #expect(!String(describing: state).contains("private record and credential text"))
    }

    @Test("A new account lifecycle starts without failures from the previous account")
    func newAccountFailureStateIsEmpty() {
        var state = FullCloudSyncFailureState()
        state.record(FullCloudSyncError.invalidRevision, channel: .reconciliation)
        state.record(NSError(domain: "SyntheticCloud", code: 37), channel: .transport(.appData, .export))
        state = FullCloudSyncFailureState()
        #expect(state.failures.isEmpty)
    }

    @Test("An identity conflict cannot overwrite an independent ordinary error")
    func conflictAndOrdinaryFailureRemainIndependent() {
        var state = FullCloudSyncFailureState()
        state.record(NSError(domain: "SyntheticCloud", code: 41), channel: .transport(.appData, .import))
        state.record(CloudModelCodec.CodecError.duplicateIdentity("private-key"), channel: .reconciliation)
        #expect(state.failures[.reconciliation]?.isIdentityConflict == true)
        #expect(state.failures.values.contains(where: { !$0.isIdentityConflict }))
        state.recoveredTransport(store: .appData, event: .import)
        #expect(state.failures.count == 1)
        let allConflicts = state.failures.values.allSatisfy(\.isIdentityConflict)
        #expect(allConflicts)
        #expect(!String(describing: state).contains("private-key"))
    }

    @Test("Cancelled device approval stops remaining connection families and all automatic retries stay quiet")
    func credentialCancellationStopsFamilies() async throws {
        var reads = [(String, Bool)]()
        try await KeychainStore.withSecurityOperationForTesting({ operation, query, _ in
            #expect(operation == "read")
            let context = query[kSecUseAuthenticationContext as String] as? LAContext
            let account = query[kSecAttrAccount as String] as? String ?? ""
            reads.append((account, context?.interactionNotAllowed == true))
            return (context?.interactionNotAllowed == true ? errSecInteractionNotAllowed : errSecUserCanceled, nil)
        }) {
            let connections = FullCloudConnectionSync(operations: FullCloudConnectionSync.Family.allCases.map { family in
                .init(family: family) {
                    // Legacy getters may swallow an error; the scope must still stop the family loop.
                    _ = try? KeychainStore.getDeviceOnly(service: "synthetic.full-cloud", account: family.rawValue)
                }
            })
            #expect(await connections.reconcile(userInitiated: true) == nil)
            #expect(connections.state == .cancelled)
            #expect(reads.count == 1)
            #expect(reads.first?.1 == false)
            #expect(connections.pendingFamilies == Set(FullCloudConnectionSync.Family.allCases))
            #expect(connections.blockedFamilies == [.gmailIMAP])
            for _ in 0..<34 { #expect(await connections.reconcile() == nil) }
            #expect(reads.count == 1)
            #expect(connections.state == .cancelled)

            // The same production content engine remains usable while connections await approval.
            let fixture = try CloudSyncFixture()
            defer { fixture.remove() }
            let peer = try fixture.peer("cancelled-connections")
            peer.values["Todo/retained"] = Data("saved task".utf8)
            try await peer.reconcile()
            #expect(try ModelContext(fixture.cloud).fetchCount(FetchDescriptor<CloudDataRevision>()) == 1)
            #expect(connections.state == .cancelled)
        }
    }

    @Test("A successful bounded attempt shares its context; 34 subsequent automatic passes cannot request UI")
    func successfulCredentialsDoNotRearmAuthentication() async throws {
        var interactiveContexts = Set<ObjectIdentifier>()
        var interactiveReads = 0
        var automaticReads = 0
        await KeychainStore.withSecurityOperationForTesting({ operation, query, _ in
            #expect(operation == "read")
            let context = query[kSecUseAuthenticationContext as String] as? LAContext
            if let context, !context.interactionNotAllowed {
                interactiveReads += 1
                interactiveContexts.insert(ObjectIdentifier(context))
            } else { automaticReads += 1 }
            return (errSecSuccess, Data("synthetic-credential".utf8) as NSData)
        }) {
            let connections = FullCloudConnectionSync(operations: FullCloudConnectionSync.Family.allCases.map { family in
                .init(family: family) {
                    _ = try KeychainStore.getDeviceOnly(service: "synthetic.full-cloud", account: family.rawValue)
                }
            })
            #expect(await connections.reconcile(userInitiated: true) == nil)
            #expect(connections.state == .prepared)
            #expect(connections.pendingFamilies.isEmpty)
            #expect(interactiveContexts.count == 1)
            #expect(interactiveReads == connections.familyCount)
            for _ in 0..<34 {
                #expect(await connections.reconcile() == nil)
                #expect(connections.state == .prepared)
                #expect(!connections.isAuthorizing)
            }
            #expect(interactiveReads == connections.familyCount)
            #expect(automaticReads == 34 * connections.familyCount)
        }
    }

    @Test("Blocked families remain awaiting explicit approval; ordinary sync never retries them interactively")
    func automaticCredentialBlockRequiresExplicitRetry() async throws {
        var contexts = [Bool]()
        await KeychainStore.withSecurityOperationForTesting({ _, query, _ in
            let noninteractive = (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
            contexts.append(noninteractive)
            return noninteractive ? (errSecInteractionNotAllowed, nil) : (errSecSuccess, Data("synthetic".utf8) as NSData)
        }) {
            let connections = FullCloudConnectionSync(operations: [.init(family: .outlookIMAP) {
                _ = try KeychainStore.getDeviceOnly(service: "synthetic.full-cloud", account: "outlook")
            }])
            #expect(await connections.reconcile() == nil)
            #expect(connections.state == .awaitingApproval)
            #expect(connections.blockedFamilies == [.outlookIMAP])
            #expect(await connections.reconcile() == nil)
            #expect(contexts == [true])
            #expect(await connections.reconcile(userInitiated: true) == nil)
            #expect(connections.state == .prepared)
            #expect(connections.pendingFamilies.isEmpty)
            #expect(contexts == [true, false])
        }
    }

    @Test("Quiet refresh preserves the last outcome instead of restarting visible progress", arguments: [false, true])
    func quietRefreshPreservesActionableOutcome(blocked: Bool) async {
        var suspend = false
        var entered: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        let connections = FullCloudConnectionSync(operations: [
            .init(family: .gmailIMAP) {
                if blocked { throw KeychainStoreError.authenticationRequired }
            },
            .init(family: .vocabulary) {
                if suspend {
                    await withCheckedContinuation { continuation in
                        release = continuation
                        entered?.resume(); entered = nil
                    }
                }
            }
        ])
        #expect(await connections.reconcile() == nil)
        let outcome = connections.state
        let completed = connections.completedFamilyCount
        suspend = true
        let refresh = Task { await connections.reconcile() }
        await withCheckedContinuation { continuation in
            entered = continuation
            if release != nil { entered?.resume(); entered = nil }
        }
        #expect(connections.state == outcome)
        #expect(connections.state != .checking)
        #expect(connections.currentFamily == nil)
        #expect(connections.completedFamilyCount == completed)
        release?.resume()
        _ = await refresh.value
        #expect(connections.state == (blocked ? .awaitingApproval : .prepared))
        #expect(connections.blockedFamilies == (blocked ? [.gmailIMAP] : []))
    }

    @Test("Approval tapped during a quiet pass starts once after that pass without overlapping")
    func approvalDuringQuietRefreshIsNotDropped() async {
        var calls = 0
        var entered: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        var authorized: CheckedContinuation<Void, Never>?
        let connections = FullCloudConnectionSync(operations: [.init(family: .google) {
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { continuation in
                    release = continuation
                    entered?.resume(); entered = nil
                }
            } else { authorized?.resume(); authorized = nil }
        }])
        let refresh = Task { await connections.reconcile() }
        await withCheckedContinuation { continuation in
            entered = continuation
            if release != nil { entered?.resume(); entered = nil }
        }
        connections.authorize()
        connections.authorize()
        #expect(calls == 1)
        await withCheckedContinuation { continuation in
            authorized = continuation
            release?.resume()
        }
        _ = await refresh.value
        // Await the authorization loop's final actor turn, not just its operation.
        while connections.isAuthorizing { await Task.yield() }
        #expect(calls == 2)
        #expect(connections.state == .prepared)
        #expect(connections.pendingFamilies.isEmpty)
    }

    @Test("Duplicate authorize taps and foreground-style passes cannot overlap an in-flight attempt")
    func credentialAuthorizationSingleFlight() async {
        var started = 0
        var release: CheckedContinuation<Void, Never>?
        let connections = FullCloudConnectionSync(operations: [.init(family: .google) {
            started += 1
            await withCheckedContinuation { release = $0 }
        }])
        connections.authorize()
        connections.authorize()
        while release == nil { await Task.yield() }
        #expect(connections.isAuthorizing)
        #expect(await connections.reconcile() == nil)
        #expect(started == 1)
        connections.cancelAuthorization()
        release?.resume()
        while connections.isAuthorizing { await Task.yield() }
        #expect(connections.state == .cancelled)
        #expect(await connections.reconcile() == nil)
        #expect(started == 1)
    }

    @Test("Background cancellation cannot turn quiet connection work into a new approval requirement", arguments: [false, true])
    func automaticCancellationDoesNotRequireApproval(previouslyBlocked: Bool) async throws {
        var reads = [(String, Bool)]()
        var protected = previouslyBlocked
        var suspend = false
        var entered: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        await KeychainStore.withSecurityOperationForTesting({ _, query, _ in
            let account = query[kSecAttrAccount as String] as? String ?? ""
            let quiet = (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
            reads.append((account, quiet))
            if account == "blocked", protected { return (errSecInteractionNotAllowed, nil) }
            return (errSecSuccess, Data("synthetic".utf8) as NSData)
        }) {
            let connections = FullCloudConnectionSync(operations: [
                .init(family: .google) {
                    if suspend {
                        await withCheckedContinuation { continuation in
                            release = continuation
                            entered?.resume()
                            entered = nil
                        }
                    }
                    _ = try KeychainStore.getDeviceOnly(service: "synthetic.lifecycle", account: "google")
                },
                .init(family: .outlookIMAP) {
                    _ = try KeychainStore.getDeviceOnly(service: "synthetic.lifecycle", account: "blocked")
                }
            ])
            #expect(await connections.reconcile() == nil)
            let priorState = connections.state
            let priorBlocked = connections.blockedFamilies
            let priorPending = connections.pendingFamilies
            let priorCount = connections.completedFamilyCount
            let initialReadCount = reads.count
            suspend = true
            let interrupted = Task { @MainActor in
                try await KeychainStore.withoutAuthenticationUI {
                    await connections.reconcile()
                }
            }
            await withCheckedContinuation { continuation in
                entered = continuation
                if release != nil { entered?.resume(); entered = nil }
            }
            interrupted.cancel()
            release?.resume()
            _ = try? await interrupted.value
            #expect(connections.state == priorState)
            #expect(connections.blockedFamilies == priorBlocked)
            #expect(connections.pendingFamilies == priorPending)
            #expect(connections.completedFamilyCount == priorCount)
            #expect(connections.currentFamily == nil)
            #expect(reads.count == initialReadCount)
            suspend = false
            protected = false
            #expect(await connections.reconcile() == nil)
            #expect(reads.count == initialReadCount + (previouslyBlocked ? 1 : 2))
            let allQueriesWereQuiet = reads.allSatisfy { $0.1 }
            #expect(allQueriesWereQuiet)
            #expect(connections.blockedFamilies == priorBlocked)
            #expect(connections.state == (previouslyBlocked ? .awaitingApproval : .prepared))
        }
    }

    @Test("Non-authentication connection failures remain failures, not a completed account sync")
    func credentialStorageFailureIsNotCompletion() async {
        let connections = FullCloudConnectionSync(operations: [.init(family: .google) {
            throw KeychainStoreError.security(errSecNotAvailable)
        }])
        let error = await connections.reconcile()
        #expect((error as? KeychainStoreError) == .security(errSecNotAvailable))
        #expect(connections.state == .failed)
        #expect(connections.pendingFamilies == [.google])
    }

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
        #expect(remote.filter { $0.itemKey == key }.allSatisfy { $0.isTombstone && $0.payload == nil })
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
        await #expect(throws: FullCloudSyncError.revisionValidation(.payloadDigestMismatch)) {
            try await peer.reconcile()
        }
        #expect(peer.values[key] == Data("changed".utf8))
        #expect(peer.engine.journal.items[key]?.revisionID != record.revisionID)
        #expect(try context.fetch(FetchDescriptor<CloudDataRevision>()).contains { $0.revisionID == record.revisionID })
        #expect(record.payload == Data("original".utf8))
    }

    @Test("A non-deleted revision with missing bytes is held intact and retries the same revision after delivery")
    func missingPayloadIsRetainedUntilSameRevisionIsReadable() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let peer = try fixture.peer("receiver")
        let key = "Todo/held-revision"
        let retained = Data("retained local value".utf8)
        let incoming = Data("validated incoming value".utf8)
        peer.values[key] = retained
        let context = ModelContext(fixture.cloud)
        let revision = CloudDataRevision(itemKey: key, clock: 1,
            installationID: UUID().uuidString, payload: nil)
        revision.isTombstone = false
        revision.contentDigest = CloudFileStore.digest(incoming)
        context.insert(revision)
        try context.save()
        let id = revision.revisionID

        await #expect(throws: FullCloudSyncError.revisionValidation(.missingPayload)) {
            try await peer.reconcile()
        }
        #expect(peer.values[key] == retained)
        #expect(peer.engine.journal.items[key] == nil)
        #expect(peer.engine.journal.pendingApplies[key]?.target.revisionID == id)
        #expect(!peer.engine.didEnqueueChanges)
        #expect(try context.fetchCount(FetchDescriptor<CloudDataRevision>()) == 1)
        #expect(revision.payload == nil)

        // Simulate later delivery to the same immutable cloud revision. Never
        // synthesize replacement bytes from the retained local value.
        revision.payload = incoming
        try context.save()
        try await peer.reconcile()
        #expect(peer.values[key] == incoming)
        #expect(peer.engine.journal.items[key]?.revisionID == id)
        #expect(peer.engine.journal.pendingApplies[key] == nil)
        #expect(!peer.engine.didEnqueueChanges)
        #expect(try context.fetchCount(FetchDescriptor<CloudDataRevision>()) == 1)
    }

    @Test("A missing early asset preserves both revisions while independent later restores and writes progress")
    func missingPayloadDoesNotStarveIndependentKeys() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let peer = try fixture.peer("receiver")
        let heldKey = "Todo/a-held"
        let restoreKey = "Todo/y-restore"
        let publishKey = "Todo/z-publish"
        let retained = Data("retained original".utf8)
        let delivered = Data("eventually delivered".utf8)
        let restored = Data("independent remote".utf8)
        let published = Data("independent local".utf8)
        peer.values[heldKey] = retained
        peer.values[publishKey] = published
        let context = ModelContext(fixture.cloud)
        let old = CloudDataRevision(itemKey: heldKey, clock: 1,
            installationID: UUID().uuidString, payload: retained)
        let missing = CloudDataRevision(itemKey: heldKey, clock: 2,
            installationID: UUID().uuidString, payload: nil)
        missing.isTombstone = false
        missing.contentDigest = CloudFileStore.digest(delivered)
        let independent = CloudDataRevision(itemKey: restoreKey, clock: 1,
            installationID: UUID().uuidString, payload: restored)
        context.insert(old); context.insert(missing); context.insert(independent)
        try context.save()

        await #expect(throws: FullCloudSyncError.revisionValidation(.missingPayload)) {
            try await peer.reconcile()
        }
        #expect(peer.values[heldKey] == retained)
        #expect(peer.values[restoreKey] == restored)
        #expect(peer.engine.journal.items[heldKey] == nil)
        #expect(peer.engine.journal.pendingApplies[heldKey]?.target.revisionID == missing.revisionID)
        #expect(peer.engine.journal.items[restoreKey]?.revisionID == independent.revisionID)
        #expect(peer.engine.journal.items[publishKey]?.digest == CloudFileStore.digest(published))
        #expect(peer.engine.didEnqueueChanges)
        let saved = try ModelContext(fixture.cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(saved.filter { $0.itemKey == heldKey }.count == 2)
        #expect(saved.contains { $0.revisionID == old.revisionID && $0.payload == retained })
        #expect(saved.contains { $0.revisionID == missing.revisionID && $0.payload == nil && !$0.isTombstone })
        #expect(saved.contains { $0.itemKey == publishKey && $0.payload == published })

        // A restart still reports the held asset instead of false completion,
        // but does not republish already committed unrelated content.
        let restarted = try fixture.peer("receiver", installation: peer.installation)
        restarted.values = peer.values
        await #expect(throws: FullCloudSyncError.revisionValidation(.missingPayload)) {
            try await restarted.reconcile()
        }
        #expect(!restarted.engine.didEnqueueChanges)
        #expect(restarted.values[heldKey] == retained)
        #expect(try ModelContext(fixture.cloud).fetchCount(FetchDescriptor<CloudDataRevision>()) == saved.count)
    }

    @Test("Missing bytes cannot acknowledge pending publication metadata or overwrite its suspect revision")
    func missingPayloadRetainsPublicationIntentAndAllowsOtherWrites() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let peer = try fixture.peer("publisher")
        let heldKey = "Todo/a-held-publication"
        let data = Data("original pending source".utf8)
        peer.values[heldKey] = data
        peer.failLoad = true
        await #expect(throws: CloudFixtureError.self) { try await peer.reconcile() }
        let pending = try #require(peer.engine.journal.pendingPublications[heldKey])
        let context = ModelContext(fixture.cloud)
        let missing = CloudDataRevision(itemKey: heldKey, clock: pending.logicalClock,
            installationID: pending.installationID, payload: nil)
        missing.revisionID = pending.revisionID
        missing.isTombstone = false
        missing.contentDigest = try #require(pending.digest)
        context.insert(missing)
        try context.save()
        peer.failLoad = false
        let otherKey = "Todo/z-independent"
        let otherData = Data("independent pending source".utf8)
        peer.values[otherKey] = otherData

        await #expect(throws: FullCloudSyncError.revisionValidation(.missingPayload)) {
            try await peer.reconcile()
        }
        #expect(peer.values[heldKey] == data)
        #expect(peer.engine.journal.items[heldKey] == nil)
        #expect(peer.engine.journal.pendingPublications[heldKey] == pending)
        #expect(peer.engine.journal.items[otherKey]?.digest == CloudFileStore.digest(otherData))
        let saved = try ModelContext(fixture.cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(saved.filter { $0.itemKey == heldKey }.count == 1)
        #expect(saved.contains { $0.revisionID == pending.revisionID && $0.payload == nil && !$0.isTombstone })
        #expect(saved.contains { $0.itemKey == otherKey && $0.payload == otherData })

        missing.payload = data
        try context.save()
        try await peer.reconcile()
        #expect(peer.engine.journal.pendingPublications[heldKey] == nil)
        #expect(peer.engine.journal.items[heldKey] == pending)
        #expect(!peer.engine.didEnqueueChanges)
    }

    @Test("Missing preference bytes cannot let dependent later bodies use an unvalidated representation")
    func missingPreferencePayloadStopsDependentBodies() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        let peer = try fixture.peer("receiver")
        let context = ModelContext(fixture.cloud)
        let missing = CloudDataRevision(itemKey: "preference/synthetic-marker", clock: 1,
            installationID: UUID().uuidString, payload: nil)
        missing.isTombstone = false
        missing.contentDigest = CloudFileStore.digest(Data("marker".utf8))
        let body = CloudDataRevision(itemKey: "EmailMessage/dependent", clock: 1,
            installationID: UUID().uuidString, payload: Data("dependent body".utf8))
        context.insert(missing); context.insert(body)
        try context.save()
        await #expect(throws: FullCloudSyncError.revisionValidation(.missingPayload)) {
            try await peer.reconcile()
        }
        #expect(peer.values.isEmpty)
        #expect(peer.engine.journal.items.isEmpty)
        #expect(!peer.engine.didEnqueueChanges)
        #expect(try context.fetchCount(FetchDescriptor<CloudDataRevision>()) == 2)
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
        source.values = try CloudModelCodec.capture(app: sourceApp, email: sourceEmail, meeting: sourceMeeting).validatedRecords()
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

    @Test("Periodic worker skips idle 20s ticks, runs a 5-minute safety pass, and never skips edits, cloud imports, conflicts, deletions or replays")
    func periodicTickSkipsIdleAndRunsOnChangesSafetyConflictsDeletionsAndReplays() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        func context(_ schema: Schema) throws -> ModelContext {
            let ctx = ModelContext(try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
            ctx.autosaveEnabled = false
            return ctx
        }
        let app = try context(AppDataContainer.appSchema)
        let email = try context(AppDataContainer.emailSchema)
        let meeting = try context(AppDataContainer.meetingSchema)
        let cloudContext = ModelContext(fixture.cloud)
        cloudContext.autosaveEnabled = false

        let journalURL = fixture.root.appendingPathComponent("periodic-journal.json")
        let archiveURL = fixture.root.appendingPathComponent("periodic-conflicts.json")
        let installation = UUID().uuidString
        let engine = try FullCloudSyncEngine(cloud: cloudContext, installationID: installation, journalURL: journalURL)
        let service = FullCloudSyncService(
            conflictApp: app, conflictEmail: email, conflictMeeting: meeting,
            engine: engine, archiveURL: archiveURL
        )
        service.attachIsolatedObserversForTesting()

        let todo = Todo(title: "Initial task")
        app.insert(todo)
        try app.save()

        var now = Date(timeIntervalSinceReferenceDate: 820_000_000)
        var passes = 0

        // 1. Initial tick runs full reconcile and establishes clean baseline.
        #expect(try await service.runIsolatedPeriodicTickForTesting(now: now, reconcilePassCount: &passes))
        #expect(passes == 1)

        // 2. Subsequent 20s ticks skip while nothing changed (< 5 min).
        for offset in [20.0, 40.0, 120.0, 299.0] {
            #expect(!(try await service.runIsolatedPeriodicTickForTesting(
                now: now.addingTimeInterval(offset),
                reconcilePassCount: &passes
            )))
        }
        #expect(passes == 1)

        // 3. Slow safety full pass runs at 5 minutes, then returns to skipping when clean.
        now = now.addingTimeInterval(FullCloudSyncService.safetyFullPassInterval)
        #expect(try await service.runIsolatedPeriodicTickForTesting(now: now, reconcilePassCount: &passes))
        #expect(passes == 2)
        now = now.addingTimeInterval(20)
        #expect(!(try await service.runIsolatedPeriodicTickForTesting(now: now, reconcilePassCount: &passes)))
        #expect(passes == 2)

        // 4. Local edit triggers periodic tick immediately.
        todo.title = "Updated task"
        try app.save()
        now = now.addingTimeInterval(20)
        #expect(try await service.runIsolatedPeriodicTickForTesting(now: now, reconcilePassCount: &passes))
        #expect(passes == 3)
        now = now.addingTimeInterval(20)
        #expect(!(try await service.runIsolatedPeriodicTickForTesting(now: now, reconcilePassCount: &passes)))

        // 5. Local deletion never skips and publishes a tombstone.
        let todoKey = "Todo/" + todo.id.uuidString.lowercased()
        app.delete(todo)
        try app.save()
        now = now.addingTimeInterval(20)
        #expect(try await service.runIsolatedPeriodicTickForTesting(now: now, reconcilePassCount: &passes))
        #expect(passes == 4)
        #expect(engine.journal.items[todoKey]?.digest == nil)

        // 6. Cloud import signal never skips and restores incoming record.
        let remoteTodo = Todo(title: "Remote incoming")
        let tempApp = try context(AppDataContainer.appSchema)
        tempApp.insert(remoteTodo)
        try tempApp.save()
        let remoteSnapshot = try CloudModelCodec.capture(app: tempApp, email: email, meeting: meeting)
        let remoteKey = "Todo/" + remoteTodo.id.uuidString.lowercased()
        cloudContext.insert(CloudDataRevision(
            itemKey: remoteKey, clock: 10,
            installationID: UUID().uuidString,
            payload: remoteSnapshot.records[remoteKey]
        ))
        try cloudContext.save()
        service.recordCloudImportSignalForTesting()
        now = now.addingTimeInterval(20)
        #expect(try await service.runIsolatedPeriodicTickForTesting(now: now, reconcilePassCount: &passes))
        #expect(passes == 5)
        // Restore sets rerunForLocalSave for post-restore verification; next tick settles clean.
        now = now.addingTimeInterval(20)
        #expect(try await service.runIsolatedPeriodicTickForTesting(now: now, reconcilePassCount: &passes))
        #expect(passes == 6)
        now = now.addingTimeInterval(20)
        #expect(!(try await service.runIsolatedPeriodicTickForTesting(now: now, reconcilePassCount: &passes)))

        // 7. Pending conflict never skips periodic passes until resolved.
        let localRestored = try #require(app.fetch(FetchDescriptor<Todo>()).first { $0.id == remoteTodo.id })
        localRestored.title = "Competing local edit"
        try app.save()
        try #require(tempApp.fetch(FetchDescriptor<Todo>()).first).title = "Competing cloud edit"
        try tempApp.save()
        let competingSnapshot = try CloudModelCodec.capture(app: tempApp, email: email, meeting: meeting)
        cloudContext.insert(CloudDataRevision(
            itemKey: remoteKey, clock: 11,
            installationID: UUID().uuidString,
            payload: competingSnapshot.records[remoteKey]
        ))
        try cloudContext.save()
        now = now.addingTimeInterval(20)
        #expect(try await service.runIsolatedPeriodicTickForTesting(now: now, reconcilePassCount: &passes))
        #expect(!service.conflicts.isEmpty)
        // Even without any further local or cloud signals, a pending conflict must NOT skip!
        now = now.addingTimeInterval(20)
        #expect(service.shouldRunPeriodicSynchronization(now: now))
        #expect(try await service.runIsolatedPeriodicTickForTesting(now: now, reconcilePassCount: &passes))

        // 8. Pending replay / deletion intent in journal never skips!
        let replayFixture = try CloudSyncFixture()
        defer { replayFixture.remove() }
        try FileManager.default.createDirectory(at: replayFixture.root, withIntermediateDirectories: true)
        let replayJournalURL = replayFixture.root.appendingPathComponent("replay-journal.json")
        var replayJournal = CloudSyncJournal()
        let deletionReplayKey = "Todo/" + UUID().uuidString.lowercased()
        replayJournal.pendingPublications[deletionReplayKey] = CloudSyncCheckpoint(
            digest: nil, revisionID: UUID(), logicalClock: 25, installationID: installation
        )
        try JSONEncoder().encode(replayJournal).write(to: replayJournalURL, options: .atomic)
        let replayEngine = try FullCloudSyncEngine(
            cloud: ModelContext(replayFixture.cloud), installationID: installation, journalURL: replayJournalURL
        )
        let replayService = FullCloudSyncService(
            conflictApp: try context(AppDataContainer.appSchema),
            conflictEmail: try context(AppDataContainer.emailSchema),
            conflictMeeting: try context(AppDataContainer.meetingSchema),
            engine: replayEngine,
            archiveURL: fixture.root.appendingPathComponent("replay-conflicts.json")
        )
        replayService.attachIsolatedObserversForTesting()
        var replayPasses = 0
        #expect(replayService.shouldRunPeriodicSynchronization(now: now))
        #expect(try await replayService.runIsolatedPeriodicTickForTesting(now: now, reconcilePassCount: &replayPasses))
        #expect(replayPasses == 1)
        #expect(replayEngine.journal.pendingPublications[deletionReplayKey] == nil)
        #expect(replayEngine.journal.items[deletionReplayKey]?.digest == nil)
        // Once the replay finishes cleanly, subsequent idle ticks skip again.
        now = now.addingTimeInterval(20)
        #expect(!(try await replayService.runIsolatedPeriodicTickForTesting(now: now, reconcilePassCount: &replayPasses)))
        #expect(replayPasses == 1)
    }

    @Test("Device-local defaults writes never wake the periodic pass, but a changed portable preference does")
    func nonPortableDefaultsWritesDoNotDefeatPeriodicSkip() async throws {
        let fixture = try CloudSyncFixture()
        defer { fixture.remove() }
        func context(_ schema: Schema) throws -> ModelContext {
            let ctx = ModelContext(try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
            ctx.autosaveEnabled = false
            return ctx
        }
        let cloudContext = ModelContext(fixture.cloud)
        cloudContext.autosaveEnabled = false
        let engine = try FullCloudSyncEngine(cloud: cloudContext, installationID: UUID().uuidString,
            journalURL: fixture.root.appendingPathComponent("defaults-journal.json"))
        let service = FullCloudSyncService(
            conflictApp: try context(AppDataContainer.appSchema),
            conflictEmail: try context(AppDataContainer.emailSchema),
            conflictMeeting: try context(AppDataContainer.meetingSchema),
            engine: engine, archiveURL: fixture.root.appendingPathComponent("defaults-conflicts.json"))
        service.attachIsolatedObserversForTesting()
        let defaults = UserDefaults.standard
        let localKey = "sift.local.mailAnalysisAttempt.\(UUID().uuidString)"
        let portableKey = "pieroot.todo.periodicSkipProbe.\(UUID().uuidString)"
        defer {
            defaults.removeObject(forKey: localKey)
            defaults.removeObject(forKey: portableKey)
        }
        #expect(!CloudPreferenceStore.isUserPreference(localKey))
        #expect(CloudPreferenceStore.isUserPreference(portableKey))

        var passes = 0
        let now = Date(timeIntervalSinceReferenceDate: 830_000_000)
        #expect(try await service.runIsolatedPeriodicTickForTesting(now: now, reconcilePassCount: &passes))
        #expect(passes == 1)
        #expect(!service.shouldRunPeriodicSynchronization(now: now.addingTimeInterval(20)))

        // Retry markers written while mail analysis runs: many notifications, no wake-up.
        for index in 0..<5 {
            defaults.set(Date().timeIntervalSince1970 + Double(index), forKey: localKey)
            service.handleDefaultsChange()
        }
        #expect(!service.shouldRunPeriodicSynchronization(now: now.addingTimeInterval(40)))
        #expect(!(try await service.runIsolatedPeriodicTickForTesting(
            now: now.addingTimeInterval(40), reconcilePassCount: &passes)))
        #expect(passes == 1)

        // A real portable preference change is a local change and must run.
        defaults.set("changed-by-user", forKey: portableKey)
        service.handleDefaultsChange()
        #expect(service.shouldRunPeriodicSynchronization(now: now.addingTimeInterval(60)))
        #expect(try await service.runIsolatedPeriodicTickForTesting(
            now: now.addingTimeInterval(60), reconcilePassCount: &passes))
        #expect(passes == 2)
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

/// Historical schema exists only to exercise a real on-disk additive migration.
private enum LegacyFullCloudSchema {
    @Model
    final class CloudDataRevision {
        var revisionID: UUID = UUID()
        @Attribute(.allowsCloudEncryption) var itemKey: String = ""
        var logicalClock: Int64 = 0
        var installationID: String = ""
        var isDeleted: Bool = false
        var contentDigest: String = ""
        @Attribute(.externalStorage, .allowsCloudEncryption) var payload: Data?

        init(key: String, payload: Data?) {
            itemKey = key
            logicalClock = 1
            installationID = UUID().uuidString
            isDeleted = payload == nil
            contentDigest = payload.map(CloudFileStore.digest) ?? ""
            self.payload = payload
        }
    }
}
