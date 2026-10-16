import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Meeting diarization label application and commit")
@MainActor
struct MeetingDiarizationCommitTests {
    private let meetingID = "123e4567-e89b-12d3-a456-426614174000"
    private let manifest = MeetingAudioManifest(
        relativeDirectory: "diarization-commit", sampleRate: 16_000, totalSamples: 48_000, parts: []
    )

    private func activity(_ id: String, _ startMs: Int64, _ endMs: Int64) -> MeetingSpeakerInterval {
        MeetingSpeakerInterval(speakerID: id, startSample: startMs * 16, endSample: endMs * 16)
    }

    /// "안녕 하세요 반갑습니다": runs over "안녕", "하세요", "반갑습니다".
    private func timedSegment(id: String = "seg", speakerIDs: [String] = []) -> MeetingSegment {
        MeetingSegment(
            id: id, startMs: 0, endMs: 1_600, speakerIDs: speakerIDs, text: "안녕 하세요 반갑습니다",
            timedRuns: [
                MeetingTimedTextRun(utf16Offset: 0, utf16Length: 2, startMs: 0, endMs: 400),
                MeetingTimedTextRun(utf16Offset: 3, utf16Length: 3, startMs: 400, endMs: 900),
                MeetingTimedTextRun(utf16Offset: 7, utf16Length: 5, startMs: 1_000, endMs: 1_600)
            ]
        )
    }

    private func result(_ segments: [MeetingSegment], revision: Int = 3) -> MeetingResult {
        MeetingResult(
            transcriptRevision: revision, title: "회의", summary: "요약", decisions: ["결정"],
            segments: segments,
            actionDrafts: [MeetingActionDraft(id: "draft-1", title: "확인", sourceSegmentIDs: [segments[0].id])]
        )
    }

    private let sequentialAB: [MeetingSpeakerInterval] = [
        MeetingSpeakerInterval(speakerID: "A", startSample: 0, endSample: 950 * 16),
        MeetingSpeakerInterval(speakerID: "B", startSample: 950 * 16, endSample: 1_700 * 16)
    ]

    private func record(
        _ source: MeetingResult,
        intervals: [MeetingSpeakerInterval] = [],
        profiles: [MeetingSpeakerProfile] = [],
        manual: [String: [String]] = [:]
    ) throws -> (MeetingRecord, MeetingDiarizationPayload) {
        let record = MeetingRecord(meetingID: meetingID)
        try record.replaceTranscriptionBase(source, status: .ready)
        try record.update(audioManifest: manifest)
        let payload = MeetingDiarizationPayload(
            status: .finalizing, generation: UUID(),
            manifestDigest: try MeetingDiarizationFingerprint.manifest(manifest),
            sourceTranscriptRevision: source.transcriptRevision,
            sourceContentDigest: try MeetingDiarizationFingerprint.source(source),
            modelRevision: "", preset: "", coveredThroughSample: 0,
            intervals: intervals, profiles: profiles, manualAssignments: manual, failureCode: nil
        )
        try record.update(diarization: payload)
        return (record, payload)
    }

    private func commit(
        _ record: MeetingRecord,
        _ payload: MeetingDiarizationPayload,
        source: MeetingResult,
        evidence: [MeetingSpeakerInterval],
        coverage: Int64 = 48_000,
        generation: UUID? = nil,
        liveTimeline: MeetingLiveSpeakerTimeline? = nil,
        voiceEvidence: MeetingSpeakerVoiceEvidence? = nil,
        save: () throws -> Void = {}
    ) throws -> MeetingDiarizationCommitter.Outcome {
        try MeetingDiarizationCommitter.commit(
            record: record, generation: generation ?? payload.generation,
            manifestDigest: try MeetingDiarizationFingerprint.manifest(manifest),
            sourceDigest: try MeetingDiarizationFingerprint.source(source),
            evidence: MeetingDiarizationReplay.Evidence(intervals: evidence, coveredThroughSample: coverage, voiceEvidence: voiceEvidence),
            liveTimeline: liveTimeline, save: save
        )
    }

    // MARK: - Applier

    @Test("A, A, B runs split once into two valid children with distinct lineages")
    func splitAtSpeakerChange() throws {
        let original = result([timedSegment()])
        let application = try MeetingSpeakerLabelApplier.apply(
            meetingID: meetingID, current: original, raw: original,
            intervals: sequentialAB, coveredThroughSample: 1_700 * 16, manualAssignments: [:]
        )
        let segments = application.result.segments
        #expect(application.didSplit)
        #expect(application.result.transcriptRevision == original.transcriptRevision + 1)
        #expect(application.result.summary.isEmpty)
        #expect(application.result.actionDrafts.isEmpty)
        #expect(segments.map(\.text) == ["안녕 하세요", "반갑습니다"])
        #expect(segments.map(\.speakerIDs) == [["A"], ["B"]])
        #expect(segments.map(\.startMs) == [0, 1_000])
        #expect(segments.map(\.endMs) == [1_000, 1_600])
        #expect(Set(segments.map(\.stableLineageID)).count == 2)
        #expect(!segments.map(\.stableLineageID).contains("seg"))
        #expect(segments.allSatisfy { $0.isValid })
        #expect(segments[0].timedRuns == [
            MeetingTimedTextRun(utf16Offset: 0, utf16Length: 2, startMs: 0, endMs: 400),
            MeetingTimedTextRun(utf16Offset: 3, utf16Length: 3, startMs: 400, endMs: 900)
        ])
        #expect(segments[1].timedRuns == [
            MeetingTimedTextRun(utf16Offset: 0, utf16Length: 5, startMs: 1_000, endMs: 1_600)
        ])
        _ = try application.result.validated()
        #expect(application.raw == application.result)

        // Re-applying the same evidence is idempotent: no second revision bump.
        let again = try MeetingSpeakerLabelApplier.apply(
            meetingID: meetingID, current: application.result, raw: application.raw,
            intervals: sequentialAB, coveredThroughSample: 1_700 * 16, manualAssignments: [:]
        )
        #expect(!again.didSplit)
        #expect(again.result == application.result)
    }

    @Test("unknown timed words stay separate through commit and a repeated pass")
    func commitPreservesUnknownWordsAndRawText() throws {
        let source = result([timedSegment()])
        let named = MeetingSpeakerProfile(id: "person", ordinal: 1, displayName: "민수")
        let intervals = [activity("person", 0, 400), activity("person", 1_000, 1_600)]
        let (record, payload) = try record(source, intervals: intervals, profiles: [named])
        #expect(try commit(record, payload, source: source,
                           evidence: [activity("detected", 0, 400), activity("detected", 1_000, 1_600)])
            == .committed(didSplit: true))
        let committed = try #require(record.result)
        #expect(committed.segments.map(\.text) == ["안녕", "하세요", "반갑습니다"])
        #expect(committed.segments.map(\.speakerIDs) == [["person"], [], ["person"]])
        #expect(committed.segments.allSatisfy { $0.isValid })
        #expect(record.rawResult?.segments == committed.segments)
        #expect(record.diarization?.intervals == intervals)
        #expect(record.diarization?.profiles == [named])
        let stored = try #require(record.diarization)
        #expect(try commit(record, stored, source: committed,
                           evidence: [activity("detected", 0, 400), activity("detected", 1_000, 1_600)])
            == .committed(didSplit: false))
        #expect(record.result == committed)
    }

    @Test("manual assignment wins over detected speakers and prevents a split")
    func manualAssignmentWins() throws {
        let original = result([timedSegment()])
        let application = try MeetingSpeakerLabelApplier.apply(
            meetingID: meetingID, current: original, raw: nil,
            intervals: sequentialAB, coveredThroughSample: 1_700 * 16, manualAssignments: ["seg": ["M"]]
        )
        #expect(!application.didSplit)
        #expect(application.result.segments.map(\.speakerIDs) == [["M"]])
        #expect(application.result.transcriptRevision == original.transcriptRevision)
        #expect(application.result.segments.map(\.id) == ["seg"])
        #expect(application.result.actionDrafts == original.actionDrafts)
    }

    @Test("untimed segment is labeled without split; its raw lineage gets the same label")
    func untimedSegmentLabelOnly() throws {
        let current = result([MeetingSegment(id: "seg", startMs: 0, endMs: 1_600, text: "교정된 문장")])
        let raw = result([MeetingSegment(id: "seg", startMs: 0, endMs: 1_600, text: "원본 문장")], revision: 2)
        let single = try MeetingSpeakerLabelApplier.apply(
            meetingID: meetingID, current: current, raw: raw,
            intervals: [activity("A", 0, 1_600)], coveredThroughSample: 1_600 * 16, manualAssignments: [:]
        )
        #expect(!single.didSplit)
        #expect(single.result.segments.map(\.speakerIDs) == [["A"]])
        #expect(single.result.segments.map(\.text) == ["교정된 문장"])
        #expect(single.result.transcriptRevision == 3)
        #expect(single.raw?.segments.map(\.speakerIDs) == [["A"]])
        #expect(single.raw?.segments.map(\.text) == ["원본 문장"])

        let mixed = try MeetingSpeakerLabelApplier.apply(
            meetingID: meetingID, current: current, raw: raw,
            intervals: sequentialAB, coveredThroughSample: 1_700 * 16, manualAssignments: [:]
        )
        #expect(!mixed.didSplit)
        #expect(mixed.result.segments.map(\.speakerIDs) == [[]])
        #expect(mixed.result.segments.map(\.id) == ["seg"])
    }

    // MARK: - Commit fence

    @Test("commit is superseded by a text edit or a new generation")
    func staleCommitRejected() throws {
        let source = result([timedSegment()])
        let (edited, editedPayload) = try record(source)
        var changed = source
        changed.segments[0].text = "안녕 하세요 반갑습니다!"
        try edited.update(result: changed, status: .ready)
        let before = edited.persistenceSnapshot()
        #expect(try commit(edited, editedPayload, source: source, evidence: sequentialAB) == .superseded)
        #expect(edited.persistenceSnapshot() == before)

        let (regenerated, payload) = try record(source)
        let snapshot = regenerated.persistenceSnapshot()
        #expect(try commit(regenerated, payload, source: source, evidence: sequentialAB, generation: UUID()) == .superseded)
        #expect(regenerated.persistenceSnapshot() == snapshot)
    }

    @Test("commit succeeds when only speaker labels differ from the replayed source")
    func labelOnlyDifferenceCommits() throws {
        let source = result([timedSegment()])
        let (record, payload) = try record(source)
        var relabeled = source
        relabeled.segments[0].speakerIDs = ["live-guess"]
        try record.update(result: relabeled, status: .ready)

        let outcome = try commit(record, payload, source: source, evidence: sequentialAB)
        #expect(outcome == .committed(didSplit: true))
        let committed = try #require(record.result)
        let stored = try #require(record.diarization)
        #expect(committed.segments.count == 2)
        #expect(!committed.segments.flatMap(\.speakerIDs).contains("live-guess"))
        #expect(stored.status == .completed)
        #expect(stored.sourceTranscriptRevision == committed.transcriptRevision)
        #expect(stored.sourceContentDigest == (try MeetingDiarizationFingerprint.source(committed)))
        #expect(Set(stored.intervals.map(\.speakerID)) == Set(committed.segments.flatMap(\.speakerIDs)))
        #expect(stored.profiles.map(\.ordinal) == [1, 2])
        // The raw base keeps its own revision but receives the same split and labels.
        let raw = try #require(record.rawResult)
        #expect(raw.transcriptRevision == source.transcriptRevision)
        #expect(raw.segments.map(\.stableLineageID) == committed.segments.map(\.stableLineageID))
        #expect(raw.segments.map(\.text) == committed.segments.map(\.text))
        #expect(raw.segments.map(\.speakerIDs) == committed.segments.map(\.speakerIDs))
    }

    @Test("save failure rolls back result, raw base and payload")
    func saveFailureRollsBack() throws {
        let source = result([timedSegment()])
        let (record, payload) = try record(source)
        let snapshot = record.persistenceSnapshot()
        #expect(throws: CommitTestError.saveFailed) {
            try commit(record, payload, source: source, evidence: sequentialAB, save: { throw CommitTestError.saveFailed })
        }
        #expect(record.persistenceSnapshot() == snapshot)
        #expect(record.result == source)
        #expect(record.rawResult == source)
        #expect(record.diarization?.status == .finalizing)
        #expect(record.diarization?.intervals.isEmpty == true)
    }

    @Test("final pass keeps live speaker IDs and numbers when it re-detects them")
    func liveIdentityCarriedIntoCommit() throws {
        let source = result([timedSegment()])
        let (record, payload) = try record(source)
        let session = UUID()
        var live = MeetingLiveSpeakerTimeline(sessionID: session)
        _ = live.apply(MeetingDiarizationUpdate(
            sessionID: session,
            closedIntervals: [activity("live-1", 0, 950), activity("live-2", 950, 1_700)],
            openIntervals: [], coveredThroughSample: 1_700 * 16
        ))
        let outcome = try commit(
            record, payload, source: source,
            evidence: [activity("slot-7", 0, 950), activity("slot-3", 950, 1_700)], liveTimeline: live
        )
        #expect(outcome == .committed(didSplit: true))
        #expect(record.result?.segments.map(\.speakerIDs) == [["live-1"], ["live-2"]])
        let profiles = try #require(record.diarization?.profiles)
        #expect(profiles.map(\.id) == ["live-1", "live-2"])
        #expect(profiles.map(\.ordinal) == [1, 2])
    }

    // MARK: - Profile assembly

    @Test("matched live identities keep their ID and ordinal through assemble")
    func assemblePreservesMatchedLiveIdentity() {
        let assembly = MeetingSpeakerProfileBook.assemble(
            detected: [activity("slot-b", 0, 1_000), activity("slot-a", 1_000, 2_000)],
            reference: [activity("live-2", 0, 1_000), activity("live-1", 1_000, 2_000)],
            referenceProfiles: [
                MeetingSpeakerProfile(id: "live-1", ordinal: 1, displayName: nil),
                MeetingSpeakerProfile(id: "live-2", ordinal: 2, displayName: nil)
            ],
            existingProfiles: [], manualAssignments: [:]
        )
        #expect(assembly.intervals == [activity("live-2", 0, 1_000), activity("live-1", 1_000, 2_000)])
        #expect(assembly.profiles == [
            MeetingSpeakerProfile(id: "live-1", ordinal: 1, displayName: nil),
            MeetingSpeakerProfile(id: "live-2", ordinal: 2, displayName: nil)
        ])
    }

    @Test("unmatched speakers take vacant ordinals and never create a ninth profile")
    func assembleNeverExceedsEightSpeakers() {
        let manualProfiles = (1...7).map { MeetingSpeakerProfile(id: "manual-\($0)", ordinal: $0, displayName: "사람 \($0)") }
        let manual = Dictionary(uniqueKeysWithValues: (1...7).map { ("lineage-\($0)", ["manual-\($0)"]) })
        let assembly = MeetingSpeakerProfileBook.assemble(
            detected: [activity("u1", 0, 1_000), activity("u2", 1_000, 2_000)],
            reference: [], referenceProfiles: [],
            existingProfiles: manualProfiles, manualAssignments: manual
        )
        #expect(assembly.profiles.count == 8)
        #expect(assembly.profiles.map(\.ordinal) == Array(1...8))
        let fresh = assembly.profiles.first { $0.ordinal == 8 }
        #expect(fresh?.displayName == nil)
        #expect(fresh.map { UUID(uuidString: $0.id) != nil } == true)
        // The second unmatched speaker stays unknown instead of becoming speaker 9.
        #expect(assembly.intervals == [
            MeetingSpeakerInterval(speakerID: fresh?.id ?? "", startSample: 0, endSample: 16_000)
        ])
    }

    @Test("a named profile without matching activity is kept but not reassigned")
    func namedUnmatchedProfileKept() {
        let named = MeetingSpeakerProfile(id: "named", ordinal: 1, displayName: "민수")
        let assembly = MeetingSpeakerProfileBook.assemble(
            detected: [activity("slot-1", 2_000, 3_000)],
            reference: [activity("named", 0, 1_000)], referenceProfiles: [named],
            existingProfiles: [named], manualAssignments: [:]
        )
        #expect(assembly.profiles.contains(named))
        #expect(assembly.intervals.count == 1)
        let newID = assembly.intervals[0].speakerID
        #expect(newID != "named")
        #expect(assembly.profiles.first { $0.id == newID }?.displayName == nil)
    }

    @Test("voice recovery preserves a named identity without overriding manual transcript assignments")
    func voiceRecoveryPreservesNameAndManualAssignment() throws {
        let source = result([
            MeetingSegment(id: "automatic", startMs: 0, endMs: 950, speakerIDs: [], text: "자동 화자"),
            MeetingSegment(id: "manual", startMs: 1_000, endMs: 1_600, speakerIDs: ["manual-person"], text: "수동 배정")
        ])
        let named = MeetingSpeakerProfile(id: "prior", ordinal: 1, displayName: "민수")
        let manualPerson = MeetingSpeakerProfile(id: "manual-person", ordinal: 2, displayName: "수진")
        let manual = ["manual": ["manual-person"]]
        let (record, payload) = try record(
            source, intervals: [activity("prior", 2_000, 3_000)], profiles: [named, manualPerson], manual: manual
        )
        var voice = [Float](repeating: 0, count: 256)
        voice[0] = 1
        let outcome = try commit(
            record, payload, source: source, evidence: [activity("detected", 0, 1_600)],
            voiceEvidence: MeetingSpeakerVoiceEvidence(newEmbeddings: ["detected": voice], referenceEmbeddings: ["prior": voice])
        )
        #expect(outcome == .committed(didSplit: false))
        #expect(record.result?.segments.map(\.speakerIDs) == [["prior"], ["manual-person"]])
        #expect(record.diarization?.profiles == [named, manualPerson])
        #expect(record.diarization?.manualAssignments == manual)
        #expect(record.diarization?.intervals == [activity("prior", 0, 1_600)])
    }

    @Test("contradictory voice does not transfer a person's name despite exact temporal agreement")
    func contradictoryVoiceKeepsNameOnPriorIdentity() throws {
        let source = result([timedSegment()])
        let named = MeetingSpeakerProfile(id: "prior", ordinal: 1, displayName: "민수")
        let (record, payload) = try record(source, intervals: [activity("prior", 0, 1_600)], profiles: [named])
        var newVoice = [Float](repeating: 0, count: 256)
        var oldVoice = newVoice
        newVoice[0] = 1
        oldVoice[1] = 1
        _ = try commit(
            record, payload, source: source, evidence: [activity("detected", 0, 1_600)],
            voiceEvidence: MeetingSpeakerVoiceEvidence(newEmbeddings: ["detected": newVoice], referenceEmbeddings: ["prior": oldVoice])
        )
        let labels = try #require(record.result?.segments.first?.speakerIDs)
        let freshID = try #require(labels.first)
        #expect(labels == [freshID])
        #expect(freshID != "prior")
        #expect(record.diarization?.profiles.contains(named) == true)
        #expect(record.diarization?.profiles.first(where: { $0.id == freshID })?.displayName == nil)
    }

    // MARK: - Re-transcription

    @Test("retranscribed base is re-aligned and stale manual lineages are pruned")
    func retranscribedBaseRealigned() throws {
        let old = result([MeetingSegment(id: "old-1", startMs: 0, endMs: 1_600, speakerIDs: ["prior"], text: "예전 전사")])
        let prior = MeetingSpeakerProfile(id: "prior", ordinal: 1, displayName: "민수")
        let (record, payload) = try record(
            old, intervals: [activity("prior", 0, 950)], profiles: [prior], manual: ["old-1": ["prior"]]
        )
        let retranscribed = result([timedSegment(id: "new-1")], revision: 4)
        try record.replaceTranscriptionBase(retranscribed, status: .ready)

        let outcome = try commit(
            record, payload, source: retranscribed,
            evidence: [activity("slot-1", 0, 950), activity("slot-2", 950, 1_700)]
        )
        #expect(outcome == .committed(didSplit: true))
        let segments = try #require(record.result?.segments)
        #expect(segments.map(\.text) == ["안녕 하세요", "반갑습니다"])
        #expect(segments[0].speakerIDs == ["prior"])
        #expect(segments[1].speakerIDs.count == 1)
        #expect(segments[1].speakerIDs != ["prior"])
        let stored = try #require(record.diarization)
        #expect(stored.manualAssignments.isEmpty)
        #expect(stored.profiles.first { $0.id == "prior" }?.displayName == "민수")
    }

    private enum CommitTestError: Error { case saveFailed }
}

@Suite("Meeting diarization pending passes", .timeLimit(.minutes(1)))
@MainActor
struct MeetingDiarizationPendingTests {
    private func fixture(seeded: Bool = true) throws -> (ModelContext, MeetingRecord) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: config)
        let context = ModelContext(container)
        let record = MeetingRecord(meetingID: UUID().uuidString.lowercased())
        let source = MeetingResult(transcriptRevision: 1, title: "Meeting", summary: "Summary",
                                   decisions: [], segments: [MeetingSegment(
                                    id: "segment", startMs: 0, endMs: 1_000, speakerIDs: ["speaker"], text: "Hello"
                                   )], actionDrafts: [])
        let manifest = MeetingAudioManifest(relativeDirectory: record.meetingID, sampleRate: 16_000,
                                            totalSamples: 16_000, parts: [])
        try record.replaceTranscriptionBase(source, status: .ready)
        try record.update(audioManifest: manifest)
        if seeded {
            var payload = try MeetingDiarizationPostProcessor.seed(
                record: record, source: source,
                manifestDigest: MeetingDiarizationFingerprint.manifest(manifest),
                sourceDigest: MeetingDiarizationFingerprint.source(source)
            )
            payload.status = .completed
            payload.intervals = [MeetingSpeakerInterval(speakerID: "speaker", startSample: 0, endSample: 16_000)]
            payload.coveredThroughSample = 16_000
            try record.update(diarization: payload)
        }
        context.insert(record)
        try context.save()
        return (context, record)
    }

    private func start(
        _ record: MeetingRecord, in context: ModelContext,
        gate: MeetingDiarizationExecutionGate, probe: PendingReplayProbe,
        installed: @escaping @Sendable () async -> Bool = { true }
    ) -> Task<MeetingDiarizationPostProcessor.Outcome, Error> {
        Task { @MainActor in
            try await MeetingDiarizationPostProcessor.run(
                record: record, context: context, captureEnabledAtStart: true,
                gate: gate, isInstalled: installed,
                replay: { _, _, _ in try await probe.replay() }
            )
        }
    }

    private func waitForQueue(_ gate: MeetingDiarizationExecutionGate, count: Int = 1) async {
        // Observe actual admission, not a sleep or an assumed number of yields.
        while gate.queuedFinalCount != count { await Task.yield() }
    }

    @Test("rename while queued is read by the seed and the final commit")
    func queuedRename() async throws {
        let (context, record) = try fixture()
        let gate = MeetingDiarizationExecutionGate()
        #expect(await gate.beginFinal())
        let probe = PendingReplayProbe()
        let task = start(record, in: context, gate: gate, probe: probe)
        await waitForQueue(gate)
        #expect(MeetingDiarizationActivity.shared.isRunning(record.meetingID))
        try MeetingSpeakerEditCommitter.rename(record: record, speakerID: "speaker", displayName: "Renamed",
                                               save: { try context.save() })
        gate.endFinal()
        #expect(try await task.value == .completed(didSplit: false))
        #expect(record.diarization?.profiles.first?.displayName == "Renamed")
        #expect(record.result?.segments.first?.speakerIDs == ["speaker"])
        #expect(await probe.calls == 1)
        #expect(!MeetingDiarizationActivity.shared.isRunning(record.meetingID))
    }

    @Test("manual assignment while queued supersedes without replacing its generation")
    func queuedAssignment() async throws {
        let (context, record) = try fixture()
        let gate = MeetingDiarizationExecutionGate()
        #expect(await gate.beginFinal())
        let probe = PendingReplayProbe()
        let task = start(record, in: context, gate: gate, probe: probe)
        await waitForQueue(gate)
        try MeetingSpeakerEditCommitter.assign(record: record, segmentID: "segment", speakerIDs: [],
                                               save: { try context.save() })
        let snapshot = record.persistenceSnapshot()
        gate.endFinal()
        #expect(try await task.value == .superseded)
        #expect(record.persistenceSnapshot() == snapshot)
        #expect(await probe.calls == 0)
    }

    @Test("deleting a queued record cannot replay or resurrect it")
    func queuedDeletion() async throws {
        let (context, record) = try fixture()
        let gate = MeetingDiarizationExecutionGate()
        #expect(await gate.beginFinal())
        let probe = PendingReplayProbe()
        let id = record.meetingID
        let task = start(record, in: context, gate: gate, probe: probe)
        await waitForQueue(gate)
        context.delete(record)
        try context.save()
        gate.endFinal()
        #expect(try await task.value == .superseded)
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
        #expect(await probe.calls == 0)
        #expect(!MeetingDiarizationPostProcessor.isRunning(meetingID: id))
        #expect(!MeetingDiarizationActivity.shared.isRunning(id))
    }

    @Test("queued cancellation drains before the owner exits and permits a retry", arguments: [false, true])
    func queuedCancellation(seeded: Bool) async throws {
        let (context, record) = try fixture(seeded: seeded)
        let manifest = record.audioManifest
        let source = record.result
        let prior = record.diarization
        let gate = MeetingDiarizationExecutionGate()
        #expect(await gate.beginFinal())
        let probe = PendingReplayProbe()
        let task = start(record, in: context, gate: gate, probe: probe)
        await waitForQueue(gate)
        await MeetingDiarizationPostProcessor.cancel(meetingID: record.meetingID)
        #expect(try await task.value == .interrupted)
        #expect(gate.queuedFinalCount == 0)
        #expect(!MeetingDiarizationPostProcessor.isRunning(meetingID: record.meetingID))
        #expect(!MeetingDiarizationActivity.shared.isRunning(record.meetingID))
        #expect(record.diarization?.status == .interrupted)
        #expect(record.result == source)
        #expect(record.audioManifest == manifest)
        if let prior {
            #expect(record.diarization?.intervals == prior.intervals)
            #expect(record.diarization?.profiles == prior.profiles)
        }
        #expect(await probe.calls == 0)
        let liveID = UUID()
        #expect(!gate.beginLive(liveID, groupID: record.meetingID)) // Canceling a waiter did not release its owner.
        gate.endFinal()
        let retry = start(record, in: context, gate: gate, probe: probe)
        #expect(try await retry.value == .completed(didSplit: false))
        #expect(await probe.calls == 1)
        #expect(gate.beginLive(liveID, groupID: record.meetingID))
        gate.endLive(liveID)
    }

    @Test("parent task cancellation removes its queued waiter without waiting for the owner")
    func parentCancellation() async throws {
        let (context, record) = try fixture()
        let gate = MeetingDiarizationExecutionGate()
        #expect(await gate.beginFinal())
        let probe = PendingReplayProbe()
        let task = start(record, in: context, gate: gate, probe: probe)
        await waitForQueue(gate)
        task.cancel()
        #expect(try await task.value == .interrupted)
        #expect(gate.queuedFinalCount == 0)
        #expect(await probe.calls == 0)
        #expect(!MeetingDiarizationActivity.shared.isRunning(record.meetingID))
        gate.endFinal()
        #expect(await gate.beginFinal())
        gate.endFinal()
    }

    @Test("unavailable model preflight re-fetches names rather than saving its original seed")
    func unavailablePreflightRename() async throws {
        let (context, record) = try fixture()
        let preflight = PendingPreflightBarrier()
        let probe = PendingReplayProbe()
        let task = start(record, in: context, gate: MeetingDiarizationExecutionGate(), probe: probe,
                         installed: { await preflight.check() })
        await preflight.waitUntilEntered()
        #expect(MeetingDiarizationPostProcessor.isRunning(meetingID: record.meetingID))
        try MeetingSpeakerEditCommitter.rename(record: record, speakerID: "speaker", displayName: "Latest",
                                               save: { try context.save() })
        await preflight.release()
        #expect(try await task.value == .modelUnavailable)
        #expect(record.diarization?.profiles.first?.displayName == "Latest")
        #expect(record.diarization?.coveredThroughSample == 16_000)
        #expect(await probe.calls == 0)
    }

    @Test("deletion during model preflight cannot save model-unavailable state")
    func preflightDeletion() async throws {
        let (context, record) = try fixture()
        let id = record.meetingID
        let preflight = PendingPreflightBarrier()
        let probe = PendingReplayProbe()
        let task = start(record, in: context, gate: MeetingDiarizationExecutionGate(), probe: probe,
                         installed: { await preflight.check() })
        await preflight.waitUntilEntered()
        context.delete(record)
        try context.save()
        await preflight.release()
        #expect(try await task.value == .superseded)
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
        #expect(await probe.calls == 0)
        #expect(!MeetingDiarizationActivity.shared.isRunning(id))
    }

    @Test("canceling first-pass preflight persists interrupted without entering replay")
    func preflightCancellation() async throws {
        let (context, record) = try fixture(seeded: false)
        let preflight = PendingPreflightBarrier()
        let probe = PendingReplayProbe()
        let task = start(record, in: context, gate: MeetingDiarizationExecutionGate(), probe: probe,
                         installed: { await preflight.check() })
        await preflight.waitUntilEntered()
        task.cancel()
        await preflight.release()
        #expect(try await task.value == .interrupted)
        #expect(record.diarization?.status == .interrupted)
        #expect(record.diarization?.manualAssignments == ["segment": ["speaker"]])
        #expect(await probe.calls == 0)
        #expect(!MeetingDiarizationActivity.shared.isRunning(record.meetingID))
    }

    @Test("source or manifest changes while queued supersede without a stale save", arguments: [false, true])
    func queuedSourceChange(changeManifest: Bool) async throws {
        let (context, record) = try fixture()
        let gate = MeetingDiarizationExecutionGate()
        #expect(await gate.beginFinal())
        let probe = PendingReplayProbe()
        let task = start(record, in: context, gate: gate, probe: probe)
        await waitForQueue(gate)
        if changeManifest {
            try record.update(audioManifest: MeetingAudioManifest(relativeDirectory: "replacement", sampleRate: 16_000,
                                                                  totalSamples: 32_000, parts: []))
        } else {
            var source = try #require(record.result)
            source.segments[0].text = "Edited"
            try record.update(result: source, status: .ready)
        }
        try context.save()
        let snapshot = record.persistenceSnapshot()
        gate.endFinal()
        #expect(try await task.value == .superseded)
        #expect(record.persistenceSnapshot() == snapshot)
        #expect(await probe.calls == 0)
    }

    @Test("failed replay preserves the recording, transcript, and successful speaker evidence")
    func replayFailure() async throws {
        let (context, record) = try fixture()
        let source = record.result
        let raw = record.rawResult
        let manifest = record.audioManifest
        let prior = try #require(record.diarization)
        let gate = MeetingDiarizationExecutionGate()
        let outcome = try await MeetingDiarizationPostProcessor.run(
            record: record, context: context, captureEnabledAtStart: true,
            gate: gate, isInstalled: { true }, replay: { _, _, _ in throw MeetingDiarizationFailure.inferenceFailed }
        )
        #expect(outcome == .failed(.inferenceFailed))
        #expect(record.result == source)
        #expect(record.rawResult == raw)
        #expect(record.audioManifest == manifest)
        #expect(record.diarization?.intervals == prior.intervals)
        #expect(record.diarization?.profiles == prior.profiles)
        #expect(record.diarization?.manualAssignments == prior.manualAssignments)
        #expect(record.diarization?.coveredThroughSample == prior.coveredThroughSample)
        #expect(!MeetingDiarizationActivity.shared.isRunning(record.meetingID))
        #expect(await gate.beginFinal())
        gate.endFinal()
    }
}

private actor PendingReplayProbe {
    private(set) var calls = 0

    func replay() throws -> MeetingDiarizationReplay.Evidence {
        calls += 1
        return MeetingDiarizationReplay.Evidence(
            intervals: [MeetingSpeakerInterval(speakerID: "detected", startSample: 0, endSample: 16_000)],
            coveredThroughSample: 16_000, voiceEvidence: nil
        )
    }
}

private actor PendingPreflightBarrier {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var resume: CheckedContinuation<Bool, Never>?

    func check() async -> Bool {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        return await withCheckedContinuation { resume = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        resume?.resume(returning: false)
        resume = nil
    }
}
