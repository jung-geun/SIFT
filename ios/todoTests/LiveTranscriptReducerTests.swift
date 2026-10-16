import Testing
@testable import todo

@Suite("Live transcript range reducer")
struct LiveTranscriptReducerTests {
    @Test("orders adjacent ranges and replaces progressive overlap")
    func replacesOverlapWithoutDroppingAdjacentSpeech() {
        var reducer = LiveTranscriptReducer()
        reducer.replace(LiveTranscriptEntry(id: "early", startMs: 0, endMs: 1_000, text: "첫 문장"))
        reducer.replace(LiveTranscriptEntry(id: "late", startMs: 2_000, endMs: 3_000, text: "마지막 문장"))
        reducer.replace(LiveTranscriptEntry(id: "expanded", startMs: 800, endMs: 2_000, text: "확장된 임시 문장"))

        #expect(reducer.entries.map(\.id) == ["expanded", "late"])
        #expect(reducer.entries.map(\.text) == ["확장된 임시 문장", "마지막 문장"])
    }

    @Test("persists multiple timestamped entries rather than one whole meeting")
    func keepsIndependentTimeRanges() {
        var reducer = LiveTranscriptReducer()
        reducer.replace(LiveTranscriptEntry(id: "a", startMs: 1_000, endMs: 1_500, text: "A"))
        reducer.replace(LiveTranscriptEntry(id: "b", startMs: 1_500, endMs: 2_000, text: "B"))

        #expect(reducer.entries.count == 2)
        #expect(reducer.entries[0].startMs == 1_000)
        #expect(reducer.entries[1].endMs == 2_000)
    }

    @Test("final segments cannot be overwritten by a late volatile overlap")
    func preservesFinalSegmentAgainstVolatileUpdate() {
        var reducer = LiveTranscriptReducer()
        reducer.replace(
            LiveTranscriptEntry(
                id: "final",
                startMs: 0,
                endMs: 1_000,
                text: "확정 문장",
                isFinal: true
            )
        )
        reducer.replace(
            LiveTranscriptEntry(
                id: "volatile",
                startMs: 100,
                endMs: 900,
                text: "늦은 임시 문장"
            )
        )

        #expect(reducer.entries.map(\.id) == ["final"])
        #expect(reducer.entries[0].text == "확정 문장")
    }

    @Test("blank hypotheses never become visible auto-follow targets")
    func ignoresBlankHypotheses() {
        var reducer = LiveTranscriptReducer()
        reducer.replace(
            LiveTranscriptEntry(
                id: "visible",
                startMs: 0,
                endMs: 1_000,
                text: "보이는 문장"
            )
        )
        reducer.replace(
            LiveTranscriptEntry(
                id: "blank",
                startMs: 1_000,
                endMs: 12_000,
                text: " \n "
            )
        )

        #expect(reducer.entries.map(\.id) == ["visible"])
    }
}
