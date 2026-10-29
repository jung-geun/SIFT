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

    @Test("A short undecided suffix remains one displayed turn without rewriting evidence")
    func shortUnknownContinuity() {
        let rows = [displayRow("a", 0, 1_000, ["A"]), displayRow("unknown", 1_000, 2_500, []),
                    displayRow("a2", 2_500, 3_000, ["A"])]
        let display = MeetingSpeakerContinuity.project(rows)
        #expect(rows.map { display[$0.id]?.speakerIDs } == [["A"], ["A"], ["A"]])
        #expect(rows.map { display[$0.id]?.startsTurn } == [true, false, false])
        #expect(rows.map { display[$0.id]?.isInherited } == [false, true, false])
        #expect(rows[1].speakerIDs.isEmpty)
        #expect(rows[1].text == "unknown")
        // A provisional marker changing back to measured A is not a new header.
        #expect(display[rows[2].id]?.startsTurn == false)
    }

    @Test("An undecided fragment never erases the following real speaker transition")
    func shortUnknownBeforeDifferentSpeaker() {
        let rows = [displayRow("a", 0, 1_000, ["A"]), displayRow("unknown", 1_000, 1_150, []),
                    displayRow("b", 1_150, 2_000, ["B"])]
        let display = MeetingSpeakerContinuity.project(rows)
        #expect(display[rows[1].id]?.speakerIDs == [])
        #expect(display[rows[1].id]?.isInherited == false)
        #expect(display[rows[2].id]?.speakerIDs == ["B"])
        #expect(display[rows[2].id]?.startsTurn == true)
    }

    @Test("Leading unknown, long fragments, silence and chained fragments cannot grow the continuity budget")
    func boundedUnknownContext() {
        let leading = [displayRow("unknown", 0, 100, []), displayRow("a", 100, 1_000, ["A"])]
        #expect(MeetingSpeakerContinuity.project(leading)[leading[0].id]?.speakerIDs == [])
        for unknown in [displayRow("long", 1_000, 3_001, []), displayRow("silence", 1_051, 1_150, [])] {
            #expect(MeetingSpeakerContinuity.project([displayRow("a", 0, 1_000, ["A"]), unknown])[unknown.id]?.speakerIDs == [])
        }
        let chain = [displayRow("a", 0, 1_000, ["A"]), displayRow("u1", 1_000, 1_800, []),
                     displayRow("u2", 1_800, 2_600, []), displayRow("u3", 2_600, 3_100, [])]
        let display = MeetingSpeakerContinuity.project(chain)
        #expect(chain.dropFirst().allSatisfy { display[$0.id]?.speakerIDs == [] })
        #expect(display[chain[1].id]?.isInherited == false)
    }

    @Test("Source changes, manual boundaries, mixed evidence and overlapping time do not inherit")
    func explicitBoundaries() {
        let a = displayRow("a", 0, 1_000, ["A"])
        var manual = displayRow("manual-unknown", 1_000, 1_100, [])
        manual.blocksSpeakerInheritance = true
        var conflict = displayRow("conflict", 1_000, 1_100, [])
        conflict.evidenceSpeakerIDs = ["B"]
        var mixed = displayRow("mixed", 1_000, 1_100, [])
        mixed.evidenceSpeakerIDs = ["A", "B"]
        for unknown in [manual, conflict, mixed, displayRow("other-source", 1_000, 1_100, [], source: "other"),
                        displayRow("overlapping", 950, 1_100, [])] {
            #expect(MeetingSpeakerContinuity.project([a, unknown])[unknown.id]?.speakerIDs == [])
        }
        let overlap = displayRow("overlap", 1_000, 1_100, ["A", "B"])
        let unknown = displayRow("after-overlap", 1_100, 1_200, [])
        #expect(MeetingSpeakerContinuity.project([a, overlap, unknown])[unknown.id]?.speakerIDs == [])
        #expect(MeetingSpeakerContinuity.project([a, overlap])[overlap.id]?.startsTurn == true)
        #expect(MeetingSpeakerContinuity.project([a, manual, unknown])[unknown.id]?.speakerIDs == [])
    }

    @Test("Contradictory interval evidence cannot anchor or confirm a single-speaker display guess")
    func conflictingKnownEvidence() {
        let unknown = displayRow("unknown", 1_000, 1_200, [])
        for evidence in [["B"], ["A", "B"]] {
            var anchor = displayRow("anchor", 0, 1_000, ["A"])
            anchor.evidenceSpeakerIDs = evidence
            let tail = MeetingSpeakerContinuity.project([anchor, unknown])
            #expect(tail[unknown.id]?.speakerIDs == [])
            #expect(tail[unknown.id]?.isInherited == false)
            var following = displayRow("following", 1_200, 2_000, ["A"])
            following.evidenceSpeakerIDs = evidence
            let bounded = MeetingSpeakerContinuity.project([displayRow("a", 0, 1_000, ["A"]), unknown, following])
            #expect(bounded[unknown.id]?.speakerIDs == [])
            #expect(bounded[unknown.id]?.isInherited == false)
            #expect(following.speakerIDs == ["A"])
        }
        var compatible = displayRow("compatible", 0, 1_000, ["A"])
        compatible.evidenceSpeakerIDs = ["A"]
        #expect(MeetingSpeakerContinuity.project([compatible, unknown])[unknown.id]?.isInherited == true)
    }


    @Test("Unknown to mixed to unknown preserves the distinct mixed-speaker warning")
    func mixedUnknownTurnKind() {
        var mixed = displayRow("mixed", 100, 200, [])
        mixed.evidenceSpeakerIDs = ["A", "B"]
        let rows = [displayRow("unknown", 0, 100, []), mixed, displayRow("unknown2", 200, 300, []),
                    displayRow("unknown3", 300, 400, [])]
        let display = MeetingSpeakerContinuity.project(rows)
        #expect(rows.map { display[$0.id]?.startsTurn } == [true, true, true, false])
        #expect(display[mixed.id]?.kind == .mixed)
        #expect(display[rows[2].id]?.kind == .unknown)
    }

    @Test("Overlap speaker set ordering never creates another heading")
    func unorderedSpeakerSets() {
        let rows = [displayRow("overlap1", 0, 1_000, ["A", "B"]),
                    displayRow("overlap2", 1_000, 2_000, ["B", "A"])]
        let display = MeetingSpeakerContinuity.project(rows)
        #expect(display[rows[1].id]?.speakerIDs == ["A", "B"])
        #expect(display[rows[1].id]?.startsTurn == false)
    }

    @Test("Live, saved group and individual details use the identical read-only projection")
    func sharedProjection() throws {
        let segments = [MeetingSegment(id: "a", startMs: 0, endMs: 1_000, speakerIDs: ["A"], text: "First"),
                        MeetingSegment(id: "u", startMs: 1_000, endMs: 1_150, text: "Uncertain"),
                        MeetingSegment(id: "a2", startMs: 1_150, endMs: 2_000, speakerIDs: ["A"], text: "Continued")]
        let record = try saved("mic", parent: "parent", kind: .microphone, offset: 0, segments: segments)
        let before = record.persistenceSnapshot()
        let liveTimeline = MeetingConversationTimeline.live([live("mic", rows: segments.map {
            MeetingLiveTranscriptRow(id: $0.id, startMs: $0.startMs, endMs: $0.endMs, text: $0.text, speakerIDs: $0.speakerIDs)
        })])
        let savedTimeline = MeetingConversationTimeline.saved([record], groupID: "parent")
        let individual = MeetingConversationTimeline.individual(record)
        let individualRows = individual.unalignedSources[0].rows
        #expect(liveTimeline.rows.compactMap { liveTimeline.speakerPresentation[$0.id] }
            == savedTimeline.rows.compactMap { savedTimeline.speakerPresentation[$0.id] })
        #expect(individualRows.compactMap { individual.speakerPresentation[$0.id] }
            == savedTimeline.rows.compactMap { savedTimeline.speakerPresentation[$0.id] })
        #expect(MeetingSpeakerDisplay(record: record).continuity == individual.speakerPresentation)
        #expect(record.persistenceSnapshot() == before)
        // Source-local manual unknown remains unknown in both saved displays.
        record.diarizationData = try JSONEncoder().encode(MeetingDiarizationPayload(status: .completed,
            generation: UUID(), manifestDigest: "fixture", sourceTranscriptRevision: 0,
            sourceContentDigest: "fixture", modelRevision: "fixture", preset: "fixture",
            coveredThroughSample: 32_000, intervals: [],
            profiles: [MeetingSpeakerProfile(id: "A", ordinal: 1, displayName: nil)],
            manualAssignments: ["u": []], failureCode: nil))
        let manualSaved = MeetingConversationTimeline.saved([record], groupID: "parent")
        let manualIndividual = MeetingConversationTimeline.individual(record)
        #expect(manualSaved.speakerPresentation[manualSaved.rows[1].id]?.speakerIDs == [])
        #expect(manualIndividual.speakerPresentation[individualRows[1].id]?.speakerIDs == [])
    }

    @Test("Speaker evidence index preserves nested ranges and half-open boundaries")
    func indexedSpeakerEvidence() throws {
        let segments = [
            MeetingSegment(id: "wide", startMs: 0, endMs: 4_000, speakerIDs: ["A"], text: "Wide range"),
            MeetingSegment(id: "nested", startMs: 1_000, endMs: 1_100, text: "Nested range"),
            MeetingSegment(id: "touching", startMs: 2_000, endMs: 2_100, text: "Touching boundary"),
            MeetingSegment(id: "gap", startMs: 4_000, endMs: 4_100, text: "After every interval")
        ]
        let record = try saved("index", parent: "parent", kind: .microphone, offset: 0, segments: segments)
        // Intentionally unsorted, nested, overlapping and touching same-speaker intervals.
        let intervals = [MeetingSpeakerInterval(speakerID: "A", startSample: 1_500 * 16, endSample: 2_000 * 16),
                         MeetingSpeakerInterval(speakerID: "B", startSample: 1_050 * 16, endSample: 1_075 * 16),
                         MeetingSpeakerInterval(speakerID: "A", startSample: 0, endSample: 2_000 * 16),
                         MeetingSpeakerInterval(speakerID: "A", startSample: 1_000 * 16, endSample: 1_100 * 16),
                         MeetingSpeakerInterval(speakerID: "B", startSample: 2_000 * 16, endSample: 4_000 * 16)]
        record.diarizationData = try JSONEncoder().encode(MeetingDiarizationPayload(status: .completed,
            generation: UUID(), manifestDigest: "fixture", sourceTranscriptRevision: 0, sourceContentDigest: "fixture",
            modelRevision: "fixture", preset: "fixture", coveredThroughSample: 4_000 * 16, intervals: intervals,
            profiles: [MeetingSpeakerProfile(id: "A", ordinal: 1, displayName: nil),
                       MeetingSpeakerProfile(id: "B", ordinal: 2, displayName: nil)],
            manualAssignments: ["touching": []], failureCode: nil))
        let rows = MeetingConversationTimeline.individual(record).unalignedSources[0].rows
        #expect(rows.map(\.evidenceSpeakerIDs) == [["A", "B"], ["A", "B"], ["B"], []])
        #expect(rows[0].speakerIDs == ["A"])
        #expect(rows[2].blocksSpeakerInheritance)
    }

    @Test("Individual continuity follows edited current-ID order rather than tied lineage order")
    func editedLineageTieOrder() throws {
        let segments = [
            MeetingSegment(id: "a", lineageID: "z", startMs: 0, endMs: 1_000, speakerIDs: ["A"], text: "First rendered"),
            MeetingSegment(id: "b", lineageID: "a", startMs: 0, endMs: 1_000, speakerIDs: ["A"], text: "Second rendered")
        ]
        let record = try saved("tie", parent: "parent", kind: .microphone, offset: 0, segments: segments)
        let before = record.persistenceSnapshot()
        let individual = MeetingConversationTimeline.individual(record)
        let rows = individual.unalignedSources[0].rows
        #expect(rows.map(\.id.localID) == ["z", "a"])
        #expect(rows.map(\.text) == segments.map(\.text))
        #expect(rows.map { individual.speakerPresentation[$0.id]?.startsTurn } == [true, false])
        #expect(record.persistenceSnapshot() == before)
    }

    private func displayRow(_ id: String, _ start: Int64, _ end: Int64, _ speakers: [String],
                            source: String = "mic") -> MeetingConversationTimeline.Row {
        .init(id: .init(trackID: source, localID: id), localStartMs: start, localEndMs: end,
              startSample: nil, endSample: nil, text: id, speakerIDs: speakers)
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
