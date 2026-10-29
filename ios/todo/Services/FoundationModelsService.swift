import Foundation

// MARK: - Foundation Models Service (WWDC 2026)
//
// 사용 조건:
//   1. Xcode > 프로젝트 타깃 > Frameworks, Libraries, and Embedded Content →
//      FoundationModels.framework 추가 (File → Add Frameworks → FoundationModels).
//   2. FoundationModelsAvailability.isAvailable == true 확인 후 사용.
//   3. iOS 26에서는 Apple Intelligence 활성화가 필요하고, iOS 27+에서는 현재 Siri AI를
//      사용할 수 있는 영어권 Siri 언어 및 Apple Intelligence 활성화 환경이어야 한다.
// 장점:
//   - Neural Engine(ANE) 실행 → GPU 백그라운드 제약·메모리 경고 취소 클래스 자체가 없음.
//   - Guided Generation(@Generable) → 우선순위 점수 0% 버그 구조적 해소.
//   - 모델 다운로드 불필요. 시스템 관리 모델.
//
// ⚠️ 프라이버시 불변식: 모든 추론 온디바이스 완결. 네트워크 미전송.
//    페르소나·우선순위 프롬프트에 이메일 본문 미포함 (메타데이터·통계만).

#if canImport(FoundationModels)
import FoundationModels
#endif

struct TranscriptCorrectionBatchResult: Sendable {
    let segments: [MeetingSegment]
    let attemptedBatchCount: Int
    let succeededBatchCount: Int
    let failedBatchCount: Int
}

enum FoundationModelsAvailability {
    /// Disabled Intelligence or pending assets do not make supported hardware
    /// eligible for a different model. Simulator has no system model runtime.
    nonisolated static var isDeviceEligible: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .unavailable(.deviceNotEligible) = SystemLanguageModel.default.availability {
                return false
            }
            return true
        }
        #endif
        return false
        #endif
    }

    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
        #endif
    }

    static var unavailableExplanation: String? {
        let iOSMajorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        #if canImport(FoundationModels)
        let frameworkLinked = true
        #else
        let frameworkLinked = false
        #endif
        return unavailableExplanation(
            isAvailable: Self.isAvailable,
            iOSMajorVersion: iOSMajorVersion,
            isSimulator: isSimulator,
            frameworkLinked: frameworkLinked,
            language: .current
        )
    }

    static func unavailableExplanation(
        isAvailable: Bool,
        iOSMajorVersion: Int,
        isSimulator: Bool,
        frameworkLinked: Bool,
        language: AppLanguage = .current
    ) -> String? {
        guard !isAvailable else { return nil }
        if isSimulator {
            return AppLanguage.localized("error.foundationModels.availability.simulator", defaultValue: "Apple Foundation Models are disabled in the simulator. Check Apple Intelligence and Siri settings on a physical device.", language: language)
        }
        guard frameworkLinked, iOSMajorVersion >= 26 else {
            return AppLanguage.localized("error.foundationModels.availability.framework", defaultValue: "Apple Foundation Models require iOS 26 or later and a build linked with FoundationModels.framework.", language: language)
        }
        if iOSMajorVersion >= 27 {
            return AppLanguage.localized("error.foundationModels.availability.siriLanguage", defaultValue: "Apple Foundation Models require an English Siri language with Apple Intelligence enabled. Check Settings > Apple Intelligence & Siri.", language: language)
        }
        return AppLanguage.localized("error.foundationModels.availability.disabled", defaultValue: "Apple Foundation Models require Apple Intelligence to be available and enabled on this device. Check Settings > Apple Intelligence & Siri.", language: language)
    }
}

#if canImport(FoundationModels)

// MARK: - Guided Generation Types


/// 단일 할 일 우선순위 랭킹.
@Generable
struct FMPriorityRanking {
    // E-2: UUID 대신 정수 번호 — 모델의 UUID 변형으로 인한 조용한 누락 버그 해소.
    @Guide(description: "To-do number (copy exactly as an integer string).")
    var todoID: String

    @Guide(description: "Priority score from 0.01 (lowest) to 1.0 (highest). Never use 0; use at least 0.2 without a due date.")
    var score: Double

    @Guide(description: "A concise priority reason of at most 40 characters in the requested output language.")
    var reason: String

    @Guide(description: "Always return an empty string.")
    var detail: String

    @Guide(description: "True when the to-do is due today, near its deadline, or contains an urgent/important keyword.")
    var needsNotification: Bool

    @Guide(description: "Recommended processing time as an ISO8601 string; return an empty string when uncertain.")
    var recommendedISO: String

    @Guide(description: "True when the to-do matches the user's persona.")
    var personaFit: Bool
}

/// 우선순위 랭킹 목록 래퍼.
@Generable
struct FMPriorityRankingList {
    var rankings: [FMPriorityRanking]
}


/// 이메일 마감 추출 출력 (C: AFM 강제 메일 분석).
/// OnDeviceLLMEmailEngine.parseExtraction의 EmailExtraction 필드와 1:1 대응.
@Generable
struct FMEmailOutput {
    @Guide(description: "Due date as an ISO8601 string. Preserve the source absolute instant and offset when the source specifies Z, UTC, UTC+9, or GMT+09:00. If no timezone is present, use the current local offset. Return an empty string when no explicit due date exists; never infer.")
    var dueDateISO: String

    @Guide(description: "True when the date has no time component and represents an all-day deadline.")
    var isAllDay: Bool

    @Guide(description: "Sender display name, or an empty string when absent.")
    var sender: String

    @Guide(description: "Sender email address, or an empty string when absent.")
    var senderEmail: String

    @Guide(description: "Deadline keyword score: 1 when the source contains a due-date keyword such as deadline, due, or expires; otherwise 0.")
    var keywordScore: Int

    @Guide(description: "One or two concise deadline-related sentences in the requested output language, or empty.")
    var deadlineSentence: String

    @Guide(description: "One to three lines of key email content in the requested output language, or empty.")
    var notes: String
}

/// 이메일 상세 화면의 구조화된 요약 출력.
@Generable
struct FMEmailSummaryOutput {
    @Guide(description: "A concise factual email summary in the requested output language. Include the purpose and any explicit deadline or required response. Do not repeat greetings, legal boilerplate, or raw markup.")
    var summary: String

    @Guide(description: "Zero to three distinct factual key points in the requested output language. Do not repeat the summary.")
    var keyPoints: [String]

    @Guide(description: "Zero to three explicit actions required of the recipient in the requested output language. Return an empty array when none are explicitly requested.")
    var actionItems: [String]
}

/// 페르소나 초안의 설명과 근거를 개선하는 출력. 분류와 신뢰도는 결정론적 분석값을 유지한다.
@Generable
struct FMPersonaNarrativeOutput {
    @Guide(description: "A two-to-four sentence persona description grounded only in the supplied deterministic behavior facts, in the requested output language. Do not prescribe actions or invent personal attributes.")
    var descriptionText: String

    @Guide(description: "Zero to three concise, non-duplicated factual evidence statements grounded only in the supplied behavior facts, in the requested output language.")
    var evidence: [String]
}

/// 결정론적 행동 지표를 설명하는 출력. 수치와 프로필 구조는 호출부가 보존한다.
@Generable
struct FMBehaviorNarrativeOutput {
    @Guide(description: "A concise factual behavior-pattern summary grounded only in the supplied deterministic statistics, in the requested output language. Do not give recommendations, advice, or infer unsupported traits.")
    var summary: String

    @Guide(description: "Two to four distinct factual observations grounded only in the supplied deterministic statistics, in the requested output language. Do not give recommendations or advice.")
    var insights: [String]
}


/// 이메일 수동 등록용 요약/마감 초안 출력.
@Generable
struct FMEmailTodoDraftOutput {
    @Guide(description: "A to-do title in a concise verb form of at most 40 characters in the requested output language. If absent, clean up the email subject.")
    var title: String

    @Guide(description: "One to three lines of key email content and action items in the requested output language. Exclude greetings.")
    var notes: String

    @Guide(description: "Explicit due date as an ISO8601 string. Preserve the source absolute instant and offset when the source specifies a timezone. If absent, return an empty string; never infer.")
    var dueDateISO: String

    @Guide(description: "True when the date has no time component and represents an all-day deadline.")
    var isAllDay: Bool

    @Guide(description: "Sender display name, or an empty string when absent.")
    var sender: String

    @Guide(description: "Sender email address, or an empty string when absent.")
    var senderEmail: String
}

/// 회의 전사 액션 후보 (LLM 출력). sourceSegmentNumber는 프롬프트에 제시한
/// 1-based 전사 구간 번호이며, 호출부에서 실제 segment.id로 매핑한다.
@available(iOS 26.0, *)
@Generable
struct FMMeetingActionItem {
    @Guide(description: "Meeting action title, at most 40 characters, in exactly the requested summary language tag. Preserve source evidence and proper nouns.")
    var title: String

    @Guide(description: "One or two sentence context note in exactly the requested summary language tag, or empty. Preserve source evidence and proper nouns.")
    var notes: String

    @Guide(description: "Explicit deadline as canonical UTC ISO8601 yyyy-MM-dd'T'HH:mm:ss.SSSZ, always Z, preserving the source timezone's absolute instant. Empty when absent; never infer.")
    var dueDateISO: String

    @Guide(description: "1-based transcript segment number supporting this action; must exist in the supplied list.")
    var sourceSegmentNumber: Int
}

/// 회의 전사 분석 출력. ProviderMeetingExtraction과 1:1 대응.
@available(iOS 26.0, *)
@Generable
struct FMMeetingExtractionOutput {
    @Guide(description: "Meeting topic noun phrase, at most 15 characters, in exactly the requested summary language tag. Empty when unclear.")
    var title: String

    @Guide(description: "Objective two-to-four sentence meeting summary in exactly the requested summary language tag. Facts only; no speculation or advice.")
    var summary: String

    @Guide(description: "Only decisions explicitly agreed or confirmed in the transcript, one sentence each in exactly the requested summary language tag. Empty when absent.")
    var decisions: [String]

    @Guide(description: "Only unanswered or follow-up questions grounded in the transcript, in exactly the requested summary language tag. Empty when absent.")
    var unresolvedQuestions: [String]

    @Guide(description: "Only explicit commitments, requests, or action candidates grounded in the transcript. Empty when absent.")
    var actions: [FMMeetingActionItem]
}

/// 전사 교정 결과의 단일 구간. 원문 구간 번호와 교정된 전체 텍스트를 담는다.
@available(iOS 26.0, *)
@Generable
struct FMSegmentCorrection {
    @Guide(description: "교정한 전사 구간 번호(1-based). 반드시 제시된 목록에 있는 번호.")
    var sourceSegmentNumber: Int

    @Guide(description: "The entire corrected transcript segment. Fix only clear recognition errors or typos; preserve content, word order, proper nouns, and every original language and script, including mixed-language speech. Never translate into the UI language.")
    var correctedText: String
}

/// 전사 교정 패스 출력. 교정이 필요한 구간만 포함한다.
@available(iOS 26.0, *)
@Generable
struct FMTranscriptCorrectionOutput {
    @Guide(description: "교정이 필요한 구간만 포함. 고칠 것이 없으면 빈 배열.")
    var corrections: [FMSegmentCorrection]
}

// MARK: - Service

/// WWDC 2026 Foundation Models(`SystemLanguageModel`) 기반 서비스.
/// iOS 26.0+, ANE 실행, Guided Generation으로 타입 안전 출력.
///
/// ⚠️ API 호환성: `session.respond(to:generating:)` 반환형이 T 직접인지
///    GeneratedContent<T>인지 프레임워크 버전에 따라 다를 수 있음.
///    크래시 시 `.content` accessor 추가/제거 조정.
@available(iOS 26.0, *)
struct FoundationModelsService {

    private let runtime: any FoundationModelsRuntime
    private let policy: BetaFeaturePolicy

    init(runtime: any FoundationModelsRuntime = LiveFoundationModelsRuntime(), policy: BetaFeaturePolicy = BetaFeaturePolicy()) {
        self.runtime = runtime
        self.policy = policy
    }

    // E-1: 배치 크기 — FM 컨텍스트 창(~4096 토큰, 입력+출력 합산)에 맞게 분할.
    // 배치당 추정: instructions ~400 + schema ~400 + prompt ~300 + output(4×~100) = ~1500 토큰.
    private let fmBatchSize = 4

    // E-4: 가변 길이 입력 방어 캡 — 페르소나·메모리 누적에 의한 instructions 비대화 방지.
    private let inputCharCap = 200

    /// Apple Intelligence가 현재 기기에서 사용 가능한지 여부.
    /// 실제 availability 판정은 모든 빌드에서 호출 가능한 FoundationModelsAvailability가 담당한다.
    static var isAvailable: Bool {
        FoundationModelsAvailability.isAvailable
    }

    // MARK: - 우선순위 랭킹 (Guided Generation + 배칭)

    /// Guided Generation으로 할 일 우선순위를 산출한다.
    ///
    /// E-1: FM 컨텍스트 창 초과 방지를 위해 최대 fmBatchSize(8)개씩 배칭.
    ///   - 배치마다 fresh LanguageModelSession → 호출 간 transcript 누적 없음.
    ///   - score는 절대값(마감·중요도 기반)이고 todos는 dueDate 정렬 후 전달되어
    ///     배치 간 보정 드리프트 미미 → 정렬 목적에 충분.
    /// E-2: UUID 대신 1-based 정수 번호 → 모델 UUID 변형으로 인한 조용한 누락 버그 해소.
    ///
    /// - Parameters:
    ///   - todos: 우선순위 평가 대상 (미완료, 최대 20개 — 호출 전 dueDate 정렬됨)
    ///   - events: 향후 7일 캘린더 이벤트 컨텍스트
    ///   - persona: 사용자 페르소나 컨텍스트
    /// - Returns: PriorityResult 배열
    func rankTodos(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext,
        language: AppLanguage = .current
    ) async throws -> [PriorityResult] {
        guard policy.authorizes(.foundationModels, for: .standardAnalysis) else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .foundationModels,
                reason: RuleFallbackReason.providerDisabled.rawValue
            )
        }
        guard !todos.isEmpty else { return [] }

        // E-2: 전역 1-based 정수 인덱스 맵 구성 (UUID 역참조용)
        let indexedTodos: [(idx: Int, todo: Todo)] = todos.enumerated().map { ($0.offset + 1, $0.element) }
        let indexMap: [String: UUID] = Dictionary(
            uniqueKeysWithValues: indexedTodos.map { (String($0.idx), $0.todo.id) }
        )

        // E-1: fmBatchSize 단위로 분할 — 배치당 transcript가 컨텍스트 창 내에 수렴
        let batches: [[(idx: Int, todo: Todo)]] = stride(from: 0, to: indexedTodos.count, by: fmBatchSize).map {
            Array(indexedTodos[$0 ..< min($0 + fmBatchSize, indexedTodos.count)])
        }

        let instructions = buildRankingInstructions(persona: persona, language: language)
        var allResults   = [PriorityResult]()

        // E-5: 배치당 출력 토큰 캡 — 4-item 배치 × ~100 토큰/항목 = 400, 25% 여유 = 500.
        // 4096 총 한도에서 instructions(~250) + schema(~500) + prompt(~210) ≈ 960 소비 → 출력 여유 3136.
        // 그러나 schema가 예상보다 크면 캡이 안전망 역할. 생성 중단 시 output.rankings가 빈 배열 → 폴백.
        let genOptions = GenerationOptions(maximumResponseTokens: 500)

        for (batchOffset, batch) in batches.enumerated() {
            let prompt   = buildRankingPrompt(
                indexedBatch: batch,
                events: events,
                language: language
            )
            let operation = "rankTodos batch \(batchOffset + 1)/\(batches.count)"
            LLMDebugLogger.request(
                provider: "AFM",
                operation: operation,
                metadata: [
                    "batchSize: \(batch.count)",
                    "eventCount: \(events.count)",
                    "maximumResponseTokens: 500"
                ],
                systemPrompt: instructions,
                userPrompt: prompt
            )
            let output = try await runtime.rankTodos(
                instructions: instructions,
                userPrompt: prompt,
                options: genOptions
            )
            LLMDebugLogger.response(
                provider: "AFM",
                operation: operation,
                text: output.rankings.map { ranking in
                    "todoID=\(ranking.todoID) score=\(ranking.score) reason=\(ranking.reason) detail=\(ranking.detail) notify=\(ranking.needsNotification) recommendedISO=\(ranking.recommendedISO) personaFit=\(ranking.personaFit)"
                }.joined(separator: "\n")
            )

            for r in output.rankings {
                // E-2: 정수 번호로 역참조 — 모델이 번호를 에코하면 변형 없이 매핑
                let key = r.todoID.trimmingCharacters(in: .whitespaces)
                guard let uuid = indexMap[key] else { continue }
                let recommendedTime: Date? = r.recommendedISO.isEmpty ? nil : AppDateFormat.parseLLMDate(r.recommendedISO)
                allResults.append(PriorityResult(
                    todoID: uuid,
                    score: max(0.01, min(1.0, r.score)),
                    reason: r.reason,
                    detail: r.detail,
                    needsNotification: r.needsNotification,
                    recommendedTime: recommendedTime,
                    personaFit: r.personaFit,
                    engine: .foundationModels   // ANE 실행 — 메모리 경고 없음
                ))
            }
        }

        return allResults
    }

    // MARK: - 이메일 마감 추출 (C: AFM 강제)

    /// Apple Foundation Models로 이메일 마감일을 추출한다.
    /// 본문 캡 ~1500자. 온디바이스/PCC 전용 — 외부 미전송 (프라이버시 불변식).
    /// 포그라운드 전용. 백그라운드 BGTask는 OnDeviceDetectorEngine(NSDataDetector) 사용.
    func analyzeEmail(
        _ msg: GmailMessage,
        now: Date,
        language: AppLanguage = .current
    ) async throws -> EmailExtraction? {
        guard policy.authorizes(.foundationModels, for: .emailAnalysis) else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .foundationModels,
                reason: RuleFallbackReason.providerDisabled.rawValue
            )
        }
        let bodyPreview = String(msg.body.prefix(1500))
        guard !msg.subject.isEmpty else { return nil }

        let instructions = Prompts.EmailFM.systemInstruction(language: language) + "\n" + outputLanguageInstruction(language)
        let prompt = """
현재 시각: \(AppDateFormat.llmString(from: now))
발신자: \(msg.from)
제목: \(msg.subject)
\(bodyPreview.isEmpty ? "" : "본문:\n\(bodyPreview)")
"""
        LLMDebugLogger.request(
            provider: "AFM",
            operation: "analyzeEmail",
            metadata: ["subject: \(msg.subject)", "bodyPreviewChars: \(bodyPreview.count)"],
            systemPrompt: instructions,
            userPrompt: prompt
        )
        let output = try await runtime.analyzeEmail(
            instructions: instructions,
            userPrompt: prompt
        )
        LLMDebugLogger.response(provider: "AFM", operation: "analyzeEmail", text: "dueDateISO=\(output.dueDateISO) isAllDay=\(output.isAllDay) sender=\(output.sender) senderEmail=\(output.senderEmail) keywordScore=\(output.keywordScore) deadlineSentence=\(output.deadlineSentence) notes=\(output.notes)")

        // 마감일 파싱
        guard !output.dueDateISO.isEmpty else { return nil }
        guard let dueDate = AppDateFormat.parseMailDate(output.dueDateISO), dueDate > now else { return nil }

        // 종일 보정
        let sourceCalendar = AppDateFormat.sourceCalendar(for: output.dueDateISO)
        let normalizedDeadline = AppDateFormat.normalizedAllDayDeadline(dueDate, calendar: sourceCalendar)
        let finalDate = normalizedDeadline.date
        let isAllDay = output.isAllDay || normalizedDeadline.isAllDay

        let deadlineString = AppDateFormat.deadlineString(
            from: finalDate,
            isAllDay: isAllDay,
            language: language
        )
        var notesLines: [String] = [
            {
                let defaultValue = language == .english
                    ? "Due by \(deadlineString)"
                    : "⏰ \(deadlineString)까지"
                let localized = AppLanguage.localized(
                    "mail.deadline",
                    defaultValue: defaultValue,
                    language: language,
                    comment: "Detected email deadline"
                )
                return localized == defaultValue
                    ? localized
                    : String(format: localized, locale: language.locale, deadlineString)
            }()
        ]
        if !output.notes.isEmpty {
            notesLines += [
                output.notes,
                AppLanguage.localized(
                    "mail.aiSummary",
                    defaultValue: language == .english ? "(AI Summary)" : "(AI 요약)",
                    language: language,
                    comment: "AI-generated email summary marker"
                )
            ]
        }
        if !output.sender.isEmpty {
            notesLines += [
                "",
                {
                    let defaultValue = language == .english
                        ? "[Sender] \(output.sender)"
                        : "[발신자] \(output.sender)"
                    let localized = AppLanguage.localized(
                        "mail.sender",
                        defaultValue: defaultValue,
                        language: language,
                        comment: "Email sender label"
                    )
                    return localized == defaultValue
                        ? localized
                        : String(format: localized, locale: language.locale, output.sender)
                }()
            ]
        }

        return EmailExtraction(
            dueDate:          finalDate,
            isAllDay:         isAllDay,
            sender:           output.sender,
            senderEmail:      output.senderEmail,
            keywordScore:     output.keywordScore,
            deadlineSentence: output.deadlineSentence,
            notes:            notesLines.joined(separator: "\n")
        )
    }

    /// Generates the structured detail-card summary entirely through Apple Foundation Models.
    /// The caller falls back to deterministic rules if this foreground-only inference is unavailable.
    func summarizeEmail(
        subject: String,
        sender: String,
        body: String,
        language: AppLanguage = .current
    ) async throws -> EmailSummaryResult {
        guard policy.authorizes(.foundationModels, for: .emailAnalysis) else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .foundationModels,
                reason: RuleFallbackReason.providerDisabled.rawValue
            )
        }

        let bodyPreview = String(body.prefix(1_500))
        let instructions = Prompts.EmailSummaryFM.systemInstruction(language: language)
        let prompt = """
        Sender: \(sender)
        Subject: \(subject)
        <email>
        \(bodyPreview)
        </email>
        """
        LLMDebugLogger.request(
            provider: "AFM",
            operation: "summarizeEmail",
            metadata: ["subject: \(subject)", "bodyPreviewChars: \(bodyPreview.count)"],
            systemPrompt: instructions,
            userPrompt: prompt
        )
        let output = try await runtime.summarizeEmail(
            instructions: instructions,
            userPrompt: prompt
        )
        let summary = output.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPoints = output.keyPoints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let actionItems = output.actionItems
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !summary.isEmpty || !keyPoints.isEmpty || !actionItems.isEmpty else {
            throw IntelligenceRoutingError.parseFailed(
                provider: .foundationModels,
                reason: RuleFallbackReason.invalidResponse.rawValue
            )
        }
        LLMDebugLogger.response(
            provider: "AFM",
            operation: "summarizeEmail",
            text: "summary=\(summary)\nkeyPoints=\(keyPoints)\nactionItems=\(actionItems)"
        )
        return EmailSummaryResult(
            summary: summary,
            keyPoints: keyPoints,
            actionItems: actionItems
        )
    }

    // MARK: - Persona and behavior narratives

    /// Improves the user-confirmed persona preview without changing deterministic type or confidence data.
    func generatePersonaNarrative(
        existingPersona: String,
        fallback: PersonaRuleDraft,
        behaviorProfile: BehaviorProfile,
        language: AppLanguage = .current
    ) async throws -> PersonaNarrative {
        guard policy.authorizes(.foundationModels, for: .personalNarrative) else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .foundationModels,
                reason: RuleFallbackReason.providerDisabled.rawValue
            )
        }
        let instructions = Prompts.PersonaNarrativeFM.systemInstruction + "\n" + narrativeLanguageInstruction(language)
        let prompt = """
        [Existing persona]
        \(String(existingPersona.prefix(inputCharCap)))

        [Deterministic persona draft]
        \(fallback.descriptionText)

        [Deterministic evidence]
        \(fallback.evidence.joined(separator: "\n"))

        [Persona types]
        \(fallback.personaTypes.map(\.displayName).joined(separator: ", "))

        [Deterministic behavior facts]
        \(behaviorFacts(behaviorProfile))

        Return a grounded narrative only from the supplied deterministic facts.
        """
        LLMDebugLogger.request(
            provider: "AFM",
            operation: "generatePersonaNarrative",
            metadata: ["evidenceCount: \(fallback.evidence.count)", "sampleCount: \(behaviorProfile.sampleCount)"],
            systemPrompt: instructions,
            userPrompt: prompt
        )
        let output = try await runtime.generatePersonaNarrative(
            instructions: instructions,
            userPrompt: prompt
        )
        let narrative = PersonaNarrative(
            descriptionText: output.descriptionText,
            evidence: output.evidence
        )
        LLMDebugLogger.response(
            provider: "AFM",
            operation: "generatePersonaNarrative",
            text: "description=\(narrative.descriptionText)\nevidence=\(narrative.evidence)"
        )
        return narrative
    }

    /// Improves only the prose in a behavior preview; deterministic metrics remain authoritative.
    func narrateBehavior(
        baseline: MemoryAnalysisResult,
        language: AppLanguage = .current
    ) async throws -> BehaviorNarrative {
        guard policy.authorizes(.foundationModels, for: .personalNarrative) else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .foundationModels,
                reason: RuleFallbackReason.providerDisabled.rawValue
            )
        }
        let instructions = Prompts.BehaviorNarrativeFM.systemInstruction + "\n" + narrativeLanguageInstruction(language)
        let prompt = """
        [Deterministic summary]
        \(baseline.summary)

        [Deterministic insights]
        \(baseline.insights.joined(separator: "\n"))

        [Deterministic behavior facts]
        \(behaviorFacts(baseline.behaviorProfile))

        [Record scope]
        \(baseline.accessScopeSummary)

        Rewrite the supplied deterministic facts only; do not add recommendations or unsupported analysis.
        """
        LLMDebugLogger.request(
            provider: "AFM",
            operation: "narrateBehavior",
            metadata: ["sampleCount: \(baseline.behaviorProfile.sampleCount)", "insightCount: \(baseline.insights.count)"],
            systemPrompt: instructions,
            userPrompt: prompt
        )
        let output = try await runtime.narrateBehavior(
            instructions: instructions,
            userPrompt: prompt
        )
        let narrative = BehaviorNarrative(summary: output.summary, insights: output.insights)
        LLMDebugLogger.response(
            provider: "AFM",
            operation: "narrateBehavior",
            text: "summary=\(narrative.summary)\ninsights=\(narrative.insights)"
        )
        return narrative
    }

    // MARK: - 회의 전사 분석

    /// 회의 전사문을 온디바이스 LLM으로 분석해 요약·결정·질문·액션 후보를 만든다.
    /// `sourceSegmentNumber`(1-based)를 실제 `segment.id`로 매핑하고, 목록 밖
    /// 번호나 빈 제목은 버려 환각 액션이 태스크로 새지 않게 한다.
    func analyzeMeeting(
        meetingID: String,
        segments: [MeetingSegment],
        glossaryHint: String = "",
        sourceLanguageTag: String,
        summaryLanguageTag: String,
        language: AppLanguage,
        transcriptCharCap: Int = 6_000,
        supportsLocale: (Locale) -> Bool = { SystemLanguageModel.default.supportsLocale($0) }
    ) async throws -> ProviderMeetingExtraction {
        guard policy.authorizes(.foundationModels, for: .meetingAnalysis) else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .foundationModels,
                reason: RuleFallbackReason.providerDisabled.rawValue
            )
        }
        try MeetingSummaryLanguages.requireSupport(
            provider: .foundationModels,
            sourceLanguageTag: sourceLanguageTag,
            summaryLanguageTag: summaryLanguageTag,
            supportsLocale: supportsLocale
        )
        // 컨텍스트 창(~4096토큰) 방어: 문자 예산 안에서만 구간을 전달한다.
        var numbered = [String]()
        var included = [MeetingSegment]()   // 1-based 번호 → segment 매핑
        var used = 0
        for segment in segments {
            let line = "\(included.count + 1). \(segment.text)"
            if used + line.count > transcriptCharCap, !included.isEmpty { break }
            numbered.append(line)
            included.append(segment)
            used += line.count
        }
        guard !included.isEmpty else {
            return ProviderMeetingExtraction(title: "", summary: "", decisions: [], unresolvedQuestions: [], actionDrafts: [])
        }
        let glossaryBlock = Self.glossaryBlock(glossaryHint, language: language)
        let prompt = """
        \(glossaryBlock)[전사 구간]
        \(numbered.joined(separator: "\n"))

        \(Prompts.MeetingFM.requestSuffix(sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: summaryLanguageTag))
        """
        let instructions = Prompts.MeetingFM.systemInstruction(
            sourceLanguageTag: sourceLanguageTag,
            summaryLanguageTag: summaryLanguageTag
        )
        LLMDebugLogger.request(
            provider: "AFM",
            operation: "analyzeMeeting",
            metadata: [
                "meetingID: \(meetingID)",
                "includedSegments: \(included.count)",
                "transcriptCharCap: \(transcriptCharCap)"
            ],
            systemPrompt: instructions,
            userPrompt: prompt
        )
        let output = try await runtime.analyzeMeeting(
            instructions: instructions,
            userPrompt: prompt
        )
        LLMDebugLogger.response(
            provider: "AFM",
            operation: "analyzeMeeting",
            text: "title=\(output.title)\nsummary=\(output.summary)\ndecisions=\(output.decisions.joined(separator: " | "))\nunresolvedQuestions=\(output.unresolvedQuestions.joined(separator: " | "))\nactions=\(output.actions.map { "#\($0.sourceSegmentNumber) title=\($0.title) due=\($0.dueDateISO) notes=\($0.notes)" }.joined(separator: "\n"))"
        )

        let drafts: [ProviderActionDraftInput] = output.actions.compactMap { item in
            let index = item.sourceSegmentNumber - 1
            guard index >= 0, index < included.count else { return nil }
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let due = item.dueDateISO.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProviderActionDraftInput(
                title: title,
                notes: item.notes.trimmingCharacters(in: .whitespacesAndNewlines),
                assignee: nil,
                dueAtISO8601: due.isEmpty ? nil : due,
                sourceSegmentIDs: [included[index].id],
                confidence: 0.7,
                requiresReview: true
            )
        }
        return ProviderMeetingExtraction(
            title: output.title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: output.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: output.decisions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            unresolvedQuestions: output.unresolvedQuestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            actionDrafts: drafts
        )
    }

    // MARK: - 회의 전사 교정 (녹음 완료·재전사 후)

    /// 전사 구간의 명백한 음성 인식 오류·오탈자만 온디바이스로 교정한다.
    /// 실시간이 아닌 배치 시점에 실행해 요약 품질을 높이는 것이 목적이다.
    ///
    /// 환각 방어(analyzeMeeting과 동일 계열):
    ///   - 배치별 1-based 번호 + `sourceSegmentNumber` 범위 검증.
    ///   - 교정본은 구간 텍스트만 대체 — 개수·타이밍·화자·순서 불변.
    ///   - 빈 텍스트·과도한 길이 변화(±40% 초과)는 원문 유지(재작성 방어).
    ///   - 배치별 fresh 세션 → 호출 간 transcript 누적 없음. 배치 실패는 원문 보존 후 계속.
    ///
    /// - Returns: corrected segments plus exact batch success/failure accounting.
    func correctTranscript(
        segments: [MeetingSegment],
        glossaryHint: String = "",
        sourceLanguageTag: String,
        language: AppLanguage,
        batchCharCap: Int = 2_000,
        supportsLocale: (Locale) -> Bool = { SystemLanguageModel.default.supportsLocale($0) }
    ) async throws -> TranscriptCorrectionBatchResult {
        guard policy.authorizes(.foundationModels, for: .transcriptRefinement) else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .foundationModels,
                reason: RuleFallbackReason.providerDisabled.rawValue
            )
        }
        try MeetingSummaryLanguages.requireSupport(
            provider: .foundationModels,
            sourceLanguageTag: sourceLanguageTag,
            summaryLanguageTag: sourceLanguageTag,
            supportsLocale: supportsLocale
        )
        guard !segments.isEmpty else {
            return TranscriptCorrectionBatchResult(
                segments: segments,
                attemptedBatchCount: 0,
                succeededBatchCount: 0,
                failedBatchCount: 0
            )
        }

        // 문자 예산 단위로 전 구간을 배치 분할(analyzeMeeting은 앞부분만, 교정은 전체 커버).
        var batches = [[Int]]()
        var current = [Int]()
        var used = 0
        for index in segments.indices {
            let lineLen = segments[index].text.count + 8
            if used + lineLen > batchCharCap, !current.isEmpty {
                batches.append(current); current = []; used = 0
            }
            current.append(index); used += lineLen
        }
        if !current.isEmpty { batches.append(current) }

        var corrected = segments
        var succeededBatchCount = 0
        var failedBatchCount = 0
        let glossaryBlock = Self.glossaryBlock(glossaryHint, language: language)
        let genOptions = GenerationOptions(maximumResponseTokens: 1_500)
        let instructions = Prompts.MeetingCorrectionFM.systemInstruction(sourceLanguageTag: sourceLanguageTag)

        for batch in batches {
            let numbered = batch.enumerated()
                .map { "\($0.offset + 1). \(segments[$0.element].text)" }
                .joined(separator: "\n")
            let prompt = """
            \(glossaryBlock)[전사 구간]
            \(numbered)

            \(Prompts.MeetingCorrectionFM.requestSuffix(sourceLanguageTag: sourceLanguageTag))
            """
            let operation = "correctTranscript batch \(succeededBatchCount + failedBatchCount + 1)/\(batches.count)"
            LLMDebugLogger.request(
                provider: "AFM",
                operation: operation,
                metadata: [
                    "batchSegments: \(batch.count)",
                    "batchCharCap: \(batchCharCap)",
                    "maximumResponseTokens: 1500"
                ],
                systemPrompt: instructions,
                userPrompt: prompt
            )
            do {
                let output = try await runtime.correctTranscript(
                    instructions: instructions,
                    userPrompt: prompt,
                    options: genOptions
                )
                LLMDebugLogger.response(
                    provider: "AFM",
                    operation: operation,
                    text: output.corrections.map { "#\($0.sourceSegmentNumber) \($0.correctedText)" }.joined(separator: "\n")
                )
                for correction in output.corrections {
                    let local = correction.sourceSegmentNumber - 1
                    guard local >= 0, local < batch.count else { continue }
                    let globalIndex = batch[local]
                    let newText = correction.correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard MeetingCorrectionGuard.isAcceptable(old: segments[globalIndex].text, new: newText) else { continue }
                    corrected[globalIndex].text = newText
                }
                succeededBatchCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                LLMDebugLogger.failure(provider: "AFM", operation: operation, error: error)
                failedBatchCount += 1
            }
        }
        return TranscriptCorrectionBatchResult(
            segments: corrected,
            attemptedBatchCount: batches.count,
            succeededBatchCount: succeededBatchCount,
            failedBatchCount: failedBatchCount
        )
    }

    /// 단어장 힌트를 프롬프트 앞에 붙일 블록으로 만든다. 비어 있으면 빈 문자열.
    private static func glossaryBlock(_ hint: String, language: AppLanguage) -> String {
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let label = AppLanguage.localized(
            "meeting.glossary.label",
            defaultValue: language == .english ? "User Vocabulary" : "사용자 단어장",
            language: language,
            comment: "Meeting prompt glossary section label"
        )
        return """
        [\(label)]
        \(trimmed)

        """
    }

    /// 이메일에서 제목/메모/마감일 초안을 생성한다.
    /// 본문 캡 ~1500자, AFM 전용(온디바이스) 처리.
    /// 추론 실패 시 throws -> 상위 계층에서 결정적 폴백 수행.
    func draftTodoFromEmail(
        _ msg: GmailMessage,
        now: Date,
        language: AppLanguage = .current
    ) async throws -> EmailTodoDraft {
        guard policy.authorizes(.foundationModels, for: .emailAnalysis) else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .foundationModels,
                reason: RuleFallbackReason.providerDisabled.rawValue
            )
        }
        let bodyPreview = String(msg.body.prefix(1500))

        let instructions = Prompts.EmailFM.systemInstruction(language: language) + "\n" + outputLanguageInstruction(language)
        let prompt = """
        현재 시각: \(AppDateFormat.llmString(from: now))
        발신자: \(msg.from)
        제목: \(msg.subject)
        본문: \(bodyPreview.isEmpty ? "(본문 없음)" : bodyPreview)

        추가 출력 요구: title은 사용자가 수행할 일을 40자 이내 \(language.outputLanguageName) 동사형으로 작성하세요. notes는 인사말 없이 핵심 내용과 액션 아이템만 1-3줄로 작성하세요.
        """

        LLMDebugLogger.request(
            provider: "AFM",
            operation: "draftTodoFromEmail",
            metadata: ["subject: \(msg.subject)", "bodyPreviewChars: \(bodyPreview.count)"],
            systemPrompt: instructions,
            userPrompt: prompt
        )
        let output = try await runtime.draftTodoFromEmail(
            instructions: instructions,
            userPrompt: prompt
        )
        LLMDebugLogger.response(provider: "AFM", operation: "draftTodoFromEmail", text: "title=\(output.title)\nnotes=\(output.notes)\ndueDateISO=\(output.dueDateISO) isAllDay=\(output.isAllDay) sender=\(output.sender) senderEmail=\(output.senderEmail)")

        let normalizedTitle = output.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if !normalizedTitle.isEmpty {
            title = normalizedTitle
        } else if !msg.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = msg.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = AppLanguage.localized(
                "mail.checkEmail",
                defaultValue: language == .english ? "Check Email" : "메일 확인",
                language: language,
                comment: "Email fallback Todo title"
            )
        }

        var dueDate: Date?
        var isAllDay = false
        if !output.dueDateISO.isEmpty, let parsed = AppDateFormat.parseMailDate(output.dueDateISO), parsed > now {
            var finalDate = parsed
            isAllDay = output.isAllDay
            let sourceCalendar = AppDateFormat.sourceCalendar(for: output.dueDateISO)
            let comps = sourceCalendar.dateComponents([.hour, .minute, .second], from: parsed)
            if comps.hour == 0 && comps.minute == 0 && (comps.second ?? 0) == 0 {
                isAllDay = true
                var eod = sourceCalendar.dateComponents([.year, .month, .day], from: parsed)
                eod.hour = 23
                eod.minute = 59
                finalDate = sourceCalendar.date(from: eod) ?? parsed
            }
            dueDate = finalDate
        }

        let cleanNotes = output.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = output.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedSender = sender.isEmpty
            ? EmailContentAnalyzer().parseSender(from: msg.from)
            : sender
        let senderEmail = output.senderEmail.trimmingCharacters(in: .whitespacesAndNewlines)

        var notesLines = [
            AppLanguage.localized(
                "mail.summaryHeader",
                defaultValue: language == .english ? "[Email Summary]" : "[메일 요약]",
                language: language,
                comment: "Email summary header"
            )
        ]
        if !cleanNotes.isEmpty {
            notesLines.append(cleanNotes)
        } else if !msg.snippet.isEmpty {
            notesLines.append(msg.snippet.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if !bodyPreview.isEmpty {
            notesLines.append(String(bodyPreview.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        notesLines.append(
            AppLanguage.localized(
                "mail.aiSummary",
                defaultValue: language == .english ? "(AI Summary)" : "(AI 요약)",
                language: language,
                comment: "AI-generated email summary marker"
            )
        )
        notesLines.append("")
        notesLines.append(
            {
                let defaultValue = language == .english
                    ? "[Sender] \(parsedSender)"
                    : "[발신자] \(parsedSender)"
                let localized = AppLanguage.localized(
                    "mail.sender",
                    defaultValue: defaultValue,
                    language: language,
                    comment: "Email sender label"
                )
                return localized == defaultValue
                    ? localized
                    : String(format: localized, locale: language.locale, parsedSender)
            }()
        )

        return EmailTodoDraft(
            title: title,
            notes: notesLines.joined(separator: "\n"),
            dueDate: dueDate,
            isAllDay: isAllDay,
            sender: parsedSender,
            senderEmail: senderEmail
        )
    }


    // MARK: - Prompt Builders (우선순위)

    private func buildRankingInstructions(
        persona: PersonaContext,
        language: AppLanguage
    ) -> String {
        var parts = [Prompts.RankingFM.baseInstruction(language: language)]
        if !persona.types.isEmpty { parts.append("사용자 유형: \(persona.displayNames)") }
        if !persona.description.isEmpty {
            parts.append("사용자 가치관:\n\(String(persona.description.prefix(inputCharCap)))")
        }
        let keywords = persona.weightedKeywords
        if !keywords.isEmpty {
            parts.append("핵심 업무 키워드: \(keywords.joined(separator: ", "))")
        }
        let memory = MemoryService.shared.summary
        if !memory.isEmpty {
            parts.append("사용자 행동 패턴 (참고):\n\(String(memory.prefix(inputCharCap)))")
        }
        parts.append(outputLanguageInstruction(language))
        return parts.joined(separator: "\n")
    }

    /// E-1/E-2: 배치 슬라이스(전역 인덱스 포함) + 이벤트로 랭킹 프롬프트 생성.
    /// 제목은 E-3 가드(60자 절단) 적용.
    private func buildRankingPrompt(
        indexedBatch: [(idx: Int, todo: Todo)],
        events: [CalendarService.CalendarEventSummary],
        language: AppLanguage
    ) -> String {
        var lines = ["현재 시각: \(AppDateFormat.llmString(from: Date()))"]
        if !events.isEmpty {
            lines.append("\n[캘린더 이벤트 (향후 7일)]")
            for e in events.prefix(5) {
                lines.append("• \(e.title) — \(AppDateFormat.llmString(from: e.startDate))")
            }
        }
        lines.append("\n[우선순위 평가 대상 할 일]")
        for (idx, todo) in indexedBatch {
            let title = String(todo.title.prefix(60))
            var ps = ["번호:\(idx)", "제목:\(title)"]
            if let due = todo.dueDate {
                let remaining = AppDateFormat.remainingTimeDescription(
                    for: due,
                    now: Date(),
                    language: language
                )
                ps.append("마감:\(AppDateFormat.llmString(from: due)) (\(remaining))")
            }
            if !todo.tags.isEmpty { ps.append("태그:\(todo.tags.joined(separator: ","))") }
            let src: String
            switch todo.todoSource {
            case .manual: src = "직접입력"
            case .email: src = "이메일"
            case .calendar: src = "캘린더"
            case .meeting: src = "회의"
            }
            ps.append("출처:\(src)")
            if todo.isFixedSchedule { ps.append("고정(주기)") }
            lines.append("• " + ps.joined(separator: " | "))
        }
        lines.append(
            "\nReturn the rankings array for these to-dos."
        )
        return lines.joined(separator: "\n")
    }

    private func behaviorFacts(_ profile: BehaviorProfile) -> String {
        let metrics = profile.insights.map { insight in
            "\(insight.metric.rawValue): value=\(insight.value), numerator=\(insight.numerator), denominator=\(insight.denominator), confidence=\(insight.confidence.rawValue), trend=\(insight.trend.rawValue)"
        }
        let classifications = profile.classifications.map { classification in
            "\(classification.dimension.rawValue): \(classification.label.rawValue), confidence=\(classification.confidence.rawValue)"
        }
        return (metrics + classifications + [
            "sampleCount=\(profile.sampleCount)",
            "effectiveSampleSize=\(profile.effectiveSampleSize)",
            "overallConfidence=\(profile.confidence.rawValue)"
        ]).joined(separator: "\n")
    }

    private func narrativeLanguageInstruction(_ language: AppLanguage) -> String {
        "Write every generated natural-language field in \(language.outputLanguageName). Do not translate or invent source facts."
    }

    private func outputLanguageInstruction(_ language: AppLanguage) -> String {
        "Write every natural-language output field in \(language.outputLanguageName). Preserve source email content; do not translate it."
    }
}
@available(iOS 26.0, *)
extension FoundationModelsService: MeetingRefinementProvider {
    func correct(
        segments: [MeetingSegment],
        glossaryHint: String,
        sourceLanguageTag: String,
        language: AppLanguage
    ) async throws -> TranscriptCorrectionBatchResult {
        try await correctTranscript(
            segments: segments,
            glossaryHint: glossaryHint,
            sourceLanguageTag: sourceLanguageTag,
            language: language
        )
    }
}
#endif
