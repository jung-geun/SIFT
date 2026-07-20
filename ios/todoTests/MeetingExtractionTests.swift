import Foundation
import Testing
@testable import todo

@Suite("Meeting extraction contracts")
struct MeetingExtractionTests {
    private let meetingID = "123e4567-e89b-12d3-a456-426614174000"

    @Test("canonical IDs match shared golden vectors")
    func canonicalIDs() {
        #expect(
            MeetingCanonicalID.replacementSegment(
                meetingID: meetingID,
                transcriptRevision: 0,
                startMs: 0,
                endMs: 1_000,
                text: "  민수님이 다음 주 화요일까지 견적서를 보내주세요\r\n"
            ) == "b1d9ec713d8164418c29c9fa85b30423"
        )
        #expect(
            MeetingCanonicalID.replacementSegment(
                meetingID: meetingID,
                transcriptRevision: 1,
                startMs: 1_000,
                endMs: 2_000,
                text: "회의 내용"
            ) == "22a82fb8c90b4004e05a13c5671738ee"
        )
        #expect(
            MeetingCanonicalID.action(
                meetingID: meetingID,
                sourceSegmentIDs: ["bbbb", "aaaa", "bbbb"],
                title: "  견적서 제출  ",
                assignee: nil,
                dueAtISO8601: nil
            ) == "ea912f8e12cf7512daa4ea43a2fe958f"
        )
        #expect(
            MeetingCanonicalID.action(
                meetingID: meetingID,
                sourceSegmentIDs: ["0001", "0002"],
                title: "\t정산  자료\n공유 ",
                assignee: " 민수 님 ",
                dueAtISO8601: "2026-07-14T00:00:00.000Z"
            ) == "1441a82b6dcff9b5de1388f3db781c87"
        )
    }

    @Test("lineage keeps revised segment IDs distinct")
    func lineageDistinguishesReplacementIDs() {
        let first = MeetingCanonicalID.replacementSegment(
            meetingID: meetingID,
            transcriptRevision: 1,
            startMs: 0,
            endMs: 1_000,
            text: "같은 교정문",
            lineageID: "raw-a"
        )
        let second = MeetingCanonicalID.replacementSegment(
            meetingID: meetingID,
            transcriptRevision: 1,
            startMs: 0,
            endMs: 1_000,
            text: "같은 교정문",
            lineageID: "raw-b"
        )

        #expect(first != second)
    }

    @Test("revision regenerates IDs and invalidates unconfirmed output")
    func revisionInvalidatesExtraction() throws {
        let source = MeetingSegment(id: "source-1", startMs: 0, endMs: 1_000, text: "민수님이 견적서를 보내주세요")
        let draft = MeetingActionDraft(id: "draft-1", title: "견적서 보내기", sourceSegmentIDs: [source.id])
        let original = MeetingResult(
            transcriptRevision: 0,
            title: "회의",
            summary: "요약",
            decisions: ["결정"],
            unresolvedQuestions: ["질문"],
            segments: [source],
            actionDrafts: [draft]
        )

        let revised = try MeetingRevisionEditor.editSegments(
            meetingID: meetingID,
            in: original,
            segments: [MeetingSegment(id: source.id, startMs: 0, endMs: 1_000, text: "민수님이 다음 주 화요일까지 견적서를 보내주세요")]
        )

        #expect(revised.transcriptRevision == 1)
        #expect(revised.summary.isEmpty)
        #expect(revised.decisions.isEmpty)
        #expect(revised.actionDrafts.isEmpty)
        #expect(revised.segments.count == 1)
        #expect(revised.segments.first?.id == "005fb00947a1e96dd940c03e96f8a982")
        #expect(revised.segments.first?.lineageID == source.id)
    }


    @Test("segment validation rejects empty and duplicate identities")
    func segmentIdentityValidation() {
        let emptyLineage = MeetingResult(segments: [
            MeetingSegment(id: "one", lineageID: "", startMs: 0, endMs: 1_000, text: "내용")
        ])
        #expect(throws: MeetingModelError.invalidSegment("one")) {
            _ = try emptyLineage.validated()
        }

        let duplicateID = MeetingResult(segments: [
            MeetingSegment(id: "same", startMs: 0, endMs: 1_000, text: "첫째"),
            MeetingSegment(id: "same", startMs: 1_000, endMs: 2_000, text: "둘째")
        ])
        #expect(throws: MeetingModelError.duplicateSegmentID("same")) {
            _ = try duplicateID.validated()
        }

        let duplicateLineage = MeetingResult(segments: [
            MeetingSegment(id: "one", lineageID: "raw", startMs: 0, endMs: 1_000, text: "첫째"),
            MeetingSegment(id: "two", lineageID: "raw", startMs: 1_000, endMs: 2_000, text: "둘째")
        ])
        #expect(throws: MeetingModelError.duplicateSegmentLineage("raw")) {
            _ = try duplicateLineage.validated()
        }
    }

    @Test("legacy segments decode without lineage")
    func legacySegmentLineageCompatibility() throws {
        let data = try #require(
            """
            {"id":"legacy","startMs":0,"endMs":1000,"speakerIDs":[],"text":"내용","isFinal":true}
            """.data(using: .utf8)
        )
        let segment = try JSONDecoder().decode(MeetingSegment.self, from: data)
        #expect(segment.lineageID == nil)
        #expect(segment.stableLineageID == segment.id)

        let encoded = try JSONEncoder().encode(segment)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["lineageID"] == nil)
    }
    @Test("due dates require exact valid UTC milliseconds")
    func dueDateValidation() {
        #expect(MeetingDate.canonicalUTC("2026-07-14T00:00:00.000Z") == "2026-07-14T00:00:00.000Z")
        #expect(MeetingDate.canonicalUTC("2026-07-14T00:00:00Z") == nil)
        #expect(MeetingDate.canonicalUTC("2026-02-29T00:00:00.000Z") == nil)
    }

    @Test("speaker rename does not revise transcript")
    func speakerRenameLeavesRevisionAndDrafts() {
        let source = MeetingSegment(id: "source-1", startMs: 0, endMs: 1_000, speakerIDs: ["speaker-1"], text: "내용")
        let draft = MeetingActionDraft(id: "draft-1", title: "확인", sourceSegmentIDs: [source.id])
        let result = MeetingResult(transcriptRevision: 4, segments: [source], actionDrafts: [draft])
        let renamed = MeetingRevisionEditor.renameSpeaker(in: result, from: "speaker-1", to: "민수")

        #expect(renamed.transcriptRevision == 4)
        #expect(renamed.actionDrafts == [draft])
        #expect(renamed.segments.count == 1)
        #expect(renamed.segments.first?.speakerIDs == ["민수"])
    }

    @Test("media timeline emits exact owned intervals without duplicates")
    func mediaTimelineBoundaries() throws {
        var oneShort = MeetingMediaTimeline()
        #expect(try oneShort.append(MeetingMediaTimeline.ownedSamplesPerPart - 1).isEmpty)
        let shortCandidate = try oneShort.finalPart()
        let shortPart = try #require(shortCandidate)
        #expect(shortPart.index == 0)
        #expect(shortPart.partStartSample == 0)
        #expect(shortPart.ownedEndSample == MeetingMediaTimeline.ownedSamplesPerPart - 1)

        var exact = MeetingMediaTimeline()
        let completed = try exact.append(MeetingMediaTimeline.ownedSamplesPerPart)
        #expect(completed.count == 1)
        #expect(exact.parts == completed)
        #expect(try exact.finalPart() == nil)

        var next = MeetingMediaTimeline()
        _ = try next.append(MeetingMediaTimeline.ownedSamplesPerPart + 1)
        let remainderCandidate = try next.finalPart()
        let remainder = try #require(remainderCandidate)
        #expect(remainder.index == 1)
        #expect(remainder.partStartSample == MeetingMediaTimeline.ownedSamplesPerPart - MeetingMediaTimeline.overlapSamples)
        #expect(remainder.ownedStartSample == MeetingMediaTimeline.ownedSamplesPerPart)
        #expect(remainder.ownedEndSample == MeetingMediaTimeline.ownedSamplesPerPart + 1)

        var sixHours = MeetingMediaTimeline()
        let parts = try sixHours.append(MeetingMediaTimeline.maximumSamples)
        #expect(parts.count == 36)
        #expect(sixHours.parts.count == 36)
        #expect(try sixHours.finalPart() == nil)
        #expect(throws: MeetingMediaTimelineError.durationLimit) {
            _ = try sixHours.append(1)
        }
    }
}
