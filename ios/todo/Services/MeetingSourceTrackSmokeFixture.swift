#if DEBUG
import AVFoundation
import Foundation
import SwiftData

/// QA-only generated audio and locally extracted task evidence, never a transcription fallback.
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
                guard ProcessInfo.processInfo.arguments.contains("-ui-test-task-provenance") else { continue }
                let label = track.audioTrackDisplayName
                // Reused speaker IDs and aliases must resolve within each source, not across the group.
                let name = track.meetingID == microphoneID ? "김민수" : "이서연"
                var segments = [
                    MeetingSegment(id: "intro", startMs: 0, endMs: 1_000, speakerIDs: ["speaker-1"], text: "저는 \(name)입니다. 미노라고 불러주세요."),
                    MeetingSegment(id: "done", startMs: 1_000, endMs: 3_000, speakerIDs: ["speaker-1"], text: "제가 \(label) 자료를 검토했습니다."),
                    MeetingSegment(id: "future", startMs: 3_000, endMs: 5_000, speakerIDs: ["speaker-1"], text: "제가 \(label) 보고서를 공유하겠습니다."),
                    MeetingSegment(id: "request", startMs: 5_000, endMs: 8_000, speakerIDs: ["speaker-2"], text: "미노님, \(label) 요약을 보내주세요.")
                ]
                if ProcessInfo.processInfo.arguments.contains("-ui-test-no-extracted-tasks") {
                    segments = Array(segments.prefix(1))
                }
                let result = MeetingTranscriptAnalysisService().analyze(meetingID: track.meetingID,
                    result: MeetingResult(title: label, segments: segments), language: .korean)
                try track.replaceTranscriptionBase(result, status: .ready)
                try track.update(diarization: MeetingDiarizationPayload(status: .completed, generation: UUID(),
                    manifestDigest: try MeetingDiarizationFingerprint.manifest(artifact.audioManifest),
                    sourceTranscriptRevision: result.transcriptRevision,
                    sourceContentDigest: try MeetingDiarizationFingerprint.source(result), modelRevision: "qa-fixture",
                    preset: "finalPass", coveredThroughSample: 128_000,
                    intervals: [MeetingSpeakerInterval(speakerID: "speaker-1", startSample: 0, endSample: 80_000),
                        MeetingSpeakerInterval(speakerID: "speaker-2", startSample: 80_000, endSample: 128_000)],
                    profiles: [MeetingSpeakerProfile(id: "speaker-1", ordinal: 1, displayName: nil),
                        MeetingSpeakerProfile(id: "speaker-2", ordinal: 2, displayName: nil)],
                    manualAssignments: [:], failureCode: nil))
            }
            try MeetingAudioTrackStore.refresh(parent: parent, in: context)
            var groupResult = MeetingResult(title: "Source tracks smoke")
            if ProcessInfo.processInfo.arguments.contains("-ui-test-task-provenance"),
               !ProcessInfo.processInfo.arguments.contains("-ui-test-no-extracted-tasks") {
                let tracks = try MeetingAudioTrackStore.tracks(for: parent, in: context)
                let conversation = MeetingConversationTimeline.saved(tracks, groupID: groupID)
                let contextSegments = conversation.rows.map { row in
                    MeetingSegment(id: "\(row.id.trackID)-\(row.id.localID)",
                        startMs: row.startSample! / 16, endMs: row.endSample! / 16, text: row.text)
                }
                let extracted = MeetingTranscriptAnalysisService().analyze(meetingID: groupID,
                    result: MeetingResult(segments: contextSegments), language: .english)
                // A group owns context-wide candidates, never a concatenated transcript or speaker namespace.
                // Do not persist temporary projection IDs as if they were parent transcript evidence.
                groupResult.actionDrafts = extracted.actionDrafts.map { draft in
                    MeetingActionDraft(title: draft.title, notes: draft.notes, sourceSegmentIDs: [],
                        confidence: draft.confidence, requiresReview: true, meetingID: groupID)
                }
            }
            try parent.update(result: groupResult, status: .ready)
            try context.save()
        } catch {
            print("Source-track QA fixture failed: \((error as NSError).domain) \((error as NSError).code)")
        }
    }
}
#endif
