import Foundation
import SwiftData
import Testing
@testable import todo

private actor SuspendedOfflineASR {
    private(set) var started = false
    private(set) var cancelled = false
    func noticeCancellation() { cancelled = true }
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Meeting offline ASR commit", .timeLimit(.minutes(1)))
@MainActor
struct MeetingOfflineOrchestratorTests {
    private enum TestError: Error, Equatable { case inference, save }

    private func fixture(status: MeetingStatus = .ready) throws -> (ModelContext, MeetingRecord, MeetingResult) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: config)
        let context = ModelContext(container)
        let record = MeetingRecord(meetingID: UUID().uuidString.lowercased())
        let apple = MeetingResult(
            transcriptRevision: 2, title: "Original", summary: "Reviewed summary",
            segments: [MeetingSegment(id: "apple", startMs: 0, endMs: 1_000, text: "Apple words")]
        )
        try record.replaceTranscriptionBase(apple, status: status)
        try record.update(audioManifest: MeetingAudioManifest(
            relativeDirectory: record.meetingID, sampleRate: 16_000,
            totalSamples: 16_000, parts: []
        ))
        context.insert(record)
        try context.save()
        return (context, record, apple)
    }

    private func output(revision: Int = 2) -> MeetingOfflineTranscriptionService.Output {
        MeetingOfflineTranscriptionService.Output(
            result: MeetingResult(
                transcriptRevision: revision + 1,
                segments: [MeetingSegment(id: "offline", startMs: 0, endMs: 1_000, text: "Offline words")]
            ),
            sourceTranscriptRevision: revision,
            detectedLanguages: ["en"]
        )
    }

    @Test("successful offline replacement preserves Apple raw evidence and releases the gate")
    func commitsWithoutErasingApple() async throws {
        let (context, record, apple) = try fixture()
        let manifest = try #require(record.audioManifest)
        let speakerPayload = try MeetingDiarizationPostProcessor.seed(
            record: record, source: apple,
            manifestDigest: MeetingDiarizationFingerprint.manifest(manifest),
            sourceDigest: MeetingDiarizationFingerprint.source(apple)
        )
        try record.update(diarization: speakerPayload)
        try context.save()
        let gate = MeetingDiarizationExecutionGate()
        let produced = output()
        let orchestrator = MeetingOfflineTranscriptionOrchestrator(gate: gate) { _, _, language in
            #expect(language == nil) // automatic detection, not the Apple language hint
            return produced
        }
        #expect(try await orchestrator.run(record: record, context: context) == .committed)
        #expect(record.result == produced.result)
        #expect(record.rawResult == produced.result)
        #expect(record.appleRawResult == apple)
        #expect(record.asrSource == .offline)
        #expect(record.asrModelRevision == MeetingWhisperManifest.modelRevision)
        #expect(record.asrDetectedLanguages == ["en"])
        #expect(record.status == .ready)
        #expect(record.offlineASRFailure == nil)
        #expect(record.diarizationData == nil)
        #expect(await gate.beginFinal()) // a subsequent speaker pass may start
        gate.endFinal()
    }

    @Test("failed offline inference keeps failed Apple finalization and allows explicit retry")
    func failureAndRetry() async throws {
        let (context, record, apple) = try fixture(status: .transcriptFinalizationFailed)
        let originalManifest = record.audioManifest
        let fail = MeetingOfflineTranscriptionOrchestrator(gate: MeetingDiarizationExecutionGate()) { _, _, _ in
            throw TestError.inference
        }
        await #expect(throws: TestError.inference) {
            try await fail.run(record: record, context: context)
        }
        #expect(record.result == apple)
        #expect(record.appleRawResult == apple)
        #expect(record.asrModelRevision == nil)
        #expect(record.asrDetectedLanguages.isEmpty)
        #expect(record.rawResult == apple)
        #expect(record.audioManifest == originalManifest)
        #expect(record.status == .transcriptFinalizationFailed)
        #expect(record.asrSource == .apple)
        #expect(record.offlineASRFailure == .transcriptionFailed)
        let produced = output()
        let retry = MeetingOfflineTranscriptionOrchestrator(gate: MeetingDiarizationExecutionGate()) { _, _, _ in produced }
        #expect(try await retry.run(record: record, context: context) == .committed)
        #expect(record.status == .ready)
        #expect(record.offlineASRFailure == nil)
        #expect(record.appleRawResult == apple)
    }

    @Test("missing local model records a safe failure without replacing Apple")
    func missingModelKeepsApple() async throws {
        let (context, record, apple) = try fixture()
        let orchestrator = MeetingOfflineTranscriptionOrchestrator(gate: MeetingDiarizationExecutionGate()) { _, _, _ in
            throw MeetingWhisperModelError.notInstalled
        }
        await #expect(throws: MeetingWhisperModelError.self) {
            try await orchestrator.run(record: record, context: context)
        }
        #expect(record.result == apple)
        #expect(record.rawResult == apple)
        #expect(record.appleRawResult == apple)
        #expect(record.asrSource == .apple)
        #expect(record.status == .ready)
        #expect(record.offlineASRFailure == .modelUnavailable)
    }

    @Test("failed save rolls back result, source, failure state and Apple snapshot together")
    func saveFailureRollsBack() async throws {
        let (context, record, _) = try fixture()
        record.offlineASRFailureRaw = MeetingOfflineASRFailure.modelUnavailable.rawValue
        let before = record.persistenceSnapshot()
        let produced = output()
        let orchestrator = MeetingOfflineTranscriptionOrchestrator(gate: MeetingDiarizationExecutionGate()) { _, _, _ in produced }
        await #expect(throws: TestError.save) {
            try await orchestrator.run(record: record, context: context, save: { _ in throw TestError.save })
        }
        #expect(record.persistenceSnapshot() == before)
    }

    @Test("user edit at a new revision supersedes in-flight ASR")
    func editedTranscriptWins() async throws {
        let (context, record, _) = try fixture()
        let probe = SuspendedOfflineASR()
        let produced = output()
        let orchestrator = MeetingOfflineTranscriptionOrchestrator(gate: MeetingDiarizationExecutionGate()) { _, _, _ in
            await probe.pause()
            return produced
        }
        let run = Task { try await orchestrator.run(record: record, context: context) }
        while !(await probe.started) { await Task.yield() }
        let revised = try MeetingTranscriptEditor.editText(
            result: record.result!, meetingID: record.meetingID, segmentID: "apple", text: "User corrected"
        )
        try record.update(result: revised)
        try context.save()
        let edited = record.persistenceSnapshot()
        await probe.resume()
        #expect(try await run.value == .superseded)
        #expect(record.persistenceSnapshot() == edited)
    }

    @Test("same-revision user summary changes also supersede in-flight ASR")
    func reviewedSummaryWins() async throws {
        let (context, record, _) = try fixture()
        let probe = SuspendedOfflineASR()
        let produced = output()
        let orchestrator = MeetingOfflineTranscriptionOrchestrator(gate: MeetingDiarizationExecutionGate()) { _, _, _ in
            await probe.pause()
            return produced
        }
        let run = Task { try await orchestrator.run(record: record, context: context) }
        while !(await probe.started) { await Task.yield() }
        var revised = try #require(record.result)
        revised.summary = "User reviewed the summary"
        try record.update(result: revised)
        try context.save()
        await probe.resume()
        #expect(try await run.value == .superseded)
        #expect(record.result?.summary == "User reviewed the summary")
        #expect(record.asrSource == .apple)
    }

    @Test("An edited child waiting behind a sibling keeps the queued source intent and is not automatically retranscribed")
    func queuedChildEditWins() async throws {
        let (context, second, apple) = try fixture()
        let queuedSecond = second.persistenceSnapshot()
        let first = MeetingRecord(meetingID: UUID().uuidString.lowercased())
        try first.replaceTranscriptionBase(apple, status: .ready)
        try first.update(audioManifest: MeetingAudioManifest(relativeDirectory: first.meetingID,
            sampleRate: 16_000, totalSamples: 16_000, parts: []))
        context.insert(first)
        try context.save()
        let probe = SuspendedOfflineASR()
        let produced = output()
        let firstPass = MeetingOfflineTranscriptionOrchestrator(gate: MeetingDiarizationExecutionGate()) { _, _, _ in
            await probe.pause()
            return produced
        }
        let running = Task { try await firstPass.run(record: first, context: context) }
        while !(await probe.started) { await Task.yield() }
        let corrected = try MeetingTranscriptEditor.editText(result: second.result!, meetingID: second.meetingID,
            segmentID: "apple", text: "Correction made while sibling runs")
        try second.update(result: corrected)
        try context.save()
        let edited = second.persistenceSnapshot()
        await probe.resume()
        #expect(try await running.value == .committed)
        let secondPass = MeetingOfflineTranscriptionOrchestrator(gate: MeetingDiarizationExecutionGate()) { _, _, _ in
            throw TestError.inference
        }
        #expect(try await secondPass.run(record: second, context: context, expectedSource: queuedSecond) == .superseded)
        #expect(second.persistenceSnapshot() == edited)
        #expect(second.result?.segments[0].text == "Correction made while sibling runs")
    }

    @Test("A speaker-name edit during offline inference cannot be erased by clearing stale annotations")
    func editedSpeakerMetadataWins() async throws {
        let (context, record, apple) = try fixture()
        let manifest = try #require(record.audioManifest)
        var payload = try MeetingDiarizationPostProcessor.seed(record: record, source: apple,
            manifestDigest: MeetingDiarizationFingerprint.manifest(manifest), sourceDigest: MeetingDiarizationFingerprint.source(apple))
        payload.profiles = [MeetingSpeakerProfile(id: "speaker", ordinal: 1, displayName: "Before")]
        try record.update(diarization: payload)
        try context.save()
        let probe = SuspendedOfflineASR()
        let produced = output()
        let orchestrator = MeetingOfflineTranscriptionOrchestrator(gate: MeetingDiarizationExecutionGate()) { _, _, _ in
            await probe.pause()
            return produced
        }
        let running = Task { try await orchestrator.run(record: record, context: context) }
        while !(await probe.started) { await Task.yield() }
        payload.profiles[0].displayName = "Renamed during inference"
        try record.update(diarization: payload)
        try context.save()
        let edited = record.persistenceSnapshot()
        await probe.resume()
        #expect(try await running.value == .superseded)
        #expect(record.persistenceSnapshot() == edited)
        #expect(record.diarization?.profiles[0].displayName == "Renamed during inference")
    }

    @Test("replaced manifest supersedes the in-flight transcription")
    func replacedManifestWins() async throws {
        let (context, record, apple) = try fixture()
        let probe = SuspendedOfflineASR()
        let produced = output()
        let orchestrator = MeetingOfflineTranscriptionOrchestrator(gate: MeetingDiarizationExecutionGate()) { _, _, _ in
            await probe.pause()
            return produced
        }
        let run = Task { try await orchestrator.run(record: record, context: context) }
        while !(await probe.started) { await Task.yield() }
        try record.update(audioManifest: MeetingAudioManifest(
            relativeDirectory: record.meetingID, sampleRate: 16_000, totalSamples: 32_000, parts: []
        ))
        try context.save()
        await probe.resume()
        #expect(try await run.value == .superseded)
        #expect(record.result == apple)
    }

    @Test("deleted meeting cannot receive offline output despite cached SwiftData fields")
    func deletedMeetingIsSuperseded() async throws {
        let (context, record, _) = try fixture()
        let id = record.meetingID
        let probe = SuspendedOfflineASR()
        let produced = output()
        let gate = MeetingDiarizationExecutionGate()
        let orchestrator = MeetingOfflineTranscriptionOrchestrator(gate: gate) { _, _, _ in
            await probe.pause()
            return produced
        }
        let run = Task { try await orchestrator.run(record: record, context: context) }
        while !(await probe.started) { await Task.yield() }
        context.delete(record)
        try context.save()
        // The deleted instance may still expose its old revision/result/manifest.
        await probe.resume()
        #expect(try await run.value == .superseded)
        let rows = try context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == id }))
        #expect(rows.isEmpty)
        #expect(await gate.beginFinal())
        gate.endFinal()
    }

    @Test("deletion cancellation drains inference and releases its execution gate")
    func cancellationDrainsOfflineRun() async throws {
        let (context, record, _) = try fixture()
        let probe = SuspendedOfflineASR()
        let produced = output()
        let gate = MeetingDiarizationExecutionGate()
        let orchestrator = MeetingOfflineTranscriptionOrchestrator(gate: gate) { _, _, _ in
            try await withTaskCancellationHandler {
                await probe.pause()
                try Task.checkCancellation()
                return produced
            } onCancel: {
                Task { await probe.noticeCancellation() }
            }
        }
        let run = Task { try await orchestrator.run(record: record, context: context) }
        while !(await probe.started) { await Task.yield() }
        let draining = Task { await MeetingOfflineTranscriptionOrchestrator.cancel(meetingID: record.meetingID) }
        while !(await probe.cancelled) { await Task.yield() }
        await probe.resume()
        await draining.value
        await #expect(throws: CancellationError.self) { try await run.value }
        context.delete(record)
        try context.save()
        #expect(await gate.beginFinal())
        gate.endFinal()
    }
}
