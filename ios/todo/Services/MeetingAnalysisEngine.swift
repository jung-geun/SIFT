import Foundation

/// Routes meeting transcript analysis to an on-device LLM, preferring Apple
/// Foundation Models (AFM), falling back to the on-device MLX LLM (Qwen) when it
/// is already loaded, and only then to the deterministic keyword heuristic.
/// On-device only — the transcript never leaves the device.
///
/// Both LLM paths extract summary / decisions / unresolved questions / action
/// candidates. The heuristic is a last resort that only yields rule-based action
/// drafts, so keeping an LLM in front means tasks and questions come from real
/// analysis rather than keyword matching whenever any on-device model is present.
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

    struct Outcome {
        let result: MeetingResult
        /// Human-readable engine name retained for compatibility with analysis callers.
        /// UI reporters should use engineSource and localize in the app language.
        let engineLabel: String
        let usedOnDeviceLLM: Bool
        let engineSource: AnalysisSource?

        init(
            result: MeetingResult,
            engineLabel: String,
            usedOnDeviceLLM: Bool,
            engineSource: AnalysisSource? = nil
        ) {
            self.result = result
            self.engineLabel = engineLabel
            self.usedOnDeviceLLM = usedOnDeviceLLM
            self.engineSource = engineSource
        }
    }

    private let heuristic = MeetingTranscriptAnalysisService()

    func analyze(
        meetingID: String,
        result: MeetingResult,
        glossaryHint: String = "",
        language: AppLanguage
    ) async -> Outcome {
        if #available(iOS 26.0, *), FoundationModelsAvailability.isAvailable {
            do {
                let extraction = try await FoundationModelsService()
                    .analyzeMeeting(
                        meetingID: meetingID,
                        segments: result.segments,
                        glossaryHint: glossaryHint,
                        language: language
                    )
                return Outcome(
                    result: merge(extraction, into: result, meetingID: meetingID),
                    engineLabel: MeetingRefinementEngine.Source.appleIntelligence.displayName(language: language),
                    usedOnDeviceLLM: true,
                    engineSource: .appleIntelligence
                )
            } catch {
                // AFM 미가용/실패 → 로컬 LLM → 휴리스틱 순으로 강등.
            }
        }
        if let extraction = await analyzeViaLocalLLM(
            meetingID: meetingID,
            segments: result.segments,
            glossaryHint: glossaryHint,
            language: language
        ) {
            return Outcome(
                result: merge(extraction, into: result, meetingID: meetingID),
                engineLabel: MeetingRefinementEngine.Source.qwen.displayName(language: language),
                usedOnDeviceLLM: true,
                engineSource: .qwen
            )
        }
        return Outcome(
            result: heuristic.analyze(meetingID: meetingID, result: result, language: language),
            engineLabel: AnalysisSource.heuristic.displayName(language: language),
            usedOnDeviceLLM: false,
            engineSource: .heuristic
        )
    }

    // MARK: - On-device LLM analysis (AFM 미가용 폴백)

    /// Extracts title/summary/decisions/questions/actions with the MLX LLM, but
    /// only when its model is already loaded (no surprise download; the manual
    /// refine path loads it first, so analysis can reuse it). Returns nil to fall
    /// through to the heuristic.
    private func analyzeViaLocalLLM(
        meetingID: String,
        segments: [MeetingSegment],
        glossaryHint: String,
        language: AppLanguage
    ) async -> ProviderMeetingExtraction? {
        let llm = OnDeviceLLMService.shared
        guard llm.isModelLoaded else { return nil }

        // Analysis needs whole-meeting context; cap to the first ~3000 chars to
        // fit the local model's smaller window (mirrors the AFM char cap).
        var numbered = [String]()
        var included = [MeetingSegment]()
        var used = 0
        for segment in segments {
            let line = "\(included.count + 1). \(segment.text)"
            if used + line.count > 3_000, !included.isEmpty { break }
            numbered.append(line)
            included.append(segment)
            used += line.count
        }
        guard !included.isEmpty else { return nil }

        let glossaryBlock: String
        if glossaryHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            glossaryBlock = ""
        } else {
            let label = AppLanguage.localized(
                "meeting.glossary.label",
                defaultValue: language == .english ? "User Vocabulary" : "사용자 단어장",
                language: language,
                comment: "Meeting prompt glossary section label"
            )
            glossaryBlock = "[\(label)]\n\(glossaryHint.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        }
        let userPrompt = """
        \(glossaryBlock)[전사 구간]
        \(numbered.joined(separator: "\n"))

        \(Prompts.MeetingAnalysisLocal.requestSuffix(language: language))
        """
        guard let raw = try? await llm.generate(
            systemPrompt: Prompts.MeetingAnalysisLocal.systemInstruction(language: language),
            userPrompt: userPrompt,
            maxTokens: 900
        ), let payload = Self.parseAnalysis(raw) else { return nil }

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
                dueAtISO8601: due.isEmpty ? nil : Self.canonicalDueDate(due),
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
        copy.title = extraction.title.isEmpty ? result.title : extraction.title
        copy.summary = extraction.summary
        copy.decisions = extraction.decisions
        copy.unresolvedQuestions = extraction.unresolvedQuestions
        copy.actionDrafts = deduped
        return copy
    }
}
