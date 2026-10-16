import AVFoundation
import Foundation
import Testing
@testable import todo

@Suite("Meeting live diarization pipeline")
@MainActor
struct MeetingDiarizationPipelineTests {
    // MARK: - Input pipeline

    @Test("contiguous buffers reach the worker in order, owned and normalized")
    func contiguousBuffersKeepSampleContinuity() async throws {
        let worker = FakeDiarizationWorker()
        let log = DeliveryLog()
        let failures = FailureLog()
        let pipeline = MeetingDiarizationInputPipeline(
            worker: worker, deliver: { await log.record($0) }, failed: { failures.append($0) }
        )
        let first = pcm(repeating: 16_384, count: 1_600)
        pipeline.enqueue(first, startSample: 0)
        // The caller may reuse its buffer right after admission.
        fill(first, with: 0)
        pipeline.enqueue(pcm(repeating: -16_384, count: 1_600), startSample: 1_600)
        pipeline.enqueue(pcm(repeating: 8_192, count: 800), startSample: 3_200)
        try await pipeline.finish()

        let batches = await worker.batches
        var expectedStart: Int64 = 0
        for batch in batches {
            #expect(batch.start == expectedStart)
            expectedStart += Int64(batch.samples.count)
        }
        #expect(expectedStart == 4_000)
        let expected = [Float](repeating: 0.5, count: 1_600) + [Float](repeating: -0.5, count: 1_600) +
            [Float](repeating: 0.25, count: 800)
        #expect(batches.flatMap(\.samples) == expected)
        #expect(await worker.finishTotals == [4_000])
        #expect(await worker.lastEvent == .finish)
        let updates = await log.updates
        #expect(updates.last?.coveredThroughSample == 4_000)
        #expect(updates.last?.closedIntervals == [MeetingSpeakerInterval(speakerID: "A", startSample: 0, endSample: 4_000)])
        #expect(failures.codes.isEmpty)

        // Input after finish is not admitted.
        pipeline.enqueue(pcm(repeating: 1, count: 160), startSample: 4_000)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await worker.batches.count == batches.count)
    }

    @Test("overflow while inference is blocked reports once and stops admission")
    func overflowReportsOnceAndStopsAdmission() async throws {
        let gate = Gate()
        let worker = FakeDiarizationWorker(processGate: gate)
        let failures = FailureLog()
        let pipeline = MeetingDiarizationInputPipeline(
            worker: worker, maximumQueuedSamples: 3_200, deliver: { _ in }, failed: { failures.append($0) }
        )
        // First buffer starts processing and blocks inside worker.process.
        pipeline.enqueue(pcm(repeating: 100, count: 1_600), startSample: 0)
        #expect(await eventually { await worker.lastEvent == .process })
        // Two more 1,600-sample buffers exceed the 3,200-sample unprocessed cap (1,600 in flight + 1,600 queued = 3,200).
        pipeline.enqueue(pcm(repeating: 100, count: 1_600), startSample: 1_600)
        #expect(failures.codes.isEmpty)
        pipeline.enqueue(pcm(repeating: 100, count: 1_600), startSample: 3_200)
        pipeline.enqueue(pcm(repeating: 100, count: 1_600), startSample: 3_200)
        pipeline.enqueue(pcm(repeating: 100, count: 1_600), startSample: 4_800)
        #expect(failures.codes == [.inputOverflow])

        await gate.open()
        await #expect(throws: MeetingDiarizationFailure.inputOverflow) {
            try await pipeline.finish()
        }
        // Only the accepted prefix was processed; time was never shifted.
        #expect(await worker.batches.reduce(0) { $0 + $1.samples.count } == 3_200)
        #expect(await worker.finishTotals == [3_200])
        #expect(failures.codes == [.inputOverflow])
    }

    @Test("preparation backlog reserves catch-up headroom at handoff so continued live admission succeeds")
    func preparationBacklogDropsOldestPrefixWithoutFailingSession() async throws {
        let prepareGate = Gate()
        let processGate = Gate()
        let worker = FakeDiarizationWorker(prepareGate: prepareGate, processGate: processGate)
        let log = DeliveryLog()
        let failures = FailureLog()
        let pipeline = MeetingDiarizationInputPipeline(
            worker: worker, maximumQueuedSamples: 3_200, deliver: { await log.record($0) }, failed: { failures.append($0) }
        )
        // Overflow during preparation: oldest buffers are evicted to reserve catch-up headroom.
        pipeline.enqueue(pcm(repeating: 8_192, count: 1_600), startSample: 0)
        pipeline.enqueue(pcm(repeating: 16_384, count: 1_600), startSample: 1_600)
        pipeline.enqueue(pcm(repeating: -16_384, count: 1_600), startSample: 3_200)
        #expect(failures.codes.isEmpty)

        // Release preparation and hold the first post-prepare batch inside worker.process.
        await prepareGate.open()
        #expect(await eventually { await worker.lastEvent == .process })

        // Enqueue another contiguous live buffer while the first batch is still in flight.
        pipeline.enqueue(pcm(repeating: 8_192, count: 1_600), startSample: 4_800)
        #expect(failures.codes.isEmpty)

        await processGate.open()
        #expect(await eventually { await log.updates.last?.coveredThroughSample == 6_400 })

        // Continued live admission after catch-up also succeeds.
        pipeline.enqueue(pcm(repeating: 16_384, count: 1_600), startSample: 6_400)
        try await pipeline.finish()

        let batches = await worker.batches
        #expect(batches.map(\.start) == [3_200, 4_800, 6_400])
        #expect(batches.flatMap(\.samples).count == 4_800)
        #expect(await worker.finishTotals == [8_000])
        #expect(failures.codes.isEmpty)
        let updates = await log.updates
        #expect(updates.last?.coveredThroughSample == 8_000)
    }

    @Test("live preparation is distinct from the first delivered inference")
    func preparationPrecedesInferenceWithoutBlockingRecordingInput() async throws {
        let prepareGate = Gate()
        let processGate = Gate()
        let worker = FakeDiarizationWorker(prepareGate: prepareGate, processGate: processGate)
        let prepared = PreparedLog()
        let delivered = DeliveryLog()
        let pipeline = MeetingDiarizationInputPipeline(
            worker: worker, prepared: { prepared.mark() },
            deliver: { await delivered.record($0) }, failed: { _ in }
        )
        pipeline.enqueue(pcm(repeating: 8_192, count: 1_600), startSample: 0)
        #expect(await eventually { await worker.lastEvent == .prepare })
        #expect(prepared.count == 0)
        #expect(await delivered.updates.isEmpty)
        await prepareGate.open()
        #expect(await eventually { await worker.lastEvent == .process })
        #expect(prepared.count == 1)
        #expect(await delivered.updates.isEmpty)
        await processGate.open()
        #expect(await eventually { await delivered.updates.last?.coveredThroughSample == 1_600 })
        try await pipeline.finish()
    }

    @Test("cancelling during model loading never reports the model as prepared")
    func cancelDuringPreparationSuppressesReadyEvent() async throws {
        let prepareGate = Gate()
        let worker = FakeDiarizationWorker(prepareGate: prepareGate)
        let prepared = PreparedLog()
        let delivered = DeliveryLog()
        let pipeline = MeetingDiarizationInputPipeline(
            worker: worker, prepared: { prepared.mark() },
            deliver: { await delivered.record($0) }, failed: { _ in }
        )
        pipeline.enqueue(pcm(repeating: 8_192, count: 1_600), startSample: 0)
        #expect(await eventually { await worker.lastEvent == .prepare })
        let cancelling = Task { await pipeline.cancel() }
        #expect(await eventually { pipeline.isCancellationRequested })
        await prepareGate.open()
        await cancelling.value
        #expect(prepared.count == 0)
        #expect(await delivered.updates.isEmpty)
        #expect(await worker.cancelCount == 1)
    }

    @Test("a timeline gap is reported once and later input is refused")
    func timelineGapStopsAdmission() async throws {
        let worker = FakeDiarizationWorker()
        let failures = FailureLog()
        let pipeline = MeetingDiarizationInputPipeline(worker: worker, deliver: { _ in }, failed: { failures.append($0) })
        pipeline.enqueue(pcm(repeating: 100, count: 1_600), startSample: 0)
        pipeline.enqueue(pcm(repeating: 100, count: 1_600), startSample: 3_200)
        pipeline.enqueue(pcm(repeating: 100, count: 1_600), startSample: 1_600)
        #expect(failures.codes == [.timelineMismatch])
        await #expect(throws: MeetingDiarizationFailure.timelineMismatch) {
            try await pipeline.finish()
        }
        #expect(await worker.batches.map(\.start) == [0])
        #expect(await worker.finishTotals == [1_600])
    }

    @Test("cancel waits for the drain; queued input is discarded and nothing is delivered afterwards")
    func cancelStopsDeliveryBeforeReturning() async throws {
        let deliveryGate = Gate()
        let worker = FakeDiarizationWorker()
        let log = DeliveryLog(blockingFirst: deliveryGate)
        let failures = FailureLog()
        let pipeline = MeetingDiarizationInputPipeline(
            worker: worker, deliver: { await log.record($0) }, failed: { failures.append($0) }
        )
        pipeline.enqueue(pcm(repeating: 100, count: 1_600), startSample: 0)
        #expect(await eventually { await log.updates.count == 1 })
        // Queued while the drain is still inside the first delivery.
        pipeline.enqueue(pcm(repeating: 100, count: 1_600), startSample: 1_600)

        let returned = Flag()
        let cancelling = Task {
            await pipeline.cancel()
            await returned.set()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await returned.value == false)
        await deliveryGate.open()
        await cancelling.value

        #expect(await worker.cancelCount == 1)
        #expect(await worker.batches.map(\.start) == [0])
        #expect(await worker.finishTotals.isEmpty)
        pipeline.enqueue(pcm(repeating: 100, count: 1_600), startSample: 3_200)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await log.updates.count == 1)
        #expect(await worker.batches.count == 1)
        #expect(failures.codes.isEmpty)
    }

    @Test("prewarming owns one live gate and transfers it without overlapping a final replay")
    func prewarmHandoffKeepsSingleModelOwner() async throws {
        let gate = MeetingDiarizationExecutionGate()
        let loading = Gate()
        let prewarmer = MeetingLiveSpeakerPrewarmer(
            gate: gate, enabled: { true }, installed: { true },
            createWorker: { FakeDiarizationWorker(sessionID: $0, prepareGate: loading) }
        )
        await prewarmer.prepareIfAvailable()
        #expect(prewarmer.phase == .preparing)
        #expect(!gate.beginLive(UUID(), groupID: "recording"))
        await loading.open()
        #expect(await eventually { prewarmer.phase == .ready })
        guard let recordingWorker = prewarmer.take(groupID: "recording") else {
            Issue.record("Prepared worker was not transferred")
            return
        }
        #expect(prewarmer.phase == .inactive)
        await prewarmer.releaseUnused()
        let sibling = UUID()
        #expect(gate.beginLive(sibling, groupID: "recording"))
        #expect(!gate.beginLive(UUID(), groupID: "unrelated"))
        let finalReplay = Task { await gate.beginFinal() }
        #expect(await eventually { gate.queuedFinalCount == 1 })
        await recordingWorker.cancel()
        gate.endLive(recordingWorker.sessionID)
        #expect(gate.queuedFinalCount == 1)
        gate.endLive(sibling)
        #expect(await finalReplay.value)
        gate.endFinal()
    }

    @Test("cancelling prewarm while loading cannot publish late ready or pin the final gate")
    func cancelledPrewarmDiscardsLatePreparation() async throws {
        let gate = MeetingDiarizationExecutionGate()
        let loading = Gate()
        let prewarmer = MeetingLiveSpeakerPrewarmer(
            gate: gate, enabled: { true }, installed: { true },
            createWorker: { FakeDiarizationWorker(sessionID: $0, prepareGate: loading) }
        )
        await prewarmer.prepareIfAvailable()
        #expect(prewarmer.phase == .preparing)
        await prewarmer.releaseUnused()
        await loading.open()
        #expect(prewarmer.phase == .inactive)
        #expect(prewarmer.take(groupID: "recording")?.sessionID == nil)
        #expect(await gate.beginFinal())
        gate.endFinal()
    }

    @Test("saved-audio replay waits for an in-flight prewarm release")
    func finalPassWaitsForPrewarmModelUnload() async {
        let gate = MeetingDiarizationExecutionGate()
        let unloading = Gate()
        let prewarmer = MeetingLiveSpeakerPrewarmer(
            gate: gate, enabled: { true }, installed: { true },
            createWorker: { FakeDiarizationWorker(sessionID: $0, cancelGate: unloading) }
        )
        await prewarmer.prepareIfAvailable()
        let leaving = Task { await prewarmer.releaseUnused() }
        #expect(await eventually { prewarmer.phase == .inactive })
        let finalPass = Task {
            await prewarmer.releaseUnused()
            return await gate.beginFinal()
        }
        #expect(!gate.beginLive(UUID(), groupID: "recording"))
        await unloading.open()
        await leaving.value
        #expect(await finalPass.value)
        gate.endFinal()
    }

    @Test("a delayed install check cannot start a model after the meeting screen leaves")
    func dismissedMeetingRejectsLatePrewarm() async {
        let gate = MeetingDiarizationExecutionGate()
        let installedGate = Gate()
        let entered = Flag()
        let prewarmer = MeetingLiveSpeakerPrewarmer(
            gate: gate, enabled: { true },
            installed: {
                await entered.set()
                await installedGate.wait()
                return true
            },
            createWorker: { FakeDiarizationWorker(sessionID: $0) }
        )
        let starting = Task { await prewarmer.prepareIfAvailable() }
        #expect(await eventually { await entered.value })
        await prewarmer.releaseUnused()
        await installedGate.open()
        await starting.value
        #expect(prewarmer.phase == .inactive)
        #expect(prewarmer.take(groupID: "recording")?.sessionID == nil)
        #expect(await gate.beginFinal())
        gate.endFinal()
    }

    @Test("same-group admission and FIFO final handoff wait for every track")
    func groupedLiveAdmissionAndFairFinalQueue() async {
        let gate = MeetingDiarizationExecutionGate()
        let mic = UUID()
        let app = UUID()
        let lateTrack = UUID()
        #expect(gate.beginLive(mic, groupID: "group"))
        #expect(!gate.beginLive(mic, groupID: "group"))
        #expect(gate.beginLive(app, groupID: "group"))
        #expect(!gate.beginLive(UUID(), groupID: "another"))
        let first = Task { await gate.beginFinal() }
        #expect(await eventually { gate.queuedFinalCount == 1 })
        let cancelled = Task { await gate.beginFinal() }
        #expect(await eventually { gate.queuedFinalCount == 2 })
        let second = Task { await gate.beginFinal() }
        #expect(await eventually { gate.queuedFinalCount == 3 })
        cancelled.cancel()
        #expect(await cancelled.value == false)
        #expect(gate.queuedFinalCount == 2)
        #expect(gate.beginLive(lateTrack, groupID: "group"))
        gate.endLive(UUID())
        gate.endLive(mic)
        gate.endLive(mic)
        gate.endLive(app)
        #expect(gate.queuedFinalCount == 2)
        #expect(!gate.beginLive(UUID(), groupID: "another"))
        gate.endLive(lateTrack)
        #expect(await first.value)
        #expect(gate.queuedFinalCount == 1)
        #expect(!gate.beginLive(UUID(), groupID: "group"))
        gate.endFinal()
        #expect(!gate.beginLive(UUID(), groupID: "another"))
        #expect(await second.value)
        gate.endFinal()
        let newGroup = UUID()
        #expect(gate.beginLive(newGroup, groupID: "another"))
        gate.endLive(newGroup)
    }

    @Test("cancellation after final ownership transfer cannot pin the gate")
    func cancelledFinalHandoffReleasesOwnership() async {
        let gate = MeetingDiarizationExecutionGate()
        let live = UUID()
        #expect(gate.beginLive(live, groupID: "group"))
        let finalReplay = Task { await gate.beginFinal() }
        #expect(await eventually { gate.queuedFinalCount == 1 })
        // MainActor prevents the resumed task from running between these calls.
        gate.endLive(live)
        finalReplay.cancel()
        #expect(await finalReplay.value == false)
        let retry = UUID()
        #expect(gate.beginLive(retry, groupID: "new"))
        gate.endLive(retry)
    }

    @Test("prewarm handoff during loading transfers the actual worker and keeps ownership until cancellation settles")
    func loadingPrewarmTransfersExistingWorker() async throws {
        let gate = MeetingDiarizationExecutionGate()
        let loading = Gate()
        let unloading = Gate()
        let created = PreparedLog()
        var candidate: FakeDiarizationWorker?
        let prewarmer = MeetingLiveSpeakerPrewarmer(
            gate: gate, enabled: { true }, installed: { true },
            createWorker: { id in
                let worker = FakeDiarizationWorker(sessionID: id, prepareGate: loading, cancelGate: unloading)
                candidate = worker
                created.mark()
                return worker
            }
        )
        await prewarmer.prepareIfAvailable()
        guard let transferred = prewarmer.take(groupID: "group") as? FakeDiarizationWorker else {
            Issue.record("Loading worker was not transferred")
            return
        }
        #expect(transferred === candidate)
        #expect(created.count == 1)
        #expect(await eventually { await transferred.lastEvent == .prepare })
        #expect(prewarmer.phase == .inactive)
        #expect(prewarmer.take(groupID: "other") == nil)
        await prewarmer.releaseUnused()
        #expect(await transferred.cancelCount == 0)
        let sibling = UUID()
        #expect(gate.beginLive(sibling, groupID: "group"))
        let finalReplay = Task { await gate.beginFinal() }
        #expect(await eventually { gate.queuedFinalCount == 1 })
        await loading.open()
        try await transferred.prepare()
        let cancelling = Task {
            await transferred.cancel()
            gate.endLive(transferred.sessionID)
        }
        #expect(await eventually { await transferred.lastEvent == .cancel })
        gate.endLive(sibling)
        #expect(gate.queuedFinalCount == 1)
        await unloading.open()
        await cancelling.value
        #expect(await finalReplay.value)
        gate.endFinal()
        #expect(created.count == 1)
        #expect(prewarmer.phase == .inactive)
    }

    @Test("one track's pipeline cancellation does not stop a sibling track")
    func siblingPipelineSurvivesCancellation() async throws {
        let loading = Gate()
        let cancelled = FakeDiarizationWorker(prepareGate: loading)
        let sibling = FakeDiarizationWorker()
        let prepared = PreparedLog()
        let failures = FailureLog()
        let first = MeetingDiarizationInputPipeline(worker: cancelled, prepared: { prepared.mark() }, deliver: { _ in }, failed: { failures.append($0) })
        let second = MeetingDiarizationInputPipeline(worker: sibling, deliver: { _ in }, failed: { failures.append($0) })
        first.enqueue(pcm(repeating: 100, count: 160), startSample: 0)
        #expect(await eventually { await cancelled.lastEvent == .prepare })
        let cancellation = Task { await first.cancel() }
        #expect(await eventually { first.isCancellationRequested })
        second.enqueue(pcm(repeating: 200, count: 160), startSample: 0)
        #expect(await eventually { await sibling.lastEvent == .process })
        await loading.open()
        await cancellation.value
        second.enqueue(pcm(repeating: 300, count: 160), startSample: 160)
        try await second.finish()
        #expect(prepared.count == 0)
        #expect(await cancelled.cancelCount == 1)
        #expect(await cancelled.batches.isEmpty)
        #expect(await sibling.finishTotals == [320])
        #expect(await sibling.cancelCount == 0)
        #expect(failures.codes.isEmpty)
    }

    @Test("independent track trackers never share slot IDs or open interval state")
    func independentSpeakerTrackers() {
        var mic = MeetingSpeakerActivityTracker(speakerCount: 1)
        var app = MeetingSpeakerActivityTracker(speakerCount: 1, baseSample: 16_000)
        var micClosed: [MeetingSpeakerInterval] = []
        var appClosed: [MeetingSpeakerInterval] = []
        let active = frames(20, active: [0], speakers: 1)
        mic.consume(probabilities: active, frames: 20, receivedSamples: 3_200, into: &micClosed)
        let micOpen = mic.openIntervals(receivedSamples: 3_200)
        #expect(app.openIntervals(receivedSamples: 19_200).isEmpty)
        app.consume(probabilities: active, frames: 20, receivedSamples: 19_200, into: &appClosed)
        let appOpen = app.openIntervals(receivedSamples: 19_200)
        #expect(micOpen.count == 1 && appOpen.count == 1)
        #expect(Set(micOpen.map(\.speakerID)).isDisjoint(with: appOpen.map(\.speakerID)))
        mic.finish(receivedSamples: 3_200, into: &micClosed)
        #expect(app.openIntervals(receivedSamples: 19_200) == appOpen)
        #expect(micClosed.map(\.startSample) == [0])
        app.finish(receivedSamples: 19_200, into: &appClosed)
        #expect(appClosed.map(\.startSample) == [16_000])
    }

    // MARK: - Activity tracker

    @Test("a 25-frame run split across chunks survives; overlapping slots stay separate")
    func runAcrossChunkBoundarySurvives() {
        var tracker = MeetingSpeakerActivityTracker(speakerCount: 2)
        var closed: [MeetingSpeakerInterval] = []
        tracker.consume(probabilities: frames(15, active: [0, 1]), frames: 15, receivedSamples: 15 * 160, into: &closed)
        #expect(closed.isEmpty)
        tracker.consume(
            probabilities: frames(10, active: [0, 1]) + frames(5, active: []), frames: 15,
            receivedSamples: 30 * 160, into: &closed
        )
        #expect(closed.count == 2)
        #expect(closed.allSatisfy { $0.startSample == 0 && $0.endSample == 4_000 })
        #expect(Set(closed.map(\.speakerID)).count == 2)
    }

    @Test("runs shorter than 20 frames are dropped; exactly 20 frames are kept")
    func shortRunsDropped() {
        var tracker = MeetingSpeakerActivityTracker(speakerCount: 2)
        var closed: [MeetingSpeakerInterval] = []
        let probabilities = frames(15, active: [0, 1]) + frames(4, active: [1]) + frames(1, active: [1]) +
            frames(10, active: [])
        tracker.consume(probabilities: probabilities, frames: 30, receivedSamples: 30 * 160, into: &closed)
        tracker.finish(receivedSamples: 30 * 160, into: &closed)
        #expect(closed.count == 1)
        #expect(closed.map(\.startSample) == [0])
        #expect(closed.map(\.endSample) == [3_200])
    }

    @Test("an open interval is exposed only after 20 frames and keeps its slot ID")
    func openIntervalAfterMinimumLength() {
        var tracker = MeetingSpeakerActivityTracker(speakerCount: 1)
        var closed: [MeetingSpeakerInterval] = []
        tracker.consume(probabilities: frames(19, active: [0], speakers: 1), frames: 19, receivedSamples: 19 * 160, into: &closed)
        #expect(tracker.openIntervals(receivedSamples: 19 * 160).isEmpty)
        tracker.consume(probabilities: frames(1, active: [0], speakers: 1), frames: 1, receivedSamples: 20 * 160, into: &closed)
        let opened = tracker.openIntervals(receivedSamples: 20 * 160)
        #expect(opened.map(\.startSample) == [0])
        #expect(opened.map(\.endSample) == [3_200])
        tracker.consume(probabilities: frames(5, active: [0], speakers: 1), frames: 5, receivedSamples: 25 * 160, into: &closed)
        let grown = tracker.openIntervals(receivedSamples: 25 * 160)
        #expect(grown.map(\.endSample) == [4_000])
        #expect(grown.map(\.speakerID) == opened.map(\.speakerID))
        #expect(closed.isEmpty)
    }

    @Test("model padding past the received samples is trimmed at finish")
    func paddingTrimmedAtFinish() {
        var tracker = MeetingSpeakerActivityTracker(speakerCount: 1)
        var closed: [MeetingSpeakerInterval] = []
        tracker.consume(probabilities: frames(30, active: [0], speakers: 1), frames: 30, receivedSamples: 4_100, into: &closed)
        #expect(tracker.openIntervals(receivedSamples: 4_100).map(\.endSample) == [4_100])
        tracker.finish(receivedSamples: 4_100, into: &closed)
        #expect(closed.map(\.startSample) == [0])
        #expect(closed.map(\.endSample) == [4_100])
    }

    @Test("coverage stops at the start of a pending short run")
    func coverageStopsAtPendingShortRun() {
        var tracker = MeetingSpeakerActivityTracker(speakerCount: 1)
        var closed: [MeetingSpeakerInterval] = []
        tracker.consume(
            probabilities: frames(30, active: [], speakers: 1) + frames(5, active: [0], speakers: 1),
            frames: 35, receivedSamples: 35 * 160, into: &closed
        )
        #expect(tracker.coveredThroughSample(receivedSamples: 35 * 160) == 30 * 160)
        tracker.consume(probabilities: frames(15, active: [0], speakers: 1), frames: 15, receivedSamples: 50 * 160, into: &closed)
        #expect(tracker.coveredThroughSample(receivedSamples: 50 * 160) == 50 * 160)
        // Coverage never runs past the real input.
        #expect(tracker.coveredThroughSample(receivedSamples: 49 * 160) == 49 * 160)
    }

    @Test("live gap tolerance bridges brief consonant dips, trims trailing silence and preserves baseSample offset")
    func shortGapBridgingInLiveMode() {
        var tracker = MeetingSpeakerActivityTracker(
            speakerCount: 1,
            maximumGapFrames: MeetingSpeakerActivityTracker.liveMaximumGapFrames,
            baseSample: 3_200
        )
        var closed: [MeetingSpeakerInterval] = []
        // 12 active frames + 3 inactive frames (30 ms dip <= 50 ms) + 10 active frames = 25-frame bridged run.
        // Followed by 6 inactive frames (> 50 ms) which closes the run at frame 25 (excluding the 6 trailing silence frames),
        // then 10 active + 6 inactive + 10 active (separated by 60 ms > 50 ms, both < 20 frames so both dropped).
        let probabilities =
            frames(12, active: [0], speakers: 1) +
            frames(3, active: [], speakers: 1) +
            frames(10, active: [0], speakers: 1) +
            frames(6, active: [], speakers: 1) +
            frames(10, active: [0], speakers: 1) +
            frames(6, active: [], speakers: 1) +
            frames(10, active: [0], speakers: 1)
        tracker.consume(probabilities: probabilities, frames: 57, receivedSamples: 3_200 + 57 * 160, into: &closed)
        tracker.finish(receivedSamples: 3_200 + 57 * 160, into: &closed)
        #expect(closed.map(\.startSample) == [3_200])
        #expect(closed.map(\.endSample) == [7_200])
    }

    // MARK: - Live timeline and rows

    @Test("live timeline rejects another session and numbers speakers by first appearance")
    func liveTimelineSessionFence() {
        let session = UUID()
        var timeline = MeetingLiveSpeakerTimeline(sessionID: session)
        let foreign = MeetingDiarizationUpdate(
            sessionID: UUID(), closedIntervals: [interval("X", 0, 500)], openIntervals: [], coveredThroughSample: 8_000
        )
        let acceptedForeign = timeline.apply(foreign)
        #expect(!acceptedForeign)
        #expect(timeline == MeetingLiveSpeakerTimeline(sessionID: session))

        let acceptedFirst = timeline.apply(MeetingDiarizationUpdate(
            sessionID: session, closedIntervals: [interval("B", 300, 600)], openIntervals: [interval("A", 700, 900)],
            coveredThroughSample: 900 * 16
        ))
        let acceptedSecond = timeline.apply(MeetingDiarizationUpdate(
            sessionID: session, closedIntervals: [interval("A", 700, 1_200), interval("C", 100, 400)], openIntervals: [],
            coveredThroughSample: 800 * 16
        ))
        #expect(acceptedFirst && acceptedSecond)
        #expect(timeline.ordinals == ["B": 1, "A": 2, "C": 3])
        #expect(timeline.openIntervals.isEmpty)
        #expect(timeline.coveredThroughSample == 900 * 16)
    }

    @Test("final text stays intact while provisional speaker labels arrive later")
    func rowsUpdateSpeakersIndependentlyOfText() {
        var reducer = LiveTranscriptReducer()
        reducer.replace(LiveTranscriptEntry(
            id: "e1", startMs: 0, endMs: 1_000, text: "안녕하세요 반갑습니다",
            timedRuns: [
                MeetingTimedTextRun(utf16Offset: 0, utf16Length: 5, startMs: 0, endMs: 500),
                MeetingTimedTextRun(utf16Offset: 6, utf16Length: 5, startMs: 500, endMs: 1_000)
            ],
            isFinal: true
        ))
        let session = UUID()
        var timeline = MeetingLiveSpeakerTimeline(sessionID: session)
        var builder = MeetingLiveTranscriptRowBuilder()

        let unlabeled = builder.rows(for: reducer.entries, timeline: timeline)
        #expect(unlabeled.map(\.text) == ["안녕하세요 반갑습니다"])
        #expect(unlabeled.map(\.speakerIDs) == [[]])

        _ = timeline.apply(MeetingDiarizationUpdate(
            sessionID: session, closedIntervals: [interval("A", 0, 500), interval("B", 500, 1_000)],
            openIntervals: [], coveredThroughSample: 1_000 * 16
        ))
        reducer.replace(LiveTranscriptEntry(id: "e2", startMs: 1_000, endMs: 1_500, text: "다음 안건"))
        let labeled = builder.rows(for: reducer.entries, timeline: timeline)
        #expect(labeled.map(\.text) == ["안녕하세요", "반갑습니다", "다음 안건"])
        #expect(labeled.map(\.speakerIDs) == [["A"], ["B"], []])
        #expect(reducer.entries.map(\.isFinal) == [true, false])
        #expect(reducer.entries.first?.text == "안녕하세요 반갑습니다")

        _ = timeline.apply(MeetingDiarizationUpdate(
            sessionID: session, closedIntervals: [interval("A", 1_000, 1_500)],
            openIntervals: [], coveredThroughSample: 1_500 * 16
        ))
        let extended = builder.rows(for: reducer.entries, timeline: timeline)
        #expect(extended.map(\.text) == ["안녕하세요", "반갑습니다", "다음 안건"])
        #expect(extended.map(\.speakerIDs) == [["A"], ["B"], ["A"]])
    }

    // MARK: - Helpers

    private func interval(_ id: String, _ startMs: Int64, _ endMs: Int64) -> MeetingSpeakerInterval {
        MeetingSpeakerInterval(speakerID: id, startSample: startMs * 16, endSample: endMs * 16)
    }

    private func frames(_ count: Int, active: Set<Int>, speakers: Int = 2) -> [Float] {
        (0..<count).flatMap { _ in (0..<speakers).map { active.contains($0) ? 0.9 : 0.1 } }
    }

    private func pcm(repeating value: Int16, count: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        fill(buffer, with: value)
        return buffer
    }

    private func fill(_ buffer: AVAudioPCMBuffer, with value: Int16) {
        let channel = buffer.int16ChannelData![0]
        for index in 0..<Int(buffer.frameLength) { channel[index] = value }
    }

    private func eventually(_ condition: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor Flag {
    private(set) var value = false
    func set() { value = true }
}

private final class PreparedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var count: Int { lock.withLock { stored } }
    func mark() { lock.withLock { stored += 1 } }
}

private final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MeetingDiarizationFailure] = []
    var codes: [MeetingDiarizationFailure] { lock.withLock { stored } }
    func append(_ code: MeetingDiarizationFailure) { lock.withLock { stored.append(code) } }
}

private actor DeliveryLog {
    private(set) var updates: [MeetingDiarizationUpdate] = []
    private let firstDeliveryGate: Gate?

    init(blockingFirst gate: Gate? = nil) {
        firstDeliveryGate = gate
    }

    func record(_ update: MeetingDiarizationUpdate) async {
        updates.append(update)
        if updates.count == 1, let firstDeliveryGate { await firstDeliveryGate.wait() }
    }
}

/// Stands in for the model: activity for speaker "A" over everything received.
private actor FakeDiarizationWorker: MeetingDiarizationProcessing {
    struct Batch: Sendable {
        let start: Int64
        let samples: [Float]
    }

    enum Event: Sendable, Equatable { case prepare, process, finish, cancel }

    nonisolated let sessionID: UUID
    private let prepareGate: Gate?
    private let processGate: Gate?
    private let cancelGate: Gate?
    private(set) var batches: [Batch] = []
    private(set) var finishTotals: [Int64] = []
    private(set) var cancelCount = 0
    private(set) var lastEvent: Event?

    init(sessionID: UUID = UUID(), prepareGate: Gate? = nil, processGate: Gate? = nil, cancelGate: Gate? = nil) {
        self.sessionID = sessionID
        self.prepareGate = prepareGate
        self.processGate = processGate
        self.cancelGate = cancelGate
    }

    func prepare() async throws {
        lastEvent = .prepare
        await prepareGate?.wait()
    }

    func process(samples: [Float], startSample: Int64) async throws -> MeetingDiarizationUpdate {
        lastEvent = .process
        if batches.isEmpty, let processGate {
            await processGate.wait()
        }
        batches.append(Batch(start: startSample, samples: samples))
        let end = startSample + Int64(samples.count)
        return MeetingDiarizationUpdate(
            sessionID: sessionID, closedIntervals: [],
            openIntervals: [MeetingSpeakerInterval(speakerID: "A", startSample: 0, endSample: end)],
            coveredThroughSample: end
        )
    }

    func finish(totalSamples: Int64) async throws -> MeetingDiarizationUpdate {
        lastEvent = .finish
        finishTotals.append(totalSamples)
        return MeetingDiarizationUpdate(
            sessionID: sessionID,
            closedIntervals: [MeetingSpeakerInterval(speakerID: "A", startSample: 0, endSample: totalSamples)],
            openIntervals: [], coveredThroughSample: totalSamples
        )
    }

    func cancel() async {
        lastEvent = .cancel
        cancelCount += 1
        await cancelGate?.wait()
    }
}
