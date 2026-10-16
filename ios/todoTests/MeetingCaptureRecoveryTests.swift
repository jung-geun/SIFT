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
            provisionalResult: MeetingProvisionalResultBuilder.make(meetingID: meetingID, entries: []),
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

    @Test("minute-long capture with tap-sized chunks survives FLAC recovery validation")
    func minuteLongCaptureCanBeRecovered() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-minute-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = UUID().uuidString.lowercased()
        let audio = root.appendingPathComponent(meetingID, isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let writer = try MeetingFLACPartWriter(directory: audio)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        let totalSamples = 990_400
        for start in stride(from: 0, to: totalSamples, by: 1_024) {
            buffer.frameLength = AVAudioFrameCount(min(1_024, totalSamples - start))
            try writer.append(buffer)
        }
        _ = try writer.finish()
        let recovery = PendingMeetingCaptureRecovery(
            meetingID: meetingID, languageTag: "ko-KR", timezoneIdentifier: "UTC",
            manifest: writer.manifest(relativeDirectory: "\(meetingID)/audio"),
            provisionalResult: MeetingProvisionalResultBuilder.make(meetingID: meetingID, entries: []), errorMessage: nil
        )
        try MeetingCaptureRecoveryStore.write(recovery, rootURL: root)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.map(\.meetingID) == [meetingID])
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
        let artifact = MeetingCaptureArtifact(meetingID: UUID().uuidString.lowercased(), tracks: [
            MeetingCaptureTrackArtifact(meetingID: recovery.meetingID, sourceKind: .microphone,
                sourceLabel: nil, sessionStartSample: 0,
                directoryURL: root.appendingPathComponent(recovery.manifest.relativeDirectory),
                audioManifest: recovery.manifest, provisionalResult: recovery.provisionalResult)
        ])

        #expect(throws: RecoveryTestError.saveFailed) {
            _ = try MeetingInitialCapturePersister.persist(
                artifact: artifact,
                languageTag: recovery.languageTag,
                timezoneIdentifier: recovery.timezoneIdentifier,
                in: context,
                save: { _ in throw RecoveryTestError.saveFailed }
            )
        }
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.count == 1)

        let parent = try MeetingInitialCapturePersister.persist(
            artifact: artifact,
            languageTag: recovery.languageTag,
            timezoneIdentifier: recovery.timezoneIdentifier,
            in: context
        )
        let record = try #require(MeetingAudioTrackStore.tracks(for: parent, in: context).first)
        let snapshot = record.persistenceSnapshot()
        #expect(throws: RecoveryTestError.saveFailed) {
            try MeetingCaptureTranscriptPersister.persist(
                record: record, baseline: recovery.provisionalResult, failed: true,
                expectedResultData: record.resultData, in: context,
                save: { _ in throw RecoveryTestError.saveFailed }
            )
        }
        #expect(record.persistenceSnapshot() == snapshot)
        #expect(record.status == .finalizingTranscript)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.count == 1)
    }

    @Test("A stale stop marker cannot erase the latest durably saved failed Apple baseline")
    func failedAppleBaselineOutranksStopMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = try makeRecovery(root: root, meetingID: UUID().uuidString.lowercased())
        let configuration = ModelConfiguration(schema: AppDataContainer.meetingSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: configuration)
        let context = ModelContext(container)
        let record = MeetingRecord(meetingID: recovery.meetingID)
        let latest = MeetingResult(segments: [MeetingSegment(id: "drained-apple", startMs: 0, endMs: 1_000,
            text: "Apple text accepted after the stop marker")])
        try record.replaceTranscriptionBase(latest, status: .transcriptFinalizationFailed)
        try record.update(audioManifest: recovery.manifest)
        context.insert(record)
        try context.save()
        let before = record.persistenceSnapshot()
        try MeetingCaptureRecoveryPersister.persist(recovery, in: context, rootURL: root)
        #expect(record.persistenceSnapshot() == before)
        #expect(record.result == latest && record.rawResult == latest && record.appleRawResult == latest)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.isEmpty)
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
        try record.replaceTranscriptionBase(recovery.provisionalResult, status: .finalizingTranscript)
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
            provisionalResult: MeetingProvisionalResultBuilder.make(meetingID: meetingID, entries: []),
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
            provisionalResult: MeetingProvisionalResultBuilder.make(meetingID: meetingID, entries: []),
            errorMessage: "capture failed"
        )
        try MeetingCaptureRecoveryStore.write(recovery, rootURL: root)
        return recovery
    }
    @Test("provisional result builder sanitizes volatile overlapping speech tokens and duplicates")
    func provisionalResultSanitization() throws {
        let meetingID = UUID().uuidString.lowercased()
        let runOverlapping1 = MeetingTimedTextRun(utf16Offset: 0, utf16Length: 2, startMs: 100, endMs: 250)
        let runOverlapping2 = MeetingTimedTextRun(utf16Offset: 2, utf16Length: 3, startMs: 240, endMs: 400)
        let runExceeds = MeetingTimedTextRun(utf16Offset: 0, utf16Length: 4, startMs: 500, endMs: 950)

        let entries = [
            LiveTranscriptEntry(id: "e1", startMs: 100, endMs: 400, text: "안녕", timedRuns: [runOverlapping1, runOverlapping2]),
            LiveTranscriptEntry(id: "e2", startMs: 100, endMs: 400, text: "안녕", timedRuns: [runOverlapping1, runOverlapping2]),
            LiveTranscriptEntry(id: "e3", startMs: 500, endMs: 900, text: "하세요", timedRuns: [runExceeds]),
            LiveTranscriptEntry(id: "e4", startMs: 450, endMs: 800, text: "중간")
        ]

        let result = MeetingProvisionalResultBuilder.make(meetingID: meetingID, entries: entries)
        let validated = try result.validated()
        #expect(!validated.segments.isEmpty)
        #expect(validated.segments.allSatisfy { $0.isValid })
        let ids = Set(validated.segments.map(\.id))
        #expect(ids.count == validated.segments.count)
    }
}

private enum RecoveryTestError: Error { case saveFailed }
