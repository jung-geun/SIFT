import Foundation
import SwiftData

/// The saved FLAC is the only input to offline ASR. The gate covers model load,
/// inference and unload, but is released before any speaker replay or AI pass.
@MainActor
struct MeetingOfflineTranscriptionOrchestrator {
    enum Outcome: Equatable {
        case committed
        case superseded
    }

    enum Failure: LocalizedError {
        case missingAudioOrTranscript, busy, invalidOutput

        var errorDescription: String? { errorDescription(language: .current) }

        func errorDescription(language: AppLanguage) -> String {
            let key: String
            let english: String
            switch self {
            case .missingAudioOrTranscript:
                key = "meeting.offlineTranscription.error.missingAudioOrTranscript"
                english = "The saved recording or transcript is unavailable."
            case .busy:
                key = "meeting.offlineTranscription.error.busy"
                english = "Another recording is using the on-device audio model. Try again after it ends."
            case .invalidOutput:
                key = "meeting.offlineTranscription.error.invalidOutput"
                english = "Offline transcription returned an invalid transcript."
            }
            return AppLanguage.localized(key, defaultValue: english, language: language,
                                         comment: "Saved-audio transcription orchestration error.")
        }
    }

    typealias Transcribe = @Sendable (MeetingAudioManifest, Int, String?) async throws -> MeetingOfflineTranscriptionService.Output

    private let gate: MeetingDiarizationExecutionGate
    private let transcribe: Transcribe?
    private static var runs: [String: Task<Outcome, Error>] = [:]

    /// Deletion waits until inference has unloaded and released the execution gate.
    static func cancel(meetingID: String) async {
        guard let task = runs[meetingID] else { return }
        task.cancel()
        _ = try? await task.value
    }


    init(
        gate: MeetingDiarizationExecutionGate? = nil,
        transcribe: Transcribe? = nil
    ) {
        self.gate = gate ?? .shared
        self.transcribe = transcribe
    }

    /// Call after persisting an Apple base (including a failed-finalization
    /// provisional base). A failed attempt keeps that base, status, manifest and
    /// raw Apple snapshot; only a safe failure code is persisted. A successful
    /// attempt commits the new raw base and clears stale speaker annotations.
    /// No diarization/refinement is started here: the caller runs those *after*
    /// this returns, when both the gate and Whisper's deletion lease are free.
    func run(
        record: MeetingRecord,
        context: ModelContext,
        languageTag: String? = nil,
        expectedSource: MeetingRecord.PersistenceSnapshot? = nil,
        reporter: MeetingProcessingReporter? = nil,
        save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) async throws -> Outcome {
        let id = record.meetingID
        guard Self.runs[id] == nil else { throw Failure.busy }
        let sourceSnapshot = expectedSource ?? record.persistenceSnapshot()
        reporter?.startTranscribing(totalMilliseconds: (record.audioManifest?.totalSamples ?? 0) / 16)
        let task = Task {
            try await execute(record: record, context: context, sourceSnapshot: sourceSnapshot,
                              languageTag: languageTag, reporter: reporter, save: save)
        }
        Self.runs[id] = task
        defer { Self.runs[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func execute(
        record: MeetingRecord,
        context: ModelContext,
        sourceSnapshot: MeetingRecord.PersistenceSnapshot,
        languageTag: String?,
        reporter: MeetingProcessingReporter?,
        save: @MainActor (ModelContext) throws -> Void
    ) async throws -> Outcome {
        guard matches(record, in: context, sourceSnapshot: sourceSnapshot) else { return .superseded }
        guard let manifest = record.audioManifest, let source = record.result else {
            throw Failure.missingAudioOrTranscript
        }
        guard source.transcriptRevision >= 0,
              source.transcriptRevision < MeetingCanonicalID.maximumSafeInteger else {
            throw Failure.invalidOutput
        }
        let sourceData = record.resultData
        let sourceRevision = source.transcriptRevision

        // An idle live prewarmer must not block an explicitly requested pass.
        await MeetingLiveSpeakerPrewarmer.shared.releaseUnused()
        guard await gate.beginFinal() else {
            try Task.checkCancellation()
            throw Failure.busy
        }
        let output: MeetingOfflineTranscriptionService.Output
        do {
            try Task.checkCancellation()
            guard matches(record, in: context, sourceSnapshot: sourceSnapshot) else {
                gate.endFinal()
                return .superseded
            }
        } catch {
            gate.endFinal()
            throw error
        }
        do {
            // This scope ends (including unload and gate release) before commit
            // or a subsequent final diarization pass can begin.
            output = try await performTranscription(manifest: manifest, revision: sourceRevision,
                                                    languageTag: languageTag, reporter: reporter)
            gate.endFinal()
        } catch {
            gate.endFinal()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if matches(record, in: context, sourceSnapshot: sourceSnapshot) {
                let failure: MeetingOfflineASRFailure = error is MeetingWhisperModelError
                    ? .modelUnavailable : .transcriptionFailed
                try MeetingRecordCommitter.persist(record: record, save: { try save(context) }) {
                    record.offlineASRFailureRaw = failure.rawValue
                    record.updatedAt = Date()
                }
            }
            throw error
        }
        try Task.checkCancellation()
        guard matches(record, in: context, sourceSnapshot: sourceSnapshot) else { return .superseded }
        let result: MeetingResult
        do {
            guard output.sourceTranscriptRevision == sourceRevision,
                  output.result.transcriptRevision == sourceRevision + 1 else {
                throw Failure.invalidOutput
            }
            result = try output.result.validated()
        } catch {
            try MeetingRecordCommitter.persist(record: record, save: { try save(context) }) {
                record.offlineASRFailureRaw = MeetingOfflineASRFailure.transcriptionFailed.rawValue
                record.updatedAt = Date()
            }
            throw Failure.invalidOutput
        }
        reporter?.updateTranscription(.init(.validating))
        try MeetingRecordCommitter.persist(record: record, save: { try save(context) }) {
            if record.appleRawResultData == nil && record.asrSource == .apple {
                record.appleRawResultData = record.rawResultData ?? sourceData
            }
            try record.replaceTranscriptionBase(
                result, status: .ready, source: .offline,
                modelRevision: MeetingWhisperManifest.modelRevision,
                detectedLanguages: output.detectedLanguages
            )
            try record.update(diarization: nil)
        }
        return .committed
    }

    private func performTranscription(
        manifest: MeetingAudioManifest, revision: Int, languageTag: String?,
        reporter: MeetingProcessingReporter?
    ) async throws -> MeetingOfflineTranscriptionService.Output {
        if let transcribe { return try await transcribe(manifest, revision, languageTag) }
        // One bounded consumer instead of an unstructured main-actor task for
        // every SDK token. Finish it before the caller can start another phase.
        let (updates, continuation) = AsyncStream<MeetingTranscriptionProgress.Update>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let observing = Task {
            for await update in updates { reporter?.updateTranscription(update) }
        }
        do {
            let output = try await MeetingOfflineTranscriptionService().transcribe(
                manifest: manifest, sourceTranscriptRevision: revision, languageTag: languageTag,
                progress: { continuation.yield($0) }
            )
            continuation.finish()
            await observing.value
            return output
        } catch {
            continuation.finish()
            await observing.value
            throw error
        }
    }

    private func matches(
        _ record: MeetingRecord, in context: ModelContext,
        sourceSnapshot: MeetingRecord.PersistenceSnapshot
    ) -> Bool {
        liveRecord(record, in: context) != nil && record.persistenceSnapshot() == sourceSnapshot
    }

    private func liveRecord(_ record: MeetingRecord, in context: ModelContext) -> MeetingRecord? {
        let id = record.meetingID
        let descriptor = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == id })
        guard let latest = try? context.fetch(descriptor).first,
              latest.persistentModelID == record.persistentModelID else { return nil }
        return latest
    }
}
