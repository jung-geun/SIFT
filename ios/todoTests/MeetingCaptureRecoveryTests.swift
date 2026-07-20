import AVFoundation
import SwiftData
import Testing
@testable import todo

@Suite("Meeting capture recovery")
@MainActor
struct MeetingCaptureRecoveryTests {
    @Test("recovery marker validates audio and persists once after retry")
    func persistsOnlyAfterSuccessfulSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = "123e4567-e89b-12d3-a456-426614174000"
        let audio = root.appendingPathComponent(meetingID, isDirectory: true).appendingPathComponent("audio", isDirectory: true)
        let writer = try MeetingFLACPartWriter(directory: audio)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        try writer.append(buffer)
        _ = try writer.finish()
        let manifest = writer.manifest(relativeDirectory: "\(meetingID)/audio")
        let recovery = PendingMeetingCaptureRecovery(
            meetingID: meetingID,
            languageTag: "ko-KR",
            timezoneIdentifier: "UTC",
            manifest: manifest,
            provisionalResult: MeetingProvisionalResultBuilder.make(meetingID: meetingID, entries: [], elapsedMediaMs: 1_000),
            errorMessage: "capture failed"
        )
        try MeetingCaptureRecoveryStore.write(recovery, rootURL: root)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.map(\.meetingID) == [meetingID])

        let configuration = ModelConfiguration(
            schema: AppDataContainer.meetingSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: configuration)
        let context = ModelContext(container)
        #expect(throws: Error.self) {
            try MeetingCaptureRecoveryPersister.persist(recovery, in: context, rootURL: root) { _ in
                throw RecoveryTestError.saveFailed
            }
        }
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.map(\.meetingID) == [meetingID])
        let pending = try context.fetch(FetchDescriptor<MeetingRecord>())
        #expect(pending.isEmpty)

        try MeetingCaptureRecoveryPersister.persist(recovery, in: context, rootURL: root)
        let persisted = try context.fetch(FetchDescriptor<MeetingRecord>())
        #expect(persisted.count == 1)
        #expect(persisted.first?.status == .transcriptFinalizationFailed)
        #expect(persisted.first?.audioManifest == manifest)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.isEmpty)
    }

    @Test("capture persistence deletes inserts and rolls back failed status saves")
    func captureCommitBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meeting-capture-commit-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = try makeRecovery(
            root: root,
            meetingID: "123e4567-e89b-12d3-a456-426614174001"
        )
        let configuration = ModelConfiguration(
            schema: AppDataContainer.meetingSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AppDataContainer.meetingSchema,
            configurations: configuration
        )
        let context = ModelContext(container)

        #expect(throws: RecoveryTestError.saveFailed) {
            _ = try MeetingInitialCapturePersister.persist(
                meetingID: recovery.meetingID,
                languageTag: recovery.languageTag,
                timezoneIdentifier: recovery.timezoneIdentifier,
                provisionalResult: recovery.provisionalResult,
                manifest: recovery.manifest,
                in: context,
                save: { _ in throw RecoveryTestError.saveFailed }
            )
        }
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.count == 1)

        let record = try MeetingInitialCapturePersister.persist(
            meetingID: recovery.meetingID,
            languageTag: recovery.languageTag,
            timezoneIdentifier: recovery.timezoneIdentifier,
            provisionalResult: recovery.provisionalResult,
            manifest: recovery.manifest,
            in: context
        )
        let snapshot = record.persistenceSnapshot()
        #expect(throws: RecoveryTestError.saveFailed) {
            try MeetingFinalizationFailurePersister.persist(
                record: record,
                in: context,
                save: { _ in throw RecoveryTestError.saveFailed }
            )
        }
        #expect(record.persistenceSnapshot() == snapshot)
        #expect(record.status == .finalizingTranscript)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.count == 1)
    }

    @Test("recovery replay is rollback-safe and ignores a committed phase two")
    func recoveryRollbackAndKillWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meeting-recovery-kill-window-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = try makeRecovery(
            root: root,
            meetingID: "123e4567-e89b-12d3-a456-426614174002"
        )
        let configuration = ModelConfiguration(
            schema: AppDataContainer.meetingSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AppDataContainer.meetingSchema,
            configurations: configuration
        )
        let context = ModelContext(container)
        let record = MeetingRecord(
            meetingID: recovery.meetingID,
            languageTag: recovery.languageTag,
            timezoneIdentifier: recovery.timezoneIdentifier
        )
        try record.replaceTranscriptionBase(recovery.provisionalResult, status: .transcriptFinalizationFailed)
        try record.update(audioManifest: recovery.manifest)
        record.refinementEngineLabel = "stale"
        context.insert(record)
        try context.save()
        let failedSnapshot = record.persistenceSnapshot()

        #expect(throws: RecoveryTestError.saveFailed) {
            try MeetingCaptureRecoveryPersister.persist(
                recovery,
                in: context,
                rootURL: root,
                save: { _ in throw RecoveryTestError.saveFailed }
            )
        }
        #expect(record.persistenceSnapshot() == failedSnapshot)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.count == 1)

        var durable = recovery.provisionalResult
        durable.summary = "durable phase two"
        try record.replaceTranscriptionBase(durable, status: .ready)
        try record.update(audioManifest: recovery.manifest)
        try context.save()
        let committedSnapshot = record.persistenceSnapshot()

        try MeetingCaptureRecoveryPersister.persist(
            recovery,
            in: context,
            rootURL: root
        )
        #expect(record.persistenceSnapshot() == committedSnapshot)
        #expect(record.status == .ready)
        #expect(record.result?.summary == "durable phase two")
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.isEmpty)
    }

    @Test("invalid provisional recovery removes a newly inserted record")
    func invalidProvisionalDeletesInsert() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meeting-recovery-invalid-result-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try makeRecovery(
            root: root,
            meetingID: "123e4567-e89b-12d3-a456-426614174003"
        )
        let invalid = PendingMeetingCaptureRecovery(
            meetingID: valid.meetingID,
            languageTag: valid.languageTag,
            timezoneIdentifier: valid.timezoneIdentifier,
            manifest: valid.manifest,
            provisionalResult: MeetingResult(segments: [
                MeetingSegment(id: "", startMs: 0, endMs: 1_000, text: "invalid")
            ]),
            errorMessage: valid.errorMessage
        )
        let configuration = ModelConfiguration(
            schema: AppDataContainer.meetingSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AppDataContainer.meetingSchema,
            configurations: configuration
        )
        let context = ModelContext(container)

        #expect(throws: Error.self) {
            try MeetingCaptureRecoveryPersister.persist(invalid, in: context, rootURL: root)
        }
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.count == 1)
    }
    @Test("recovery validation rejects paths and incomplete ownership")
    func rejectsInvalidRecoveryMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-recovery-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = "123e4567-e89b-12d3-a456-426614174000"
        let recovery = PendingMeetingCaptureRecovery(
            meetingID: meetingID,
            languageTag: "ko-KR",
            timezoneIdentifier: "UTC",
            manifest: MeetingAudioManifest(
                relativeDirectory: "../escape",
                sampleRate: MeetingMediaTimeline.sampleRate,
                totalSamples: 1,
                parts: [MeetingAudioPartManifest(fileName: "part-00.flac", partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 1)]
            ),
            provisionalResult: MeetingProvisionalResultBuilder.make(meetingID: meetingID, entries: [], elapsedMediaMs: 1),
            errorMessage: nil
        )
        #expect(throws: Error.self) {
            try MeetingCaptureRecoveryStore.validate(
                recovery,
                markerDirectory: root.appendingPathComponent(meetingID, isDirectory: true),
                rootURL: root
            )
        }
    }
    private func makeRecovery(root: URL, meetingID: String) throws -> PendingMeetingCaptureRecovery {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root
            .appendingPathComponent(meetingID, isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let writer = try MeetingFLACPartWriter(directory: audio)
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        try writer.append(buffer)
        _ = try writer.finish()
        let recovery = PendingMeetingCaptureRecovery(
            meetingID: meetingID,
            languageTag: "ko-KR",
            timezoneIdentifier: "UTC",
            manifest: writer.manifest(relativeDirectory: "\(meetingID)/audio"),
            provisionalResult: MeetingProvisionalResultBuilder.make(
                meetingID: meetingID,
                entries: [],
                elapsedMediaMs: 1_000
            ),
            errorMessage: "capture failed"
        )
        try MeetingCaptureRecoveryStore.write(recovery, rootURL: root)
        return recovery
    }
}

private enum RecoveryTestError: Error { case saveFailed }
