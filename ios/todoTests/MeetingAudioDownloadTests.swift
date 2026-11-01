import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import todo

@MainActor
@Suite("Meeting source downloads")
struct MeetingAudioDownloadTests {
    @Test("A selected source downloads its own samples without changing either original")
    func selectedSourcePreservesOriginals() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let before = try fixture.artifacts.map { try Data(contentsOf: $0.directoryURL.appendingPathComponent("part-00.flac")) }
        for (index, track) in fixture.artifacts.enumerated() {
            let download = try await MeetingAudioDownload.prepare(record: fixture.parent, in: fixture.context,
                sourceID: track.meetingID, format: .wav)
            defer { try? FileManager.default.removeItem(at: download.url.deletingLastPathComponent()) }
            let file = try AVAudioFile(forReading: download.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            #expect(file.length == 16_000)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000))
            try file.read(into: buffer, frameCount: 16_000)
            let samples = try #require(buffer.floatChannelData?[0])
            let expected: Float = index == 0 ? 12_000 / 32_768 : -8_000 / 32_768
            #expect(abs(samples[0] - expected) < 0.0001)
            #expect(abs(samples[15_999] - expected) < 0.0001)
        }
        for (index, track) in fixture.artifacts.enumerated() {
            #expect(try Data(contentsOf: track.directoryURL.appendingPathComponent("part-00.flac")) == before[index])
        }
        #expect(try fixture.context.fetch(FetchDescriptor<MeetingRecord>()).count == 3)
    }

    @Test("A legacy standalone recording downloads without group metadata")
    func standaloneRecordingDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let artifact = fixture.artifacts[0]
        let configuration = ModelConfiguration(schema: AppDataContainer.meetingSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: configuration)
        let context = ModelContext(container)
        let legacy = MeetingRecord(meetingID: artifact.meetingID, languageTag: "en-US", timezoneIdentifier: "UTC")
        try legacy.replaceTranscriptionBase(artifact.provisionalResult, status: .ready)
        try legacy.update(audioManifest: artifact.audioManifest)
        context.insert(legacy)
        try context.save()
        let download = try await MeetingAudioDownload.prepare(record: legacy, in: context, format: .wav)
        defer { try? FileManager.default.removeItem(at: download.url.deletingLastPathComponent()) }
        let file = try AVAudioFile(forReading: download.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1))
        try file.read(into: buffer, frameCount: 1)
        #expect(file.length == 16_000)
        let sample = try #require(buffer.floatChannelData?[0][0])
        #expect(abs(sample - Float(12_000) / 32_768) < 0.0001)
        #expect(legacy.parentMeetingID == nil)
        #expect(legacy.audioTrackIDs.isEmpty)
    }

    @Test("All-source download rejects incomplete membership rather than returning a partial archive")
    func missingSourceRejectsWholeArchive() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let records = try MeetingAudioTrackStore.tracks(for: fixture.parent, in: fixture.context)
        fixture.context.delete(records[1])
        try fixture.context.save()
        do {
            _ = try await MeetingAudioDownload.prepare(record: fixture.parent, in: fixture.context)
            Issue.record("A partial group was exported as all sources")
        } catch MeetingCaptureRecoveryStore.RecoveryError.invalidManifest {
        }
        #expect(FileManager.default.fileExists(atPath: fixture.artifacts[0].directoryURL.appendingPathComponent("part-00.flac").path))
    }

    @Test("A foreign source and a still-recording source cannot be downloaded")
    func invalidSourceAdmission() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        do {
            _ = try await MeetingAudioDownload.prepare(record: fixture.parent, in: fixture.context,
                sourceID: UUID().uuidString.lowercased(), format: .wav)
            Issue.record("A foreign source was accepted")
        } catch MeetingAudioExporter.ExportError.format {
        }
        let track = try #require(MeetingAudioTrackStore.tracks(for: fixture.parent, in: fixture.context).first)
        track.update(status: .recording)
        for source in [nil, Optional(track.meetingID)] {
            do {
                _ = try await MeetingAudioDownload.prepare(record: fixture.parent, in: fixture.context, sourceID: source)
                Issue.record("Unfinished recording was accepted")
            } catch MeetingAudioExporter.ExportError.format {
            }
        }
        #expect(try fixture.context.fetch(FetchDescriptor<MeetingRecord>()).count == 3)
    }

    @MainActor
    private struct Fixture {
        let context: ModelContext
        let artifacts: [MeetingCaptureTrackArtifact]
        let parent: MeetingRecord

        init() throws {
            let configuration = ModelConfiguration(schema: AppDataContainer.meetingSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: configuration)
            context = ModelContext(container)
            context.autosaveEnabled = false
            var created = [MeetingCaptureTrackArtifact]()
            do {
                for (index, value) in [Int16(12_000), Int16(-8_000)].enumerated() {
                    let id = UUID().uuidString.lowercased()
                    let directory = AppDataContainer.meetingDirectory().appendingPathComponent(id).appendingPathComponent("audio")
                    let writer = try MeetingFLACPartWriter(directory: directory)
                    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
                    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
                    buffer.frameLength = 16_000
                    let samples = try #require(buffer.int16ChannelData?[0])
                    for sample in 0..<16_000 { samples[sample] = value }
                    try writer.append(buffer)
                    _ = try writer.finish()
                    created.append(MeetingCaptureTrackArtifact(meetingID: id,
                        sourceKind: index == 0 ? .microphone : .application, sourceLabel: nil,
                        sessionStartSample: 0, directoryURL: directory,
                        audioManifest: writer.manifest(relativeDirectory: "\(id)/audio"),
                        provisionalResult: MeetingProvisionalResultBuilder.make(meetingID: id, entries: [])))
                }
                artifacts = created
                parent = try MeetingInitialCapturePersister.persist(
                    artifact: MeetingCaptureArtifact(meetingID: UUID().uuidString.lowercased(), tracks: created),
                    languageTag: "en-US", timezoneIdentifier: "UTC", in: context)
            } catch {
                for artifact in created { try? FileManager.default.removeItem(at: artifact.directoryURL.deletingLastPathComponent()) }
                throw error
            }
        }
        func clean() {
            for artifact in artifacts { try? FileManager.default.removeItem(at: artifact.directoryURL.deletingLastPathComponent()) }
            try? FileManager.default.removeItem(at: AppDataContainer.meetingDirectory().appendingPathComponent(parent.meetingID))
        }
    }
}
