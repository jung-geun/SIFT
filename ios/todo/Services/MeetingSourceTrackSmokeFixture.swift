#if DEBUG
import AVFoundation
import Foundation
import SwiftData

/// QA-only generated audio for playback/export regressions, never a transcription fallback.
@MainActor
enum MeetingSourceTrackSmokeFixture {
    static let groupID = "b53c91da-05f8-4a76-978c-22bd87411802"
    static let microphoneID = "b53c91da-05f8-4a76-978c-22bd87411803"
    static let applicationID = "b53c91da-05f8-4a76-978c-22bd87411804"

    static func seedIfNeeded(into container: ModelContainer) {
        guard Bundle.main.bundleIdentifier == "pieroot.sift-todo.qa",
              ProcessInfo.processInfo.arguments.contains("-ui-test-source-track-smoke"),
              ProcessInfo.processInfo.arguments.contains("-ui-test-in-memory-store") else { return }
        do {
            let context = container.mainContext
            let specs: [(String, MeetingAudioTrackKind, String, String, Double, Int64)] = [
                (microphoneID, .microphone, "Synthetic microphone", "마이크 트랙의 독립 전사", 220, 0),
                (applicationID, .application, "Synthetic application", "앱 트랙의 독립 전사", 440, 32_000)
            ]
            var artifacts = [MeetingCaptureTrackArtifact]()
            for (id, kind, label, text, frequency, offset) in specs {
                let directory = AppDataContainer.activeMeetingAudioDirectory(meetingID: id)
                try? FileManager.default.removeItem(at: directory)
                let writer = try MeetingFLACPartWriter(directory: directory)
                let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128_000)!
                buffer.frameLength = 128_000
                let samples = buffer.int16ChannelData![0]
                for index in 0..<128_000 {
                    samples[index] = Int16(6_000 * sin(2 * .pi * frequency * Double(index) / 16_000))
                }
                try writer.append(buffer)
                _ = try writer.finish()
                let provisional = MeetingProvisionalResultBuilder.make(meetingID: id, entries: [LiveTranscriptEntry(id: "fixture-\(id)", startMs: 0, endMs: 8_000, text: text, isFinal: true)])
                artifacts.append(MeetingCaptureTrackArtifact(meetingID: id, sourceKind: kind, sourceLabel: label,
                    sessionStartSample: offset, directoryURL: directory,
                    audioManifest: writer.manifest(relativeDirectory: "\(id)/audio"), provisionalResult: provisional))
            }
            let parent = try MeetingInitialCapturePersister.persist(
                artifact: MeetingCaptureArtifact(meetingID: groupID, tracks: artifacts),
                languageTag: "ko-KR", timezoneIdentifier: "UTC", in: context)
            for track in try MeetingAudioTrackStore.tracks(for: parent, in: context) {
                let artifact = artifacts.first { $0.meetingID == track.meetingID }!
                try track.replaceTranscriptionBase(artifact.provisionalResult, status: .ready)
            }
            try MeetingAudioTrackStore.refresh(parent: parent, in: context)
            try parent.update(result: MeetingResult(title: "Source tracks smoke"), status: .ready)
            try context.save()
        } catch {
            print("Source-track QA fixture failed: \((error as NSError).domain) \((error as NSError).code)")
        }
    }
}
#endif
