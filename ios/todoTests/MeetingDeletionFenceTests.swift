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
                    try await store.apply(key: key(track.meetingID, name), payload: bytes, expectedDigest: nil)
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
        try await store.apply(key: key(track.meetingID, "capture-recovery.json"), payload: marker, expectedDigest: nil)
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
        let payloads = try CloudModelCodec.capture(app: app, email: email, meeting: meeting)
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
