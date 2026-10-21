import Foundation

/// Analyzes transcripts only with a selected, enabled on-device provider.
/// Unsupported/unavailable providers return source excerpts, never a fake translation.
@MainActor
struct MeetingAnalysisEngine {

    enum AnalysisSource: String, Sendable {
        case appleIntelligence = "apple-intelligence"
        case qwen = "qwen"
        case heuristic = "heuristic"

        func displayName(language: AppLanguage) -> String {
            switch self {
            case .appleIntelligence:
                return MeetingRefinementEngine.Source.appleIntelligence.displayName(language: language)
            case .qwen:
                return MeetingRefinementEngine.Source.qwen.displayName(language: language)
            case .heuristic:
                return AppLanguage.localized(
                    "meeting.engine.heuristic",
                    defaultValue: language == .english ? "Offline Heuristic" : "휴리스틱(오프라인)",
                    language: language,
                    comment: "Meeting analysis fallback engine name"
                )
            }
        }
    }
    enum SummaryKind: String, Sendable {
        case generated
        case sourceExcerpts
    }


    struct Outcome {
        let result: MeetingResult
        /// Human-readable engine name retained for compatibility with analysis callers.
        /// UI reporters should use engineSource and localize in the app language.
        let engineLabel: String
        let usedOnDeviceLLM: Bool
        let engineSource: AnalysisSource?
        let executionPath: AnalysisExecutionPath
        var summaryKind: SummaryKind { usedOnDeviceLLM ? .generated : .sourceExcerpts }

        init(
            result: MeetingResult,
            engineLabel: String,
            usedOnDeviceLLM: Bool,
            engineSource: AnalysisSource? = nil,
            executionPath: AnalysisExecutionPath = .rules(.noProviderOptIn)
        ) {
            self.result = result
            self.engineLabel = engineLabel
            self.usedOnDeviceLLM = usedOnDeviceLLM
            self.engineSource = engineSource
            self.executionPath = executionPath
        }
    }

    private let heuristic = MeetingTranscriptAnalysisService()
    private let localLLM: OnDeviceLLMService
    private let policy: BetaFeaturePolicy

    init(localLLM: OnDeviceLLMService? = nil, policy: BetaFeaturePolicy = BetaFeaturePolicy()) {
        self.localLLM = localLLM ?? .shared
        self.policy = policy
    }

    func analyze(
        meetingID: String,
        result: MeetingResult,
        glossaryHint: String = "",
        sourceLanguageTag: String,
        summaryLanguageTag: String,
        language: AppLanguage = .current
    ) async throws -> Outcome {
        let decision = policy.routingDecision(for: .meetingAnalysis)
        guard case .providers(let providers) = decision, let provider = providers.first else {
            let reason: RuleFallbackReason
            if case .rules(let fallback) = decision {
                reason = fallback
            } else {
                reason = .noEligibleProvider
            }
            return heuristicOutcome(
                meetingID: meetingID,
                result: result,
                language: language,
                reason: reason
            )
        }

        do {
            if let outcome = try await analyze(
                provider: provider,
                meetingID: meetingID,
                result: result,
                glossaryHint: glossaryHint,
                sourceLanguageTag: sourceLanguageTag,
                summaryLanguageTag: summaryLanguageTag,
                language: language
            ) {
                return outcome
            }
            throw IntelligenceRoutingError.parseFailed(
                provider: provider,
                reason: "Meeting provider returned no analysis."
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return heuristicOutcome(
                meetingID: meetingID,
                result: result,
                language: language,
                reason: ProviderErrorMapper.fallbackReason(for: error) ?? .providerExecutionFailed
            )
        }
    }

    private func heuristicOutcome(
        meetingID: String,
        result: MeetingResult,
        language: AppLanguage,
        reason: RuleFallbackReason
    ) -> Outcome {
        var excerpts = heuristic.analyze(meetingID: meetingID, result: result, language: language)
        excerpts.title = result.segments.first.map { String($0.text.prefix(80)) } ?? ""
        excerpts.summary = result.segments.prefix(8).map(\.text).joined(separator: "\n")
        excerpts.decisions = []
        excerpts.unresolvedQuestions = []
        // Rule action candidates retain their source evidence, without UI-language prose.
        for index in excerpts.actionDrafts.indices {
            let sourceID = excerpts.actionDrafts[index].sourceSegmentIDs.first
            excerpts.actionDrafts[index].notes = result.segments.first { $0.id == sourceID }?.text ?? ""
        }
        return Outcome(
            result: excerpts,
            engineLabel: AnalysisSource.heuristic.displayName(language: language),
            usedOnDeviceLLM: false,
            engineSource: .heuristic,
            executionPath: .rules(reason)
        )
    }

    private func analyze(
        provider: PersonaAIProvider,
        meetingID: String,
        result: MeetingResult,
        glossaryHint: String,
        sourceLanguageTag: String,
        summaryLanguageTag: String,
        language: AppLanguage
    ) async throws -> Outcome? {
        switch provider {
        case .foundationModels:
            return try await analyzeViaFoundationModels(
                meetingID: meetingID,
                result: result,
                glossaryHint: glossaryHint,
                sourceLanguageTag: sourceLanguageTag,
                summaryLanguageTag: summaryLanguageTag,
                language: language
            )
        case .onDevice:
            guard let extraction = try await analyzeViaLocalLLM(
                segments: result.segments,
                glossaryHint: glossaryHint,
                sourceLanguageTag: sourceLanguageTag,
                summaryLanguageTag: summaryLanguageTag,
                language: language
            ) else { return nil }
            return Outcome(
                result: merge(extraction, into: result, meetingID: meetingID),
                engineLabel: MeetingRefinementEngine.Source.qwen.displayName(language: language),
                usedOnDeviceLLM: true,
                engineSource: .qwen,
                executionPath: .beta(.onDevice)
            )
        case .openAI, .laya:
            return nil
        }
    }
    private func analyzeViaFoundationModels(
        meetingID: String,
        result: MeetingResult,
        glossaryHint: String,
        sourceLanguageTag: String,
        summaryLanguageTag: String,
        language: AppLanguage
    ) async throws -> Outcome {
        guard #available(iOS 26.0, *), FoundationModelsAvailability.isAvailable else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .foundationModels,
                reason: RuleFallbackReason.unavailable.rawValue
            )
        }
        let extraction = try await FoundationModelsService()
            .analyzeMeeting(
                meetingID: meetingID,
                segments: result.segments,
                glossaryHint: glossaryHint,
                sourceLanguageTag: sourceLanguageTag,
                summaryLanguageTag: summaryLanguageTag,
                language: language
            )
        return Outcome(
            result: merge(extraction, into: result, meetingID: meetingID),
            engineLabel: MeetingRefinementEngine.Source.appleIntelligence.displayName(language: language),
            usedOnDeviceLLM: true,
            engineSource: .appleIntelligence,
            executionPath: .beta(.foundationModels)
        )
    }


    // MARK: - On-device LLM analysis

    /// Extracts title/summary/decisions/questions/actions with the MLX LLM, but
    /// only when its model is already loaded (no surprise download). Returns nil
    /// to continue routing.
    private func analyzeViaLocalLLM(
        segments: [MeetingSegment],
        glossaryHint: String,
        sourceLanguageTag: String,
        summaryLanguageTag: String,
        language: AppLanguage
    ) async throws -> ProviderMeetingExtraction? {
        let llm = localLLM
        guard llm.isModelLoaded, let loadedModelID = llm.loadedModelIdentifier,
              loadedModelID == llm.modelID else {
            throw OnDeviceLLMService.LLMError.modelNotLoaded
        }
        try MeetingSummaryLanguages.requireLocalModelSupport(
            modelID: loadedModelID,
            sourceLanguageTag: sourceLanguageTag,
            summaryLanguageTag: summaryLanguageTag
        )
        guard let context = buildTranscriptContext(
            segments: segments,
            glossaryHint: glossaryHint,
            transcriptCharCap: 3_000
        ) else {
            throw IntelligenceRoutingError.parseFailed(
                provider: .onDevice,
                reason: "Meeting transcript context is empty."
            )
        }

        let userPrompt = """
        \(context.glossaryBlock)[Transcript segments]
        \(context.numbered.joined(separator: "\n"))

        \(Prompts.MeetingAnalysisLocal.requestSuffix(sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: summaryLanguageTag))
        """
        let raw = try await llm.generate(
            systemPrompt: Prompts.MeetingAnalysisLocal.systemInstruction(sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: summaryLanguageTag),
            userPrompt: userPrompt,
            maxTokens: 900,
            use: .meetingAnalysis
        )
        guard let extraction = Self.extraction(from: raw, included: context.included) else {
            throw IntelligenceRoutingError.parseFailed(
                provider: .onDevice,
                reason: "On-device meeting response was invalid."
            )
        }
        return extraction

    }

    private struct TranscriptContext {
        let numbered: [String]
        let included: [MeetingSegment]
        let glossaryBlock: String
    }

    private func buildTranscriptContext(
        segments: [MeetingSegment],
        glossaryHint: String,
        transcriptCharCap: Int
    ) -> TranscriptContext? {
        var numbered = [String]()
        var included = [MeetingSegment]()
        var used = 0
        for segment in segments {
            let line = "\(included.count + 1). \(segment.text)"
            if used + line.count > transcriptCharCap, !included.isEmpty { break }
            numbered.append(line)
            included.append(segment)
            used += line.count
        }
        guard !included.isEmpty else { return nil }

        let glossaryBlock: String
        if glossaryHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            glossaryBlock = ""
        } else {
            glossaryBlock = "[User vocabulary]\n\(glossaryHint.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        }

        return TranscriptContext(numbered: numbered, included: included, glossaryBlock: glossaryBlock)
    }

    private struct AnalysisAction: Decodable {
        let n: Int
        let title: String
        let notes: String?
        let due: String?
    }

    private struct AnalysisPayload: Decodable {
        let title: String?
        let summary: String?
        let decisions: [String]?
        let questions: [String]?
        let actions: [AnalysisAction]?
    }

    /// Tolerant JSON extraction (first `{` … last `}`), mirroring the existing
    /// MLX-output decoding elsewhere in the app.
    private static func parseAnalysis(_ raw: String) -> AnalysisPayload? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.range(of: "{"), let last = trimmed.range(of: "}", options: .backwards) {
            trimmed = String(trimmed[first.lowerBound..<last.upperBound])
        }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnalysisPayload.self, from: data)
    }

    private static func extraction(from raw: String, included: [MeetingSegment]) -> ProviderMeetingExtraction? {
        guard let payload = parseAnalysis(raw) else { return nil }

        let drafts: [ProviderActionDraftInput] = (payload.actions ?? []).compactMap { action -> ProviderActionDraftInput? in
            let index = action.n - 1
            guard index >= 0, index < included.count else { return nil }
            let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let due = (action.due ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ProviderActionDraftInput(
                title: title,
                notes: (action.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                assignee: nil,
                dueAtISO8601: due.isEmpty ? nil : canonicalDueDate(due),
                sourceSegmentIDs: [included[index].id],
                confidence: 0.6,
                requiresReview: true
            )
        }
        return ProviderMeetingExtraction(
            title: (payload.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            summary: (payload.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: (payload.decisions ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            unresolvedQuestions: (payload.questions ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            actionDrafts: drafts
        )
    }

    /// Converts model dates to the canonical UTC contract. Model output without
    /// an explicit timezone, malformed dates, and impossible dates are treated
    /// as absent rather than reaching MeetingCanonicalID's precondition.
    static func canonicalDueDate(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#,
            options: .regularExpression
        ) != nil else { return nil }

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = parser.date(from: trimmed) ?? AppDateFormat.parseLLMDate(trimmed) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }

    /// Fills summary/decisions/questions and canonical-ID action drafts while
    /// preserving the transcript revision and segments untouched.
    private func merge(_ extraction: ProviderMeetingExtraction, into result: MeetingResult, meetingID: String) -> MeetingResult {
        let drafts = extraction.actionDrafts.map { input in
            MeetingActionDraft(
                title: input.title,
                notes: input.notes,
                assignee: input.assignee,
                dueAtISO8601: input.dueAtISO8601.flatMap(Self.canonicalDueDate),
                sourceSegmentIDs: input.sourceSegmentIDs,
                confidence: input.confidence,
                requiresReview: input.requiresReview,
                meetingID: meetingID
            )
        }
        let deduped = Array(Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) }).values)
            .sorted { $0.id < $1.id }
        var copy = result
        copy.title = extraction.title
        copy.summary = extraction.summary
        copy.decisions = extraction.decisions
        copy.unresolvedQuestions = extraction.unresolvedQuestions
        copy.actionDrafts = deduped
        return MeetingActionAttribution.applying(to: copy, meetingID: meetingID)
    }
}
