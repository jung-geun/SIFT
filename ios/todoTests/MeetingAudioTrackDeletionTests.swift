import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Source-track deletion")
@MainActor
struct MeetingAudioTrackDeletionTests {
    private enum Failure: Error { case save }

    @Test("Deleting a group removes its children and journals without touching a standalone recording")
    func deletesOnlyOwnedNamespaces() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let first = try makeTrack(root: root, value: 12_000)
        let second = try makeTrack(root: root, value: -8_000)
        let group = try MeetingInitialCapturePersister.persist(
            artifact: MeetingCaptureArtifact(meetingID: UUID().uuidString.lowercased(), tracks: [first, second]),
            languageTag: "en-US", timezoneIdentifier: "UTC", in: context)
        let legacy = try makeTrack(root: root, value: 2_000)
        let record = MeetingRecord(meetingID: legacy.meetingID, languageTag: "en-US", timezoneIdentifier: "UTC")
        try record.replaceTranscriptionBase(legacy.provisionalResult, status: .ready)
        try record.update(audioManifest: legacy.audioManifest)
        context.insert(record)
        try context.save()
        for track in [first, second] {
            try MeetingCaptureRecoveryStore.markActive(meetingID: track.meetingID, parentMeetingID: group.meetingID,
                sourceKind: track.sourceKind, sourceLabel: nil, sessionStartSample: 0,
                languageTag: "en-US", timezoneIdentifier: "UTC", directoryURL: track.directoryURL, rootURL: root)
            try MeetingCaptureRecoveryStore.markStopped(meetingID: track.meetingID, audioManifest: track.audioManifest,
                provisionalResult: track.provisionalResult, rootURL: root)
        }
        try MeetingAudioTrackDeletion.delete(parent: group, in: context, rootURL: root)
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).map(\.meetingID) == [legacy.meetingID])
        #expect(!FileManager.default.fileExists(atPath: first.directoryURL.path))
        #expect(!FileManager.default.fileExists(atPath: second.directoryURL.path))
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.isEmpty)
        #expect(try readSample(legacy) == 2_000)
    }

    @Test("A failed deletion save retains source audio, unrelated edits and retryable provisional records")
    func failedDeletionKeepsOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let first = try makeTrack(root: root, value: 12_000)
        let second = try makeTrack(root: root, value: -8_000)
        let parentID = UUID().uuidString.lowercased()
        let group = try MeetingInitialCapturePersister.persist(
            artifact: MeetingCaptureArtifact(meetingID: parentID, tracks: [first, second]),
            languageTag: "en-US", timezoneIdentifier: "UTC", in: context)
        let unrelated = MeetingRecord(meetingID: UUID().uuidString.lowercased(), languageTag: "en-US", timezoneIdentifier: "UTC")
        context.insert(unrelated)
        try unrelated.update(result: MeetingResult(title: "Retained edit"), status: .ready)
        var saves = 0
        #expect(throws: Failure.save) {
            try MeetingAudioTrackDeletion.delete(parent: group, in: context, rootURL: root) { context in
                saves += 1
                if saves == 3 { throw Failure.save }
                try context.save()
            }
        }
        let records = try context.fetch(FetchDescriptor<MeetingRecord>())
        #expect(Set(records.map(\.meetingID)) == Set([parentID, first.meetingID, second.meetingID, unrelated.meetingID]))
        #expect(records.filter { $0.parentMeetingID == parentID }.allSatisfy { $0.status == .transcriptFinalizationFailed })
        #expect(records.first { $0.meetingID == unrelated.meetingID }?.result?.title == "Retained edit")
        #expect(try readSample(first) == 12_000)
        #expect(try readSample(second) == -8_000)
    }

    @Test("Legacy standalone deletion does not require or create track grouping")
    func deletesLegacyStandalone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let track = try makeTrack(root: root, value: 3_000)
        let record = MeetingRecord(meetingID: track.meetingID, languageTag: "en-US", timezoneIdentifier: "UTC")
        try record.replaceTranscriptionBase(track.provisionalResult, status: .ready)
        try record.update(audioManifest: track.audioManifest)
        context.insert(record)
        try context.save()
        try MeetingAudioTrackDeletion.delete(parent: record, in: context, rootURL: root)
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: track.directoryURL.path))
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(schema: AppDataContainer.meetingSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func makeTrack(root: URL, value: Int16) throws -> MeetingCaptureTrackArtifact {
        let id = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent(id).appendingPathComponent("audio")
        let writer = try MeetingFLACPartWriter(directory: directory)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try #require(buffer.int16ChannelData?[0])
        for index in 0..<16_000 { samples[index] = value }
        try writer.append(buffer)
        _ = try writer.finish()
        return MeetingCaptureTrackArtifact(meetingID: id, sourceKind: .microphone, sourceLabel: nil,
            sessionStartSample: 0, directoryURL: directory, audioManifest: writer.manifest(relativeDirectory: "\(id)/audio"),
            provisionalResult: MeetingProvisionalResultBuilder.make(meetingID: id, entries: []))
    }

    private func readSample(_ track: MeetingCaptureTrackArtifact) throws -> Int16 {
        let file = try AVAudioFile(forReading: track.directoryURL.appendingPathComponent("part-00.flac"), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1))
        try file.read(into: buffer, frameCount: 1)
        return try #require(buffer.int16ChannelData?[0][0])
    }
}
