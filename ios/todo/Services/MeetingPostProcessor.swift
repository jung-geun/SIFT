import Foundation
import SwiftData

/// Shared post-transcription pipeline: optionally correct the transcript, then
/// analyze it into a summary, decisions, questions, and action candidates.
/// The caller establishes a durable raw base before entering this pipeline.
/// Each persisted stage commits independently so a later failure cannot erase
/// an already-saved transcription or leave in-memory state ahead of disk.
@MainActor
enum MeetingPostProcessor {
    enum Failure: LocalizedError, Equatable {
        case superseded

        var errorDescription: String? {
            AppLanguage.localized("meeting.error.changedDuringSummary", defaultValue: "The meeting changed during processing. Please try again.",
                                  language: .current, comment: "Meeting processing lost a race to an edit or deletion.")
        }
    }

    /// SwiftData can retain a deleted record's cached fields. Fetch the persisted
    /// row as well as comparing its source before committing a suspended pass.
    private static func requireCurrent(
        _ record: MeetingRecord, in context: ModelContext, revision: Int, data: Data,
        reporter: MeetingProcessingReporter? = nil
    ) throws {
        try Task.checkCancellation()
        let meetingID = record.meetingID
        let descriptor = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == meetingID })
        guard let persisted = try context.fetch(descriptor).first,
              persisted.persistentModelID == record.persistentModelID,
              persisted.transcriptRevision == revision, persisted.resultData == data,
              record.transcriptRevision == revision, record.resultData == data
        else {
            reporter?.reset()
            throw Failure.superseded
        }
    }

    private struct ProcessingLanguages {
        let sourceLanguageTag: String
        let savedSourceLanguageTag: String
        let automaticLanguageDetection: Bool
        let detectedLanguages: [String]
        let summaryLanguageTag: String

        init(record: MeetingRecord) {
            sourceLanguageTag = record.processingSourceLanguageTag
            savedSourceLanguageTag = record.languageTag
            automaticLanguageDetection = record.automaticLanguageDetection
            detectedLanguages = record.asrDetectedLanguages
            // Preserve the intentionally existing legacy output preference.
            // Actual source evidence must not change the requested summary language.
            summaryLanguageTag = MeetingSummaryLanguages.requestedLanguageTag(
                sourceLanguageTag: record.languageTag, savedSummaryLanguageTag: record.summaryLanguageTag
            )
        }
    }

    private static func requireLanguages(
        _ record: MeetingRecord, languages: ProcessingLanguages,
        reporter: MeetingProcessingReporter?
    ) throws {
        guard record.languageTag == languages.savedSourceLanguageTag,
              record.automaticLanguageDetection == languages.automaticLanguageDetection,
              record.asrDetectedLanguages == languages.detectedLanguages,
              MeetingSummaryLanguages.requestedLanguageTag(
                sourceLanguageTag: record.languageTag, savedSummaryLanguageTag: record.summaryLanguageTag
              ) == languages.summaryLanguageTag else {
            reporter?.reset()
            throw Failure.superseded
        }
    }

    struct Result {
        /// True when the correction pass actually changed the transcript.
        let refined: Bool
        /// Analysis engine label for the detail screen (empty if analysis skipped).
        let analysisLabel: String
        /// Number of segments the correction pass changed.
        let correctionCount: Int
    }

    struct Dependencies {
        let snapshot: () async -> UserVocabularySnapshot
        let refine: (
            _ meetingID: String,
            _ result: MeetingResult,
            _ vocabulary: UserVocabularySnapshot,
            _ sourceLanguageTag: String,
            _ language: AppLanguage,
            _ allowModelLoad: Bool
        ) async throws -> MeetingRefinementEngine.Outcome
        let analyze: (
            _ meetingID: String,
            _ result: MeetingResult,
            _ glossaryHint: String,
            _ sourceLanguageTag: String,
            _ summaryLanguageTag: String,
            _ language: AppLanguage
        ) async throws -> MeetingAnalysisEngine.Outcome
        let save: (_ context: ModelContext) throws -> Void
        let learnCorrections: (_ meetingID: String, _ pairs: [MeetingRefinementEngine.CorrectionPair]) async -> Void

        static var empty: Dependencies {
            Dependencies(
                snapshot: { .empty },
                refine: { meetingID, result, vocabulary, sourceLanguageTag, language, allowModelLoad in
                    try await MeetingRefinementEngine().refine(
                        meetingID: meetingID,
                        result: result,
                        vocabulary: vocabulary,
                        sourceLanguageTag: sourceLanguageTag,
                        language: language,
                        allowModelLoad: allowModelLoad
                    )
                },
                analyze: { meetingID, result, glossaryHint, sourceLanguageTag, summaryLanguageTag, language in
                    try await MeetingAnalysisEngine().analyze(
                        meetingID: meetingID,
                        result: result,
                        glossaryHint: glossaryHint,
                        sourceLanguageTag: sourceLanguageTag,
                        summaryLanguageTag: summaryLanguageTag,
                        language: language
                    )
                },
                save: { try $0.save() },
                learnCorrections: { _, _ in }
            )
        }
    }

    private static func displayEngineLabel(_ label: String, language: AppLanguage) -> String {
        let stored = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source = MeetingRefinementEngine.Source(rawValue: stored) {
            return source.displayName(language: language)
        }
        switch stored {
        case "Apple Intelligence 온디바이스", "Apple Intelligence (On Device)":
            return MeetingRefinementEngine.Source.appleIntelligence.displayName(language: language)
        case "온디바이스 LLM(Qwen)", "On-Device LLM (Qwen)":
            return MeetingRefinementEngine.Source.qwen.displayName(language: language)
        case "사용자 단어장", "User Vocabulary":
            return MeetingRefinementEngine.Source.userVocabulary.displayName(language: language)
        case "휴리스틱(오프라인)", "Offline Heuristic":
            return AppLanguage.localized(
                "meeting.engine.heuristic",
                defaultValue: language == .english ? "Offline Heuristic" : "휴리스틱(오프라인)",
                language: language,
                comment: "Meeting analysis fallback engine name"
            )
        default:
            return AppLanguage.localized(
                "meeting.engine.unknown",
                defaultValue: language == .english ? "Unknown Engine" : "알 수 없는 엔진",
                language: language,
                comment: "Unknown meeting engine label must not expose raw provenance."
            )
        }
    }

    private static func processingErrorMessage(language: AppLanguage) -> String {
        AppLanguage.localized(
            "meeting.error.processingFailed",
            defaultValue: language == .english ? "Meeting processing failed." : "회의 처리에 실패했습니다.",
            language: language,
            comment: "Generic meeting processing error shown after an internal failure"
        )
    }

    static func refineAndAnalyze(
        record: MeetingRecord,
        context: ModelContext,
        allowRefine: Bool,
        allowModelLoad: Bool,
        reporter: MeetingProcessingReporter? = nil,
        dependencies: Dependencies? = nil
    ) async throws -> Result {
        let dependencies = dependencies ?? .empty
        let languages = ProcessingLanguages(record: record)
        let sourceLanguageTag = languages.sourceLanguageTag
        let summaryLanguageTag = languages.summaryLanguageTag
        let language = AppLanguage.current
        guard let base = record.result else {
            reporter?.reset()
            return Result(refined: false, analysisLabel: "", correctionCount: 0)
        }
        var result = base
        let meetingID = record.meetingID
        var sourceRevision = base.transcriptRevision
        var sourceData = record.resultData
        try requireCurrent(record, in: context, revision: sourceRevision, data: sourceData, reporter: reporter)
        var refined = false
        var correctionCount = 0
        var proofreadOutcome: MeetingProcessingReporter.ProofreadOutcome = base.segments.isEmpty
            ? .skipped(reason: .emptyTranscript)
            : .skipped(reason: .disabled)
        var proofreadEngine = ""

        if allowRefine, !base.segments.isEmpty {
            if let planned = MeetingRefinementEngine().plannedEngine(allowModelLoad: allowModelLoad) {
                proofreadEngine = planned.displayName(language: .current)
                reporter?.set(.proofreading(engine: proofreadEngine))
            }
            do {
                let vocabulary = await dependencies.snapshot()
                try requireCurrent(record, in: context, revision: sourceRevision, data: sourceData, reporter: reporter)
                try requireLanguages(record, languages: languages, reporter: reporter)
                let outcome = try await dependencies.refine(
                    record.meetingID,
                    result,
                    vocabulary,
                    sourceLanguageTag,
                    language,
                    allowModelLoad
                )
                try requireCurrent(record, in: context, revision: sourceRevision, data: sourceData, reporter: reporter)
                try requireLanguages(record, languages: languages, reporter: reporter)
                if case .rules(let reason) = outcome.executionPath {
                    record.refinementFallbackReasonRaw = reason.rawValue
                } else {
                    record.refinementFallbackReasonRaw = nil
                }
                if let reason = outcome.skipReason {
                    proofreadOutcome = .skipped(reason: reason)
                    try dependencies.save(context)
                } else if let source = outcome.source {
                    let refinedResult = outcome.result
                    let changed = outcome.changed
                    let correctionPairs = outcome.correctionPairs
                    let engineLabel = source.displayName(language: .current)
                    proofreadEngine = engineLabel
                    let count = MeetingProofread.corrections(raw: base, current: refinedResult).count
                    do {
                        let committedData = try await MeetingRefinementCommitter.commit(
                            record: record,
                            result: refinedResult,
                            changed: changed,
                            source: source,
                            correctionPairs: correctionPairs,
                            save: { try dependencies.save(context) },
                            learnCorrections: { pairs in
                                await dependencies.learnCorrections(record.meetingID, pairs)
                            }
                        )
                        sourceRevision = changed ? refinedResult.transcriptRevision : sourceRevision
                        sourceData = committedData
                        try requireCurrent(record, in: context, revision: sourceRevision, data: sourceData, reporter: reporter)
                        try requireLanguages(record, languages: languages, reporter: reporter)
                        result = refinedResult
                        refined = changed
                        correctionCount = changed ? count : 0
                        proofreadOutcome = changed
                            ? .changed(count: correctionCount, engine: engineLabel)
                            : .unchanged(engine: engineLabel)
                    } catch Failure.superseded {
                        throw Failure.superseded
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        result = base
                        refined = false
                        correctionCount = 0
                        proofreadOutcome = .failed(
                            engine: engineLabel,
                            message: Self.processingErrorMessage(language: .current)
                        )
                    }
                }
            } catch Failure.superseded {
                reporter?.reset()
                throw Failure.superseded
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try requireCurrent(record, in: context, revision: sourceRevision, data: sourceData, reporter: reporter)
                try requireLanguages(record, languages: languages, reporter: reporter)
                let reason = ProviderErrorMapper.fallbackReason(for: error) ?? .providerExecutionFailed
                record.refinementFallbackReasonRaw = reason.rawValue
                try? dependencies.save(context)
                result = base
                refined = false
                correctionCount = 0
                proofreadOutcome = .failed(
                    engine: proofreadEngine.isEmpty ? nil : proofreadEngine,
                    message: Self.processingErrorMessage(language: .current)
                )
            }
        }

        reporter?.set(.summarizing(engine: ""))
        let analysisHint = (await dependencies.snapshot()).promptHint
        try requireCurrent(record, in: context, revision: sourceRevision, data: sourceData, reporter: reporter)
        try requireLanguages(record, languages: languages, reporter: reporter)
        let analysis = try await dependencies.analyze(
            meetingID, result, analysisHint, sourceLanguageTag, summaryLanguageTag, language
        )
        do {
            try requireCurrent(record, in: context, revision: sourceRevision, data: sourceData, reporter: reporter)
            try requireLanguages(record, languages: languages, reporter: reporter)
        } catch Failure.superseded {
            reporter?.reset()
            throw Failure.superseded
        }
        let analysisLabel = analysis.engineSource?.displayName(language: .current)
            ?? AppLanguage.localized(
                "meeting.engine.unknown",
                defaultValue: "Unknown Engine",
                language: .current,
                comment: "Unknown meeting engine provenance shown in the current app language."
            )
        let attributedResult = MeetingActionAttribution.applying(to: analysis.result, meetingID: meetingID,
            profiles: record.diarization?.profiles ?? [])
        do {
            try MeetingRecordCommitter.persist(
                record: record,
                save: { try dependencies.save(context) },
                mutate: {
                    try record.update(result: attributedResult, status: .ready)
                    record.summaryKindRaw = analysis.summaryKind.rawValue
                    record.summaryEngineLabel = analysis.engineSource?.rawValue ?? ""
                    record.summaryResultLanguageTag = analysis.summaryKind == .generated ? summaryLanguageTag : sourceLanguageTag
                    if case .rules(let reason) = analysis.executionPath {
                        record.summaryFallbackReasonRaw = reason.rawValue
                    } else {
                        record.summaryFallbackReasonRaw = nil
                    }
                }
            )
        } catch {
            // Never report `.completed` when the final persist failed — the
            // documented invariant on `Phase.completed` is "never a
            // fabricated success." Leave the reporter idle; the caller
            // surfaces the real failure via its own error path.
            reporter?.reset()
            throw error
        }

        reporter?.set(.completed(proofread: proofreadOutcome, analysisEngine: analysisLabel))
        return Result(refined: refined, analysisLabel: analysisLabel, correctionCount: correctionCount)
    }
}
@MainActor
enum MeetingRefinementCommitter {
    static func commit(
        record: MeetingRecord,
        result: MeetingResult,
        changed: Bool,
        source: MeetingRefinementEngine.Source,
        correctionPairs: [MeetingRefinementEngine.CorrectionPair],
        save: () throws -> Void,
        learnCorrections: @escaping ([MeetingRefinementEngine.CorrectionPair]) async -> Void
    ) async throws -> Data {
        try MeetingRecordCommitter.persist(
            record: record,
            save: save,
            mutate: {
                if changed {
                    try record.update(result: result, status: .ready)
                } else {
                    record.updatedAt = Date()
                }
                record.refinementEngineLabel = source.rawValue
            }
        )
        let committedData = record.resultData
        await learnCorrections(correctionPairs)
        return committedData
    }
}
