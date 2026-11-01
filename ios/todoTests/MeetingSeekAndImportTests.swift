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

    @Test("importer registers a persisted summary sentence as a review-queue Todo")
    @MainActor
    func importerCreatesReviewTodo() throws {
        // cloudKitDatabase: .none — otherwise .automatic tries CloudKit mirroring
        // on a host without an iCloud account and crashes save() (serial run).
        let meetingContainer = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let todoContainer = try ModelContainer(for: AppDataContainer.appSchema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)])

        let segment = MeetingSegment(id: "seg-1", startMs: 0, endMs: 1_000, text: "다음 주까지 견적서를 보내주세요")
        let record = MeetingRecord(meetingID: meetingID, languageTag: "ko-KR")
        let item = MeetingSummaryItem(id: "summary-item", text: "견적서 발송", citations: [
            MeetingSummaryCitation(trackID: meetingID, segmentID: segment.id, transcriptRevision: 0)
        ], isTask: true)
        var result = MeetingResult(segments: [segment],
            summarySections: [MeetingSummarySection(id: "actions", title: "Actions", items: [item])])
        result.summarySourceFingerprint = MeetingSummaryEvidence.sourceFingerprint(result)
        try record.update(result: result, status: .ready)
        meetingContainer.mainContext.insert(record)
        try meetingContainer.mainContext.save()

        let todo = try MeetingTodoImporter.confirmSummaryItem(
            sectionID: "actions",
            itemID: item.id,
            reviewedSourceRef: MeetingTodoImporter.summarySourceRef(item: item, meetingID: record.meetingID),
            meeting: record,
            todoContext: todoContainer.mainContext,
            meetingContext: meetingContainer.mainContext
        )
        #expect(todo.title == "견적서 발송")
        #expect(todo.triage == .review)
        #expect(todo.source == TodoSource.meeting.rawValue)
        #expect(record.confirmedTodoIDs.contains(todo.id.uuidString))
    }

    @Test("summary import keeps the displayed sentence exactly and remains registered after reopen and regeneration")
    func summaryImportExactTitleAndDurableDedup() throws {
        let fixture = try SummaryImportFixture()
        let item = try #require(fixture.record.result?.summarySections?.first?.items.first)
        let todo = try fixture.confirm(item.id)
        #expect(todo.title == item.text)
        #expect(todo.triage == .review)
        #expect(todo.source == TodoSource.meeting.rawValue)
        #expect(todo.dueDate == nil && todo.aiRecommendedTime == nil)
        #expect(!todo.aiNeedsNotification && todo.reminderOffsets.isEmpty)
        #expect(todo.notes.contains("Original request without an owner or date."))
        #expect(!todo.notes.contains("Assignee:"))
        #expect(todo.sourceRef == MeetingTodoImporter.summarySourceRef(item: item, meetingID: fixture.record.meetingID))
        #expect(fixture.record.confirmedTodoIDs == [todo.id.uuidString])

        let reopenedMeetings = ModelContext(fixture.meetings)
        let reopenedTodos = ModelContext(fixture.todos)
        let reopened = try #require(reopenedMeetings.fetch(FetchDescriptor<MeetingRecord>()).first)
        var regenerated = try #require(reopened.result)
        var regeneratedItem = item
        regeneratedItem.id = "a-new-provider-position"
        regenerated.summarySections = [MeetingSummarySection(id: "new-section", title: "Commitments", items: [regeneratedItem])]
        try reopened.update(result: regenerated)
        try reopenedMeetings.save()
        let duplicate = try MeetingTodoImporter.confirmSummaryItem(sectionID: "new-section", itemID: regeneratedItem.id,
            reviewedSourceRef: MeetingTodoImporter.summarySourceRef(item: regeneratedItem, meetingID: reopened.meetingID),
            meeting: reopened, todoContext: reopenedTodos, meetingContext: reopenedMeetings)
        #expect(duplicate.id == todo.id)
        #expect(duplicate.title == item.text)
        #expect(try reopenedTodos.fetchCount(FetchDescriptor<Todo>()) == 1)
        #expect(try reopenedTodos.fetchCount(FetchDescriptor<TaskBehaviorEvent>()) == 1)
        #expect(reopened.confirmedTodoIDs == [todo.id.uuidString])
    }

    @Test("reused provider IDs cannot import an unseen changed sentence or citation", arguments: [false, true])
    func summaryImportRejectsReusedItemIdentity(changedCitation: Bool) throws {
        let fixture = try SummaryImportFixture(group: true)
        var result = try #require(fixture.record.result)
        let reviewed = try #require(result.summarySections?.first?.items.first)
        let reviewedRef = MeetingTodoImporter.summarySourceRef(item: reviewed, meetingID: fixture.record.meetingID)
        if changedCitation {
            // Both citations remain valid current originals; only the reviewed
            // sentence's evidence membership changed under the same item ID.
            result.summarySections?[0].items[0].citations.removeLast()
        } else {
            result.summarySections?[0].items[0].text = "An unseen replacement sentence."
        }
        try fixture.record.update(result: result)
        try fixture.meetings.mainContext.save()
        #expect(throws: MeetingTodoImportError.staleOrUnknownSummaryItem) {
            _ = try fixture.confirm(reviewed.id, reviewedSourceRef: reviewedRef)
        }
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<Todo>()) == 0)
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<TaskBehaviorEvent>()) == 0)
        #expect(fixture.record.confirmedTodoIDs.isEmpty)
    }

    @Test("a prior registration does not bypass rechecking the currently persisted classification")
    func summaryImportRevalidatesExistingRegistration() throws {
        let fixture = try SummaryImportFixture()
        let original = try fixture.confirm("item")
        var result = try #require(fixture.record.result)
        result.summarySections?[0].items[0].isTask = false
        try fixture.record.update(result: result)
        try fixture.meetings.mainContext.save()
        #expect(throws: MeetingTodoImportError.staleOrUnknownSummaryItem) { _ = try fixture.confirm("item") }
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<Todo>()) == 1)
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<TaskBehaviorEvent>()) == 1)
        #expect(fixture.record.confirmedTodoIDs == [original.id.uuidString])
    }

    @Test("summary imports reject missing, non-task, foreign and stale source evidence", arguments: SummaryImportRejection.allCases)
    func summaryImportRejectsStaleEvidence(reason: SummaryImportRejection) throws {
        let fixture = try SummaryImportFixture()
        var result = try #require(fixture.record.result)
        var section = try #require(result.summarySections?.first)
        switch reason {
        case .missingItem: section.items = []
        case .unclassified: section.items[0].isTask = false
        case .wrongTrack: section.items[0].citations[0].trackID = UUID().uuidString.lowercased()
        case .wrongRevision: section.items[0].citations[0].transcriptRevision += 1
        case .missingSegment: section.items[0].citations[0].segmentID = "missing-original"
        case .changedText: result.segments[0].text = "Changed original without advancing its revision."
        case .changedRevision: result.transcriptRevision += 1
        }
        // Retain the saved structured summary deliberately to exercise the
        // import fence even when a legacy caller bypassed invalidation.
        result.summarySections = [section]
        fixture.record.resultData = try JSONEncoder().encode(result)
        fixture.record.transcriptRevision = result.transcriptRevision
        try fixture.meetings.mainContext.save()
        #expect(throws: MeetingTodoImportError.staleOrUnknownSummaryItem) { _ = try fixture.confirm("item") }
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<Todo>()) == 0)
        #expect(fixture.record.confirmedTodoIDs.isEmpty)
    }

    @Test("one reviewed group sentence retains both tracks' original evidence and imports once")
    func summaryGroupImportCombinesOriginalEvidence() throws {
        let fixture = try SummaryImportFixture(group: true)
        let item = try #require(fixture.record.result?.summarySections?.first?.items.first)
        let todo = try fixture.confirm(item.id)
        #expect(todo.title == item.text && todo.triage == .review)
        #expect(todo.notes.contains(fixture.sources[0].meetingID))
        #expect(todo.notes.contains(fixture.sources[1].meetingID))
        #expect(todo.notes.contains("Original request without an owner or date."))
        #expect(todo.notes.contains("Second track's distinct evidence."))
        #expect(todo.dueDate == nil)
        #expect(try fixture.confirm(item.id).id == todo.id)
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<Todo>()) == 1)
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<TaskBehaviorEvent>()) == 1)
    }

    @Test("reviewed group sentences import after output settings change without replacing analysis", arguments: GroupSummaryOutputSetting.allCases)
    func summaryGroupImportAfterOutputSettingsChange(setting: GroupSummaryOutputSetting) throws {
        let fixture = try SummaryImportFixture(group: true)
        let item = try #require(fixture.record.result?.summarySections?.first?.items.first)
        let reviewedRef = MeetingTodoImporter.summarySourceRef(item: item, meetingID: fixture.record.meetingID)
        switch setting {
        case .format: fixture.record.summaryFormatRaw = MeetingSummaryFormat.interview.rawValue
        case .instructions: fixture.record.summaryCustomInstructions = "Focus on decisions."
        case .language: fixture.record.summaryLanguageTag = "ko-KR"
        }
        try fixture.meetings.mainContext.save()
        #expect(!(try MeetingGroupSummaryService.isSummaryCurrent(parent: fixture.record, in: fixture.meetings.mainContext)))
        #expect(try MeetingGroupSummaryService.summaryEvidenceValidity(parent: fixture.record, in: fixture.meetings.mainContext) == .current)
        try MeetingAudioTrackStore.refresh(parent: fixture.record, in: fixture.meetings.mainContext)
        let originalAnalysis = fixture.record.resultData
        let originalSources = fixture.sources.map { $0.persistenceSnapshot() }
        let originalEngine = fixture.record.summaryEngineLabel
        let originalOutputLanguage = fixture.record.summaryResultLanguageTag

        // The synchronous import consumes the captured reviewed sentence, not a
        // fresh summary in the newly requested format or output language.
        let todo = try fixture.confirm(item.id, reviewedSourceRef: reviewedRef)
        #expect(todo.title == item.text)
        #expect(todo.triage == .review && todo.dueDate == nil)
        #expect(todo.notes.contains("Original request without an owner or date."))
        #expect(todo.notes.contains("Second track's distinct evidence."))
        #expect(fixture.record.resultData == originalAnalysis)
        #expect(fixture.record.summaryEngineLabel == originalEngine)
        #expect(fixture.record.summaryResultLanguageTag == originalOutputLanguage)
        #expect(fixture.sources.map { $0.persistenceSnapshot() } == originalSources)
        #expect(!(try MeetingGroupSummaryService.isSummaryCurrent(parent: fixture.record, in: fixture.meetings.mainContext)))
        #expect(try fixture.confirm(item.id, reviewedSourceRef: reviewedRef).id == todo.id)
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<Todo>()) == 1)
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<TaskBehaviorEvent>()) == 1)
    }

    @Test("unverifiable legacy group evidence remains ineligible for import", arguments: [false, true])
    func summaryGroupImportRejectsUnverifiableLegacy(missingFingerprint: Bool) throws {
        let fixture = try SummaryImportFixture(group: true)
        var result = try #require(fixture.record.result)
        let item = try #require(result.summarySections?.first?.items.first)
        let reviewedRef = MeetingTodoImporter.summarySourceRef(item: item, meetingID: fixture.record.meetingID)
        let fingerprint = try #require(result.summarySourceFingerprint)
        result.summarySourceFingerprint = missingFingerprint ? nil : String(try #require(fingerprint.split(separator: ":").last))
        try fixture.record.update(result: result)
        fixture.record.summaryCustomInstructions = "Focus on decisions."
        try fixture.meetings.mainContext.save()
        #expect(try MeetingGroupSummaryService.summaryEvidenceValidity(parent: fixture.record, in: fixture.meetings.mainContext) == .unverifiable)
        let priorAnalysis = try #require(fixture.record.result)
        try MeetingAudioTrackStore.refresh(parent: fixture.record, in: fixture.meetings.mainContext)
        let refreshedAnalysis = try #require(fixture.record.result)
        // Refresh may fill the fixture's empty display title. It must not
        // replace or clear the saved summary, citations or evidence provenance.
        #expect(refreshedAnalysis.summary == priorAnalysis.summary)
        #expect(refreshedAnalysis.summarySections == priorAnalysis.summarySections)
        #expect(refreshedAnalysis.summarySourceFingerprint == priorAnalysis.summarySourceFingerprint)
        #expect(refreshedAnalysis.decisions == priorAnalysis.decisions)
        #expect(refreshedAnalysis.unresolvedQuestions == priorAnalysis.unresolvedQuestions)
        #expect(refreshedAnalysis.actionDrafts == priorAnalysis.actionDrafts)
        #expect(!(try MeetingGroupSummaryService.isSummaryCurrent(parent: fixture.record, in: fixture.meetings.mainContext)))
        #expect(try MeetingGroupSummaryService.summaryEvidenceValidity(parent: fixture.record, in: fixture.meetings.mainContext) == .unverifiable)
        #expect(throws: MeetingTodoImportError.staleOrUnknownSummaryItem) {
            _ = try fixture.confirm(item.id, reviewedSourceRef: reviewedRef)
        }
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<Todo>()) == 0)
        #expect(fixture.record.confirmedTodoIDs.isEmpty)
    }

    @Test("an exact legacy draft registration is reused only with the same original evidence", arguments: [false, true])
    func summaryImportReusesProvenLegacyRegistration(differentEvidence: Bool) throws {
        let fixture = try SummaryImportFixture()
        var result = try #require(fixture.record.result)
        let item = try #require(result.summarySections?.first?.items.first)
        let draft = MeetingActionDraft(id: "legacy-draft", title: item.text,
            sourceSegmentIDs: [differentEvidence ? "another-original" : item.citations[0].segmentID])
        result.actionDrafts = [draft]
        try fixture.record.update(result: result)
        try fixture.meetings.mainContext.save()
        // Seed the historical persisted outcome, not a removed production API.
        let legacy = Todo(title: draft.title, source: .meeting,
            sourceRef: "meeting:\(fixture.record.meetingID):action:\(draft.id)", reminderOffsets: [])
        legacy.triageStatus = TodoTriage.review.rawValue
        fixture.todos.mainContext.insert(legacy)
        TaskBehaviorRecorder.recordCreation(of: legacy, actor: .meetingImport, in: fixture.todos.mainContext)
        try fixture.todos.mainContext.save()
        fixture.record.confirmedTodoIDs = [legacy.id.uuidString]
        try fixture.meetings.mainContext.save()
        let aliases = MeetingTodoImporter.summarySourceRefs(item: item, meeting: fixture.record)
        #expect(aliases.contains(legacy.sourceRef) == !differentEvidence)
        let todo = try fixture.confirm(item.id)
        #expect((todo.id == legacy.id) == !differentEvidence)
        #expect(todo.sourceRef == MeetingTodoImporter.summarySourceRef(item: item, meetingID: fixture.record.meetingID))
        let repeated = try fixture.confirm(item.id)
        #expect(repeated.id == todo.id)
        #expect(Set(fixture.record.confirmedTodoIDs) == Set([legacy.id.uuidString, todo.id.uuidString]))
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<Todo>()) == (differentEvidence ? 2 : 1))
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<TaskBehaviorEvent>()) == (differentEvidence ? 2 : 1))
    }

    @Test("group summary imports retain both original track namespaces when segment IDs collide")
    func summaryGroupImportPreservesNamespaces() throws {
        let fixture = try SummaryImportFixture(group: true)
        var result = try #require(fixture.record.result)
        var first = try #require(result.summarySections?.first?.items.first)
        var second = first
        first.citations = [first.citations[0]]
        second.id = "second-item"
        second.citations = [second.citations[1]]
        result.summarySections = [MeetingSummarySection(id: "actions", title: "Actions", items: [first, second])]
        try fixture.record.update(result: result)
        try fixture.meetings.mainContext.save()
        let firstTodo = try fixture.confirm(first.id)
        let secondTodo = try fixture.confirm(second.id)
        #expect(firstTodo.title == first.text && secondTodo.title == second.text)
        #expect(firstTodo.triage == .review && secondTodo.triage == .review)
        #expect(firstTodo.id != secondTodo.id)
        #expect(firstTodo.sourceRef != secondTodo.sourceRef)
        #expect(firstTodo.notes.contains(fixture.sources[0].meetingID))
        #expect(firstTodo.notes.contains("Original request without an owner or date."))
        #expect(!firstTodo.notes.contains("Second track's distinct evidence."))
        #expect(secondTodo.notes.contains(fixture.sources[1].meetingID))
        #expect(secondTodo.notes.contains("Second track's distinct evidence."))
        #expect(!secondTodo.notes.contains("Original request without an owner or date."))
        #expect(try fixture.confirm(second.id).id == secondTodo.id)
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<Todo>()) == 2)
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<TaskBehaviorEvent>()) == 2)
        #expect(Set(fixture.record.confirmedTodoIDs) == Set([firstTodo.id.uuidString, secondTodo.id.uuidString]))
    }

    @Test("group summary import rejects changed source bytes, revisions, missing tracks and parent-namespace citations", arguments: GroupSummaryImportRejection.allCases)
    func summaryGroupImportRejectsStaleEvidence(reason: GroupSummaryImportRejection) throws {
        let fixture = try SummaryImportFixture(group: true)
        fixture.record.summaryLanguageTag = "ko-KR"
        switch reason {
        case .changedText, .changedRevision:
            var source = try #require(fixture.sources[1].result)
            if reason == .changedText { source.segments[0].text = "Changed second track." }
            else { source.transcriptRevision += 1 }
            try fixture.sources[1].update(result: source)
        case .missingTrack:
            fixture.meetings.mainContext.delete(fixture.sources[1])
        case .parentNamespace:
            var result = try #require(fixture.record.result)
            result.summarySections?[0].items[0].citations[1].trackID = fixture.record.meetingID
            try fixture.record.update(result: result)
        }
        try fixture.meetings.mainContext.save()
        #expect(throws: MeetingTodoImportError.staleOrUnknownSummaryItem) { _ = try fixture.confirm("item") }
        #expect(try fixture.todos.mainContext.fetchCount(FetchDescriptor<Todo>()) == 0)
        #expect(fixture.record.confirmedTodoIDs.isEmpty)
    }

    @Test("summary registration identity ignores provider IDs and citation order, not content or source")
    func summarySourceIdentity() throws {
        let fixture = try SummaryImportFixture(group: true)
        let item = try #require(fixture.record.result?.summarySections?.first?.items.first)
        var reordered = item
        reordered.id = "different-provider-id"
        reordered.citations.reverse()
        reordered.citations.append(item.citations[0])
        let identity = MeetingTodoImporter.summarySourceRef(item: item, meetingID: fixture.record.meetingID)
        #expect(identity == MeetingTodoImporter.summarySourceRef(item: reordered, meetingID: fixture.record.meetingID))
        reordered.text += " A different sentence."
        #expect(identity != MeetingTodoImporter.summarySourceRef(item: reordered, meetingID: fixture.record.meetingID))
        #expect(identity != MeetingTodoImporter.summarySourceRef(item: item, meetingID: UUID().uuidString))
    }

    enum SummaryImportRejection: CaseIterable, Sendable {
        case missingItem, unclassified, wrongTrack, wrongRevision, missingSegment, changedText, changedRevision
    }

    enum GroupSummaryImportRejection: CaseIterable, Sendable {
        case changedText, changedRevision, missingTrack, parentNamespace
    }

    enum GroupSummaryOutputSetting: CaseIterable, Sendable {
        case format, instructions, language
    }

    @MainActor
    private final class SummaryImportFixture {
        let meetings: ModelContainer
        let todos: ModelContainer
        let record: MeetingRecord
        let sources: [MeetingRecord]

        init(group: Bool = false) throws {
            meetings = try ModelContainer(for: AppDataContainer.meetingSchema,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            todos = try ModelContainer(for: AppDataContainer.appSchema,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            record = MeetingRecord(languageTag: "en-US")
            sources = group ? [MeetingRecord(languageTag: "en-US"), MeetingRecord(languageTag: "en-US")] : [record]
            for (index, source) in sources.enumerated() {
                if group {
                    source.parentMeetingID = record.meetingID
                    source.audioTrackKindRaw = MeetingAudioTrackKind.microphone.rawValue
                }
                let text = index == 0 ? "Original request without an owner or date." : "Second track's distinct evidence."
                try source.update(result: MeetingResult(transcriptRevision: 3, segments: [
                    MeetingSegment(id: "same-segment-id", startMs: 0, endMs: 1_000, text: text)
                ]), status: .ready)
                meetings.mainContext.insert(source)
            }
            if group {
                record.audioTrackIDs = sources.map(\.meetingID)
                meetings.mainContext.insert(record)
                try record.update(result: MeetingResult(), status: .ready)
            }
            try meetings.mainContext.save()
            let item = MeetingSummaryItem(id: "item", text: "  Send the proposal — exactly as reviewed.  ",
                citations: sources.map { MeetingSummaryCitation(trackID: $0.meetingID,
                    segmentID: "same-segment-id", transcriptRevision: $0.transcriptRevision) }, isTask: true)
            var result = try #require(record.result)
            result.summary = item.text
            result.summarySections = [MeetingSummarySection(id: "actions", title: "Actions", items: [item])]
            if group {
                result.summarySourceFingerprint = try MeetingGroupSummaryService.sourceFingerprint(parent: record, in: meetings.mainContext)
            } else {
                result.summarySourceFingerprint = MeetingSummaryEvidence.sourceFingerprint(result)
            }
            try record.update(result: result)
            try meetings.mainContext.save()
        }

        func confirm(_ itemID: String, reviewedSourceRef: String? = nil) throws -> Todo {
            let item = record.result?.summarySections?.first(where: { $0.id == "actions" })?.items.first(where: { $0.id == itemID })
            let sourceRef = reviewedSourceRef ?? item.map {
                MeetingTodoImporter.summarySourceRef(item: $0, meetingID: record.meetingID)
            } ?? ""
            return try MeetingTodoImporter.confirmSummaryItem(sectionID: "actions", itemID: itemID,
                reviewedSourceRef: sourceRef, meeting: record,
                todoContext: todos.mainContext, meetingContext: meetings.mainContext)
        }
    }

    @Test("unavailable contextual analysis preserves excerpts without inventing tasks", arguments: [
        "그렇게 내가 얘기를 해야 될 것 같아요",
        "우리 가상화를 해야 되겠다",
        "김대리가 보고서를 제출해주세요",
        "We will send the proposal by Friday."
    ])
    func analysisFallbackDoesNotInferTasks(text: String) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let segment = MeetingSegment(id: "seg-1", startMs: 0, endMs: 1_000, text: text)
            let result = MeetingResult(transcriptRevision: 7, segments: [segment])
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
            #expect(outcome.summaryKind == .sourceExcerpts)
            #expect(outcome.result.segments == result.segments)
            #expect(outcome.result.transcriptRevision == result.transcriptRevision)
            #expect(outcome.result.title == text)
            #expect(outcome.result.summary == text)
            #expect(outcome.result.actionDrafts.isEmpty)
        }
    }

    @Test("source-excerpt fallback clears prior drafts and inferred summary fields")
    func analysisFallbackClearsStaleDrafts() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let segments = [
                MeetingSegment(id: "first", startMs: 0, endMs: 1_000, text: "그렇게 내가 얘기를 해야 될 것 같아요"),
                MeetingSegment(id: "second", startMs: 1_000, endMs: 2_000, text: "우리 가상화를 해야 되겠다")
            ]
            let staleDraft = MeetingActionDraft(title: "가상화 진행", sourceSegmentIDs: ["second"], meetingID: meetingID)
            let result = MeetingResult(transcriptRevision: 4, title: "Old generated title", summary: "Old generated summary",
                decisions: ["Old decision"], unresolvedQuestions: ["Old question"], segments: segments,
                actionDrafts: [staleDraft], summarySections: [], summarySourceFingerprint: "old-fingerprint")
            let outcome = try await MeetingAnalysisEngine(
                policy: BetaFeaturePolicy(accessReader: { .disabled }, selectionReader: { nil })
            ).analyze(meetingID: meetingID, result: result, sourceLanguageTag: "ko-KR",
                summaryLanguageTag: "ko-KR", language: .korean)
            #expect(outcome.result.actionDrafts.isEmpty)
            #expect(outcome.result.segments == segments)
            #expect(outcome.result.transcriptRevision == result.transcriptRevision)
            #expect(outcome.result.title == segments[0].text)
            #expect(outcome.result.summary == segments.map(\.text).joined(separator: "\n"))
            #expect(outcome.result.decisions.isEmpty)
            #expect(outcome.result.unresolvedQuestions.isEmpty)
            #expect(outcome.result.summarySections == nil)
            #expect(outcome.result.summarySourceFingerprint == nil)
            #expect(result.actionDrafts == [staleDraft])
        }
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
