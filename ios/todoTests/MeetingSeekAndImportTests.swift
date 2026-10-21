import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Meeting seek, import, and analysis fallback")
@MainActor
struct MeetingSeekAndImportTests {
    private let meetingID = "123e4567-e89b-12d3-a456-426614174000"

    /// Writes a synthesized single-part recording under the real meeting
    /// directory so the logical cursor can resolve it, and returns its manifest.
    private func makeFixture(totalSamples: Int) throws -> (manifest: MeetingAudioManifest, cleanup: URL) {
        let name = "seek-\(UUID().uuidString.lowercased())"
        let root = AppDataContainer.meetingDirectory().appendingPathComponent(name, isDirectory: true)
        let audioDirectory = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        let writer = try MeetingFLACPartWriter(directory: audioDirectory)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(MeetingMediaTimeline.sampleRate),
            channels: 1,
            interleaved: true
        ))
        var written = 0
        while written < totalSamples {
            let frames = min(8_000, totalSamples - written)
            let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            input.frameLength = AVAudioFrameCount(frames)
            let samples = try #require(input.int16ChannelData?[0])
            for index in 0..<frames { samples[index] = Int16(truncatingIfNeeded: (written + index) % 8_000) }
            try writer.append(input)
            written += frames
        }
        _ = try writer.finish()
        return (writer.manifest(relativeDirectory: "\(name)/audio"), root)
    }

    private func drainFrameCount(_ cursor: MeetingLogicalAudioCursor, format: AVAudioFormat) throws -> Int64 {
        var total: Int64 = 0
        while let buffer = try cursor.nextPCMBuffer(maxFrames: 4_096, outputFormat: format) {
            total += Int64(buffer.frameLength)
        }
        return total
    }

    @Test("cursor seek yields exactly the remaining tail")
    func cursorSeekRemainingTail() throws {
        let fixture = try makeFixture(totalSamples: 32_000)
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(fixture.manifest.sampleRate), channels: 1, interleaved: false
        ))

        let cursor = try MeetingLogicalAudioCursor(manifest: fixture.manifest)
        try cursor.seek(toLogicalSample: 12_000)
        #expect(try drainFrameCount(cursor, format: format) == 32_000 - 12_000)

        let atZero = try MeetingLogicalAudioCursor(manifest: fixture.manifest)
        try atZero.seek(toLogicalSample: 0)
        #expect(try drainFrameCount(atZero, format: format) == 32_000)

        let atEnd = try MeetingLogicalAudioCursor(manifest: fixture.manifest)
        try atEnd.seek(toLogicalSample: 32_000)
        #expect(try atEnd.nextPCMBuffer(maxFrames: 4_096, outputFormat: format) == nil)
    }

    @Test("cursor seek clamps out-of-range values")
    func cursorSeekClamps() throws {
        let fixture = try makeFixture(totalSamples: 16_000)
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(fixture.manifest.sampleRate), channels: 1, interleaved: false
        ))
        let cursor = try MeetingLogicalAudioCursor(manifest: fixture.manifest)
        try cursor.seek(toLogicalSample: -5_000)
        #expect(try drainFrameCount(cursor, format: format) == 16_000)

        let past = try MeetingLogicalAudioCursor(manifest: fixture.manifest)
        try past.seek(toLogicalSample: 99_999)
        #expect(try past.nextPCMBuffer(maxFrames: 4_096, outputFormat: format) == nil)
    }

    @Test("scheduler seek reschedules and still reaches the end")
    func schedulerSeekReachesEnd() async throws {
        let fixture = try makeFixture(totalSamples: 48_000)
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(fixture.manifest.sampleRate), channels: 1, interleaved: false
        ))
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        try engine.start()
        node.play()

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            private var err: Error?
            func record(_ e: MeetingPlaybackStreamScheduler.Event) {
                lock.lock(); defer { lock.unlock() }
                switch e { case .finished: done = true; case .failed(let x, _): err = x }
            }
            var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }
            var error: Error? { lock.lock(); defer { lock.unlock() }; return err }
        }
        let box = Box()
        let cursor = try MeetingLogicalAudioCursor(manifest: fixture.manifest)
        let scheduler = MeetingPlaybackStreamScheduler(cursor: cursor, node: node, format: format)
        scheduler.onEvent = { box.record($0) }
        try scheduler.start()
        try scheduler.seek(toLogicalSample: 24_000, resumePlaying: true)

        let render = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
        var iterations = 0
        while !box.finished, box.error == nil, iterations < 400 {
            _ = try engine.renderOffline(4_096, to: render)
            iterations += 1
            try await Task.sleep(for: .milliseconds(2))
        }
        node.stop(); engine.stop()
        #expect(box.error == nil)
        #expect(box.finished)
    }

    @Test("transcript tap arms the visible playback position before playback starts")
    @MainActor
    func transcriptTapArmsPosition() {
        let controller = MeetingAudioPlaybackController()
        let totalMs: Int64 = 60_000
        let segment = MeetingSegment(id: "s2", startMs: 15_000, endMs: 20_000, text: "두 번째 구간")

        // No playback has started yet (fresh/unpositioned) — a caption tap must
        // still arm the segment's start as the visible position, matching what
        // `play(manifest:)` reads as its resume point.
        controller.seek(toProgress: Double(segment.startMs) / Double(totalMs), totalMilliseconds: totalMs)
        #expect(abs(controller.playbackProgress - 0.25) < 0.0001)
        #expect(controller.playbackMilliseconds == segment.startMs)

        // Tapping an earlier caption after the first tap replaces the armed
        // position rather than accumulating from the previous one.
        let earlier = MeetingSegment(id: "s1", startMs: 5_000, endMs: 10_000, text: "첫 구간")
        controller.seek(toProgress: Double(earlier.startMs) / Double(totalMs), totalMilliseconds: totalMs)
        #expect(abs(controller.playbackProgress - (5.0 / 60.0)) < 0.0001)
        #expect(controller.playbackMilliseconds == earlier.startMs)
    }

    @Test("segment lookup follows half-open latest-start precedence")
    func segmentLookupBoundaries() throws {
        let result = try MeetingResult(segments: [
            MeetingSegment(id: "early", startMs: 100, endMs: 1_000, text: "앞 구간"),
            MeetingSegment(id: "same-a", startMs: 300, endMs: 400, text: "겹침 A"),
            MeetingSegment(id: "same-z", startMs: 300, endMs: 500, text: "겹침 Z"),
            MeetingSegment(id: "after-gap", startMs: 1_200, endMs: 1_500, text: "뒤 구간")
        ]).validated()

        #expect(result.segmentID(at: -1) == nil)
        #expect(result.segmentID(at: 99) == nil)
        #expect(result.segmentID(at: 100) == "early")
        #expect(result.segmentID(at: 299) == "early")
        #expect(result.segmentID(at: 300) == "same-z")
        #expect(result.segmentID(at: 499) == "same-z")
        #expect(result.segmentID(at: 500) == nil)
        #expect(result.segmentID(at: 1_000) == nil)
        #expect(result.segmentID(at: 1_199) == nil)
        #expect(result.segmentID(at: 1_200) == "after-gap")
        #expect(result.segmentID(at: 1_500) == nil)

        let whitespace = try MeetingResult(segments: [
            MeetingSegment(id: "visible", startMs: 0, endMs: 2_000, text: "보이는 구간"),
            MeetingSegment(id: "blank", startMs: 500, endMs: 1_000, text: " \n ")
        ]).validated()
        #expect(whitespace.segmentID(at: 600) == nil)
        #expect(whitespace.segmentID(at: 1_100) == nil)
    }

    @Test("summary replacement preserves the complete transcript contract")
    func summaryReplacement() throws {
        let segment = MeetingSegment(id: "segment", startMs: 0, endMs: 1_000, text: "원문")
        let current = MeetingResult(
            transcriptRevision: 2,
            title: "기존 제목",
            summary: "기존 요약",
            decisions: ["결정"],
            unresolvedQuestions: ["질문"],
            segments: [segment],
            actionDrafts: [MeetingActionDraft(id: "draft", title: "할 일")]
        )
        let source = MeetingResult(transcriptRevision: 2, segments: [segment])
        let replaced = try #require(current.replacingSummary("새 요약", ifTranscriptMatches: source))

        #expect(current.hasSameTranscript(as: source))
        #expect(replaced.summary == "새 요약")
        #expect(replaced.title == current.title)
        #expect(replaced.decisions == current.decisions)
        #expect(replaced.unresolvedQuestions == current.unresolvedQuestions)
        #expect(replaced.segments == current.segments)
        #expect(replaced.actionDrafts == current.actionDrafts)
        #expect(replaced.transcriptRevision == current.transcriptRevision)

        var changedRevision = source
        changedRevision.transcriptRevision += 1
        #expect(current.replacingSummary("무시", ifTranscriptMatches: changedRevision) == nil)

        var changedText = source
        changedText.segments[0].text = "변경된 원문"
        #expect(current.replacingSummary("무시", ifTranscriptMatches: changedText) == nil)
    }

    @Test("importer registers a confirmed draft as a review-queue Todo")
    @MainActor
    func importerCreatesReviewTodo() throws {
        // cloudKitDatabase: .none — otherwise .automatic tries CloudKit mirroring
        // on a host without an iCloud account and crashes save() (serial run).
        let meetingContainer = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let todoContainer = try ModelContainer(for: AppDataContainer.appSchema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)])

        let segment = MeetingSegment(id: "seg-1", startMs: 0, endMs: 1_000, text: "다음 주까지 견적서를 보내주세요")
        let draft = MeetingActionDraft(id: "draft-1", title: "견적서 발송", sourceSegmentIDs: [segment.id], confidence: 0.7)
        let record = MeetingRecord(meetingID: meetingID, languageTag: "ko-KR")
        try record.update(result: MeetingResult(segments: [segment], actionDrafts: [draft]), status: .ready)
        meetingContainer.mainContext.insert(record)
        try meetingContainer.mainContext.save()

        let todo = try MeetingTodoImporter.confirm(
            draftID: "draft-1",
            transcriptRevision: record.transcriptRevision,
            meeting: record,
            todoContext: todoContainer.mainContext,
            meetingContext: meetingContainer.mainContext
        )
        #expect(todo.title == "견적서 발송")
        #expect(todo.triage == .review)
        #expect(todo.source == TodoSource.meeting.rawValue)
        #expect(record.confirmedTodoIDs.contains(todo.id.uuidString))
    }

    @Test("analysis engine falls back to the heuristic without an eligible provider")
    func analysisHeuristicFallback() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let segment = MeetingSegment(id: "seg-1", startMs: 0, endMs: 1_000, text: "김대리가 보고서를 제출해주세요")
            let result = MeetingResult(segments: [segment])
            let outcome = try await MeetingAnalysisEngine(
                policy: BetaFeaturePolicy(accessReader: { .disabled }, selectionReader: { nil })
            ).analyze(
                meetingID: meetingID,
                result: result,
                sourceLanguageTag: "ko-KR",
                summaryLanguageTag: "ko-KR",
                language: .korean
            )
            #expect(outcome.usedOnDeviceLLM == false)
            #expect(outcome.result.actionDrafts.isEmpty == false)
        }
    }
    @Test("English action cues use whole-word matching and preserve original title")
    func englishActionCueUnion() {
        let action = MeetingSegment(
            id: "action",
            startMs: 0,
            endMs: 1_000,
            text: "We will send the proposal by Friday."
        )
        let discussion = MeetingSegment(
            id: "discussion",
            startMs: 1_000,
            endMs: 2_000,
            text: "We discussed the proposal timeline."
        )
        let result = MeetingTranscriptAnalysisService().analyze(
            meetingID: meetingID,
            result: MeetingResult(segments: [action, discussion]),
            language: .english
        )
        #expect(result.actionDrafts.count == 1)
        #expect(result.actionDrafts.first?.title == action.text)
        #expect(result.actionDrafts.first?.notes == "Meeting transcript: \(action.text)")
    }
    @Test("analysis due dates canonicalize offsets and reject timezone-less output")
    @MainActor
    func canonicalAnalysisDueDateContract() {
        #expect(
            MeetingAnalysisEngine.canonicalDueDate("2026-06-21T21:00:00.000+09:00")
                == "2026-06-21T12:00:00.000Z"
        )
        #expect(MeetingAnalysisEngine.canonicalDueDate("2026-06-21T21:00:00.000") == nil)
        #expect(MeetingAnalysisEngine.canonicalDueDate("not-a-date") == nil)
    }
}
