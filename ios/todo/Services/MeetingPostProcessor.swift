import Foundation
import SwiftData

/// Shared post-transcription pipeline: optionally correct the transcript, then
/// analyze it into a summary, decisions, questions, and action candidates.
/// The caller establishes a durable raw base before entering this pipeline.
/// Each persisted stage commits independently so a later failure cannot erase
/// an already-saved transcription or leave in-memory state ahead of disk.
@MainActor
enum MeetingPostProcessor {
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
            _ language: AppLanguage,
            _ allowModelLoad: Bool
        ) async throws -> MeetingRefinementEngine.Outcome
        let analyze: (
            _ meetingID: String,
            _ result: MeetingResult,
            _ glossaryHint: String,
            _ language: AppLanguage
        ) async -> MeetingAnalysisEngine.Outcome
        let save: (_ context: ModelContext) throws -> Void
        let learnCorrections: (_ meetingID: String, _ pairs: [MeetingRefinementEngine.CorrectionPair]) async -> Void

        static var empty: Dependencies {
            Dependencies(
                snapshot: { .empty },
                refine: { meetingID, result, vocabulary, language, allowModelLoad in
                    try await MeetingRefinementEngine().refine(
                        meetingID: meetingID,
                        result: result,
                        vocabulary: vocabulary,
                        language: language,
                        allowModelLoad: allowModelLoad
                    )
                },
                analyze: { meetingID, result, glossaryHint, language in
                    await MeetingAnalysisEngine().analyze(
                        meetingID: meetingID,
                        result: result,
                        glossaryHint: glossaryHint,
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
        let language = AppLanguage.resolve(languageTag: record.languageTag)
        guard let base = record.result else {
            reporter?.reset()
            return Result(refined: false, analysisLabel: "", correctionCount: 0)
        }
        var result = base
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
                let outcome = try await dependencies.refine(
                    record.meetingID,
                    result,
                    vocabulary,
                    language,
                    allowModelLoad
                )
                switch outcome {
                case .skipped(let reason):
                    proofreadOutcome = .skipped(reason: reason)
                case .applied(let refinedResult, let changed, let source, let correctionPairs, _):
                    let engineLabel = source.displayName(language: .current)
                    proofreadEngine = engineLabel
                    let count = MeetingProofread.corrections(raw: base, current: refinedResult).count
                    do {
                        try await MeetingRefinementCommitter.commit(
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
                        result = refinedResult
                        refined = changed
                        correctionCount = changed ? count : 0
                        proofreadOutcome = changed
                            ? .changed(count: correctionCount, engine: engineLabel)
                            : .unchanged(engine: engineLabel)
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
            } catch {
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
        let analysis = await dependencies.analyze(record.meetingID, result, analysisHint, language)
        let analysisLabel = analysis.engineSource?.displayName(language: .current)
            ?? AppLanguage.localized(
                "meeting.engine.unknown",
                defaultValue: "Unknown Engine",
                language: .current,
                comment: "Unknown meeting engine provenance shown in the current app language."
            )
        do {
            try MeetingRecordCommitter.persist(
                record: record,
                save: { try dependencies.save(context) },
                mutate: { try record.update(result: analysis.result, status: .ready) }
            )
        } catch {
            reporter?.set(.completed(proofread: proofreadOutcome, analysisEngine: analysisLabel))
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
    ) async throws {
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
        await learnCorrections(correctionPairs)
    }
}
