import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Meeting deletion fences")
@MainActor
struct MeetingDeletionFenceTests {
    @Test("Tombstone before marker or audio keeps late live file revisions absent")
    func tombstoneBeforeLiveFiles() async throws {
        for markerFirst in [true, false] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let track = try makeTrack(root: fixture.meetings)
            let recovery = pending(track)
            let marker = try JSONEncoder().encode(recovery)
            let audio = try Data(contentsOf: track.directoryURL.appendingPathComponent("part-00.flac"))
            let context = try makeContext()
            try MeetingCaptureRecoveryPersister.persist(recovery, in: context, rootURL: fixture.meetings)
            let row = try #require(try context.fetch(FetchDescriptor<MeetingRecord>()).first)
            // This is the integration order for CloudModelCodec.apply(nil):
            // fence durably, delete/save the model, then clean up content.
            try MeetingDeletionFence.recordDeletion(meetingID: row.meetingID, rootURL: fixture.meetings)
            context.delete(row)
            try context.save()
            try MeetingDeletionFence.removeDeletedContent(meetingID: track.meetingID, rootURL: fixture.meetings)
            let revisions = markerFirst
                ? [("capture-recovery.json", marker), ("audio/part-00.flac", audio)]
                : [("audio/part-00.flac", audio), ("capture-recovery.json", marker)]
            // Recreate the transfer actor for every replay: fences cannot depend
            // on the lifetime of the service, its journal cache or foreground.
            for _ in 0..<2 {
                let store = CloudFileStore(root: fixture.root)
                for (name, bytes) in revisions {
                    let result = try await store.apply(key: key(track.meetingID, name), payload: bytes, expectedDigest: nil)
                    #expect(result == .awaitingModelRestore)
                }
                #expect(try await store.capture().isEmpty)
                #expect(MeetingCaptureRecoveryStore.scan(rootURL: fixture.meetings).recoveries.isEmpty)
                #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
                #expect(!FileManager.default.fileExists(atPath: track.directoryURL.deletingLastPathComponent().path))
            }
        }
    }

    @Test("Restart and foreground recovery cannot resurrect a deleted disk-backed row")
    func restartAndForegroundRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let track = try makeTrack(root: fixture.meetings)
        let recovery = pending(track)
        let modelURL = fixture.root.appendingPathComponent("meeting-test.store")
        do {
            let context = try makeContext(storeURL: modelURL)
            try MeetingCaptureRecoveryPersister.persist(recovery, in: context, rootURL: fixture.meetings)
            try MeetingCaptureRecoveryStore.write(recovery, rootURL: fixture.meetings)
            let row = try #require(try context.fetch(FetchDescriptor<MeetingRecord>()).first)
            try MeetingDeletionFence.recordDeletion(meetingID: track.meetingID, rootURL: fixture.meetings)
            context.delete(row)
            try context.save()
            // Simulate process death before journal/audio cleanup.
        }
        do {
            let reopened = try makeContext(storeURL: modelURL)
            #expect(try reopened.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
            let scan = MeetingCaptureRecoveryStore.scan(rootURL: fixture.meetings)
            #expect(scan.recoveries.isEmpty && scan.unreadableMarkerNames.isEmpty)
            // A view may still hold a recovery captured before the tombstone.
            try MeetingCaptureRecoveryPersister.persist(recovery, in: reopened, rootURL: fixture.meetings)
            #expect(try reopened.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
            #expect(try MeetingDeletionFence.isDeleted(meetingID: track.meetingID, rootURL: fixture.meetings))
            #expect(!FileManager.default.fileExists(atPath: track.directoryURL.path))
        }
        let foreground = try makeContext(storeURL: modelURL)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: fixture.meetings).recoveries.isEmpty)
        #expect(try foreground.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
    }

    @Test("Parent deletion fences unknown late children in either file delivery order")
    func parentDeletionAndLateChildFiles() async throws {
        for markerFirst in [true, false] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let parentID = UUID().uuidString.lowercased()
            let track = try makeTrack(root: fixture.meetings)
            let marker = try JSONEncoder().encode(pending(track, parentID: parentID))
            let audio = try Data(contentsOf: track.directoryURL.appendingPathComponent("part-00.flac"))
            try FileManager.default.removeItem(at: track.directoryURL.deletingLastPathComponent())
            try MeetingDeletionFence.recordDeletion(meetingID: parentID, rootURL: fixture.meetings)
            let store = CloudFileStore(root: fixture.root)
            let revisions = markerFirst
                ? [("capture-recovery.json", marker), ("audio/part-00.flac", audio)]
                : [("audio/part-00.flac", audio), ("capture-recovery.json", marker)]
            for (name, bytes) in revisions {
                try await store.apply(key: key(track.meetingID, name), payload: bytes, expectedDigest: nil)
            }
            // Refusing a live marker cannot delete bytes delivered earlier.
            if !markerFirst {
                #expect(try Data(contentsOf: track.directoryURL.appendingPathComponent("part-00.flac")) == audio)
            }
            let deleted = try await store.apply(key: key(track.meetingID, "audio/part-00.flac"),
                payload: nil, expectedDigest: nil)
            #expect(deleted == .applied)
            #expect(try MeetingDeletionFence.isDeleted(meetingID: track.meetingID, rootURL: fixture.meetings))
            #expect(!FileManager.default.fileExists(atPath: track.directoryURL.deletingLastPathComponent().path))
            #expect(MeetingCaptureRecoveryStore.scan(rootURL: fixture.meetings).recoveries.isEmpty)
            let context = try makeContext()
            try MeetingCaptureRecoveryPersister.persist(pending(track, parentID: parentID), in: context, rootURL: fixture.meetings)
            #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
        }
    }

    @Test("A parent fence blocks active foreground recovery and cached child persistence")
    func parentDeletionBlocksActiveAndCachedRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let parentID = UUID().uuidString.lowercased()
        let active = try makeTrack(root: fixture.meetings)
        try MeetingCaptureRecoveryStore.markActive(meetingID: active.meetingID, parentMeetingID: parentID,
            sourceKind: .microphone, sourceLabel: nil, sessionStartSample: 0,
            languageTag: "en-US", timezoneIdentifier: "UTC", directoryURL: active.directoryURL, rootURL: fixture.meetings)
        let stopped = try makeTrack(root: fixture.meetings)
        let cached = pending(stopped, parentID: parentID)
        try MeetingCaptureRecoveryStore.write(cached, rootURL: fixture.meetings)
        try MeetingDeletionFence.recordDeletion(meetingID: parentID, rootURL: fixture.meetings)
        let scan = MeetingCaptureRecoveryStore.scan(rootURL: fixture.meetings)
        #expect(scan.recoveries.isEmpty && scan.unreadableMarkerNames.isEmpty)
        let context = try makeContext()
        try MeetingCaptureRecoveryPersister.persist(cached, in: context, rootURL: fixture.meetings)
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
        for child in [active, stopped] {
            #expect(try MeetingDeletionFence.isDeleted(meetingID: child.meetingID, rootURL: fixture.meetings))
            #expect(!FileManager.default.fileExists(atPath: child.directoryURL.path))
        }
    }

    @Test("Another meeting's fence does not block an independent new UUID capture")
    func independentCaptureAfterDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldID = UUID().uuidString.lowercased()
        try MeetingDeletionFence.recordDeletion(meetingID: oldID, rootURL: fixture.meetings)
        let parentID = UUID().uuidString.lowercased()
        let track = try makeTrack(root: fixture.meetings)
        try MeetingCaptureRecoveryStore.markActive(meetingID: track.meetingID, parentMeetingID: parentID,
            sourceKind: .microphone, sourceLabel: nil, sessionStartSample: 0,
            languageTag: "en-US", timezoneIdentifier: "UTC", directoryURL: track.directoryURL, rootURL: fixture.meetings)
        try MeetingCaptureRecoveryStore.markStopped(meetingID: track.meetingID, audioManifest: track.audioManifest,
            provisionalResult: track.provisionalResult, rootURL: fixture.meetings)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: fixture.meetings).recoveries.map(\.meetingID) == [track.meetingID])
        let context = try makeContext()
        let parent = try MeetingInitialCapturePersister.persist(
            artifact: MeetingCaptureArtifact(meetingID: parentID, tracks: [track]),
            languageTag: "en-US", timezoneIdentifier: "UTC", in: context)
        #expect(parent.audioTrackIDs == [track.meetingID])
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).count == 2)
        let files = try await CloudFileStore(root: fixture.root).capture()
        #expect(files[key(track.meetingID, "audio/part-00.flac")] != nil)
        #expect(files.keys.allSatisfy { !$0.contains(oldID) && !$0.contains(".deletion-fences") })
    }

    @Test("Only an authoritative saved record restore reopens its fenced identity")
    func authoritativeRestore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let track = try makeTrack(root: fixture.meetings)
        let recovery = pending(track)
        let marker = try JSONEncoder().encode(recovery)
        let audio = try Data(contentsOf: track.directoryURL.appendingPathComponent("part-00.flac"))
        try MeetingDeletionFence.recordDeletion(meetingID: track.meetingID, rootURL: fixture.meetings)
        try MeetingDeletionFence.removeDeletedContent(meetingID: track.meetingID, rootURL: fixture.meetings)
        let store = CloudFileStore(root: fixture.root)
        let held = try await store.apply(key: key(track.meetingID, "capture-recovery.json"), payload: marker, expectedDigest: nil)
        #expect(held == .awaitingModelRestore)
        #expect(try MeetingDeletionFence.isDeleted(meetingID: track.meetingID, rootURL: fixture.meetings))
        // Main invokes this only for a newer live record selected by the engine,
        // never for a marker, after the authoritative model has been saved.
        let context = try makeContext()
        let record = MeetingRecord(meetingID: track.meetingID, languageTag: "en-US", timezoneIdentifier: "UTC")
        try record.replaceTranscriptionBase(track.provisionalResult, status: .ready)
        try record.update(audioManifest: track.audioManifest)
        context.insert(record)
        try context.save()
        try MeetingDeletionFence.recordAuthoritativeRestore(meetingID: track.meetingID, rootURL: fixture.meetings)
        try await store.apply(key: key(track.meetingID, "audio/part-00.flac"), payload: audio, expectedDigest: nil)
        try await store.apply(key: key(track.meetingID, "capture-recovery.json"), payload: marker, expectedDigest: nil)
        #expect(try Data(contentsOf: track.directoryURL.appendingPathComponent("part-00.flac")) == audio)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: fixture.meetings).recoveries.count == 1)
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).count == 1)
        let parentID = UUID().uuidString.lowercased()
        try MeetingDeletionFence.recordDeletion(meetingID: parentID, rootURL: fixture.meetings)
        try MeetingDeletionFence.recordDeletion(meetingID: track.meetingID, rootURL: fixture.meetings)
        try MeetingDeletionFence.recordAuthoritativeRestore(meetingID: track.meetingID, rootURL: fixture.meetings)
        #expect(try MeetingDeletionFence.isDeleted(meetingID: track.meetingID, parentMeetingID: parentID, rootURL: fixture.meetings))
    }

    @Test("Explicit local deletion durably fences before saving deleted models")
    func localDeletionFencesBeforeModelSave() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let track = try makeTrack(root: fixture.meetings)
        let recovery = pending(track)
        let marker = try JSONEncoder().encode(recovery)
        let context = try makeContext()
        try MeetingCaptureRecoveryPersister.persist(recovery, in: context, rootURL: fixture.meetings)
        let record = try #require(try context.fetch(FetchDescriptor<MeetingRecord>()).first)
        var saves = 0
        try MeetingAudioTrackDeletion.delete(parent: record, in: context, rootURL: fixture.meetings) { context in
            saves += 1
            if saves == 2 {
                #expect(try MeetingDeletionFence.isDeleted(meetingID: track.meetingID, rootURL: fixture.meetings))
            }
            try context.save()
        }
        #expect(try MeetingDeletionFence.isDeleted(meetingID: track.meetingID, rootURL: fixture.meetings))
        try await CloudFileStore(root: fixture.root).apply(key: key(track.meetingID, "capture-recovery.json"),
            payload: marker, expectedDigest: nil)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: fixture.meetings).recoveries.isEmpty)
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
    }

    @Test("An aborted cloud deletion preserves live audio after a later model edit, without clearing an older fence",
          arguments: [false, true])
    func failedCloudDeletionPreservesAudio(preexistingFence: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let track = try makeTrack(root: fixture.meetings)
        let meeting = try makeContext()
        let app = try makeContext(schema: AppDataContainer.appSchema)
        let email = try makeContext(schema: AppDataContainer.emailSchema)
        try MeetingCaptureRecoveryPersister.persist(pending(track), in: meeting, rootURL: fixture.meetings)
        let audioURL = track.directoryURL.appendingPathComponent("part-00.flac")
        let original = try Data(contentsOf: audioURL)
        let payloads = try CloudModelCodec.capture(app: app, email: email, meeting: meeting).validatedRecords()
        let recordKey = try #require(payloads.keys.first { $0.hasPrefix("MeetingRecord/") })
        if preexistingFence { try MeetingDeletionFence.recordDeletion(meetingID: track.meetingID, rootURL: fixture.meetings) }
        #expect(throws: InjectedSaveFailure.self) {
            try FullCloudSyncService.shared.applyModelRecord(key: recordKey, payload: nil,
                app: app, email: email, meeting: meeting, meetingRootURL: fixture.meetings,
                isAuthorized: { true }, save: { _ in throw InjectedSaveFailure.failed })
        }
        let retained = try #require(try meeting.fetch(FetchDescriptor<MeetingRecord>()).first)
        retained.summaryLanguageTag = "ko"
        retained.updatedAt = Date().addingTimeInterval(1)
        try meeting.save()
        #expect(try MeetingDeletionFence.isDeleted(meetingID: track.meetingID, rootURL: fixture.meetings) == preexistingFence)
        #expect(try Data(contentsOf: audioURL) == original)
        let store = CloudFileStore(root: fixture.root)
        let files = try await store.capture()
        let audioKey = key(track.meetingID, "audio/part-00.flac")
        if preexistingFence {
            #expect(files[audioKey] == nil)
        } else {
            let audio = try #require(files[audioKey])
            #expect(try await store.load(audio) == original)
        }
        #expect(retained.summaryLanguageTag == "ko")
    }

    @Test("Failed parent restoration holds original audio and tombstones across restart",
          arguments: ["newerSchema", "invalidMetadata", "saveFailure"])
    func failedParentRestoreHoldsOriginalFiles(mode: String) async throws {
        let origin = try Fixture(), receiver = try Fixture()
        defer { origin.remove(); receiver.remove() }
        let track = try makeTrack(root: origin.meetings)
        let otherTrack = try makeTrack(root: origin.meetings)
        let originalURL = track.directoryURL.appendingPathComponent("part-00.flac")
        let original = try Data(contentsOf: originalURL)
        let addedURL = track.directoryURL.appendingPathComponent("part-02.flac")
        try original.write(to: addedURL)
        let otherAudio = try Data(contentsOf: otherTrack.directoryURL.appendingPathComponent("part-00.flac"))
        let parentID = UUID().uuidString.lowercased()
        let sourceApp = try makeContext(schema: AppDataContainer.appSchema)
        let sourceEmail = try makeContext(schema: AppDataContainer.emailSchema)
        let sourceMeeting = try makeContext()
        let parent = MeetingRecord(meetingID: parentID, languageTag: "en-US", timezoneIdentifier: "UTC")
        parent.summaryEngineLabel = "Newer authoritative root"
        parent.audioTrackIDs = [track.meetingID]
        let child = MeetingRecord(meetingID: track.meetingID, languageTag: "en-US", timezoneIdentifier: "UTC")
        child.parentMeetingID = parentID
        try child.update(audioManifest: track.audioManifest)
        let other = MeetingRecord(meetingID: otherTrack.meetingID, languageTag: "en-US", timezoneIdentifier: "UTC")
        try other.update(audioManifest: otherTrack.audioManifest)
        sourceMeeting.insert(parent); sourceMeeting.insert(child); sourceMeeting.insert(other)
        let task = Todo(title: "Independent task must restore")
        sourceApp.insert(task)
        try sourceApp.save(); try sourceMeeting.save()
        let source = try CloudModelCodec.capture(app: sourceApp, email: sourceEmail, meeting: sourceMeeting)
        func recordKey(_ id: String) throws -> String {
            try #require(source.records.keys.first { (try? CloudModelCodec.meetingID(for: $0)) == id })
        }
        let parentKey = try recordKey(parentID), childKey = try recordKey(track.meetingID)
        let otherKey = try recordKey(otherTrack.meetingID)
        let taskKey = "Todo/" + task.id.uuidString.lowercased()
        let validParent = try #require(source.records[parentKey])
        var future = try #require(JSONSerialization.jsonObject(with: validParent) as? [String: Any])
        var fields = try #require(future["fields"] as? [String: String])
        fields["newerClientOnly"] = try JSONEncoder().encode("future schema value").base64EncodedString()
        future["fields"] = fields
        let futureParent = try JSONSerialization.data(withJSONObject: future, options: [.sortedKeys])
        let schema = Schema([CloudDataRevision.self])
        let cloud = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let cloudContext = ModelContext(cloud)
        cloudContext.autosaveEnabled = false
        let installation = UUID().uuidString
        cloudContext.insert(CloudDataRevision(itemKey: otherKey, clock: 1, installationID: installation, payload: source.records[otherKey]))
        try cloudContext.save()
        let app = try makeContext(schema: AppDataContainer.appSchema)
        let email = try makeContext(schema: AppDataContainer.emailSchema)
        let meeting = try makeContext()
        try CloudModelCodec.apply(key: otherKey, payload: source.records[otherKey], app: app, email: email, meeting: meeting)
        try meeting.save()
        let journalURL = receiver.root.appendingPathComponent("journal.json")
        var engine = try FullCloudSyncEngine(cloud: ModelContext(cloud), installationID: UUID().uuidString, journalURL: journalURL)
        let service = FullCloudSyncService(conflictApp: app, conflictEmail: email, conflictMeeting: meeting,
            engine: engine, archiveURL: receiver.root.appendingPathComponent("conflicts.json"))
        let store = CloudFileStore(root: receiver.root)
        let audioKey = key(track.meetingID, "audio/part-00.flac")
        let addedKey = key(track.meetingID, "audio/part-02.flac")
        let deletedKey = key(track.meetingID, "audio/part-01.flac")
        let otherAudioKey = key(otherTrack.meetingID, "audio/part-00.flac")
        try await store.apply(key: audioKey, payload: original, expectedDigest: nil)
        let receiverOriginal = receiver.meetings.appendingPathComponent(track.meetingID).appendingPathComponent("audio/part-00.flac")
        try MeetingDeletionFence.recordDeletion(meetingID: parentID, rootURL: receiver.meetings)
        try MeetingDeletionFence.recordDeletion(meetingID: track.meetingID, rootURL: receiver.meetings)
        if mode == "newerSchema" {
            #expect(throws: CloudModelCodec.CodecError.malformedPayload("MeetingRecord")) {
                try service.applyModelRecord(key: parentKey, payload: futureParent, app: app, email: email,
                    meeting: meeting, meetingRootURL: receiver.meetings, isAuthorized: { true })
            }
        }
        var rejectSave = mode == "saveFailure"
        var parentApplyCount = 0
        func reconcile() async throws {
            let snapshot = try CloudModelCodec.capture(app: app, email: email, meeting: meeting)
            let base = FullCloudFileScope(graph: try CloudModelCodec.meetingNamespaceGraph(snapshot),
                heldMeetingIDs: [], modelUnavailable: false, namespaceAuthorization: { _ in true })
            let files = try await store.captureInventory(isMeetingAuthorized: { base.authorizes($0) })
            var digests = snapshot.digests
            digests.merge(files.files.mapValues(\.digest)) { _, value in value }
            try await engine.reconcile(digests: digests, isKeyValid: { item in
                guard let id = CloudFileStore.meetingID(for: item) else { return true }
                return !files.unavailableMeetingIDs.contains(id)
                    && base.holding(meetingKeys: engine.unsettledMeetingKeys,
                        deletedMeetingKeys: engine.settledMeetingTombstones)
                    .authorizes(id, isFenced: files.fencedMeetingIDs.contains(id))
            }, load: { item in
                if let file = files.files[item] { return try await store.load(file) }
                return snapshot.records[item]
            }, apply: { item, payload in
                if CloudFileStore.meetingID(for: item) != nil {
                    let scope = base.holding(meetingKeys: engine.unsettledMeetingKeys,
                        deletedMeetingKeys: engine.settledMeetingTombstones)
                    let result = try await store.apply(key: item, payload: payload, expectedDigest: files.files[item]?.digest,
                        isMeetingAuthorized: { scope.authorizes($0) })
                    guard result == .applied else { throw CloudFileError.changingFile }
                } else {
                    let info = try CloudModelCodec.meetingNamespaceInfo(key: item, payload: payload ?? snapshot.records[item])
                    guard FullCloudFileScope.permitsModelParent(info?.parent, unsettledMeetingKeys: engine.unsettledMeetingKeys)
                    else { throw CloudFileError.changingFile }
                    if item == parentKey { parentApplyCount += 1 }
                    try service.applyModelRecord(key: item, payload: payload, app: app, email: email, meeting: meeting,
                        meetingRootURL: receiver.meetings, isAuthorized: { true }, save: { context in
                            if item == parentKey && rejectSave { throw InjectedSaveFailure.failed }
                            try context.save()
                        })
                }
            })
        }
        try await reconcile() // Establish the unrelated model's exact checkpoint.
        if mode == "saveFailure" {
            // Exercise a known graph with retained rows and an existing fence too.
            try CloudModelCodec.apply(key: parentKey, payload: validParent, app: app, email: email, meeting: meeting)
            try CloudModelCodec.apply(key: childKey, payload: source.records[childKey], app: app, email: email, meeting: meeting)
            let localRoot = try #require(meeting.fetch(FetchDescriptor<MeetingRecord>()).first { $0.meetingID == parentID })
            localRoot.summaryEngineLabel = "Older local root"
            try meeting.save()
            let localPayload = try #require(CloudModelCodec.capture(app: app, email: email, meeting: meeting).records[parentKey])
            #expect(CloudFileStore.digest(localPayload) != CloudFileStore.digest(validParent))
        }
        let rootRevision = CloudDataRevision(itemKey: parentKey, clock: 5, installationID: installation,
            payload: mode == "newerSchema" ? futureParent : validParent)
        if mode == "invalidMetadata" { rootRevision.installationID = "invalid-installation" }
        cloudContext.insert(rootRevision)
        cloudContext.insert(CloudDataRevision(itemKey: childKey, clock: 5, installationID: installation, payload: source.records[childKey]))
        cloudContext.insert(CloudDataRevision(itemKey: taskKey, clock: 5, installationID: installation, payload: source.records[taskKey]))
        let addedRevision = CloudDataRevision(itemKey: addedKey, clock: 5, installationID: installation, payload: original)
        let deletionRevision = CloudDataRevision(itemKey: deletedKey, clock: 5, installationID: installation, payload: nil)
        cloudContext.insert(CloudDataRevision(itemKey: audioKey, clock: 5, installationID: installation, payload: original))
        cloudContext.insert(addedRevision); cloudContext.insert(deletionRevision)
        cloudContext.insert(CloudDataRevision(itemKey: otherAudioKey, clock: 5, installationID: installation, payload: otherAudio))
        try cloudContext.save()
        for attempt in 0..<2 {
            if attempt == 1 {
                engine = try FullCloudSyncEngine(cloud: ModelContext(cloud), installationID: UUID().uuidString, journalURL: journalURL)
            }
            do { try await reconcile(); Issue.record("The actual schema/metadata/save failure must remain visible") }
            catch {
                if mode == "newerSchema" { #expect(error as? CloudModelCodec.CodecError == .malformedPayload("MeetingRecord")) }
                else if mode == "invalidMetadata" { #expect(error as? FullCloudSyncError == .invalidRevision) }
                else { #expect(error is InjectedSaveFailure) }
            }
            #expect(try Data(contentsOf: receiverOriginal) == original)
            #expect(try Data(contentsOf: originalURL) == original)
            #expect(try Data(contentsOf: addedURL) == original)
            #expect(try meeting.fetch(FetchDescriptor<MeetingRecord>()).count == (mode == "saveFailure" ? 3 : 1))
            #expect(try app.fetch(FetchDescriptor<Todo>()).first?.title == task.title)
            #expect(engine.journal.items[taskKey] != nil)
            #expect(engine.journal.items[otherAudioKey] != nil)
            for item in [audioKey, addedKey, deletedKey] {
                #expect(engine.journal.items[item] == nil)
                #expect(engine.journal.pendingPublications[item] == nil)
            }
            let saved = try ModelContext(cloud).fetch(FetchDescriptor<CloudDataRevision>())
            #expect(saved.filter { $0.itemKey == addedKey }.map(\.revisionID) == [addedRevision.revisionID])
            #expect(saved.first { $0.itemKey == addedKey }?.payload == original)
        }
        #expect(parentApplyCount == (mode == "invalidMetadata" ? 0 : 2))
        rejectSave = false
        rootRevision.installationID = installation
        cloudContext.insert(CloudDataRevision(itemKey: parentKey, clock: 20, installationID: installation, payload: validParent))
        try cloudContext.save()
        for _ in 0..<3 { try await reconcile() }
        #expect(try Data(contentsOf: receiverOriginal) == original)
        let receivedAdded = receiver.meetings.appendingPathComponent(track.meetingID).appendingPathComponent("audio/part-02.flac")
        #expect(try Data(contentsOf: receivedAdded) == original)
        #expect(engine.journal.items[addedKey]?.revisionID == addedRevision.revisionID)
        #expect(engine.journal.items[deletedKey]?.revisionID == deletionRevision.revisionID)
        #expect(engine.journal.pendingPublications.isEmpty && engine.journal.pendingApplies.isEmpty)
        #expect(try !MeetingDeletionFence.isDeleted(meetingID: parentID, rootURL: receiver.meetings))
        #expect(try !MeetingDeletionFence.isDeleted(meetingID: track.meetingID, rootURL: receiver.meetings))
        let final = try ModelContext(cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(final.filter { $0.itemKey == addedKey }.count == 1)
        #expect(final.first { $0.itemKey == addedKey }?.payload == original)
        #expect(try Data(contentsOf: addedURL) == original)
    }

    @Test("A fenced live-asset refusal remains pending across restart and cannot manufacture a file tombstone")
    func refusedAssetIsNotAnAppliedCheckpoint() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let track = try makeTrack(root: fixture.meetings)
        let url = track.directoryURL.appendingPathComponent("part-00.flac")
        let original = try Data(contentsOf: url)
        let item = key(track.meetingID, "audio/part-00.flac")
        try MeetingDeletionFence.recordDeletion(meetingID: track.meetingID, rootURL: fixture.meetings)
        let schema = Schema([CloudDataRevision.self])
        let cloud = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(cloud)
        let revision = CloudDataRevision(itemKey: item, clock: 1, installationID: UUID().uuidString, payload: original)
        context.insert(revision)
        try context.save()
        let store = CloudFileStore(root: fixture.root)
        let journalURL = fixture.root.appendingPathComponent("journal.json")
        for _ in 0..<2 {
            let engine = try FullCloudSyncEngine(cloud: ModelContext(cloud), installationID: UUID().uuidString, journalURL: journalURL)
            try await engine.reconcile(digests: [:], load: { _ in nil }, apply: { key, payload in
                let result = try await store.apply(key: key, payload: payload, expectedDigest: nil)
                guard result == .applied else { throw CloudFileError.changingFile }
            })
            #expect(engine.deferredKeys == [item])
            #expect(engine.journal.items[item] == nil)
            #expect(engine.journal.pendingApplies[item]?.target.revisionID == revision.revisionID)
            #expect(engine.journal.pendingPublications[item] == nil)
            #expect(try Data(contentsOf: url) == original)
            let saved = try ModelContext(cloud).fetch(FetchDescriptor<CloudDataRevision>())
            #expect(saved.count == 1 && saved.first?.revisionID == revision.revisionID)
            #expect(saved.first?.payload == original && saved.first?.isTombstone == false)
        }
    }

    @Test("An authoritative settled model deletion still permits its real file tombstones")
    func settledModelDeletionStillPublishesFileDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let track = try makeTrack(root: fixture.meetings)
        let app = try makeContext(schema: AppDataContainer.appSchema)
        let email = try makeContext(schema: AppDataContainer.emailSchema)
        let meeting = try makeContext()
        let record = MeetingRecord(meetingID: track.meetingID, languageTag: "en-US", timezoneIdentifier: "UTC")
        try record.update(audioManifest: track.audioManifest)
        meeting.insert(record)
        try meeting.save()
        let schema = Schema([CloudDataRevision.self])
        let cloud = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let engine = try FullCloudSyncEngine(cloud: ModelContext(cloud), installationID: UUID().uuidString,
            journalURL: fixture.root.appendingPathComponent("journal.json"))
        let store = CloudFileStore(root: fixture.root)
        let item = key(track.meetingID, "audio/part-00.flac")
        let originalSnapshot = try CloudModelCodec.capture(app: app, email: email, meeting: meeting)
        let modelKey = try #require(originalSnapshot.records.keys.first)
        func reconcile() async throws {
            let snapshot = try CloudModelCodec.capture(app: app, email: email, meeting: meeting)
            let base = FullCloudFileScope(graph: try CloudModelCodec.meetingNamespaceGraph(snapshot),
                heldMeetingIDs: [], modelUnavailable: false, namespaceAuthorization: { _ in true })
            let files = try await store.captureInventory(isMeetingAuthorized: { base.authorizes($0) })
            var digests = snapshot.digests
            digests.merge(files.files.mapValues(\.digest)) { _, value in value }
            try await engine.reconcile(digests: digests, isKeyValid: { key in
                guard let id = CloudFileStore.meetingID(for: key) else { return true }
                return base.holding(meetingKeys: engine.unsettledMeetingKeys,
                    deletedMeetingKeys: engine.settledMeetingTombstones)
                    .authorizes(id, isFenced: files.fencedMeetingIDs.contains(id))
            }, load: { key in
                if let file = files.files[key] { return try await store.load(file) }
                return snapshot.records[key]
            }, apply: { _, _ in Issue.record("These local publications must not restore") })
        }
        try await reconcile()
        #expect(engine.journal.items[item] == nil)
        try await reconcile()
        let original = try #require(engine.journal.items[item])
        #expect(original.digest != nil)
        try MeetingDeletionFence.recordDeletion(meetingID: track.meetingID, rootURL: fixture.meetings)
        meeting.delete(record)
        try meeting.save()
        try MeetingDeletionFence.removeDeletedContent(meetingID: track.meetingID, rootURL: fixture.meetings)
        try await reconcile()
        #expect(engine.journal.items[modelKey]?.digest == nil)
        #expect(engine.journal.items[item] == original)
        try await reconcile()
        let deleted = try #require(engine.journal.items[item])
        #expect(deleted.digest == nil && deleted.logicalClock > original.logicalClock)
        #expect(engine.journal.pendingPublications.isEmpty && engine.deferredKeys.isEmpty)
        let provenDeletion = FullCloudFileScope(graph: [:], heldMeetingIDs: [], modelUnavailable: false,
            namespaceAuthorization: { _ in true }).holding(meetingKeys: [], deletedMeetingKeys: engine.settledMeetingTombstones)
        #expect(provenDeletion.authorizes(track.meetingID, isFenced: true))
        let saved = try ModelContext(cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(saved.count == 2)
        #expect(try saved.allSatisfy(\.isTombstone))
    }

    @Test("A live-model fence conflict cannot plan an audio tombstone before cold missing-asset validation")
    func fencedInventoryIsNotAuthoritativeDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let track = try makeTrack(root: fixture.meetings)
        let url = track.directoryURL.appendingPathComponent("part-00.flac")
        let original = try Data(contentsOf: url)
        let app = try makeContext(schema: AppDataContainer.appSchema)
        let email = try makeContext(schema: AppDataContainer.emailSchema)
        let meeting = try makeContext()
        let record = MeetingRecord(meetingID: track.meetingID, languageTag: "en-US", timezoneIdentifier: "UTC")
        try record.update(audioManifest: track.audioManifest)
        meeting.insert(record)
        try meeting.save()
        let snapshot = try CloudModelCodec.capture(app: app, email: email, meeting: meeting)
        let modelKey = try #require(snapshot.records.keys.first)
        let payload = try #require(snapshot.records[modelKey])
        let audioKey = key(track.meetingID, "audio/part-00.flac")
        let schema = Schema([CloudDataRevision.self])
        let cloud = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let journalURL = fixture.root.appendingPathComponent("journal.json")
        var engine = try FullCloudSyncEngine(cloud: ModelContext(cloud), installationID: UUID().uuidString, journalURL: journalURL)
        let service = FullCloudSyncService(conflictApp: app, conflictEmail: email, conflictMeeting: meeting,
            engine: engine, archiveURL: fixture.root.appendingPathComponent("conflicts.json"))
        let store = CloudFileStore(root: fixture.root)
        var capturedFences = Set<String>()
        func reconcile() async throws {
            let current = try CloudModelCodec.capture(app: app, email: email, meeting: meeting)
            let base = FullCloudFileScope(graph: try CloudModelCodec.meetingNamespaceGraph(current),
                heldMeetingIDs: [], modelUnavailable: false, namespaceAuthorization: { _ in true })
            let files = try await store.captureInventory(isMeetingAuthorized: { base.authorizes($0) })
            capturedFences = files.fencedMeetingIDs
            var digests = current.digests
            digests.merge(files.files.mapValues(\.digest)) { _, value in value }
            try await engine.reconcile(digests: digests, isKeyValid: { item in
                guard let id = CloudFileStore.meetingID(for: item) else { return true }
                return base.holding(meetingKeys: engine.unsettledMeetingKeys,
                    deletedMeetingKeys: engine.settledMeetingTombstones)
                    .authorizes(id, isFenced: files.fencedMeetingIDs.contains(id))
            }, load: { item in
                if let file = files.files[item] { return try await store.load(file) }
                return current.records[item]
            }, apply: { item, data in
                if CloudFileStore.meetingID(for: item) != nil {
                    let result = try await store.apply(key: item, payload: data, expectedDigest: files.files[item]?.digest)
                    guard result == .applied else { throw CloudFileError.changingFile }
                } else {
                    try service.applyModelRecord(key: item, payload: data, app: app, email: email, meeting: meeting,
                        meetingRootURL: fixture.meetings, isAuthorized: { true })
                }
            })
        }
        try await reconcile()
        try await reconcile()
        let audioCheckpoint = try #require(engine.journal.items[audioKey])
        let modelCheckpoint = try #require(engine.journal.items[modelKey])
        try MeetingDeletionFence.recordDeletion(meetingID: track.meetingID, rootURL: fixture.meetings)
        let cloudContext = ModelContext(cloud)
        cloudContext.autosaveEnabled = false
        let missing = try #require(cloudContext.fetch(FetchDescriptor<CloudDataRevision>()).first { $0.itemKey == modelKey })
        missing.payload = nil // Same checkpoint metadata; its external asset is temporarily unavailable.
        try cloudContext.save()
        engine = try FullCloudSyncEngine(cloud: ModelContext(cloud), installationID: UUID().uuidString, journalURL: journalURL)
        await #expect(throws: FullCloudSyncError.revisionValidation(.missingPayload)) { try await reconcile() }
        #expect(capturedFences == [track.meetingID])
        let liveScope = FullCloudFileScope(graph: try CloudModelCodec.meetingNamespaceGraph(
            CloudModelCodec.capture(app: app, email: email, meeting: meeting)), heldMeetingIDs: [],
            modelUnavailable: false, namespaceAuthorization: { _ in true })
        var fencedInventory = CloudFileInventory()
        fencedInventory.fencedMeetingIDs = capturedFences
        #expect(liveScope.hasUnresolvedInventory(fencedInventory))
        #expect(engine.journal.items[modelKey] == modelCheckpoint)
        #expect(engine.journal.items[audioKey] == audioCheckpoint)
        #expect(engine.journal.pendingPublications[audioKey] == nil)
        let disk = try JSONDecoder().decode(CloudSyncJournal.self, from: Data(contentsOf: journalURL))
        #expect(disk.pendingPublications[audioKey] == nil)
        #expect(try Data(contentsOf: url) == original)
        let restored = CloudDataRevision(itemKey: modelKey, clock: 20,
            installationID: UUID().uuidString, payload: payload)
        cloudContext.insert(restored)
        try cloudContext.save()
        try await reconcile() // An authoritative model restore clears the old fence.
        try await reconcile()
        #expect(capturedFences.isEmpty && engine.deferredKeys.isEmpty)
        #expect(engine.journal.items[audioKey] == audioCheckpoint)
        #expect(engine.journal.pendingPublications.isEmpty)
        #expect(try Data(contentsOf: url) == original)
        let saved = try ModelContext(cloud).fetch(FetchDescriptor<CloudDataRevision>()).filter { $0.itemKey == audioKey }
        #expect(saved.count == 1 && saved.first?.revisionID == audioCheckpoint.revisionID)
        #expect(saved.first?.payload == original && saved.first?.isTombstone == false)
    }

    @Test("One local save drains parent, child and original FLAC through progress-driven dependency continuation")
    func oneSaveContinuesUntilOriginalAudioIsQueued() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let track = try makeTrack(root: fixture.meetings)
        let original = try Data(contentsOf: track.directoryURL.appendingPathComponent("part-00.flac"))
        let app = try makeContext(schema: AppDataContainer.appSchema)
        let email = try makeContext(schema: AppDataContainer.emailSchema)
        let meeting = try makeContext()
        let parentID = UUID().uuidString.lowercased()
        let parent = MeetingRecord(meetingID: parentID, languageTag: "en-US", timezoneIdentifier: "UTC")
        parent.audioTrackIDs = [track.meetingID]
        let child = MeetingRecord(meetingID: track.meetingID, languageTag: "en-US", timezoneIdentifier: "UTC")
        child.parentMeetingID = parentID
        try child.update(audioManifest: track.audioManifest)
        meeting.insert(parent); meeting.insert(child)
        try meeting.save() // The only canonical source-save trigger in this journey.
        let schema = Schema([CloudDataRevision.self])
        let cloud = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let engine = try FullCloudSyncEngine(cloud: ModelContext(cloud), installationID: UUID().uuidString,
            journalURL: fixture.root.appendingPathComponent("journal.json"))
        let store = CloudFileStore(root: fixture.root)
        var passes = 0
        var continuation = true
        while continuation {
            let snapshot = try CloudModelCodec.capture(app: app, email: email, meeting: meeting)
            let base = FullCloudFileScope(graph: try CloudModelCodec.meetingNamespaceGraph(snapshot),
                heldMeetingIDs: [], modelUnavailable: false, namespaceAuthorization: { _ in true })
            let files = try await store.captureInventory(isMeetingAuthorized: { base.authorizes($0) })
            var digests = snapshot.digests
            digests.merge(files.files.mapValues(\.digest)) { _, value in value }
            let restored = try await engine.reconcile(digests: digests, isKeyValid: { item in
                guard let id = CloudFileStore.meetingID(for: item) else { return true }
                return base.holding(meetingKeys: engine.unsettledMeetingKeys,
                    deletedMeetingKeys: engine.settledMeetingTombstones)
                    .authorizes(id, isFenced: files.fencedMeetingIDs.contains(id))
            }, load: { item in
                if let file = files.files[item] { return try await store.load(file) }
                if let info = try CloudModelCodec.meetingNamespaceInfo(key: item, payload: snapshot.records[item]),
                   !FullCloudFileScope.permitsModelParent(info.parent, unsettledMeetingKeys: engine.unsettledMeetingKeys) {
                    throw CloudFileError.changingFile
                }
                return snapshot.records[item]
            }, apply: { _, _ in Issue.record("This journey publishes local originals, never restores") })
            passes += 1
            continuation = FullCloudSyncProgress.shouldContinueDependencies(enqueued: engine.didEnqueueChanges,
                restored: restored, hasDeferredKeys: !engine.deferredKeys.isEmpty)
            if passes >= 4 { break } // A broken policy must fail, never hang the test runner.
        }
        #expect(passes == 3 && !continuation)
        #expect(engine.deferredKeys.isEmpty)
        #expect(engine.journal.pendingPublications.isEmpty && engine.journal.pendingApplies.isEmpty)
        let rows = try ModelContext(cloud).fetch(FetchDescriptor<CloudDataRevision>())
        #expect(rows.count == 3 && rows.allSatisfy { !$0.isTombstone })
        let audioKey = key(track.meetingID, "audio/part-00.flac")
        #expect(rows.first { $0.itemKey == audioKey }?.payload == original)
        #expect(engine.journal.items[audioKey]?.digest == CloudFileStore.digest(original))
        #expect(!FullCloudSyncProgress.shouldContinueDependencies(enqueued: false, restored: 0, hasDeferredKeys: true))
        #expect(!FullCloudSyncProgress.shouldContinueDependencies(enqueued: true, restored: 0, hasDeferredKeys: false))
    }

    private enum InjectedSaveFailure: Error { case failed }

    private func key(_ id: String, _ name: String) -> String { "file/Meetings/\(id)/\(name)" }

    private func makeContext(schema: Schema? = nil, storeURL: URL? = nil) throws -> ModelContext {
        let schema = schema ?? AppDataContainer.meetingSchema
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func pending(_ track: MeetingCaptureTrackArtifact, parentID: String? = nil) -> PendingMeetingCaptureRecovery {
        PendingMeetingCaptureRecovery(meetingID: track.meetingID, languageTag: "en-US", timezoneIdentifier: "UTC",
            manifest: track.audioManifest, provisionalResult: track.provisionalResult, errorMessage: nil,
            parentMeetingID: parentID, sourceKind: parentID == nil ? nil : track.sourceKind,
            sessionStartSample: parentID == nil ? nil : track.sessionStartSample)
    }

    private func makeTrack(root: URL) throws -> MeetingCaptureTrackArtifact {
        let id = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent(id).appendingPathComponent("audio")
        let writer = try MeetingFLACPartWriter(directory: directory)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try #require(buffer.int16ChannelData?[0])
        for index in 0..<16_000 { samples[index] = 2_000 }
        try writer.append(buffer)
        _ = try writer.finish()
        return MeetingCaptureTrackArtifact(meetingID: id, sourceKind: .microphone, sourceLabel: nil,
            sessionStartSample: 0, directoryURL: directory, audioManifest: writer.manifest(relativeDirectory: "\(id)/audio"),
            provisionalResult: MeetingProvisionalResultBuilder.make(meetingID: id, entries: []))
    }

    private struct Fixture {
        let root: URL
        let meetings: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            meetings = root.appendingPathComponent("Meetings", isDirectory: true)
            try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
