import Foundation

/// Runs the transcript-correction ("검수") pass at recording completion /
/// re-transcription (not in real time), then bumps the transcript to a new
/// revision. The corrected transcript feeds a higher-quality summary, and the
/// (raw → corrected) diff seeds the personalized glossary — zero extra model calls.
///
/// Engine selection (on-device only):
///   1. Apple Foundation Models (AFM / ANE) when available — preferred.
///   2. Otherwise the on-device MLX LLM (Qwen), but only when its model is
///      already loaded, or (for explicit foreground actions) already downloaded —
///      never triggers a surprise download, and honors the "MLX foreground only"
///      invariant.
///   3. If neither is available, the transcript is returned unchanged and the UI
///      shows an honest "on-device AI unavailable" state.
@MainActor
struct MeetingRefinementEngine {
    typealias CorrectionPair = (from: String, to: String)

    nonisolated enum Source: String, Sendable {
        case appleIntelligence = "apple-intelligence"
        case qwen = "qwen"
        case userVocabulary = "user-vocabulary"

        func displayName(language: AppLanguage) -> String {
            switch self {
            case .appleIntelligence:
                return AppLanguage.localized(
                    "meeting.engine.afm",
                    defaultValue: language == .english ? "Apple Intelligence (On Device)" : "Apple Intelligence 온디바이스",
                    language: language,
                    comment: "Meeting transcript correction or analysis engine name"
                )
            case .qwen:
                return AppLanguage.localized(
                    "meeting.engine.qwen",
                    defaultValue: language == .english ? "On-Device LLM (Qwen)" : "온디바이스 LLM(Qwen)",
                    language: language,
                    comment: "Meeting transcript correction or analysis engine name"
                )
            case .userVocabulary:
                return AppLanguage.localized(
                    "meeting.engine.userVocabulary",
                    defaultValue: language == .english ? "User Vocabulary" : "사용자 단어장",
                    language: language,
                    comment: "Meeting transcript correction provenance"
                )
            }
        }
    }

    enum Outcome {
        case skipped(MeetingProcessingReporter.SkipReason)
        case applied(
            result: MeetingResult,
            changed: Bool,
            source: Source,
            correctionPairs: [CorrectionPair],
            providerRan: Bool
        )
    }

    enum RefinementError: LocalizedError {
        case engineUnavailable
        case localModelUnavailable
        case invalidModelResponse

        var errorDescription: String? {
            switch self {
            case .engineUnavailable, .localModelUnavailable:
                return AppLanguage.localized(
                    "meeting.error.engineUnavailable",
                    defaultValue: "AI 검수 엔진을 준비하지 못했습니다.",
                    language: .current,
                    comment: "Meeting proofreading unavailable error"
                )
            case .invalidModelResponse:
                return AppLanguage.localized(
                    "meeting.error.invalidModelResponse",
                    defaultValue: "AI 검수 결과를 해석하지 못했습니다.",
                    language: .current,
                    comment: "Meeting proofreading invalid result error"
                )
            }
        }
    }

    enum Engine {
        case afm
        case localLLM

        var source: Source {
            switch self {
            case .afm: .appleIntelligence
            case .localLLM: .qwen
            }
        }

        func displayName(language: AppLanguage) -> String {
            source.displayName(language: language)
        }
    }

    /// The engine that *would* run, for pre-run UI. `allowModelLoad` should be
    /// true only for explicit foreground actions (the manual "improve" button),
    /// where loading an already-downloaded model is acceptable.
    func plannedEngine(allowModelLoad: Bool) -> Engine? {
        if #available(iOS 26.0, *), FoundationModelsAvailability.isAvailable { return .afm }
        let llm = OnDeviceLLMService.shared
        if llm.isModelLoaded { return .localLLM }
        if allowModelLoad, llm.isCapable, llm.isModelCachedOnDisk { return .localLLM }
        return nil
    }

    func refine(
        meetingID: String,
        result: MeetingResult,
        vocabulary: UserVocabularySnapshot,
        language: AppLanguage,
        allowModelLoad: Bool
    ) async throws -> Outcome {
        guard !result.segments.isEmpty else {
            return .skipped(.emptyTranscript)
        }

        var mapped = result.segments
        let canonicalizer = UserVocabularyCanonicalizer(snapshot: vocabulary)
        for index in mapped.indices {
            mapped[index].text = canonicalizer.canonicalize(mapped[index].text)
        }
        let mappingChanged = mapped.map(\.text) != result.segments.map(\.text)
        guard let engine = plannedEngine(allowModelLoad: allowModelLoad) else {
            guard mappingChanged else {
                let llm = OnDeviceLLMService.shared
                if !allowModelLoad, llm.isCapable, llm.isModelCachedOnDisk {
                    return .skipped(.modelNotLoaded)
                }
                return .skipped(.unavailable)
            }
            return .applied(
                result: try MeetingRevisionEditor.editSegments(meetingID: meetingID, in: result, segments: mapped),
                changed: true,
                source: .userVocabulary,
                correctionPairs: [],
                providerRan: false
            )
        }

        let corrected: [MeetingSegment]
        switch engine {
        case .afm:
            guard #available(iOS 26.0, *) else { throw RefinementError.engineUnavailable }
            let batchResult = try await FoundationModelsService()
                .correctTranscript(
                    segments: mapped,
                    glossaryHint: vocabulary.promptHint,
                    language: language
                )
            guard batchResult.succeededBatchCount > 0 || batchResult.failedBatchCount == 0 else {
                throw RefinementError.invalidModelResponse
            }
            corrected = batchResult.segments
        case .localLLM:
            corrected = try await correctViaLocalLLM(
                segments: mapped,
                glossaryHint: vocabulary.promptHint,
                language: language,
                allowModelLoad: allowModelLoad
            )
        }

        guard corrected.map(\.text) != result.segments.map(\.text) else {
            return .applied(
                result: result,
                changed: false,
                source: engine.source,
                correctionPairs: [],
                providerRan: true
            )
        }
        let refined = try MeetingRevisionEditor.editSegments(
            meetingID: meetingID,
            in: result,
            segments: corrected
        )
        let pairs = zip(mapped, corrected).flatMap { original, fixed in
            UserVocabularyService.replacementPairs(before: original.text, after: fixed.text)
        }
        return .applied(
            result: refined,
            changed: true,
            source: engine.source,
            correctionPairs: pairs,
            providerRan: true
        )
    }

    // MARK: - On-device LLM correction (AFM 미가용 폴백)

    private func correctViaLocalLLM(
        segments: [MeetingSegment],
        glossaryHint: String,
        language: AppLanguage,
        allowModelLoad: Bool
    ) async throws -> [MeetingSegment] {
        let llm = OnDeviceLLMService.shared
        if !llm.isModelLoaded {
            guard allowModelLoad, llm.isCapable, llm.isModelCachedOnDisk else {
                throw RefinementError.localModelUnavailable
            }
            await llm.loadModelIfNeeded()
        }
        guard llm.isModelLoaded else { throw RefinementError.localModelUnavailable }

        var batches = [[Int]]()
        var current = [Int]()
        var used = 0
        for index in segments.indices {
            let lineLen = segments[index].text.count + 8
            if used + lineLen > 1_500, !current.isEmpty {
                batches.append(current); current = []; used = 0
            }
            current.append(index); used += lineLen
        }
        if !current.isEmpty { batches.append(current) }

        let glossaryBlock = Self.glossaryBlock(glossaryHint, language: language)
        var corrected = segments
        for batch in batches {
            let numbered = batch.enumerated()
                .map { "\($0.offset + 1). \(segments[$0.element].text)" }
                .joined(separator: "\n")
            let userPrompt = """
            \(glossaryBlock)[전사 구간]
            \(numbered)

            \(Prompts.MeetingCorrectionLocal.requestSuffix(language: language))
            """
            let raw = try await llm.generate(
                systemPrompt: Prompts.MeetingCorrectionLocal.systemInstruction(language: language),
                userPrompt: userPrompt,
                maxTokens: 700
            )
            guard let parsed = Self.parseLocalCorrections(raw) else {
                throw RefinementError.invalidModelResponse
            }
            for correction in parsed {
                let local = correction.n - 1
                guard local >= 0, local < batch.count else { continue }
                let globalIndex = batch[local]
                let newText = correction.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard MeetingCorrectionGuard.isAcceptable(old: segments[globalIndex].text, new: newText) else { continue }
                corrected[globalIndex].text = newText
            }
        }
        return corrected
    }

    private static func glossaryBlock(_ hint: String, language: AppLanguage) -> String {
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let label = AppLanguage.localized(
            "meeting.glossary.label",
            defaultValue: language == .english ? "User Vocabulary" : "사용자 단어장",
            language: language,
            comment: "Meeting prompt glossary section label"
        )
        return "[\(label)]\n\(trimmed)\n\n"
    }

    private struct LocalCorrection: Decodable {
        let n: Int
        let text: String
    }

    private struct LocalCorrectionPayload: Decodable {
        let corrections: [LocalCorrection]
    }

    /// Tolerant JSON extraction (first `{` … last `}`), mirroring the existing
    /// MLX-output decoding in `MemoryService`.
    private static func parseLocalCorrections(_ raw: String) -> [LocalCorrection]? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.range(of: "{"), let last = trimmed.range(of: "}", options: .backwards) {
            trimmed = String(trimmed[first.lowerBound..<last.upperBound])
        }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(LocalCorrectionPayload.self, from: data))?.corrections
    }
}
