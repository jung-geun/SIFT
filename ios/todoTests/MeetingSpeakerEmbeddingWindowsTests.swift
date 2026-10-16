import Testing
@testable import todo

@Suite("Clean speaker embedding windows")
struct MeetingSpeakerEmbeddingWindowsTests {
    private func activity(_ id: String, _ start: Int64, _ end: Int64) -> MeetingSpeakerInterval {
        MeetingSpeakerInterval(speakerID: id, startSample: start, endSample: end)
    }

    private func window(_ id: String, _ start: Int64, _ end: Int64) -> MeetingSpeakerEmbeddingWindows.Window {
        MeetingSpeakerEmbeddingWindows.Window(speakerID: id, startSample: start, endSample: end)
    }

    @Test("mixed speaker activity is removed, including transition margins")
    func mixedSpeechIsNeverEnrolled() {
        let windows = MeetingSpeakerEmbeddingWindows.select(
            intervals: [activity("A", 0, 160_000), activity("B", 48_000, 112_000)],
            totalSamples: 160_000
        )
        #expect(windows == [window("A", 1_600, 46_400), window("A", 113_600, 158_400)])
        #expect(windows.allSatisfy { $0.endSample <= 46_400 || $0.startSample >= 113_600 })
    }

    @Test("minimum clean duration is required after both 100 ms margins")
    func shortSpeechIsExcludedAfterTrimming() {
        let tooShort = MeetingSpeakerEmbeddingWindows.select(
            intervals: [activity("A", 0, 35_199)], totalSamples: 35_199
        )
        #expect(tooShort.isEmpty)
        let boundary = MeetingSpeakerEmbeddingWindows.select(
            intervals: [activity("A", 0, 35_200)], totalSamples: 35_200
        )
        #expect(boundary == [window("A", 1_600, 33_600)])
    }

    @Test("separate short runs cannot be concatenated even across a one-sample gap")
    func silenceGapsDoNotCreateEnrollment() {
        let windows = MeetingSpeakerEmbeddingWindows.select(
            intervals: [activity("A", 0, 24_000), activity("A", 24_001, 48_001)],
            totalSamples: 48_001
        )
        #expect(windows.isEmpty)
    }

    @Test("same-speaker touching and overlapping runs form one clean region")
    func sameSpeakerOverlapAndTouchingAreAllowed() {
        let intervals = [activity("A", 0, 24_000), activity("A", 16_000, 48_000), activity("A", 48_000, 64_000)]
        let windows = MeetingSpeakerEmbeddingWindows.select(intervals: intervals, totalSamples: 64_000)
        #expect(windows == [window("A", 1_600, 49_600)])
        #expect(MeetingSpeakerEmbeddingWindows.select(intervals: Array(intervals.reversed()), totalSamples: 64_000) == windows)
    }

    @Test("out-of-recording and invalid intervals cannot produce invalid sample bounds")
    func selectionClampsToRecordingBounds() {
        let intervals = [
            activity("A", .min, .max), activity("B", -64_000, -1),
            activity("B", 64_000, .max), activity("B", 20_000, 10_000), activity("B", 32_000, 32_000)
        ]
        let windows = MeetingSpeakerEmbeddingWindows.select(intervals: intervals, totalSamples: 64_000)
        #expect(windows == [window("A", 1_600, 49_600)])
        #expect(windows.allSatisfy {
            $0.startSample >= 0 && $0.endSample <= 64_000 && $0.endSample - $0.startSample >= 32_000
        })
        #expect(MeetingSpeakerEmbeddingWindows.select(intervals: intervals, totalSamples: 0).isEmpty)
        #expect(MeetingSpeakerEmbeddingWindows.select(intervals: intervals, totalSamples: -1).isEmpty)
    }

    @Test("long speech samples the whole recording with bounded non-overlapping clean clips")
    func longSpeechIsDistributedWithoutExpandingAllWindows() throws {
        let windows = MeetingSpeakerEmbeddingWindows.select(
            intervals: [activity("A", 0, .max)], totalSamples: .max
        )
        #expect(windows.count == MeetingSpeakerEmbeddingWindows.maximumWindowsPerSpeaker)
        let first = try #require(windows.first)
        let last = try #require(windows.last)
        #expect(first.startSample == 1_600)
        #expect(last.endSample > Int64.max - MeetingSpeakerEmbeddingWindows.targetSamples - 3_200)
        #expect(last.endSample <= Int64.max - 1_600)
        #expect(windows.allSatisfy {
            (MeetingSpeakerEmbeddingWindows.minimumSamples...MeetingSpeakerEmbeddingWindows.targetSamples)
                .contains($0.endSample - $0.startSample)
        })
        #expect(zip(windows, windows.dropFirst()).allSatisfy { $0.endSample <= $1.startSample })
    }

    @Test("clean clips include later turns while per-ID limits and chronological order stay stable")
    func windowOrderAndPerSpeakerCapAreStable() {
        let intervals = [
            activity("A", 0, 64_000), activity("B", 80_000, 144_000),
            activity("A", 160_000, 224_000), activity("B", 240_000, 304_000),
            activity("A", 320_000, 384_000), activity("B", 400_000, 464_000),
            activity("A", 480_000, 544_000), activity("B", 560_000, 624_000)
        ]
        let windows = MeetingSpeakerEmbeddingWindows.select(intervals: intervals, totalSamples: 624_000)
        for id in ["A", "B"] {
            let selected = windows.filter { $0.speakerID == id }
            #expect(selected.count <= MeetingSpeakerEmbeddingWindows.maximumWindowsPerSpeaker)
            let earliest: Int64 = id == "A" ? 0 : 80_000
            let latest: Int64 = id == "A" ? 480_000 : 560_000
            #expect(selected.contains { $0.startSample >= earliest && $0.endSample <= earliest + 64_000 })
            #expect(selected.contains { $0.startSample >= latest && $0.endSample <= latest + 64_000 })
        }
        #expect(windows.map(\.startSample) == windows.map(\.startSample).sorted())
        #expect(MeetingSpeakerEmbeddingWindows.select(intervals: Array(intervals.reversed()), totalSamples: 624_000) == windows)
    }

    @Test("at most eight IDs get windows, but excluded IDs still block mixed speech")
    func speakerCapDoesNotIgnoreOtherSpeakerActivity() {
        var intervals = [activity("S0", 0, 128_000), activity("S8", 48_000, 80_000)]
        for index in 1...8 {
            let start = Int64(index) * 160_000
            intervals.append(activity("S\(index)", start, start + 64_000))
        }
        let windows = MeetingSpeakerEmbeddingWindows.select(intervals: intervals, totalSamples: 1_344_000)
        #expect(Set(windows.map(\.speakerID)) == Set((0..<8).map { "S\($0)" }))
        #expect(windows.filter { $0.speakerID == "S0" } == [window("S0", 1_600, 46_400), window("S0", 81_600, 126_400)])
        #expect(windows.count == 9)
        #expect(MeetingSpeakerEmbeddingWindows.select(intervals: Array(intervals.reversed()), totalSamples: 1_344_000) == windows)
    }
}
