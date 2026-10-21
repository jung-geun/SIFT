import Foundation
import Testing
@testable import todo

@Suite("Source-local chronological conversation")
@MainActor
struct MeetingConversationTimelineTests {
    @Test("Q/A/Q follows media time, not source enumeration or ASR arrival")
    func questionAnswerFollowup() {
        let mic = live("mic", rows: [row("late-arrival-q", 1_000, 2_000, "Q"), row("first-arrival-followup", 5_000, 6_000, "Q2")])
        let system = live("system", kind: .screen, offset: 32_000, rows: [row("answer", 1_000, 2_000, "A")])
        let firstArrival = MeetingConversationTimeline.live([system, live("mic", rows: [mic.liveTranscriptRows[1]])])
        #expect(firstArrival.rows.map(\.text) == ["A", "Q2"])
        let timeline = MeetingConversationTimeline.live([system, mic])
        #expect(timeline.rows.map(\.text) == ["Q", "A", "Q2"])
        #expect(timeline.rows.map(\.startSample) == [16_000, 48_000, 80_000])
        #expect(timeline.rows == MeetingConversationTimeline.live([mic, system]).rows)
        #expect(timeline.rows.last?.id == firstArrival.rows.last?.id)
        #expect(system.liveTranscriptRows[0].startMs == 1_000)
    }

    @Test("sub-millisecond origins survive offset addition and endpoint ties")
    func sampleBoundaries() {
        let early = live("z", offset: 15, rows: [row("early", 0, 1, "early")])
        let later = live("a", offset: 16, rows: [row("later", 0, 1, "later")])
        let next = live("b", offset: 31, rows: [row("next", 0, 1, "next")])
        let timeline = MeetingConversationTimeline.live([next, later, early])
        #expect(timeline.rows.map(\.text) == ["early", "later", "next"])
        #expect(timeline.rows.map(\.startSample) == [15, 16, 31])
        #expect(timeline.rows.map(\.endSample) == [31, 32, 47])
        // An onset exactly at a preceding endpoint is not dropped or shifted.
        #expect(timeline.rows[0].endSample == timeline.rows[2].startSample)
    }

    @Test("ties and overlapping turns retain independent deterministic rows")
    func tiesAndOverlaps() {
        let a = live("a", rows: [row("long", 0, 4_000, "long"), row("short", 0, 2_000, "short")])
        let b = live("b", rows: [row("same-id", 0, 2_000, "other source"), row("overlap", 1_000, 3_000, "overlap")])
        let rows = MeetingConversationTimeline.live([b, a]).rows
        #expect(rows.map(\.text) == ["short", "other source", "long", "overlap"])
        #expect(rows == MeetingConversationTimeline.live([a, b]).rows)
        #expect(Set(rows.map(\.id)).count == 4)
        #expect(rows.allSatisfy { $0.speakerIDs == ["speaker-1"] })
        #expect(rows[0].id.trackID != rows[1].id.trackID)
    }

    @Test("partial duration replacement and finalization keep onset identity without stale rows")
    func partialReplacementAndFinalization() {
        var reducer = LiveTranscriptReducer()
        var builder = MeetingLiveTranscriptRowBuilder()
        func projection() -> MeetingConversationTimeline {
            let rows = builder.rows(for: reducer.entries, timeline: nil)
            return .live([live("mic", rows: rows)])
        }
        reducer.replace(LiveTranscriptEntry(id: "range:1000:1200", startMs: 1_000, endMs: 1_200, text: "Wh"))
        let partial = projection()
        reducer.replace(LiveTranscriptEntry(id: "range:1000:1800", startMs: 1_000, endMs: 1_800, text: "What now?"))
        let replacement = projection()
        #expect(replacement.rows.count == 1)
        #expect(partial.rows[0].id == replacement.rows[0].id)
        #expect(replacement.rows[0].text == "What now?")
        reducer.replace(LiveTranscriptEntry(id: "range:1000:2000", startMs: 1_000, endMs: 2_000, text: "What now?", isFinal: true))
        let final = projection()
        #expect(final.rows.count == 1)
        #expect(final.rows[0].id == partial.rows[0].id)
        #expect(final.rows[0].endSample == 32_000)
        reducer.replace(LiveTranscriptEntry(id: "stale-partial", startMs: 1_000, endMs: 1_500, text: "stale"))
        #expect(projection().rows == final.rows)
    }

    @Test("saved offsets interleave without rewriting any persistence fields or speaker ownership")
    func savedProjectionIsReadOnly() throws {
        let parent = "parent"
        let mic = try saved("mic", parent: parent, kind: .microphone, offset: 0, segments: [
            MeetingSegment(id: "q", lineageID: "question-lineage", startMs: 1_000, endMs: 2_000, speakerIDs: ["speaker-1"], text: "Q"),
            MeetingSegment(id: "q2", startMs: 5_000, endMs: 6_000, speakerIDs: ["speaker-1"], text: "Q2")])
        let system = try saved("system", parent: parent, kind: .application, offset: 32_000, segments: [
            MeetingSegment(id: "q", startMs: 1_000, endMs: 2_000, speakerIDs: ["speaker-1"], text: "A")])
        let before = [mic.persistenceSnapshot(), system.persistenceSnapshot()]
        let timeline = MeetingConversationTimeline.saved([system, mic], groupID: parent)
        #expect(timeline.rows.map(\.text) == ["Q", "A", "Q2"])
        #expect(timeline.rows[0].id.localID == "question-lineage")
        #expect(timeline.rows[1].id.localID == "q")
        #expect(timeline.rows[0].id.trackID != timeline.rows[1].id.trackID)
        #expect(timeline.rows.allSatisfy { $0.speakerIDs == ["speaker-1"] })
        #expect([mic.persistenceSnapshot(), system.persistenceSnapshot()] == before)
        // A text-edit replacement ID does not churn saved display identity.
        try mic.update(result: MeetingResult(segments: [MeetingSegment(id: "edited-q", lineageID: "question-lineage",
            startMs: 1_000, endMs: 2_000, speakerIDs: ["speaker-1"], text: "Edited Q")]))
        #expect(MeetingConversationTimeline.saved([mic], groupID: parent).rows.first?.id == timeline.rows.first?.id)
    }

    @Test("legacy defaults and unrelated groups never fabricate a common origin")
    func missingTiming() throws {
        let segments = [MeetingSegment(id: "legacy", startMs: 1_000, endMs: 2_000, text: "local only")]
        let legacy = try saved("legacy", parent: "parent", kind: .legacyMixed, offset: 0, segments: segments)
        let absent = try saved("absent", parent: "parent", kind: nil, offset: 0, segments: segments)
        let unrelated = try saved("unrelated", parent: "elsewhere", kind: .screen, offset: 0, segments: segments)
        let known = try saved("known", parent: "parent", kind: .microphone, offset: 0, segments: segments)
        let timeline = MeetingConversationTimeline.saved([legacy, unrelated, known, absent], groupID: "parent")
        #expect(timeline.rows.map(\.id.trackID) == ["known"])
        #expect(timeline.unalignedSources.map(\.id) == ["absent", "legacy", "unrelated"])
        #expect(timeline.unalignedSources.flatMap(\.rows).allSatisfy { $0.startSample == nil && $0.localStartMs == 1_000 })
    }

    @Test("invalid and overflowing timestamps remain explicitly unaligned; maximum endpoint is valid")
    func invalidAndMaximumOffsets() {
        let maximum = MeetingMediaTimeline.maximumSamples
        let valid = live("valid", offset: maximum - 16, rows: [row("end", 0, 1, "end")])
        let over = live("over", offset: maximum - 15, rows: [row("over", 0, 1, "over")])
        let negative = live("negative", offset: -1, rows: [row("negative", 0, 1, "negative")])
        let overflow = live("overflow", offset: Int64.max, rows: [row("huge", 0, Int64.max, "huge")])
        let negativeTime = live("negative-time", rows: [row("negative-time", -1, 1, "negative time")])
        let result = MeetingConversationTimeline.live([over, overflow, negative, valid, negativeTime])
        #expect(result.rows.map(\.id.trackID) == ["valid"])
        #expect(result.rows[0].endSample == maximum)
        #expect(result.unalignedSources.count == 4)
    }

    @Test("blank rows are omitted without changing the source transcript")
    func emptyRows() {
        let source = live("mic", rows: [row("empty", 0, 1_000, " \n"), row("text", 1_000, 2_000, "text")])
        #expect(MeetingConversationTimeline.live([source]).rows.map(\.text) == ["text"])
        #expect(source.liveTranscriptRows.count == 2)
    }

    private func row(_ id: String, _ start: Int64, _ end: Int64, _ text: String) -> MeetingLiveTranscriptRow {
        MeetingLiveTranscriptRow(id: id, startMs: start, endMs: end, text: text, speakerIDs: ["speaker-1"])
    }

    private func live(_ id: String, kind: MeetingAudioTrackKind = .microphone, offset: Int64 = 0,
                      rows: [MeetingLiveTranscriptRow]) -> MeetingLiveCaptureTrack {
        MeetingLiveCaptureTrack(meetingID: id, sourceKind: kind, sourceLabel: id,
            sessionStartSample: offset, recordedAudioSamples: 128_000, recordedAudioPartCount: 1,
            liveTranscriptRows: rows, liveSpeakerOrdinals: ["speaker-1": 1], liveSpeakerPhase: .analyzing,
            liveTranscriptionWarning: nil, liveDiarizationWarning: nil)
    }

    private func saved(_ id: String, parent: String, kind: MeetingAudioTrackKind?, offset: Int64,
                       segments: [MeetingSegment]) throws -> MeetingRecord {
        let record = MeetingRecord(meetingID: id)
        record.parentMeetingID = parent
        record.audioTrackKindRaw = kind?.rawValue
        record.audioTrackStartSample = offset
        try record.update(result: MeetingResult(segments: segments))
        return record
    }
}
