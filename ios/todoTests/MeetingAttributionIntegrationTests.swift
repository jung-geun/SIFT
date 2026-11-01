import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Meeting person attribution integration")
@MainActor
struct MeetingAttributionIntegrationTests {
    private let meetingID = "e2836f39-2800-4971-9057-39286367b910"

    @Test("attribution retains supported assignees and removes completed-work drafts")
    func attributionSeparatesCompletedWorkFromFutureTasks() {
        let segments = [
            MeetingSegment(id: "intro", startMs: 0, endMs: 1_000, speakerIDs: ["speaker-1"], text: "저는 민수입니다."),
            MeetingSegment(id: "done", startMs: 1_000, endMs: 2_000, speakerIDs: ["speaker-1"], text: "제가 견적서를 제출했습니다."),
            MeetingSegment(id: "future", startMs: 2_000, endMs: 3_000, speakerIDs: ["speaker-1"], text: "제가 보고서를 공유하겠습니다.")
        ]
        let drafts = [
            MeetingActionDraft(title: "견적서 제출", sourceSegmentIDs: ["done"], meetingID: meetingID),
            MeetingActionDraft(title: "보고서 공유", sourceSegmentIDs: ["future"], meetingID: meetingID)
        ]
        let source = MeetingResult(segments: segments, actionDrafts: drafts)
        let analyzed = MeetingActionAttribution.applying(to: source, meetingID: meetingID)
        #expect(analyzed.segments == segments)
        #expect(analyzed.actionDrafts.count == 1)
        #expect(analyzed.actionDrafts.allSatisfy { !$0.sourceSegmentIDs.contains("done") })
        let future = analyzed.actionDrafts.first { $0.sourceSegmentIDs == ["future"] }
        #expect(future?.assignee == "민수")
        #expect(future?.requiresReview == true)
        let report = MeetingTranscriptAttribution(meetingID: meetingID, result: analyzed, profiles: [])
        #expect(report.activities.contains { $0.sourceSegmentIDs.contains("done") && $0.kind == .completed })
    }

    @Test("summary import preserves its exact sentence across manual speaker renames without inferring an assignee")
    func summaryImportKeepsReviewedIdentityAcrossSpeakerRenames() throws {
        let (meetingContainer, todoContainer) = try containers()
        let record = MeetingRecord(meetingID: meetingID, languageTag: "ko-KR")
        let segments = [
            MeetingSegment(id: "intro", startMs: 0, endMs: 1_000, speakerIDs: ["speaker-1"], text: "저는 민수입니다."),
            MeetingSegment(id: "future", startMs: 1_000, endMs: 2_000, speakerIDs: ["speaker-1"], text: "제가 보고서를 공유하겠습니다.")
        ]
        let item = MeetingSummaryItem(id: "reviewed-summary", text: "보고서를 공유하겠습니다.", citations: [
            MeetingSummaryCitation(trackID: meetingID, segmentID: "future", transcriptRevision: 0)
        ], isTask: true)
        var result = MeetingResult(segments: segments,
            summarySections: [MeetingSummarySection(id: "actions", title: "Actions", items: [item])])
        result.summarySourceFingerprint = MeetingSummaryEvidence.sourceFingerprint(result)
        try record.update(result: result)
        let manifest = MeetingAudioManifest(relativeDirectory: "attribution-test", sampleRate: 16_000, totalSamples: 32_000, parts: [])
        try record.update(audioManifest: manifest)
        var payload = MeetingDiarizationPayload(status: .completed, generation: UUID(),
            manifestDigest: try MeetingDiarizationFingerprint.manifest(manifest), sourceTranscriptRevision: 0,
            sourceContentDigest: try MeetingDiarizationFingerprint.source(result), modelRevision: "test", preset: "finalPass",
            coveredThroughSample: 32_000, intervals: [MeetingSpeakerInterval(speakerID: "speaker-1", startSample: 0, endSample: 32_000)],
            profiles: [MeetingSpeakerProfile(id: "speaker-1", ordinal: 1, displayName: "검토자")], manualAssignments: [:], failureCode: nil)
        try record.update(diarization: payload)
        meetingContainer.mainContext.insert(record)
        try meetingContainer.mainContext.save()
        let imported = try MeetingTodoImporter.confirmSummaryItem(sectionID: "actions", itemID: item.id,
            reviewedSourceRef: MeetingTodoImporter.summarySourceRef(item: item, meetingID: record.meetingID), meeting: record,
            todoContext: todoContainer.mainContext, meetingContext: meetingContainer.mainContext)
        #expect(imported.title == item.text)
        #expect(imported.notes.contains(segments[1].text))
        #expect(!imported.notes.contains("검토자"))
        #expect(imported.dueDate == nil)
        #expect(imported.triage == .review)
        #expect(record.result == result)
        payload.profiles[0].displayName = "검토자 수정"
        try record.update(diarization: payload)
        try meetingContainer.mainContext.save()
        let repeated = try MeetingTodoImporter.confirmSummaryItem(sectionID: "actions", itemID: item.id,
            reviewedSourceRef: MeetingTodoImporter.summarySourceRef(item: item, meetingID: record.meetingID), meeting: record,
            todoContext: todoContainer.mainContext, meetingContext: meetingContainer.mainContext)
        #expect(repeated.id == imported.id)
        #expect(try todoContainer.mainContext.fetch(FetchDescriptor<Todo>()).count == 1)
    }

    @Test("a completed non-task summary sentence cannot create a future task")
    func completedSummaryCannotBeImported() throws {
        let (meetingContainer, todoContainer) = try containers()
        let record = MeetingRecord(meetingID: meetingID, languageTag: "ko-KR")
        let done = MeetingSegment(id: "done", startMs: 0, endMs: 1_000, speakerIDs: ["speaker-1"], text: "제가 견적서를 제출했습니다.")
        let item = MeetingSummaryItem(id: "completed-summary", text: done.text, citations: [
            MeetingSummaryCitation(trackID: meetingID, segmentID: done.id, transcriptRevision: 0)
        ], isTask: false)
        var result = MeetingResult(segments: [done],
            summarySections: [MeetingSummarySection(id: "history", title: "History", items: [item])])
        result.summarySourceFingerprint = MeetingSummaryEvidence.sourceFingerprint(result)
        try record.update(result: result)
        meetingContainer.mainContext.insert(record)
        try meetingContainer.mainContext.save()
        #expect(throws: MeetingTodoImportError.staleOrUnknownSummaryItem) {
            try MeetingTodoImporter.confirmSummaryItem(sectionID: "history", itemID: item.id,
                reviewedSourceRef: MeetingTodoImporter.summarySourceRef(item: item, meetingID: record.meetingID), meeting: record,
                todoContext: todoContainer.mainContext, meetingContext: meetingContainer.mainContext)
        }
        #expect(try todoContainer.mainContext.fetch(FetchDescriptor<Todo>()).isEmpty)
        #expect(record.confirmedTodoIDs.isEmpty)
    }

    @Test("correcting conflicting proposed assignees cannot duplicate one canonical task")
    func correctedAssigneesDeduplicate() {
        let segments = [
            MeetingSegment(id: "intro", startMs: 0, endMs: 1_000, speakerIDs: ["speaker-1"], text: "My name is Alex."),
            MeetingSegment(id: "work", startMs: 1_000, endMs: 2_000, speakerIDs: ["speaker-1"], text: "I will send the report.")
        ]
        let drafts = ["Alex", "Invented"].map { name in
            MeetingActionDraft(title: "Send the report", assignee: name, sourceSegmentIDs: ["work"], meetingID: meetingID)
        }
        let result = MeetingActionAttribution.applying(to: MeetingResult(segments: segments, actionDrafts: drafts), meetingID: meetingID)
        #expect(result.actionDrafts.count == 1)
        #expect(result.actionDrafts.first?.assignee == "Alex")
        #expect(result.actionDrafts.first?.sourceSegmentIDs == ["work"])
    }

    private func containers() throws -> (ModelContainer, ModelContainer) {
        let meeting = try ModelContainer(for: AppDataContainer.meetingSchema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let todo = try ModelContainer(for: AppDataContainer.appSchema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        return (meeting, todo)
    }
}
