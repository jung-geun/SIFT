import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Meeting transcript manual edits")
struct MeetingTranscriptEditorTests {
    private let meetingID = "123e4567-e89b-12d3-a456-426614174000"

    private func makeResult() -> MeetingResult {
        let first = MeetingSegment(id: "seg-1", startMs: 0, endMs: 1_000, speakerIDs: ["화자 1"], text: "안건을 공유합니다")
        let second = MeetingSegment(id: "seg-2", startMs: 1_000, endMs: 2_000, text: "다음 주 화요일까지 견적서를 보내주세요")
        let draft = MeetingActionDraft(id: "draft-1", title: "견적서 보내기", sourceSegmentIDs: [second.id])
        return MeetingResult(
            transcriptRevision: 3,
            title: "회의",
            summary: "요약",
            decisions: ["결정"],
            unresolvedQuestions: ["질문"],
            segments: [first, second],
            actionDrafts: [draft]
        )
    }

    @Test("text edit bumps revision, regenerates IDs, and drops drafts")
    func editTextInvalidatesRevision() throws {
        let original = makeResult()
        let edited = try MeetingTranscriptEditor.editText(
            result: original, meetingID: meetingID, segmentID: "seg-2", text: "  수정된 내용입니다  "
        )
        #expect(edited.transcriptRevision == 4)
        #expect(edited.actionDrafts.isEmpty)
        #expect(edited.summary.isEmpty)
        #expect(edited.segments.count == 2)
        #expect(edited.segments[1].text == "수정된 내용입니다")
        #expect(edited.segments.allSatisfy { $0.id != "seg-1" && $0.id != "seg-2" })
        #expect(edited.segments[0].speakerIDs == ["화자 1"])
        #expect(edited.segments.map(\.lineageID) == ["seg-1", "seg-2"])
    }

    @Test("text edit rejects unknown segment and empty text")
    func editTextValidation() {
        let original = makeResult()
        #expect(throws: MeetingTranscriptEditor.EditError.unknownSegment) {
            try MeetingTranscriptEditor.editText(result: original, meetingID: meetingID, segmentID: "missing", text: "내용")
        }
        #expect(throws: MeetingTranscriptEditor.EditError.emptyText) {
            try MeetingTranscriptEditor.editText(result: original, meetingID: meetingID, segmentID: "seg-1", text: "   ")
        }
    }

    @Test("split produces two ordered segments inside the original range")
    func splitSegment() throws {
        let original = makeResult()
        let edited = try MeetingTranscriptEditor.split(
            result: original, meetingID: meetingID, segmentID: "seg-2",
            atMs: 1_500, firstText: "다음 주 화요일까지", secondText: "견적서를 보내주세요"
        )
        #expect(edited.transcriptRevision == 4)
        #expect(edited.segments.count == 3)
        #expect(edited.segments[1].startMs == 1_000 && edited.segments[1].endMs == 1_500)
        #expect(edited.segments[2].startMs == 1_500 && edited.segments[2].endMs == 2_000)
        #expect(edited.segments[1].text == "다음 주 화요일까지")
        #expect(edited.segments[2].text == "견적서를 보내주세요")
        let splitLineages = Set(edited.segments.compactMap(\.lineageID))
        #expect(splitLineages.count == 3)
        #expect(splitLineages.contains("seg-1"))
        #expect(!splitLineages.contains("seg-2"))
    }

    @Test("split rejects out-of-range points")
    func splitValidation() {
        let original = makeResult()
        for badPoint: Int64 in [1_000, 2_000, 999, 2_001] {
            #expect(throws: MeetingTranscriptEditor.EditError.invalidSplitPoint) {
                try MeetingTranscriptEditor.split(
                    result: original, meetingID: meetingID, segmentID: "seg-2",
                    atMs: badPoint, firstText: "앞", secondText: "뒤"
                )
            }
        }
    }

    @Test("merge with previous combines range, text, and speakers")
    func mergeSegments() throws {
        let original = makeResult()
        let edited = try MeetingTranscriptEditor.mergeWithPrevious(
            result: original, meetingID: meetingID, segmentID: "seg-2"
        )
        #expect(edited.transcriptRevision == 4)
        #expect(edited.segments.count == 1)
        #expect(edited.segments[0].startMs == 0 && edited.segments[0].endMs == 2_000)
        #expect(edited.segments[0].text == "안건을 공유합니다 다음 주 화요일까지 견적서를 보내주세요")
        #expect(edited.segments[0].speakerIDs == ["화자 1"])
        #expect(edited.segments[0].lineageID != "seg-1")
        #expect(edited.segments[0].lineageID != "seg-2")
        #expect(throws: MeetingTranscriptEditor.EditError.noPreviousSegment) {
            try MeetingTranscriptEditor.mergeWithPrevious(result: original, meetingID: meetingID, segmentID: "seg-1")
        }
    }

    @Test("speaker edit trims, sorts, and drops empty labels")
    func speakerEdit() throws {
        let original = makeResult()
        let edited = try MeetingTranscriptEditor.setSpeakers(
            result: original, meetingID: meetingID, segmentID: "seg-2",
            speakerIDs: [" 화자 2 ", "", "화자 1"]
        )
        #expect(edited.segments[1].speakerIDs == ["화자 1", "화자 2"])
    }

    @Test("edit committer fences provenance, saves, and glossary side effects")
    @MainActor
    func editCommitterBoundaries() throws {
        let original = makeResult()
        let record = MeetingRecord(meetingID: meetingID)
        try record.replaceTranscriptionBase(original, status: .ready)
        record.refinementEngineLabel = MeetingRefinementEngine.Source.appleIntelligence.rawValue
        var saveCount = 0
        var acceptedCount = 0

        let accepted = try MeetingTranscriptEditCommitter.commit(
            record: record,
            isReprocessing: false,
            status: .ready,
            save: { saveCount += 1 },
            onAccepted: { acceptedCount += 1 },
            transform: {
                try MeetingTranscriptEditor.editText(
                    result: $0,
                    meetingID: meetingID,
                    segmentID: "seg-2",
                    text: "수정된 전사"
                )
            }
        )
        #expect(accepted)
        #expect(saveCount == 1)
        #expect(acceptedCount == 1)
        #expect(record.refinementEngineLabel.isEmpty)
        #expect(
            MeetingProofread.inlinePresentation(
                raw: record.rawResult,
                current: try #require(record.result),
                engineLabel: record.refinementEngineLabel,
                language: .korean
            ) == .hidden
        )

        record.refinementEngineLabel = MeetingRefinementEngine.Source.appleIntelligence.rawValue
        let noChange = try MeetingTranscriptEditCommitter.commit(
            record: record,
            isReprocessing: false,
            status: .ready,
            save: { saveCount += 1 },
            onAccepted: { acceptedCount += 1 },
            transform: { $0 }
        )
        #expect(!noChange)
        #expect(saveCount == 1)
        #expect(acceptedCount == 1)
        #expect(record.refinementEngineLabel == MeetingRefinementEngine.Source.appleIntelligence.rawValue)

        let blocked = try MeetingTranscriptEditCommitter.commit(
            record: record,
            isReprocessing: true,
            status: .ready,
            save: { saveCount += 1 },
            onAccepted: { acceptedCount += 1 },
            transform: { _ in throw TranscriptCommitTestError.invalidTransform }
        )
        #expect(!blocked)
        #expect(saveCount == 1)
        #expect(acceptedCount == 1)
    }

    @Test("edit committer rolls back transform and save failures")
    @MainActor
    func editCommitterRollback() throws {
        let original = makeResult()
        let transformRecord = MeetingRecord(meetingID: meetingID)
        try transformRecord.replaceTranscriptionBase(original, status: .ready)
        transformRecord.refinementEngineLabel = MeetingRefinementEngine.Source.appleIntelligence.rawValue
        let transformSnapshot = transformRecord.persistenceSnapshot()
        var acceptedCount = 0
        #expect(throws: TranscriptCommitTestError.invalidTransform) {
            _ = try MeetingTranscriptEditCommitter.commit(
                record: transformRecord,
                isReprocessing: false,
                status: .ready,
                save: {},
                onAccepted: { acceptedCount += 1 },
                transform: { _ in throw TranscriptCommitTestError.invalidTransform }
            )
        }
        #expect(transformRecord.persistenceSnapshot() == transformSnapshot)
        #expect(acceptedCount == 0)

        let saveRecord = MeetingRecord(meetingID: meetingID)
        try saveRecord.replaceTranscriptionBase(original, status: .ready)
        saveRecord.refinementEngineLabel = MeetingRefinementEngine.Source.appleIntelligence.rawValue
        let saveSnapshot = saveRecord.persistenceSnapshot()
        #expect(throws: TranscriptCommitTestError.saveFailed) {
            _ = try MeetingTranscriptEditCommitter.commit(
                record: saveRecord,
                isReprocessing: false,
                status: .ready,
                save: { throw TranscriptCommitTestError.saveFailed },
                onAccepted: { acceptedCount += 1 },
                transform: {
                    try MeetingTranscriptEditor.editText(
                        result: $0,
                        meetingID: meetingID,
                        segmentID: "seg-1",
                        text: "저장 실패"
                    )
                }
            )
        }
        #expect(saveRecord.persistenceSnapshot() == saveSnapshot)
        #expect(acceptedCount == 0)
    }

    @Test("importer rejects drafts from a pre-edit revision")
    @MainActor
    func staleDraftRejectedAfterEdit() throws {
        // cloudKitDatabase: .none — otherwise .automatic tries CloudKit mirroring
        // on a host without an iCloud account and crashes save() (serial run).
        let meetingConfig = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let meetingContainer = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: [meetingConfig])
        let todoConfig = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let todoContainer = try ModelContainer(for: AppDataContainer.appSchema, configurations: [todoConfig])

        let record = MeetingRecord(meetingID: meetingID)
        let original = makeResult()
        try record.update(result: original, status: .ready)
        meetingContainer.mainContext.insert(record)
        try meetingContainer.mainContext.save()

        let staleRevision = record.transcriptRevision
        let edited = try MeetingTranscriptEditor.editText(
            result: original, meetingID: meetingID, segmentID: "seg-2", text: "수정된 내용"
        )
        try record.update(result: edited, status: .ready)
        try meetingContainer.mainContext.save()

        #expect(throws: MeetingTodoImportError.staleOrUnknownDraft) {
            try MeetingTodoImporter.confirm(
                draftID: "draft-1",
                transcriptRevision: staleRevision,
                meeting: record,
                todoContext: todoContainer.mainContext,
                meetingContext: meetingContainer.mainContext
            )
        }
    }
}

private enum TranscriptCommitTestError: Error {
    case invalidTransform
    case saveFailed
}
