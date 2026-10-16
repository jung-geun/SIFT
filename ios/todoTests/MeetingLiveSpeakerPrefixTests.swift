import Foundation
import Testing
@testable import todo

@Suite("Meeting live speaker prefix attribution")
@MainActor
struct MeetingLiveSpeakerPrefixTests {
    @Test("a growing untimed entry gets a provisional speaker before EOS without splitting text")
    func growingUntimedPrefix() {
        var builder = MeetingLiveTranscriptRowBuilder()
        var timeline = MeetingLiveSpeakerTimeline(sessionID: UUID())
        update(&timeline, coverageMs: 400, open: [interval("A", 0, 400)])
        let first = LiveTranscriptEntry(id: "growing", startMs: 0, endMs: 1_000, text: "  안녕하세요 👋\n")
        #expect(builder.rows(for: [first], timeline: timeline) == [
            MeetingLiveTranscriptRow(id: first.id, startMs: 0, endMs: 1_000, text: first.text, speakerIDs: ["A"])
        ])

        update(&timeline, coverageMs: 800, open: [interval("A", 0, 800)])
        let growing = LiveTranscriptEntry(id: first.id, startMs: 0, endMs: 2_000, text: first.text + "계속 이야기합니다.")
        #expect(builder.rows(for: [growing], timeline: timeline) == [
            MeetingLiveTranscriptRow(id: growing.id, startMs: 0, endMs: 2_000, text: growing.text, speakerIDs: ["A"])
        ])
        #expect(!growing.isFinal)
    }

    @Test("a sequential second speaker invalidates an untimed prefix label without fabricating boundaries")
    func sequentialMixedPrefixStaysUnknown() {
        var builder = MeetingLiveTranscriptRowBuilder()
        var timeline = MeetingLiveSpeakerTimeline(sessionID: UUID())
        let entry = LiveTranscriptEntry(id: "mixed", startMs: 0, endMs: 3_000, text: "A speaks. B replies.", isFinal: true)
        update(&timeline, coverageMs: 800, open: [interval("A", 0, 800)])
        #expect(builder.rows(for: [entry], timeline: timeline).map(\.speakerIDs) == [["A"]])

        update(&timeline, coverageMs: 1_000, closed: [interval("A", 0, 800)], open: [interval("B", 800, 1_000)])
        #expect(builder.rows(for: [entry], timeline: timeline) == [
            MeetingLiveTranscriptRow(id: entry.id, startMs: 0, endMs: 3_000, text: entry.text, speakerIDs: [])
        ])
    }

    @Test("no coverage, silence and less than 200 ms of actual evidence stay unknown")
    func insufficientUntimedEvidence() {
        let entry = LiveTranscriptEntry(id: "e", startMs: 1_000, endMs: 10_000, text: "raw text")
        let cases: [(coverage: Int64, intervals: [MeetingSpeakerInterval])] = [
            (1_000, [interval("A", 1_000, 2_000)]),
            (5_000, []),
            (1_199, [interval("A", 1_000, 2_000)]),
            (5_000, [interval("A", 1_000, 1_199)]),
            (5_000, [interval("A", 0, 1_000), interval("B", 5_000, 6_000)])
        ]
        for sample in cases {
            var builder = MeetingLiveTranscriptRowBuilder()
            var timeline = MeetingLiveSpeakerTimeline(sessionID: UUID())
            update(&timeline, coverageMs: sample.coverage, open: sample.intervals)
            #expect(builder.rows(for: [entry], timeline: timeline) == [
                MeetingLiveTranscriptRow(id: entry.id, startMs: entry.startMs, endMs: entry.endMs, text: entry.text, speakerIDs: [])
            ])
        }
    }

    @Test("200 ms of unique live speaker evidence is not diluted by long silence")
    func uniqueEvidenceAcrossSilence() {
        var builder = MeetingLiveTranscriptRowBuilder()
        var timeline = MeetingLiveSpeakerTimeline(sessionID: UUID())
        update(&timeline, coverageMs: 8_000, closed: [interval("A", 1_000, 1_200)])
        let entry = LiveTranscriptEntry(id: "silence", startMs: 0, endMs: 10_000, text: "one short phrase")
        #expect(builder.rows(for: [entry], timeline: timeline).map(\.speakerIDs) == [["A"]])
    }

    @Test("covered timed text is labeled separately from the pending suffix, then B gets its own label")
    func coveredPrefixKeepsUncoveredSuffixUnknown() {
        var builder = MeetingLiveTranscriptRowBuilder()
        var timeline = MeetingLiveSpeakerTimeline(sessionID: UUID())
        let entry = timedEntry()
        update(&timeline, coverageMs: 500, open: [interval("A", 0, 500)])
        let partial = builder.rows(for: [entry], timeline: timeline)
        #expect(partial == [
            MeetingLiveTranscriptRow(id: entry.id, startMs: 0, endMs: 500, text: "first", speakerIDs: ["A"]),
            MeetingLiveTranscriptRow(id: "\(entry.id)#1", startMs: 500, endMs: 1_000, text: "second", speakerIDs: [])
        ])

        update(&timeline, coverageMs: 1_000, closed: [interval("A", 0, 500), interval("B", 500, 1_000)])
        let covered = builder.rows(for: [entry], timeline: timeline)
        #expect(covered.map(\.text) == ["first", "second"])
        #expect(covered.map(\.speakerIDs) == [["A"], ["B"]])
        #expect(entry.text == "first second")
        #expect(entry.isFinal)
    }

    @Test("a word crossing coverage waits for its whole duration before splitting to a new speaker")
    func crossingWordWaitsForCoverage() {
        var builder = MeetingLiveTranscriptRowBuilder()
        var timeline = MeetingLiveSpeakerTimeline(sessionID: UUID())
        let entry = timedEntry()
        for coverage: Int64 in [501, 999] {
            update(&timeline, coverageMs: coverage, open: [interval("A", 0, 500), interval("B", 500, coverage)])
            let rows = builder.rows(for: [entry], timeline: timeline)
            #expect(rows.map(\.text) == ["first", "second"])
            #expect(rows.map(\.speakerIDs) == [["A"], []])
        }
        update(&timeline, coverageMs: 1_000, open: [interval("A", 0, 500), interval("B", 500, 1_000)])
        let split = builder.rows(for: [entry], timeline: timeline)
        #expect(split.map(\.text) == ["first", "second"])
        #expect(split.map(\.speakerIDs) == [["A"], ["B"]])
    }

    @Test("covered but insufficient word evidence stays unknown instead of adopting the prior speaker")
    func coveredUnknownWordKeepsUnknownLabel() {
        var builder = MeetingLiveTranscriptRowBuilder()
        var timeline = MeetingLiveSpeakerTimeline(sessionID: UUID())
        let entry = timedEntry()
        update(&timeline, coverageMs: 1_000, open: [interval("A", 0, 500)])
        #expect(builder.rows(for: [entry], timeline: timeline).map(\.speakerIDs) == [["A"], []])
        update(&timeline, coverageMs: 1_000, open: [interval("A", 0, 500), interval("B", 500, 700)])
        #expect(builder.rows(for: [entry], timeline: timeline).map(\.speakerIDs) == [["A"], []])
    }
    @Test("fixed entries are relabeled when evidence arrives without additional coverage")
    func evidenceChangesInvalidateCache() {
        var builder = MeetingLiveTranscriptRowBuilder()
        var timeline = MeetingLiveSpeakerTimeline(sessionID: UUID())
        let entry = timedEntry()
        update(&timeline, coverageMs: 1_000)
        #expect(builder.rows(for: [entry], timeline: timeline).map(\.speakerIDs) == [[]])
        update(&timeline, coverageMs: 1_000, open: [interval("A", 0, 500), interval("B", 500, 1_000)])
        #expect(builder.rows(for: [entry], timeline: timeline).map(\.speakerIDs) == [["A"], ["B"]])
        #expect(builder.rows(for: [entry], timeline: nil).map(\.speakerIDs) == [[]])
        #expect(builder.rows(for: [entry], timeline: timeline).map(\.speakerIDs) == [["A"], ["B"]])
    }

    @Test("strict final segment alignment still requires complete coverage and a majority")
    func finalSegmentAlignmentRemainsStrict() {
        #expect(MeetingSpeakerAlignment.assignSegment(
            startMs: 0, endMs: 2_000, intervals: [interval("A", 0, 1_500)], coveredThroughSample: 1_500 * 16
        ) == [])
        #expect(MeetingSpeakerAlignment.assignSegment(
            startMs: 0, endMs: 2_000, intervals: [interval("A", 0, 200)], coveredThroughSample: 2_000 * 16
        ) == [])
        #expect(MeetingSpeakerAlignment.assignSegment(
            startMs: 0, endMs: 2_000, intervals: [interval("A", 0, 1_800), interval("B", 1_800, 2_000)], coveredThroughSample: 2_000 * 16
        ) == [])
        #expect(MeetingSpeakerAlignment.assignSegment(
            startMs: 0, endMs: 2_000, intervals: [interval("A", 0, 2_000)], coveredThroughSample: 2_000 * 16
        ) == ["A"])
    }

    private func timedEntry() -> LiveTranscriptEntry {
        LiveTranscriptEntry(id: "timed", startMs: 0, endMs: 1_000, text: "first second", timedRuns: [
            MeetingTimedTextRun(utf16Offset: 0, utf16Length: 5, startMs: 0, endMs: 500),
            MeetingTimedTextRun(utf16Offset: 6, utf16Length: 6, startMs: 500, endMs: 1_000)
        ], isFinal: true)
    }

    private func interval(_ id: String, _ startMs: Int64, _ endMs: Int64) -> MeetingSpeakerInterval {
        MeetingSpeakerInterval(speakerID: id, startSample: startMs * 16, endSample: endMs * 16)
    }

    private func update(
        _ timeline: inout MeetingLiveSpeakerTimeline,
        coverageMs: Int64,
        closed: [MeetingSpeakerInterval] = [],
        open: [MeetingSpeakerInterval] = []
    ) {
        _ = timeline.apply(MeetingDiarizationUpdate(
            sessionID: timeline.sessionID, closedIntervals: closed, openIntervals: open, coveredThroughSample: coverageMs * 16
        ))
    }
}
