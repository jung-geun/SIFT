import AVFoundation
import Foundation
import Testing
@testable import todo

@Suite("Source-track original archive")
@MainActor
struct MeetingAudioTrackExportTests {
    @Test("A group archive rejects duplicate namespaces, parent reuse and impossible source offsets")
    func rejectsInvalidNamespacesAndOffsets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let parent = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent(id).appendingPathComponent("audio")
        let writer = try MeetingFLACPartWriter(directory: directory)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try #require(buffer.int16ChannelData?[0])
        for index in 0..<16_000 { channel[index] = Int16(index % 20_000) }
        try writer.append(buffer)
        _ = try writer.finish()
        let manifest = writer.manifest(relativeDirectory: "\(id)/audio")
        let track = MeetingAudioTrackExport(meetingID: id, sourceKind: .microphone, sourceLabel: nil,
            sessionStartSample: 0, manifest: manifest)
        for tracks in [
            [track, track],
            [MeetingAudioTrackExport(meetingID: id, sourceKind: .microphone, sourceLabel: nil, sessionStartSample: -1, manifest: manifest)],
            [MeetingAudioTrackExport(meetingID: id, sourceKind: .microphone, sourceLabel: nil,
                sessionStartSample: MeetingMediaTimeline.maximumSamples, manifest: manifest)]
        ] {
            #expect(throws: MeetingAudioExporter.ExportError.self) {
                _ = try MeetingAudioExporter.exportTrackArchive(meetingID: parent, tracks: tracks, rootURL: root)
            }
        }
        #expect(throws: MeetingAudioExporter.ExportError.self) {
            _ = try MeetingAudioExporter.exportTrackArchive(meetingID: id, tracks: [track], rootURL: root)
        }
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("part-00.flac"))
        #expect(file.length == 16_000)
    }

    @Test("A symlink outside the child namespace cannot be copied into an exported archive")
    func rejectsEscapingSourceDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let child = root.appendingPathComponent(id)
        let external = root.appendingPathComponent("unowned")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: child.appendingPathComponent("audio"), withDestinationURL: external)
        let manifest = MeetingAudioManifest(relativeDirectory: "\(id)/audio", sampleRate: 16_000, totalSamples: 16_000,
            parts: [MeetingAudioPartManifest(fileName: "part-00.flac", partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 16_000)])
        let track = MeetingAudioTrackExport(meetingID: id, sourceKind: .application, sourceLabel: nil, sessionStartSample: 0, manifest: manifest)
        #expect(throws: MeetingAudioExporter.ExportError.self) {
            _ = try MeetingAudioExporter.exportTrackArchive(meetingID: UUID().uuidString.lowercased(), tracks: [track], rootURL: root)
        }
        #expect(FileManager.default.fileExists(atPath: external.path))
    }
}
