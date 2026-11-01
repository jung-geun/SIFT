import Foundation

/// An explicit summary choice, separate from automatic on-device routing.
nonisolated enum MeetingSummaryModel: String, CaseIterable, Identifiable, Sendable {
    case gptSol
    case gptLuna
    case appleIntelligence

    var id: String { rawValue }

    var openAITier: OpenAIAnalysisTier? {
        switch self {
        case .appleIntelligence: nil
        case .gptLuna: .basic
        case .gptSol: .advanced
        }
    }

    var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .gptLuna: "GPT-6 Luna"
        case .gptSol: "GPT-6.1 Sol"
        }
    }
}

/// Automatic analysis uses only an enabled on-device provider. Remote analysis
/// is available solely through the explicit, consent-fenced analyzeWithOpenAI entry.
@MainActor
struct MeetingAnalysisEngine {

    enum AnalysisSource: String, Sendable {
        case appleIntelligence = "apple-intelligence"
        case qwen = "qwen"
        case openAI = "openai"
        case heuristic = "heuristic"

        func displayName(language: AppLanguage) -> String {
            switch self {
            case .appleIntelligence:
                return MeetingRefinementEngine.Source.appleIntelligence.displayName(language: language)
            case .qwen:
                return MeetingRefinementEngine.Source.qwen.displayName(language: language)
            case .openAI:
                return AppLanguage.localized("meeting.engine.openAI", defaultValue: "ChatGPT",
                    language: language, comment: "Explicit remote meeting summary engine name")
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
        var summaryKind: SummaryKind { usedOnDeviceLLM || engineSource == .openAI ? .generated : .sourceExcerpts }
        /// Rechecked synchronously by persistence callers after their final await.
        let authorizationCheck: (@MainActor () throws -> Void)?

        init(
            result: MeetingResult,
            engineLabel: String,
            usedOnDeviceLLM: Bool,
            engineSource: AnalysisSource? = nil,
            executionPath: AnalysisExecutionPath = .rules(.noProviderOptIn),
            authorizationCheck: (@MainActor () throws -> Void)? = nil
        ) {
            self.result = result
            self.engineLabel = engineLabel
            self.usedOnDeviceLLM = usedOnDeviceLLM
            self.engineSource = engineSource
            self.executionPath = executionPath
            self.authorizationCheck = authorizationCheck
        }
    }

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
        language: AppLanguage = .current,
        summaryFormat: MeetingSummaryFormat = .minutes,
        customInstructions: String = "",
        citationSources: [String: MeetingSummaryCitation]? = nil,
        sourceLanguageTags: [String]? = nil
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
                language: language,
                summaryFormat: summaryFormat,
                customInstructions: customInstructions,
                citationSources: citationSources, sourceLanguageTags: sourceLanguageTags
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

    /// Explicit on-device summary only. Unavailability or invalid analysis is an
    /// error, never permission to select another provider or return excerpts.
    func analyzeWithAppleIntelligence(
        meetingID: String,
        result: MeetingResult,
        sourceLanguageTag: String,
        summaryLanguageTag: String,
        language: AppLanguage = .current,
        summaryFormat: MeetingSummaryFormat = .minutes,
        customInstructions: String = "",
        citationSources: [String: MeetingSummaryCitation]? = nil,
        sourceLanguageTags: [String]? = nil
    ) async throws -> Outcome {
        try Task.checkCancellation()
        guard let outcome = try await analyze(
            provider: .foundationModels,
            meetingID: meetingID,
            result: result,
            glossaryHint: "",
            sourceLanguageTag: sourceLanguageTag,
            summaryLanguageTag: summaryLanguageTag,
            language: language,
            summaryFormat: summaryFormat,
            customInstructions: customInstructions,
            citationSources: citationSources,
            sourceLanguageTags: sourceLanguageTags
        ) else {
            throw IntelligenceRoutingError.parseFailed(
                provider: .foundationModels,
                reason: "Meeting provider returned no analysis."
            )
        }
        try Task.checkCancellation()
        return outcome
    }

    /// Explicit remote retry. Never refines the transcript, shares vocabulary,
    /// changes automatic routing, or replaces a failed request with excerpts.
    func analyzeWithOpenAI(
        meetingID: String,
        result: MeetingResult,
        sourceLanguageTag: String,
        summaryLanguageTag: String,
        language: AppLanguage = .current,
        summaryFormat: MeetingSummaryFormat = .minutes,
        customInstructions: String = "",
        citationSources: [String: MeetingSummaryCitation]? = nil,
        sourceLanguageTags: [String]? = nil,
        provider: OpenAIProviderService? = nil,
        tier: OpenAIAnalysisTier = .basic
    ) async throws -> Outcome {
        try await LLMDebugLogger.withOpenAITrace(operation: "meeting.summary") {
            LLMDebugLogger.openAIEvent("meeting.prepare", "segments=\(result.segments.count)")
            let provider = provider ?? OpenAIProviderService()
            let authorize = try provider.authorizationCheck(for: .meetings)
            try authorize()
            guard !result.segments.isEmpty else { throw OpenAIRequestError.invalidResponse }
            let promptCap = 24_000
            let budget = try Prompts.MeetingStructuredSummary.transcriptBudget(
                promptByteCap: promptCap, glossaryHint: "", customInstructions: customInstructions,
                sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: summaryLanguageTag)
            let instructions = Prompts.MeetingAnalysisLocal.systemInstruction(
                sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: summaryLanguageTag,
                summaryFormat: summaryFormat)
            @MainActor
            func generate(_ chunk: [MeetingSegment], synthesis: Bool) async throws -> ProviderMeetingExtraction {
                try Task.checkCancellation()
                try authorize()
                LLMDebugLogger.openAIEvent("meeting.chunk", "synthesis=\(synthesis) segments=\(chunk.count)")
                let prompt = try Prompts.MeetingStructuredSummary.input(
                    segments: chunk, glossaryHint: "", customInstructions: customInstructions,
                    sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: summaryLanguageTag,
                    isSynthesis: synthesis)
                LLMDebugLogger.openAIEvent("meeting.prompt.validate", "bytes=\(prompt.utf8.count) cap=\(promptCap)")
                guard prompt.utf8.count <= promptCap else { throw OpenAIRequestError.invalidResponse }
                let raw = try await provider.generateJSON(
                    systemInstruction: instructions + (synthesis ? "\n" + Prompts.MeetingStructuredSummary.synthesisInstruction : ""),
                    userPrompt: prompt, scope: .meetings, tier: tier, language: language,
                    authorizationCheck: authorize)
                try Task.checkCancellation()
                try authorize()
                guard let extraction = Self.extraction(from: raw, included: chunk, strict: true) else {
                    throw OpenAIRequestError.invalidResponse
                }
                if synthesis, extraction.summarySections?.isEmpty != false {
                    LLMDebugLogger.openAIEvent("meeting.validation.rejected", "synthesis requires nonempty sections")
                    throw OpenAIRequestError.invalidResponse
                }
                return extraction
            }
            var extractions: [ProviderMeetingExtraction] = []
            for chunk in MeetingSummaryEvidence.chunks(result.segments, characterBudget: budget) {
                extractions.append(try await generate(chunk, synthesis: false))
            }
            // The shared local helper can preserve generated notes on synthesis
            // failure. An explicit remote operation instead propagates that failure.
            var synthesisError: Error?
            let extraction = try await MeetingSummaryEvidence.synthesize(extractions, budget: budget) { chunk, synthesis in
                do { return try await generate(chunk, synthesis: synthesis) }
                catch { synthesisError = error; throw error }
            }
            if let synthesisError { throw synthesisError }
            try Task.checkCancellation()
            try authorize()
            LLMDebugLogger.openAIEvent("meeting.citations.validate")
            if let citationSources {
                let references = (extraction.summarySections ?? []).flatMap(\.items).flatMap(\.sourceSegmentIDs)
                guard references.allSatisfy({ id in
                    guard let citation = citationSources[id] else { return false }
                    return !citation.trackID.isEmpty && !citation.segmentID.isEmpty && citation.transcriptRevision >= 0
                }) else {
                    LLMDebugLogger.openAIEvent("meeting.validation.rejected", "unresolved source track/segment/revision")
                    throw OpenAIRequestError.invalidResponse
                }
            }
            LLMDebugLogger.openAIEvent("meeting.merge.validate")
            guard let merged = Self.merging(extraction, into: result, meetingID: meetingID,
                                            citationSources: citationSources) else {
                LLMDebugLogger.openAIEvent("meeting.validation.rejected", "no mergeable cited summary sections")
                throw OpenAIRequestError.invalidResponse
            }
            return Outcome(result: merged, engineLabel: AnalysisSource.openAI.displayName(language: language),
                usedOnDeviceLLM: false, engineSource: .openAI, executionPath: .beta(.openAI),
                authorizationCheck: authorize)
        }
    }

    private func heuristicOutcome(
        meetingID: String,
        result: MeetingResult,
        language: AppLanguage,
        reason: RuleFallbackReason
    ) -> Outcome {
        var excerpts = result
        excerpts.title = result.segments.first.map { String($0.text.prefix(80)) } ?? ""
        excerpts.summary = result.segments.prefix(8).map(\.text).joined(separator: "\n")
        excerpts.decisions = []
        excerpts.unresolvedQuestions = []
        excerpts.actionDrafts = []
        excerpts.invalidateStructuredSummary()
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
        language: AppLanguage,
        summaryFormat: MeetingSummaryFormat,
        customInstructions: String,
        citationSources: [String: MeetingSummaryCitation]?,
        sourceLanguageTags: [String]?
    ) async throws -> Outcome? {
        let extraction: ProviderMeetingExtraction
        let source: AnalysisSource
        switch provider {
        case .foundationModels:
            guard #available(iOS 26.0, *), FoundationModelsAvailability.isAvailable else {
                throw IntelligenceRoutingError.backendUnavailable(provider: provider, reason: RuleFallbackReason.unavailable.rawValue)
            }
            extraction = try await FoundationModelsService().analyzeMeeting(
                meetingID: meetingID, segments: result.segments, glossaryHint: glossaryHint,
                sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: summaryLanguageTag,
                language: language, summaryFormat: summaryFormat, customInstructions: customInstructions,
                sourceLanguageTags: sourceLanguageTags)
            source = .appleIntelligence
        case .onDevice:
            extraction = try await analyzeViaLocalLLM(segments: result.segments,
                glossaryHint: glossaryHint, sourceLanguageTag: sourceLanguageTag,
                summaryLanguageTag: summaryLanguageTag, summaryFormat: summaryFormat,
                customInstructions: customInstructions, sourceLanguageTags: sourceLanguageTags)
            source = .qwen
        case .openAI, .laya:
            return nil
        }
        guard let merged = Self.merging(extraction, into: result, meetingID: meetingID, citationSources: citationSources) else {
            throw IntelligenceRoutingError.parseFailed(provider: provider, reason: "Meeting response contained no valid cited summary.")
        }
        return Outcome(result: merged, engineLabel: source.displayName(language: language),
                       usedOnDeviceLLM: true, engineSource: source, executionPath: .beta(provider))
    }

    private func analyzeViaLocalLLM(
        segments: [MeetingSegment], glossaryHint: String,
        sourceLanguageTag: String, summaryLanguageTag: String,
        summaryFormat: MeetingSummaryFormat, customInstructions: String, sourceLanguageTags: [String]?
    ) async throws -> ProviderMeetingExtraction {
        let llm = localLLM
        guard llm.isModelLoaded, let loadedModelID = llm.loadedModelIdentifier,
              loadedModelID == llm.modelID else { throw OnDeviceLLMService.LLMError.modelNotLoaded }
        for source in sourceLanguageTags ?? [sourceLanguageTag] {
            try MeetingSummaryLanguages.requireLocalModelSupport(modelID: loadedModelID,
                sourceLanguageTag: source, summaryLanguageTag: summaryLanguageTag)
        }
        guard sourceLanguageTags?.isEmpty != true else {
            throw IntelligenceRoutingError.parseFailed(provider: .onDevice, reason: "Meeting source language evidence is empty.")
        }
        let promptCap = 12_000
        let budget = try Prompts.MeetingStructuredSummary.transcriptBudget(promptByteCap: promptCap,
            glossaryHint: glossaryHint, customInstructions: customInstructions,
            sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: summaryLanguageTag)
        let instructions = Prompts.MeetingAnalysisLocal.systemInstruction(
            sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: summaryLanguageTag, summaryFormat: summaryFormat)
        func generate(_ chunk: [MeetingSegment], synthesis: Bool) async throws -> ProviderMeetingExtraction {
            try Task.checkCancellation()
            let prompt = try Prompts.MeetingStructuredSummary.input(segments: chunk,
                glossaryHint: glossaryHint, customInstructions: customInstructions,
                sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: summaryLanguageTag, isSynthesis: synthesis)
            guard prompt.utf8.count <= promptCap else {
                throw IntelligenceRoutingError.parseFailed(provider: .onDevice, reason: "Meeting input exceeds the provider context budget.")
            }
            let raw = try await llm.generate(
                systemPrompt: instructions + (synthesis ? "\n" + Prompts.MeetingStructuredSummary.synthesisInstruction : ""),
                userPrompt: prompt, maxTokens: 1_500, use: .meetingAnalysis)
            guard let extraction = Self.extraction(from: raw, included: chunk) else {
                throw IntelligenceRoutingError.parseFailed(provider: .onDevice, reason: "On-device meeting response was invalid.")
            }
            return extraction
        }
        var extractions: [ProviderMeetingExtraction] = []
        for chunk in MeetingSummaryEvidence.chunks(segments, characterBudget: budget) {
            // Greetings and unsupported/invalid facts contribute no notes. They
            // must not erase useful cited output from the rest of the meeting.
            extractions.append(try await generate(chunk, synthesis: false))
        }
        return try await MeetingSummaryEvidence.synthesize(extractions, budget: budget) { chunk, synthesis in
            try await generate(chunk, synthesis: synthesis)
        }
    }

    private struct AnalysisAction: Decodable {
        let sourceSegmentNumbers: [Int]
        let title: String
        let notes: String?
        let due: String?
    }

    private struct AnalysisItem: Decodable {
        let text: String
        let sourceSegmentNumbers: [Int]
        let isTask: Bool?
    }

    private struct AnalysisSection: Decodable {
        let id: String
        let title: String
        let items: [AnalysisItem]
    }

    private struct AnalysisPayload: Decodable {
        let title: String?
        let actions: [AnalysisAction]?
        let sections: [AnalysisSection]?
    }

    static func extraction(from raw: String, included: [MeetingSegment], strict: Bool = false) -> ProviderMeetingExtraction? {
        var json = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = json.firstIndex(of: "{"), let last = json.lastIndex(of: "}") {
            json = String(json[first...last])
        }
        LLMDebugLogger.openAIEvent("meeting.decode")
        guard let data = json.data(using: .utf8) else {
            LLMDebugLogger.openAIEvent("meeting.validation.rejected", "output is not UTF-8")
            return nil
        }
        let payload: AnalysisPayload
        do { payload = try JSONDecoder().decode(AnalysisPayload.self, from: data) }
        catch {
            LLMDebugLogger.openAIFailure(error)
            return nil
        }
        if strict {
            // Reject incomplete or partially invalid remote documents as a unit;
            // silently dropping bad facts could overwrite good existing notes.
            guard payload.title != nil, let sections = payload.sections, let actions = payload.actions else {
                LLMDebugLogger.openAIEvent("meeting.validation.rejected", "required title/sections/actions missing or null")
                return nil
            }
            for (sectionIndex, section) in sections.enumerated() {
                guard !section.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !section.items.isEmpty else {
                    LLMDebugLogger.openAIEvent("meeting.validation.rejected", "sections[\(sectionIndex)] has empty id/title/items")
                    return nil
                }
                for (itemIndex, item) in section.items.enumerated() {
                    guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          actionEvidence(item.sourceSegmentNumbers, included: included) != nil else {
                        LLMDebugLogger.openAIEvent("meeting.validation.rejected", "sections[\(sectionIndex)].items[\(itemIndex)] has empty text or invalid sourceSegmentNumbers=\(item.sourceSegmentNumbers); validRange=1...\(included.count)")
                        return nil
                    }
                }
            }
            for (actionIndex, action) in actions.enumerated() {
                guard !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      actionEvidence(action.sourceSegmentNumbers, included: included) != nil else {
                    LLMDebugLogger.openAIEvent("meeting.validation.rejected", "actions[\(actionIndex)] has empty title or invalid sourceSegmentNumbers=\(action.sourceSegmentNumbers); validRange=1...\(included.count)")
                    return nil
                }
            }
        }
        let sections = (payload.sections ?? []).compactMap { section -> ProviderMeetingSummarySection? in
            let items = MeetingSummaryEvidence.validatedItems(
                section.items.map { (text: $0.text, numbers: $0.sourceSegmentNumbers, isTask: $0.isTask) }, included: included)
            guard !items.isEmpty, !section.id.isEmpty, !section.title.isEmpty else { return nil }
            return ProviderMeetingSummarySection(id: section.id, title: section.title, items: items)
        }
        let drafts = (payload.actions ?? []).compactMap { action -> ProviderActionDraftInput? in
            guard let evidence = actionEvidence(action.sourceSegmentNumbers, included: included) else { return nil }
            let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return ProviderActionDraftInput(title: title, notes: action.notes ?? "", assignee: nil,
                dueAtISO8601: action.due.flatMap(canonicalDueDate), sourceSegmentIDs: evidence,
                confidence: 0.6, requiresReview: true)
        }
        // Legacy free-text fields are not evidence. Persist only facts returned
        // with valid explicit numbered references, never infer refs from prose.
        return ProviderMeetingExtraction(title: payload.title ?? "",
            summary: sections.flatMap(\.items).map(\.text).joined(separator: "\n"),
            decisions: sections.filter { $0.id == "decisions" }.flatMap(\.items).map(\.text),
            unresolvedQuestions: sections.filter { $0.id == "openQuestions" }.flatMap(\.items).map(\.text),
            actionDrafts: drafts, summarySections: sections)
    }

    /// Reject invalid references as a unit. Oversized source segments can span
    /// several input pieces; retain that shared source identity exactly once.
    static func actionEvidence(_ numbers: [Int], included: [MeetingSegment]) -> [String]? {
        guard !numbers.isEmpty, Set(numbers).count == numbers.count,
              numbers.allSatisfy({ $0 > 0 && $0 <= included.count }) else { return nil }
        let ids = numbers.map { included[$0 - 1].id }
        guard ids.allSatisfy({ !$0.isEmpty }) else { return nil }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
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
    static func merging(_ extraction: ProviderMeetingExtraction, into result: MeetingResult, meetingID: String,
                        citationSources: [String: MeetingSummaryCitation]? = nil) -> MeetingResult? {
        let segmentIDs = Set(result.segments.map(\.id))
        let sections = (extraction.summarySections ?? []).enumerated().compactMap { sectionIndex, section -> MeetingSummarySection? in
            let items = section.items.enumerated().compactMap { itemIndex, item -> MeetingSummaryItem? in
                guard !item.text.isEmpty, !item.sourceSegmentIDs.isEmpty,
                      item.sourceSegmentIDs.allSatisfy({ segmentIDs.contains($0) }) else { return nil }
                let citations = item.sourceSegmentIDs.compactMap { segmentID -> MeetingSummaryCitation? in
                    if let citationSources { return citationSources[segmentID] }
                    return MeetingSummaryCitation(trackID: meetingID, segmentID: segmentID,
                                                  transcriptRevision: result.transcriptRevision)
                }
                guard citations.count == item.sourceSegmentIDs.count,
                      citations.allSatisfy({ !$0.trackID.isEmpty && !$0.segmentID.isEmpty && $0.transcriptRevision >= 0 }) else { return nil }
                return MeetingSummaryItem(id: "\(sectionIndex)-\(itemIndex)", text: item.text, citations: citations, isTask: item.isTask)
            }
            guard !items.isEmpty else { return nil }
            return MeetingSummarySection(id: section.id, title: section.title, items: items)
        }
        guard !sections.isEmpty else { return nil }
        let drafts = extraction.actionDrafts.filter {
            !$0.sourceSegmentIDs.isEmpty && $0.sourceSegmentIDs.allSatisfy { segmentIDs.contains($0) }
        }.map { input in
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
        let deduped = Dictionary(drafts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.id < $1.id }
        var copy = result
        copy.title = extraction.title
        copy.summary = sections.map { $0.title + "\n" + $0.items.map(\.text).joined(separator: "\n") }.joined(separator: "\n\n")
        copy.summarySections = sections
        copy.summarySourceFingerprint = MeetingSummaryEvidence.sourceFingerprint(result)
        copy.decisions = (extraction.summarySections ?? []).filter { $0.id == "decisions" }
            .flatMap(\.items).filter { item in item.sourceSegmentIDs.allSatisfy { segmentIDs.contains($0) } }.map(\.text)
        copy.unresolvedQuestions = (extraction.summarySections ?? []).filter { $0.id == "openQuestions" }
            .flatMap(\.items).filter { item in item.sourceSegmentIDs.allSatisfy { segmentIDs.contains($0) } }.map(\.text)
        copy.actionDrafts = deduped
        return MeetingActionAttribution.applying(to: copy, meetingID: meetingID)
    }
}
