import CoreMedia
import Foundation
import Speech
import Testing
@testable import todo

@Suite("Meeting diarization contract")
struct MeetingDiarizationPersistenceTests {
    private let original = MeetingResult(
        transcriptRevision: 2,
        segments: [MeetingSegment(id: "speech", startMs: 1_000, endMs: 3_000, text: "😀 hello")]
    )
    private let manifest = MeetingAudioManifest(relativeDirectory: "test", sampleRate: 16_000,
                                                totalSamples: 48_000, parts: [])

    private func payload() throws -> MeetingDiarizationPayload {
        MeetingDiarizationPayload(
            status: .completed, generation: UUID(),
            manifestDigest: try MeetingDiarizationFingerprint.manifest(manifest),
            sourceTranscriptRevision: original.transcriptRevision,
            sourceContentDigest: try MeetingDiarizationFingerprint.source(original),
            modelRevision: "pinned", preset: "finalPass", coveredThroughSample: 48_000,
            intervals: [MeetingSpeakerInterval(speakerID: "speaker-1", startSample: 16_000, endSample: 32_000)],
            profiles: [MeetingSpeakerProfile(id: "speaker-1", ordinal: 1, displayName: nil)],
            manualAssignments: [:], failureCode: nil
        )
    }

    @Test("old result JSON decodes without timed runs; annotation saves separately")
    @MainActor
    func legacyResultAndSeparatePayload() throws {
        let oldJSON = try #require("""
            {"transcriptRevision":2,"title":"","summary":"","decisions":[],"unresolvedQuestions":[],"segments":[{"id":"speech","startMs":1000,"endMs":3000,"speakerIDs":[],"text":"😀 hello","isFinal":true}],"actionDrafts":[]}
            """.data(using: .utf8))
        let record = MeetingRecord()
        record.resultData = oldJSON
        record.rawResultData = oldJSON
        record.transcriptRevision = 2
        try record.update(audioManifest: manifest)
        #expect(record.result == original)
        #expect(record.rawResult == original)
        #expect(record.result?.segments[0].timedRuns == nil)
        #expect(record.diarization == nil)
        let annotation = try payload()
        try record.update(diarization: annotation)
        #expect(record.diarization?.intervals == annotation.intervals)
        #expect(record.resultData == oldJSON)
        #expect(record.rawResultData == oldJSON)
    }

    @Test("Speech runs retain original UTF-16 offsets and only attributed timings")
    func timedRuns() {
        var emoji = AttributedString("😀")
        emoji.audioTimeRange = CMTimeRange(start: CMTime(value: 3, timescale: 2),
                                           duration: CMTime(value: 1, timescale: 2))
        var next = AttributedString("word")
        next.audioTimeRange = CMTimeRange(start: CMTime(value: 5, timescale: 2),
                                          duration: CMTime(value: 1, timescale: 2))
        let text = AttributedString("intro ") + emoji + AttributedString(" gap ") + next
        let runs = MeetingTimedTextRun.extract(from: text, startMs: 0, endMs: 3_000)
        #expect(runs == [
            MeetingTimedTextRun(utf16Offset: 6, utf16Length: 2, startMs: 1_500, endMs: 2_000),
            MeetingTimedTextRun(utf16Offset: 13, utf16Length: 4, startMs: 2_500, endMs: 3_000)
        ])
        #expect(MeetingTimedTextRun.extract(from: AttributedString("untimed"), startMs: 0, endMs: 1_000).isEmpty)
    }

    @Test("overlapping and end-clipped speaker words retain persistable timing")
    @MainActor
    func clippedSpeakerWordsPersist() throws {
        var first = AttributedString("안녕하세요")
        first.audioTimeRange = CMTimeRange(start: CMTime(value: 1_000, timescale: 1_000),
                                            duration: CMTime(value: 500, timescale: 1_000))
        var overlapping = AttributedString(" 반갑습니다")
        overlapping.audioTimeRange = CMTimeRange(start: CMTime(value: 1_490, timescale: 1_000),
                                                  duration: CMTime(value: 400, timescale: 1_000))
        var last = AttributedString(" 다음에 봐요")
        last.audioTimeRange = CMTimeRange(start: CMTime(value: 1_900, timescale: 1_000),
                                          duration: CMTime(value: 400, timescale: 1_000))
        let text = first + overlapping + last
        let entry = LiveTranscriptEntry(id: "speech", startMs: 1_000, endMs: 2_000,
                                        text: String(text.characters),
                                        timedRuns: MeetingTimedTextRun.extract(from: text, startMs: 1_000, endMs: 2_000),
                                        isFinal: true)
        let result = MeetingProvisionalResultBuilder.make(meetingID: UUID().uuidString.lowercased(), entries: [entry])
        let expected = [
            MeetingTimedTextRun(utf16Offset: 0, utf16Length: 5, startMs: 1_000, endMs: 1_500),
            MeetingTimedTextRun(utf16Offset: 5, utf16Length: 6, startMs: 1_500, endMs: 1_890),
            MeetingTimedTextRun(utf16Offset: 11, utf16Length: 7, startMs: 1_900, endMs: 2_000)
        ]
        #expect(result.segments[0].text == "안녕하세요 반갑습니다 다음에 봐요")
        #expect(result.segments[0].timedRuns == expected)
        let record = MeetingRecord()
        try record.replaceTranscriptionBase(result, status: .ready)
        #expect(record.result?.segments[0].timedRuns == expected)
        #expect(record.rawResult?.segments[0].timedRuns == expected)
    }

    @Test("measured spans clip at either or both result boundaries")
    func measuredSpansClipToResultBounds() throws {
        let cases: [(Int64, Int64, Int64, Int64)] = [
            (700, 1_300, 1_000, 1_300),
            (1_700, 2_400, 1_700, 2_000),
            (-100, 2_400, 1_000, 2_000)
        ]
        for (start, end, expectedStart, expectedEnd) in cases {
            var word = AttributedString("😀word")
            word.audioTimeRange = CMTimeRange(start: CMTime(value: start, timescale: 1_000),
                                              duration: CMTime(value: end - start, timescale: 1_000))
            let runs = MeetingTimedTextRun.extract(from: word, startMs: 1_000, endMs: 2_000)
            #expect(runs == [MeetingTimedTextRun(utf16Offset: 0, utf16Length: 6,
                                                startMs: expectedStart, endMs: expectedEnd)])
            _ = try MeetingResult(segments: [MeetingSegment(startMs: 1_000, endMs: 2_000,
                                                             text: "😀word", timedRuns: runs)]).validated()
        }
    }

    @Test("fully consumed runs and untimed gaps retain exact UTF-16 offsets")
    func consumedRunsLeaveTextGaps() throws {
        var first = AttributedString("one")
        first.audioTimeRange = CMTimeRange(start: CMTime(value: 1_000, timescale: 1_000),
                                            duration: CMTime(value: 500, timescale: 1_000))
        var consumed = AttributedString("old😀")
        consumed.audioTimeRange = CMTimeRange(start: CMTime(value: 1_100, timescale: 1_000),
                                               duration: CMTime(value: 400, timescale: 1_000))
        var later = AttributedString("two")
        later.audioTimeRange = CMTimeRange(start: CMTime(value: 1_450, timescale: 1_000),
                                            duration: CMTime(value: 350, timescale: 1_000))
        let text = AttributedString("😀 ") + first + AttributedString(" ")
            + consumed + AttributedString("  ") + later
        let runs = MeetingTimedTextRun.extract(from: text, startMs: 1_000, endMs: 2_000)
        #expect(runs == [
            MeetingTimedTextRun(utf16Offset: 3, utf16Length: 3, startMs: 1_000, endMs: 1_500),
            MeetingTimedTextRun(utf16Offset: 14, utf16Length: 3, startMs: 1_500, endMs: 1_800)
        ])
        _ = try MeetingResult(segments: [MeetingSegment(startMs: 1_000, endMs: 2_000,
                                                         text: String(text.characters), timedRuns: runs)]).validated()
    }

    @Test("invalid and wholly out-of-bounds measurements never invent timing or consume later words")
    func unusableMeasurementsLeaveLaterTimingIntact() throws {
        let ranges = [
            CMTimeRange.invalid,
            CMTimeRange(start: .indefinite, duration: CMTime(value: 1, timescale: 1)),
            CMTimeRange(start: .positiveInfinity, duration: CMTime(value: 1, timescale: 1)),
            CMTimeRange(start: .negativeInfinity, duration: CMTime(value: 1, timescale: 1)),
            CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: .positiveInfinity),
            CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: .zero),
            CMTimeRange(start: CMTime(value: 2, timescale: 1), duration: CMTime(value: -1, timescale: 1)),
            CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)),
            CMTimeRange(start: CMTime(value: 2, timescale: 1), duration: CMTime(value: 1, timescale: 1)),
            CMTimeRange(start: CMTime(value: 12_001, timescale: 10_000),
                        duration: CMTime(value: 1, timescale: 10_000))
        ]
        for range in ranges {
            var invalid = AttributedString("bad😀")
            invalid.audioTimeRange = range
            var later = AttributedString("word")
            later.audioTimeRange = CMTimeRange(start: CMTime(value: 1_500, timescale: 1_000),
                                                duration: CMTime(value: 300, timescale: 1_000))
            let text = invalid + AttributedString("  ") + later
            let runs = MeetingTimedTextRun.extract(from: text, startMs: 1_000, endMs: 2_000)
            #expect(runs == [MeetingTimedTextRun(utf16Offset: 7, utf16Length: 4,
                                                startMs: 1_500, endMs: 1_800)])
            _ = try MeetingResult(segments: [MeetingSegment(startMs: 1_000, endMs: 2_000,
                                                             text: String(text.characters), timedRuns: runs)]).validated()
        }
    }

    @Test("end-of-result word survives a one-millisecond Speech rounding difference")
    func boundaryWordKeepsUsableTime() throws {
        var word = AttributedString("네")
        word.audioTimeRange = CMTimeRange(start: CMTime(value: 100, timescale: 1_000),
                                          duration: CMTime(value: 700, timescale: 1_000))
        let runs = MeetingTimedTextRun.extract(from: word, startMs: 100, endMs: 799)
        #expect(runs == [MeetingTimedTextRun(utf16Offset: 0, utf16Length: 1,
                                            startMs: 100, endMs: 799)])
        _ = try MeetingResult(segments: [MeetingSegment(startMs: 100, endMs: 799,
                                                         text: "네", timedRuns: runs)]).validated()
    }

    @Test("timed text rejects negative, out-of-bounds and overlapping spans")
    func invalidTimedRuns() {
        let first = MeetingTimedTextRun(utf16Offset: 0, utf16Length: 2, startMs: 1_000, endMs: 1_500)
        for bad in [
            MeetingTimedTextRun(utf16Offset: -1, utf16Length: 1, startMs: 1_500, endMs: 2_000),
            MeetingTimedTextRun(utf16Offset: 8, utf16Length: 1, startMs: 1_500, endMs: 2_000),
            MeetingTimedTextRun(utf16Offset: 1, utf16Length: 1, startMs: 1_500, endMs: 2_000),
            MeetingTimedTextRun(utf16Offset: 3, utf16Length: 1, startMs: -1, endMs: 2_000),
            MeetingTimedTextRun(utf16Offset: 3, utf16Length: 1, startMs: 1_400, endMs: 2_000),
            MeetingTimedTextRun(utf16Offset: 3, utf16Length: 1, startMs: 1_500, endMs: 3_001)
        ] {
            let segment = MeetingSegment(id: "speech", startMs: 1_000, endMs: 3_000,
                                         text: "😀 hello", timedRuns: [first, bad])
            #expect(throws: MeetingModelError.invalidSegment("speech")) {
                _ = try MeetingResult(segments: [segment]).validated()
            }
        }
    }

    @Test("cross-speaker sample overlaps are valid, but negative or out-of-bounds ranges fail")
    func sampleBoundsAndOverlap() throws {
        var annotation = try payload()
        annotation.profiles.append(MeetingSpeakerProfile(id: "speaker-2", ordinal: 2, displayName: nil))
        annotation.intervals.append(MeetingSpeakerInterval(speakerID: "speaker-2", startSample: 24_000,
                                                            endSample: 40_000))
        _ = try annotation.validated(totalSamples: manifest.totalSamples)
        for bad in [
            MeetingSpeakerInterval(speakerID: "speaker-1", startSample: -1, endSample: 3),
            MeetingSpeakerInterval(speakerID: "speaker-1", startSample: 48_000, endSample: 48_001),
            MeetingSpeakerInterval(speakerID: "speaker-1", startSample: 3, endSample: 3)
        ] {
            var invalid = annotation
            invalid.intervals = [bad]
            #expect(throws: MeetingDiarizationError.invalidTimeline) {
                _ = try invalid.validated(totalSamples: manifest.totalSamples)
            }
        }
    }

    @Test("content fingerprint excludes labels but includes original timed runs")
    func sourceDigestBoundaries() throws {
        var labeled = original
        labeled.segments[0].speakerIDs = ["speaker-1"]
        #expect(try MeetingDiarizationFingerprint.source(labeled) ==
                MeetingDiarizationFingerprint.source(original))
        labeled.segments[0].timedRuns = [
            MeetingTimedTextRun(utf16Offset: 0, utf16Length: 2, startMs: 1_000, endMs: 1_500)
        ]
        #expect(try MeetingDiarizationFingerprint.source(labeled) !=
                MeetingDiarizationFingerprint.source(original))
    }

    @Test("failed persistence restores result, raw base and optional payload together")
    @MainActor
    func rollbackAndRetainedEvidence() throws {
        let record = MeetingRecord()
        try record.replaceTranscriptionBase(original, status: .ready)
        try record.update(audioManifest: manifest)
        let annotation = try payload()
        try record.update(diarization: annotation)
        let before = record.persistenceSnapshot()
        var replacement = original
        replacement.transcriptRevision = 3
        replacement.segments[0].text = "changed"
        #expect(throws: SaveError.failed) {
            try MeetingRecordCommitter.persist(record: record, save: { throw SaveError.failed }) {
                try record.replaceTranscriptionBase(replacement, status: .finalizingTranscript)
                try record.update(diarization: nil)
            }
        }
        #expect(record.persistenceSnapshot() == before)
        #expect(record.result == original)
        #expect(record.rawResult == original)
        #expect(record.diarization?.intervals == annotation.intervals)

        try record.replaceTranscriptionBase(replacement, status: .ready)
        #expect(record.diarization?.intervals == annotation.intervals)
        #expect(record.rawResult == replacement)
        #expect(try MeetingDiarizationFingerprint.source(replacement) != annotation.sourceContentDigest)
    }

    private enum SaveError: Error { case failed }
}
