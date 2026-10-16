import Testing
@testable import todo

@Suite("Timed speaker alignment")
struct MeetingSpeakerAlignmentTests {
    private func run(_ start: Int64, _ end: Int64) -> MeetingTimedTextRun {
        MeetingTimedTextRun(utf16Offset: 0, utf16Length: 3, startMs: start, endMs: end)
    }

    private func activity(_ id: String, _ start: Int64, _ end: Int64) -> MeetingSpeakerInterval {
        MeetingSpeakerInterval(speakerID: id, startSample: start * 16, endSample: end * 16)
    }

    @Test func provisionalSuffixStaysUnknownUntilCoverageAdvances() {
        let runs = [run(0, 700), run(900, 1300), run(1500, 2000)]
        let initial = MeetingSpeakerAlignment.assign(
            runs: runs, intervals: [activity("A", 0, 800), activity("B", 800, 1400)],
            coveredThroughSample: 1400 * 16
        )
        #expect(initial == [["A"], ["B"], []])
        let updated = MeetingSpeakerAlignment.assign(
            runs: runs,
            intervals: [activity("A", 0, 800), activity("B", 800, 1400), activity("A", 1400, 2100)],
            coveredThroughSample: 2100 * 16
        )
        #expect(updated == [["A"], ["B"], ["A"]])
    }

    @Test func simultaneousSpeechDiffersFromAdjacentSequentialTurns() {
        let simultaneous = MeetingSpeakerAlignment.assign(
            runs: [run(450, 700)],
            intervals: [activity("A", 0, 1000), activity("B", 400, 800)],
            coveredThroughSample: 1000 * 16
        )
        #expect(simultaneous == [["A", "B"]])
        let adjacent = MeetingSpeakerAlignment.assign(
            runs: [run(400, 600)],
            intervals: [activity("A", 0, 500), activity("B", 500, 1000)],
            coveredThroughSample: 1000 * 16
        )
        #expect(adjacent == [[]])
    }

    @Test func touchingEndAndUncoveredTailDoNotAssignASpeaker() {
        let labels = MeetingSpeakerAlignment.assign(
            runs: [run(100, 200), run(200, 310), run(310, 450)],
            intervals: [activity("A", 0, 200), activity("B", 200, 400)],
            coveredThroughSample: 400 * 16
        )
        #expect(labels == [["A"], ["B"], []])
    }

    @Test("sample-coordinate intervals cut at a FLAC part boundary label like one ms interval")
    func partBoundaryUsesSameSampleClock() {
        let runs = [run(600, 1_400), run(1_500, 2_400), run(900, 1_100)]
        // Part 0 owns samples [0, 16_000); part 1 continues the same speaker.
        let split = [
            MeetingSpeakerInterval(speakerID: "A", startSample: 8_000, endSample: 16_000),
            MeetingSpeakerInterval(speakerID: "A", startSample: 16_000, endSample: 24_000),
            MeetingSpeakerInterval(speakerID: "B", startSample: 24_000, endSample: 40_000)
        ]
        let whole = [activity("A", 500, 1_500), activity("B", 1_500, 2_500)]
        let fromSamples = MeetingSpeakerAlignment.assign(runs: runs, intervals: split, coveredThroughSample: 40_000)
        let fromMilliseconds = MeetingSpeakerAlignment.assign(runs: runs, intervals: whole, coveredThroughSample: 2_500 * 16)
        #expect(fromSamples == [["A"], ["B"], ["A"]])
        #expect(fromSamples == fromMilliseconds)
        // Coverage one sample short of a run end keeps that run unknown.
        let short = MeetingSpeakerAlignment.assign(runs: runs, intervals: split, coveredThroughSample: 2_400 * 16 - 1)
        #expect(short == [["A"], [], ["A"]])
    }

    @Test("turns split where speaker evidence changes at a timed-run boundary")
    func turnBoundaries() {
        let runs = [
            MeetingTimedTextRun(utf16Offset: 0, utf16Length: 2, startMs: 0, endMs: 400),
            MeetingTimedTextRun(utf16Offset: 3, utf16Length: 3, startMs: 500, endMs: 900),
            MeetingTimedTextRun(utf16Offset: 7, utf16Length: 2, startMs: 1_000, endMs: 1_400)
        ]
        let sequential = MeetingSpeakerAlignment.turns(
            textLength: 9, startMs: 0, endMs: 1_500, runs: Array(runs.prefix(2)), labels: [["A"], ["B"]]
        )
        #expect(sequential.map(\.speakerIDs) == [["A"], ["B"]])
        #expect(sequential.map(\.utf16Start) == [0, 3])
        #expect(sequential.map(\.utf16End) == [3, 9])
        #expect(sequential.map(\.startMs) == [0, 500])
        #expect(sequential.map(\.endMs) == [500, 1_500])


        let overlap = MeetingSpeakerAlignment.turns(
            textLength: 9, startMs: 0, endMs: 1_500, runs: runs, labels: [["A", "B"], ["A", "B"], ["A", "B"]]
        )
        #expect(overlap.map(\.speakerIDs) == [["A", "B"]])
    }

    @Test("uncovered or ambiguous words never inherit an adjacent speaker")
    func unknownRunsRemainUnknownTurns() {
        let runs = [
            MeetingTimedTextRun(utf16Offset: 0, utf16Length: 2, startMs: 0, endMs: 400),
            MeetingTimedTextRun(utf16Offset: 3, utf16Length: 3, startMs: 500, endMs: 900),
            MeetingTimedTextRun(utf16Offset: 7, utf16Length: 2, startMs: 1_000, endMs: 1_400)
        ]
        let labels = MeetingSpeakerAlignment.assign(
            runs: runs, intervals: [activity("A", 0, 400), activity("A", 1_000, 1_400)],
            coveredThroughSample: 1_400 * 16
        )
        let turns = MeetingSpeakerAlignment.turns(
            textLength: 9, startMs: 0, endMs: 1_500, runs: runs, labels: labels
        )
        #expect(turns.map(\.speakerIDs) == [["A"], [], ["A"]])
        #expect(turns.map(\.utf16Start) == [0, 3, 7])
        #expect(turns.map(\.utf16End) == [3, 7, 9])
        #expect(turns.map(\.startMs) == [0, 500, 1_000])
        #expect(turns.map(\.endMs) == [500, 1_000, 1_500])
    }

    @Test("untimed segment becomes mixed only for a real sequential second speaker")
    func untimedSegmentLabels() {
        let sequential = MeetingSpeakerAlignment.assignSegment(
            startMs: 0, endMs: 1_000, intervals: [activity("A", 0, 500), activity("B", 500, 1_000)],
            coveredThroughSample: 1_000 * 16
        )
        #expect(sequential.isEmpty)
        let single = MeetingSpeakerAlignment.assignSegment(
            startMs: 0, endMs: 1_000, intervals: [activity("A", 0, 1_000)], coveredThroughSample: 1_000 * 16
        )
        #expect(single == ["A"])
        let backchannel = MeetingSpeakerAlignment.assignSegment(
            startMs: 0, endMs: 1_000, intervals: [activity("A", 0, 900), activity("B", 900, 1_000)],
            coveredThroughSample: 1_000 * 16
        )
        #expect(backchannel == ["A"])
        let uncovered = MeetingSpeakerAlignment.assignSegment(
            startMs: 0, endMs: 1_000, intervals: [activity("A", 0, 1_000)], coveredThroughSample: 999 * 16
        )
        #expect(uncovered.isEmpty)
    }

    @Test("identity matcher keeps a re-detected live speaker under a new slot ID")
    func identityMatcherKeepsLiveID() {
        let reference = [activity("live-1", 0, 1_000), activity("live-2", 1_000, 2_000)]
        let mapping = MeetingSpeakerIdentityMatcher.match(
            new: [activity("slot-b", 0, 1_000), activity("slot-a", 1_000, 2_000)],
            reference: reference, referenceOrdinals: ["live-1": 1, "live-2": 2]
        )
        #expect(mapping == ["slot-b": "live-1", "slot-a": "live-2"])
    }

    @Test("identity matcher refuses agreement below 0.6 and accepts exactly 0.6")
    func identityMatcherAgreementThreshold() {
        let reference = [activity("live-1", 0, 1_000)]
        let below = MeetingSpeakerIdentityMatcher.match(
            new: [activity("final-1", 500, 1_500)], reference: reference, referenceOrdinals: ["live-1": 1]
        )
        #expect(below.isEmpty)
        let boundary = MeetingSpeakerIdentityMatcher.match(
            new: [activity("final-1", 400, 1_400)], reference: reference, referenceOrdinals: ["live-1": 1]
        )
        #expect(boundary == ["final-1": "live-1"])
    }

    @Test("identity matcher is one-to-one and keeps the larger shared activity")
    func identityMatcherIsOneToOne() {
        let mapping = MeetingSpeakerIdentityMatcher.match(
            new: [activity("final-1", 0, 600), activity("final-2", 600, 1_000)],
            reference: [activity("live-1", 0, 1_000)], referenceOrdinals: ["live-1": 1]
        )
        #expect(mapping == ["final-1": "live-1"])
        #expect(Set(mapping.values).count == mapping.count)
    }

    private func vector(_ components: [Float]) -> [Float] {
        components + Array(repeating: 0, count: 256 - components.count)
    }

    @Test("strong voice retains identity despite insufficient temporal agreement")
    func voiceMatchesWithoutTimingAgreement() {
        let mapping = MeetingSpeakerIdentityMatcher.match(
            new: [activity("final", 500, 1_500)],
            reference: [activity("live", 0, 1_000)], referenceOrdinals: ["live": 1],
            voiceEvidence: MeetingSpeakerVoiceEvidence(
                newEmbeddings: ["final": vector([12, 0])],
                referenceEmbeddings: ["live": vector([0.25, 0])]
            )
        )
        #expect(mapping == ["final": "live"])
    }

    @Test("contradictory voice blocks a temporal identity transfer and recovers the correct IDs")
    func contradictoryVoiceVetoesTiming() {
        let new = [activity("final-a", 0, 1_000), activity("final-b", 1_000, 2_000)]
        let reference = [activity("live-a", 0, 1_000), activity("live-b", 1_000, 2_000)]
        let mapping = MeetingSpeakerIdentityMatcher.match(
            new: new, reference: reference, referenceOrdinals: ["live-a": 1, "live-b": 2],
            voiceEvidence: MeetingSpeakerVoiceEvidence(
                newEmbeddings: ["final-a": vector([1, 0]), "final-b": vector([0, 1])],
                referenceEmbeddings: ["live-a": vector([0, 1]), "live-b": vector([1, 0])]
            )
        )
        #expect(mapping == ["final-a": "live-b", "final-b": "live-a"])
        let vetoOnly = MeetingSpeakerIdentityMatcher.match(
            new: [new[0]], reference: [reference[0]], referenceOrdinals: ["live-a": 1],
            voiceEvidence: MeetingSpeakerVoiceEvidence(
                newEmbeddings: ["final-a": vector([1, 0])],
                referenceEmbeddings: ["live-a": vector([0, 1])]
            )
        )
        #expect(vetoOnly.isEmpty)
    }

    @Test("strong mutual voice wins even when a wrong temporal match passes the cosine threshold")
    func strongVoicePrecedesCompatibleTiming() {
        let new = [activity("final-a", 0, 1_000), activity("final-b", 1_000, 2_000)]
        let reference = [activity("live-a", 0, 1_000), activity("live-b", 1_000, 2_000)]
        let evidence = MeetingSpeakerVoiceEvidence(
            newEmbeddings: ["final-a": vector([1, 0]), "final-b": vector([0.8, 0.6])],
            referenceEmbeddings: ["live-a": vector([0.8, 0.6]), "live-b": vector([1, 0])]
        )
        #expect(MeetingSpeakerIdentityMatcher.match(
            new: new, reference: reference, referenceOrdinals: ["live-a": 1, "live-b": 2], voiceEvidence: evidence
        ) == ["final-a": "live-b", "final-b": "live-a"])
    }

    @Test("voice needs the cosine threshold, not a large unnormalized dot product")
    func voiceCosineThreshold() {
        let new = [activity("final", 2_000, 3_000)]
        let reference = [activity("live", 0, 1_000)]
        // Norm is exactly four, giving an exact cosine of 3/4.
        let boundary = vector([3, 1, 1, 1, 1, 1, 1, 1])
        let accepted = MeetingSpeakerIdentityMatcher.match(
            new: new, reference: reference, referenceOrdinals: ["live": 1],
            voiceEvidence: MeetingSpeakerVoiceEvidence(
                newEmbeddings: ["final": vector([1])], referenceEmbeddings: ["live": boundary]
            )
        )
        #expect(accepted == ["final": "live"])
        let rejected = MeetingSpeakerIdentityMatcher.match(
            new: new, reference: reference, referenceOrdinals: ["live": 1],
            voiceEvidence: MeetingSpeakerVoiceEvidence(
                newEmbeddings: ["final": vector([100, 0])],
                referenceEmbeddings: ["live": vector([100, 100])]
            )
        )
        #expect(rejected.isEmpty)
    }

    @Test("ambiguous voice on either side does not force or collapse identities")
    func voiceRequiresMutualBestMargin() {
        let evidence = MeetingSpeakerVoiceEvidence(
            newEmbeddings: ["final-a": vector([1, 0]), "final-b": vector([1, 0])],
            referenceEmbeddings: ["live-a": vector([1, 0]), "live-b": vector([1, 0])]
        )
        let ambiguousRow = MeetingSpeakerIdentityMatcher.match(
            new: [activity("final-a", 3_000, 4_000)],
            reference: [activity("live-a", 0, 1_000), activity("live-b", 1_000, 2_000)],
            referenceOrdinals: ["live-a": 1, "live-b": 2], voiceEvidence: evidence
        )
        #expect(ambiguousRow.isEmpty)
        let ambiguousColumn = MeetingSpeakerIdentityMatcher.match(
            new: [activity("final-a", 3_000, 4_000), activity("final-b", 4_000, 5_000)],
            reference: [activity("live-a", 0, 1_000)],
            referenceOrdinals: ["live-a": 1], voiceEvidence: evidence
        )
        #expect(ambiguousColumn.isEmpty)
        let narrowMargin = MeetingSpeakerIdentityMatcher.match(
            new: [activity("final-a", 3_000, 4_000)],
            reference: [activity("live-a", 0, 1_000), activity("live-b", 1_000, 2_000)],
            referenceOrdinals: ["live-a": 1, "live-b": 2],
            voiceEvidence: MeetingSpeakerVoiceEvidence(
                newEmbeddings: ["final-a": vector([1, 0])],
                referenceEmbeddings: ["live-a": vector([4, 3]), "live-b": vector([3, 1, 1, 1, 1, 1, 1, 1])]
            )
        )
        #expect(narrowMargin.isEmpty)
    }

    @Test("consuming a temporal best does not promote an ambiguous voice runner-up")
    func voiceMarginsIncludeAlreadyMatchedIDs() {
        let mapping = MeetingSpeakerIdentityMatcher.match(
            new: [activity("final-a", 0, 1_000), activity("final-b", 3_000, 4_000)],
            reference: [activity("live-a", 0, 1_000), activity("live-b", 1_000, 2_000)],
            referenceOrdinals: ["live-a": 1, "live-b": 2],
            voiceEvidence: MeetingSpeakerVoiceEvidence(
                newEmbeddings: ["final-a": vector([1, 0]), "final-b": vector([1, 0])],
                referenceEmbeddings: ["live-a": vector([1, 0]), "live-b": vector([1, 0])]
            )
        )
        #expect(mapping == ["final-a": "live-a"])
    }

    @Test("timing ties retain reference ordinal order even with compatible ambiguous voice")
    func timingTieStaysDeterministicWithVoice() {
        let reference = [activity("live-a", 0, 500), activity("live-z", 500, 1_000)]
        let evidence = MeetingSpeakerVoiceEvidence(
            newEmbeddings: ["final": vector([1])],
            referenceEmbeddings: ["live-a": vector([1]), "live-z": vector([1])]
        )
        for intervals in [reference, Array(reference.reversed())] {
            let mapping = MeetingSpeakerIdentityMatcher.match(
                new: [activity("final", 0, 1_000)], reference: intervals,
                referenceOrdinals: ["live-a": 2, "live-z": 1], voiceEvidence: evidence
            )
            #expect(mapping == ["final": "live-z"])
        }
    }

    @Test("independent voice bests remain one-to-one and independent of interval input order")
    func voiceAssignmentIsOneToOneAndStable() {
        let new = [activity("final-a", 3_000, 4_000), activity("final-b", 4_000, 5_000)]
        let reference = [activity("live-a", 0, 1_000), activity("live-b", 1_000, 2_000)]
        let evidence = MeetingSpeakerVoiceEvidence(
            newEmbeddings: ["final-a": vector([1, 0]), "final-b": vector([0, 1])],
            referenceEmbeddings: ["live-a": vector([0, 1]), "live-b": vector([1, 0])]
        )
        for reversed in [false, true] {
            let mapping = MeetingSpeakerIdentityMatcher.match(
                new: reversed ? Array(new.reversed()) : new,
                reference: reversed ? Array(reference.reversed()) : reference,
                referenceOrdinals: ["live-a": 1, "live-b": 2], voiceEvidence: evidence
            )
            #expect(mapping == ["final-a": "live-b", "final-b": "live-a"])
            #expect(Set(mapping.values).count == mapping.count)
        }
    }

    @Test("missing, malformed, zero and nonfinite voice retain timing-only behavior")
    func unusableVoiceKeepsTiming() {
        let invalid: [[Float]] = [
            [], Array(repeating: 1, count: 255), Array(repeating: 1, count: 257),
            Array(repeating: 0, count: 256), vector([.nan]), vector([.infinity])
        ]
        var evidence = [MeetingSpeakerVoiceEvidence(newEmbeddings: [:], referenceEmbeddings: [:])]
        for value in invalid {
            evidence.append(MeetingSpeakerVoiceEvidence(
                newEmbeddings: ["final": value], referenceEmbeddings: ["live": vector([1])]
            ))
            evidence.append(MeetingSpeakerVoiceEvidence(
                newEmbeddings: ["final": vector([1])], referenceEmbeddings: ["live": value]
            ))
        }
        evidence.append(MeetingSpeakerVoiceEvidence(newEmbeddings: ["final": vector([1])], referenceEmbeddings: [:]))
        evidence.append(MeetingSpeakerVoiceEvidence(newEmbeddings: [:], referenceEmbeddings: ["live": vector([1])]))
        for value in evidence {
            let temporal = MeetingSpeakerIdentityMatcher.match(
                new: [activity("final", 0, 1_000)], reference: [activity("live", 0, 1_000)],
                referenceOrdinals: ["live": 1], voiceEvidence: value
            )
            #expect(temporal == ["final": "live"])
            let withoutTiming = MeetingSpeakerIdentityMatcher.match(
                new: [activity("final", 2_000, 3_000)], reference: [activity("live", 0, 1_000)],
                referenceOrdinals: ["live": 1], voiceEvidence: value
            )
            #expect(withoutTiming.isEmpty)
        }
    }

    @Test("finite nonzero vectors remain valid at extreme Float scales")
    func voiceNormalizationHandlesExtremeScales() {
        let mapping = MeetingSpeakerIdentityMatcher.match(
            new: [activity("final", 2_000, 3_000)], reference: [activity("live", 0, 1_000)],
            referenceOrdinals: ["live": 1],
            voiceEvidence: MeetingSpeakerVoiceEvidence(
                newEmbeddings: ["final": vector([.greatestFiniteMagnitude])],
                referenceEmbeddings: ["live": vector([.leastNonzeroMagnitude])]
            )
        )
        #expect(mapping == ["final": "live"])
    }

    @Test("a speaker without eligible voice keeps timing even when another has valid evidence")
    func partialVoiceEvidenceKeepsOtherTemporalMatches() {
        let mapping = MeetingSpeakerIdentityMatcher.match(
            new: [activity("final-a", 0, 1_000), activity("final-b", 1_000, 2_000)],
            reference: [activity("live-a", 0, 1_000), activity("live-b", 1_000, 2_000)],
            referenceOrdinals: ["live-a": 1, "live-b": 2],
            voiceEvidence: MeetingSpeakerVoiceEvidence(
                newEmbeddings: ["final-a": vector([1, 0]), "final-b": Array(repeating: 0, count: 256)],
                referenceEmbeddings: ["live-a": vector([1, 0]), "live-b": vector([0, 1])]
            )
        )
        #expect(mapping == ["final-a": "live-a", "final-b": "live-b"])
    }
}
