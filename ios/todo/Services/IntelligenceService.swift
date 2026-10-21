import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Engine Source

/// 우선순위 산출 실제 주체. Todo.aiEngine에 rawValue로 저장되어 UI 배지에 표시된다.
/// "휴리스틱"이면 LLM 경로가 실패해 규칙 기반으로 폴백됐음을 의미한다.
enum PriorityEngine: String, Sendable {
    case foundationModels = "Apple AI"   // ANE 실행
    case onDeviceMLX      = "온디바이스 AI" // GPU/MLX 실행
    case openAI           = "OpenAI"   // user-authorized ChatGPT plan Responses API
    case laya             = "Laya"       // multilingual on-device Core ML, priority only
    case heuristic        = "휴리스틱"   // LLM 실패 폴백 — 규칙 기반

    var displayName: String {
        displayName(language: .current)
    }

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .foundationModels:
            return "Apple AI"
        case .onDeviceMLX:
            return AppLanguage.localized("intelligence.engine.onDevice", defaultValue: "On Device AI", language: language)
        case .openAI:
            return "OpenAI"
        case .laya:
            return "Laya"
        case .heuristic:
            return AppLanguage.localized("intelligence.engine.heuristic", defaultValue: "Heuristic", language: language)
        }
    }

}

// MARK: - Result

struct PriorityResult: Sendable, Equatable {
    let todoID: UUID
    let score: Double          // 0.0 ~ 1.0 (axes 있으면 ScheduleScorer 재산출, 없으면 레거시)
    let reason: String         // 40자 이내 한 줄 요약
    let detail: String         // 세부 설명 (빈 문자열 가능)
    let needsNotification: Bool
    let recommendedTime: Date? // nil = 추천 없음
    let personaFit: Bool       // 페르소나 부합 여부
    let engine: PriorityEngine // 실제 산출 엔진 식별자 (UI 배지용)
    // 4축 (nil = 레거시 단일 score 경로, 하위호환)
    var axes: AxisScores? = nil
    var chainingDetail: String = ""
    var requestedProviderRawValue: String = ""
    var fallbackReason: String = ""
    var executionPath: AnalysisExecutionPath = .rules(.noProviderOptIn)
}

enum IntelligenceProgressEvent: Equatable, Sendable {
    case preparing(total: Int, requestedProvider: String)
    case requesting(index: Int, total: Int, title: String, provider: String)
    case received(index: Int, total: Int, title: String, provider: String)
    case fallback(from: String, to: String, reason: String)
    case result(PriorityResult, index: Int, total: Int, title: String)
    case applying(index: Int, total: Int, title: String)
    case completed(finalProvider: String, total: Int)
}

typealias IntelligenceProgressHandler = @MainActor @Sendable (IntelligenceProgressEvent) -> Void

// MARK: - Persona Context

/// 우선순위 산출에 주입되는 페르소나 컨텍스트.
/// types: 온보딩에서 선택한 생활 유형 목록 (다중 선택, HeuristicEngine 키워드 가중치에 사용).
/// description: 자연어 페르소나 (클라우드 AI 프롬프트에 삽입).
struct PersonaContext: Sendable {
    let types: [PersonaType]
    let description: String

    static let empty = PersonaContext(types: [], description: "")

    /// 모든 선택 유형의 가중 키워드 합집합
    var weightedKeywords: [String] {
        Array(Set(types.flatMap { $0.weightedKeywords }))
    }

    var displayNames: String {
        types.isEmpty ? "" : types.map { $0.displayName }.joined(separator: ", ")
    }
}

// MARK: - Protocol

/// 페르소나·캘린더 컨텍스트 기반 할 일 우선순위 산출 서비스.
@MainActor
protocol IntelligenceService: Sendable {
    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext,
        progress: IntelligenceProgressHandler?
    ) async throws -> [PriorityResult]
}

extension IntelligenceService {
    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext
    ) async throws -> [PriorityResult] {
        try await prioritize(todos: todos, events: events, persona: persona, progress: nil)
    }
}

enum IntelligenceRoutingError: LocalizedError, Sendable {
    case backendUnavailable(provider: PersonaAIProvider, reason: String)
    case backendNotConfigured(provider: PersonaAIProvider, reason: String)
    case generationFailed(provider: PersonaAIProvider, reason: String)
    case parseFailed(provider: PersonaAIProvider, reason: String)

    var errorDescription: String? {
        errorDescription(language: .current)
    }

    func errorDescription(language: AppLanguage) -> String {
        let providerName: String
        switch self {
        case .backendUnavailable(let provider, _),
             .backendNotConfigured(let provider, _),
             .generationFailed(let provider, _),
             .parseFailed(let provider, _):
            providerName = provider.displayName(language: language)
        }
        switch self {
        case .backendUnavailable:
            return String(format: AppLanguage.localized("error.intelligence.backendUnavailable", defaultValue: "%@ is unavailable on this device.", language: language), locale: language.locale, String(providerName))
        case .backendNotConfigured:
            return String(format: AppLanguage.localized("error.intelligence.backendNotConfigured", defaultValue: "%@ is not configured.", language: language), locale: language.locale, String(providerName))
        case .generationFailed:
            return String(format: AppLanguage.localized("error.intelligence.generationFailed", defaultValue: "%@ could not generate a result.", language: language), locale: language.locale, String(providerName))
        case .parseFailed:
            return String(format: AppLanguage.localized("error.intelligence.parseFailed", defaultValue: "%@ returned an invalid result.", language: language), locale: language.locale, String(providerName))
        }
    }
}

private func normalizeRequestedProvider(_ rawValue: String?) -> PersonaAIProvider {
    guard let rawValue, let provider = PersonaAIProvider(rawValue: rawValue) else {
        return .foundationModels
    }
    return provider
}

private func emitResultEvents(
    _ results: [PriorityResult],
    todos: [Todo],
    progress: IntelligenceProgressHandler?
) {
    let total = results.count
    for (offset, result) in results.enumerated() {
        let title = todos.first(where: { $0.id == result.todoID })?.title
            ?? AppLanguage.localized(
                "todo.untitled",
                defaultValue: AppLanguage.current == .english ? "(No Title)" : "(제목 없음)",
                language: .current,
                comment: "Untitled to-do progress label"
            )
        progress?(.result(result, index: offset + 1, total: total, title: title))
    }
}

private func annotateResults(
    _ results: [PriorityResult],
    requestedProvider: PersonaAIProvider,
    fallbackReason: String
) -> [PriorityResult] {
    results.map { result in
        var updated = result
        updated.requestedProviderRawValue = requestedProvider.rawValue
        let combinedReasons = [fallbackReason, updated.fallbackReason]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        updated.fallbackReason = combinedReasons.joined(separator: " → ")
        return updated
    }
}

// MARK: - Heuristic Weights (페르소나·행동 패턴 기반 하이퍼파라미터)

struct HeuristicWeights {
    var urgencyKeywordBoost: Double  = 2.0   // 긴급 키워드 감지 시 urgency += 이 값
    var emailSourceBoost: Double     = 1.0   // 이메일 출처 urgency boost
    var importantTagBoost: Double    = 2.0   // 중요 태그 importance boost
    var personaKeywordBoost: Double  = 1.5   // 제목/태그 내 페르소나 키워드 importance boost
    var notesPersonaBoost: Double    = 1.0   // 메모 내 페르소나 키워드 importance boost (제목보다 낮게)
    var fastTagBoost: Double         = 0.5   // 행동 패턴 빠른 태그 importance boost
    var deadlineMultiplier: Double   = 1.0   // 생산적 시간대 활성 시 ~1.15

    /// 페르소나 타입과 행동 패턴(MemoryService)에서 적응형 가중치를 도출한다.
    static func adaptive(persona: PersonaContext, memory: MemoryService) -> HeuristicWeights {
        var w = HeuristicWeights()
        for ptype in persona.types {
            switch ptype {
            case .officeWorker:
                w.emailSourceBoost    = max(w.emailSourceBoost,    1.5)
                w.personaKeywordBoost = max(w.personaKeywordBoost, 2.0)
                w.importantTagBoost   = max(w.importantTagBoost,   2.5)
            case .freelancer:
                w.urgencyKeywordBoost = max(w.urgencyKeywordBoost, 2.5)
                w.personaKeywordBoost = max(w.personaKeywordBoost, 2.0)
                w.emailSourceBoost    = max(w.emailSourceBoost,    1.3)
            case .student:
                w.personaKeywordBoost = max(w.personaKeywordBoost, 2.0)
                w.urgencyKeywordBoost = max(w.urgencyKeywordBoost, 2.0)
            case .jobSeeker:
                w.personaKeywordBoost = max(w.personaKeywordBoost, 2.5)
                w.urgencyKeywordBoost = max(w.urgencyKeywordBoost, 2.0)
            case .selfEmployed:
                w.personaKeywordBoost = max(w.personaKeywordBoost, 2.0)
                w.emailSourceBoost    = max(w.emailSourceBoost,    1.3)
            case .homemaker:
                w.personaKeywordBoost = max(w.personaKeywordBoost, 1.8)
            case .other, .unspecified:
                break
            }
        }
        if let ph = memory.productiveHour {
            let hour = Calendar.current.component(.hour, from: Date())
            if abs(hour - ph) <= 2 {
                w.deadlineMultiplier  = 1.15
                w.urgencyKeywordBoost = min(w.urgencyKeywordBoost * 1.2, 3.0)
            }
        }
        if memory.overdueRate > 0.3 {
            w.urgencyKeywordBoost = min(w.urgencyKeywordBoost * 1.1, 3.0)
        }
        return w
    }
}

// MARK: - Heuristic Engine (항상 동작하는 규칙 기반 fallback)

/// 4축 결정론적 산출 + ScheduleScorer 수동 계산 — 모델 폴백 시에도 동일 구조 보장.
struct HeuristicEngine: IntelligenceService {
    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext,
        progress: IntelligenceProgressHandler?
    ) async throws -> [PriorityResult] {
        let context = RuleAnalysisContextBuilder.make(
            todos: todos,
            calendarEvents: events,
            persona: persona,
            now: Date(),
            calendar: Calendar.current
        )
        let eligible = context.candidates.filter {
            !$0.isCompleted && $0.triage == .todo && $0.manualPriority == nil
        }
        let results = eligible
            .map { RuleBasedPriorityAnalyzer.classify($0, context: context) }
            .sorted { left, right in
                guard let lhs = eligible.first(where: { $0.id == left.todoID }),
                      let rhs = eligible.first(where: { $0.id == right.todoID }) else {
                    return left.todoID.uuidString < right.todoID.uuidString
                }
                return Self.higherPriorityFirst(left, right, lhs: lhs, rhs: rhs, now: context.now)
            }
        emitResultEvents(results, todos: todos, progress: progress)
        return results
    }
    /// Legacy localization compatibility for callers that display the no-deadline explanation.
    func heuristicReason(todo: Todo, persona: PersonaContext, language: AppLanguage) -> String {
        guard todo.dueDate == nil else {
            return AppLanguage.localized("priority.reason.rules.withDeadline", defaultValue: "Rule-based priority", language: language)
        }
        return AppLanguage.localized("priority.reason.rules.noDeadline", defaultValue: "No deadline — low default priority", language: language)
    }

    private static func higherPriorityFirst(
        _ lhs: PriorityResult,
        _ rhs: PriorityResult,
        lhs left: TodoPriorityCandidateSnapshot,
        rhs right: TodoPriorityCandidateSnapshot,
        now: Date
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let leftOverdue = left.dueDate.map { $0 < now } ?? false
        let rightOverdue = right.dueDate.map { $0 < now } ?? false
        if leftOverdue != rightOverdue { return leftOverdue }
        switch (left.dueDate, right.dueDate) {
        case let (a?, b?) where a != b: return a < b
        case (nil, .some): return false
        case (.some, nil): return true
        default: break
        }
        if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
        return left.id.uuidString < right.id.uuidString
    }
}

// MARK: - Foundation Models Engine (WWDC 2026 — Guided Generation, ANE)

/// Foundation Models(SystemLanguageModel) 기반 우선순위 산출 엔진.
///
/// FoundationModels.framework가 링크되고 Apple Intelligence가 가용하면
/// FoundationModelsService.rankTodos()로 Guided Generation 실행.
/// 비가용 시(구형 기기, FM 미활성, 링크 없음) HeuristicEngine으로 자동 폴백.
///
/// 재링크 조건: Xcode > 타깃 > Frameworks, Libraries → FoundationModels.framework 추가.
/// 모든 코드는 #if canImport(FoundationModels) + @available(iOS 26.0, *) 로 격리.
final class FoundationModelsEngine: IntelligenceService {
    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext,
        progress: IntelligenceProgressHandler?
    ) async throws -> [PriorityResult] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelsAvailability.isAvailable {
            let sorted = todos.filter(\.isEligibleForAutomaticPriority).sorted {
                switch ($0.dueDate, $1.dueDate) {
                case (let a?, let b?): return a < b
                case (.some, .none): return true
                default: return false
                }
            }
            let active = Array(sorted.prefix(20))
            guard !active.isEmpty else { return [] }
            let batchTitle = AppLanguage.localizedCount("priority.batchTitle", count: active.count, defaultValue: "%lld-item batch", language: .current)
            progress?(.requesting(
                index: 1,
                total: 1,
                title: batchTitle,
                provider: PriorityEngine.foundationModels.displayName
            ))
            do {
                let results = try await rankTodosWithTimeout(
                    todos: active,
                    events: events,
                    persona: persona,
                    language: .current
                )
                progress?(.received(
                    index: 1,
                    total: 1,
                    title: batchTitle,
                    provider: PriorityEngine.foundationModels.displayName
                ))
                emitResultEvents(results, todos: active, progress: progress)
                return results
            } catch let genErr as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize(let tokenCount) = genErr {
                    throw IntelligenceRoutingError.generationFailed(
                        provider: .foundationModels,
                        reason: "Apple Foundation Models 컨텍스트 초과 (\(tokenCount) 토큰)"
                    )
                }
                throw IntelligenceRoutingError.generationFailed(
                    provider: .foundationModels,
                    reason: genErr.localizedDescription
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw IntelligenceRoutingError.generationFailed(
                    provider: .foundationModels,
                    reason: error.localizedDescription
                )
            }
        }
        #endif
        throw IntelligenceRoutingError.backendUnavailable(
            provider: .foundationModels,
            reason: AppLanguage.localized(
                "error.intelligence.unavailable",
                defaultValue: AppLanguage.current == .english
                    ? "Apple Foundation Models are unavailable on this device."
                    : "Apple Foundation Models를 이 기기에서 사용할 수 없습니다.",
                language: .current,
                comment: "Intelligence backend unavailable error"
            )
        )
    }

    private func rankTodosWithTimeout(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext,
        language: AppLanguage,
        timeoutSeconds: UInt64 = 15
    ) async throws -> [PriorityResult] {
        try await withThrowingTaskGroup(of: [PriorityResult].self) { group in
            group.addTask { @MainActor in
                try await FoundationModelsService().rankTodos(
                    todos: todos,
                    events: events,
                    persona: persona,
                    language: language
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw IntelligenceRoutingError.generationFailed(
                    provider: .foundationModels,
                    reason: AppLanguage.localized("error.intelligence.timeout", defaultValue: "Apple AI took too long to respond.", language: AppLanguage.current)
                )
            }

            guard let results = try await group.next() else { return [] }
            group.cancelAll()
            return results
        }
    }
}

// MARK: - On-Device LLM Intelligence Engine (timesorter-v9 / MLX)

/// timesorter-scheduler-v9-ko MLX 파인튜닝 모델 기반 우선순위 산출 엔진.
///
/// 입력: ScheduleInput JSON (current_time / user_persona / tasks[]).
/// 출력: ScheduleResponseV9 JSON (4축 scoring + reasoning + recommended_schedule).
/// total_score는 모델 출력값을 무시하고 ScheduleScorer + 적응형 가중치로 재산출.
final class OnDeviceLLMIntelligenceEngine: IntelligenceService {
    private static func systemPrompt(language: AppLanguage = .current) -> String {
        ScheduleLLMAdapter.systemPrompt(language: language)
    }

    private static func buildScheduleInput(
        todos: [Todo],
        persona: PersonaContext,
        events: [CalendarService.CalendarEventSummary]
    ) -> String {
        ScheduleLLMAdapter.buildScheduleInput(
            todos: todos, persona: persona, events: events, allowsPrivateCalendarTitles: true
        )
    }

    func parseScheduleResponseV9(
        text: String,
        todos: [Todo],
        persona: PersonaContext
    ) -> [PriorityResult]? {
        ScheduleLLMAdapter.parseScheduleResponseV9(
            text: text,
            todos: todos,
            persona: persona,
            engine: .onDeviceMLX
        )
    }

    // MARK: prioritize

    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext,
        progress: IntelligenceProgressHandler?
    ) async throws -> [PriorityResult] {
        let service = OnDeviceLLMService.shared
        guard service.isCapable else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .onDevice,
                reason: "이 기기는 현재 Qwen 로컬 실행 기준(메모리 6GB 이상)을 충족하지 않습니다."
            )
        }
        if service.isModelCachedOnDisk {
            await service.loadModelIfNeeded(use: .standardAnalysis)
        }

        guard service.isModelLoaded else {
            let reason = service.isModelCachedOnDisk
                ? (service.loadError ?? "온디바이스 모델을 로드할 수 없습니다.")
                : "온디바이스 모델이 아직 다운로드되지 않았습니다."
            throw IntelligenceRoutingError.backendUnavailable(provider: .onDevice, reason: reason)
        }

        let sortedActive = todos.filter(\.isEligibleForAutomaticPriority).sorted {
            switch ($0.dueDate, $1.dueDate) {
            case (let a?, let b?): return a < b
            case (.some, .none):   return true
            default:               return false
            }
        }
        let active = Array(sortedActive.prefix(15))
        guard !active.isEmpty else { return [] }

        let batchTitle = AppLanguage.localizedCount("priority.batchTitle", count: active.count, defaultValue: "%lld-item batch", language: .current)
        let isMiniCPM = service.modelID == OnDeviceLLMService.miniCPMModelID
        let maxTokens = isMiniCPM ? max(360, min(760, active.count * 95)) : max(512, min(1_200, active.count * 140))
        let scheduleInput = Self.buildScheduleInput(todos: active, persona: persona, events: events)
        debugLogRequest(
            todos: active,
            events: events,
            persona: persona,
            systemPrompt: Self.systemPrompt(language: AppLanguage.current),
            scheduleInput: scheduleInput,
            maxTokens: maxTokens,
            modelID: service.modelID
        )

        var text: String
        progress?(.requesting(
            index: 1,
            total: 1,
            title: batchTitle,
            provider: PriorityEngine.onDeviceMLX.displayName
        ))
        do {
            print("[OnDeviceMLX][rankTodos] stage=generate-request todoCount=\(active.count) inputChars=\(scheduleInput.count) maxTokens=\(maxTokens) model=\(service.modelID) compact=\(isMiniCPM)")
            if isMiniCPM {
                text = try await compactJSONSchedule(
                    service: service,
                    todos: active,
                    events: events,
                    persona: persona,
                    maxTokens: maxTokens
                )
            } else {
                text = try await service.generate(
                    systemPrompt: Self.systemPrompt(language: AppLanguage.current),
                    userPrompt: scheduleInput,
                    maxTokens: maxTokens,
                    use: .standardAnalysis
                )
            }
            print("[OnDeviceMLX][rankTodos] stage=generate-response chars=\(text.count) preview=\(Self.logPreview(text))")
            debugLogRawOutput(text)
            progress?(.received(
                index: 1,
                total: 1,
                title: batchTitle,
                provider: PriorityEngine.onDeviceMLX.displayName
            ))
        } catch let llmError as OnDeviceLLMService.LLMError {
            DiagnosticRecorder.shared.record(
                error: llmError,
                component: "ai.prioritize",
                operation: "generateFailed"
            )
            print("[OnDeviceMLX][rankTodos] stage=generate-failed error=\(llmError.localizedDescription)")
            throw IntelligenceRoutingError.generationFailed(
                provider: .onDevice,
                reason: llmError.localizedDescription
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            DiagnosticRecorder.shared.record(
                error: error,
                component: "ai.prioritize",
                operation: "generateFailed"
            )
            print("[OnDeviceMLX][rankTodos] stage=generate-failed errorType=\(String(describing: type(of: error))) message=\(error.localizedDescription)")
            throw IntelligenceRoutingError.generationFailed(
                provider: .onDevice,
                reason: error.localizedDescription
            )
        }

        print("[OnDeviceMLX][rankTodos] stage=parse-start chars=\(text.count)")
        if let parsed = parseScheduleResponseV9(text: text, todos: active, persona: persona), !parsed.isEmpty {
            print("[OnDeviceMLX][rankTodos] stage=parse-success resultCount=\(parsed.count)")
            debugLogParsedResults(parsed, todos: active)
            emitResultEvents(parsed, todos: active, progress: progress)
            return parsed
        }

        print("[OnDeviceMLX][rankTodos] stage=parse-failed responseChars=\(text.count) preview=\(Self.logPreview(text))")
        DiagnosticRecorder.shared.record(
            error: DiagnosticFailure(code: 0, reason: "Schedule ranking response failed to parse"),
            component: "ai.prioritize",
            operation: "parseFailed"
        )
        LLMDebugLogger.event(
            provider: "OnDeviceMLX",
            operation: "schedule",
            title: "parseFailure",
            details: "responseChars=\(text.count) preview=\(Self.logPreview(text))"
        )

        do {
            print("[OnDeviceMLX][rankTodos] stage=json-retry-request reason=initialParseFailed")
            text = try await retryJSONOnlySchedule(
                service: service,
                todos: active,
                events: events,
                persona: persona
            )
            print("[OnDeviceMLX][rankTodos] stage=json-retry-response chars=\(text.count) preview=\(Self.logPreview(text))")
            if let parsed = parseScheduleResponseV9(text: text, todos: active, persona: persona), !parsed.isEmpty {
                print("[OnDeviceMLX][rankTodos] stage=json-retry-parse-success resultCount=\(parsed.count)")
                debugLogParsedResults(parsed, todos: active)
                emitResultEvents(parsed, todos: active, progress: progress)
                return parsed
            }
            print("[OnDeviceMLX][rankTodos] stage=json-retry-parse-failed responseChars=\(text.count) preview=\(Self.logPreview(text))")
        }
        catch is CancellationError {
            throw CancellationError()
        } catch {
            print("[OnDeviceMLX][rankTodos] stage=json-retry-failed errorType=\(String(describing: type(of: error))) message=\(error.localizedDescription)")
        }

        throw IntelligenceRoutingError.parseFailed(
            provider: .onDevice,
            reason: "온디바이스 모델 응답을 우선순위 JSON으로 해석하지 못했습니다."
        )
    }

    private func retryJSONOnlySchedule(
        service: OnDeviceLLMService,
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext
    ) async throws -> String {
        try await compactJSONSchedule(
            service: service,
            todos: todos,
            events: events,
            persona: persona,
            maxTokens: max(420, min(900, todos.count * 110))
        )
    }

    private func compactJSONSchedule(
        service: OnDeviceLLMService,
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext,
        maxTokens: Int
    ) async throws -> String {
        let system = """
        Return exactly one compact JSON object and nothing else. No markdown. No list. No explanation.
        Include scheduled_tasks for every task_id in the input. Scores are integers 1 to 10.
        Empty start_time is allowed. New text must be Korean.
        """
        let user = """
        Convert this JSON:
        \(Self.buildScheduleInput(todos: todos, persona: persona, events: events))

        Required output shape:
        {"scheduled_tasks":[{"task_id":"T1","scoring":{"deadline_proximity":5,"urgency":5,"task_importance":5,"task_chaining":2},"reasoning":{"summary":"짧은 근거","chaining_detail":""},"recommended_schedule":{"start_time":""}}]}
        """
        return try await service.generate(
            systemPrompt: system,
            userPrompt: user,
            maxTokens: maxTokens,
            contextLength: OnDeviceLLMService.defaultContextLength,
            use: .standardAnalysis
        )
    }

    private static func logPreview(_ text: String, limit: Int = 240) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        if singleLine.count <= limit { return singleLine }
        return String(singleLine.prefix(limit)) + "..."
    }

    private func debugLogRequest(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext,
        systemPrompt: String,
        scheduleInput: String,
        maxTokens: Int,
        modelID: String
    ) {
        LLMDebugLogger.request(
            provider: "OnDeviceMLX",
            operation: "rankTodos",
            metadata: [
                "modelID: \(modelID)",
                "maxTokens: \(maxTokens)",
                "todoCount: \(todos.count)",
                "eventCount: \(events.count)",
                "personaTypes: \(persona.displayNames.isEmpty ? "(none)" : persona.displayNames)",
                "personaDescription: \(persona.description.isEmpty ? "(empty)" : persona.description)"
            ],
            systemPrompt: systemPrompt,
            userPrompt: scheduleInput
        )
    }

    private func debugLogRawOutput(_ text: String) {
        LLMDebugLogger.response(provider: "OnDeviceMLX", operation: "rankTodos", text: text)
    }

    private func debugLogParsedResults(_ results: [PriorityResult], todos: [Todo]) {
        let todoByID = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
        let lines = results
            .sorted { $0.score > $1.score }
            .enumerated()
            .map { index, result in
                let todo = todoByID[result.todoID]
                let title = todo?.title.isEmpty == false ? todo?.title ?? "(제목 없음)" : "(제목 없음)"
                let dueDate = todo?.dueDate.map { AppDateFormat.llmString(from: $0) } ?? "nil"
                let axes = result.axes.map {
                    String(format: "deadline=%.1f urgency=%.1f importance=%.1f chaining=%.1f", $0.deadlineProximity, $0.urgency, $0.importance, $0.chaining)
                } ?? "none"
                let recommended = result.recommendedTime.map { AppDateFormat.llmString(from: $0) } ?? "nil"
                return "#\(index + 1) score=\(String(format: "%.3f", result.score)) task=\(title) due=\(dueDate) axes=[\(axes)] notify=\(result.needsNotification) recommended=\(recommended) reason=\(result.reason) detail=\(result.detail.isEmpty ? "(empty)" : result.detail)"
            }
            .joined(separator: "\n")

        LLMDebugLogger.event(
            provider: "OnDeviceMLX",
            operation: "rankTodos",
            title: "ParsedResults",
            details: "resultCount: \(results.count)\nsortedByScore:\n\(lines)"
        )
    }
}

enum IntelligenceProviderRouting {
    static func decision(
        policy: BetaFeaturePolicy = BetaFeaturePolicy()
    ) -> ProviderRoutingDecision {
        policy.routingDecision(for: .standardAnalysis)
    }
}

final class RoutedIntelligenceEngine: IntelligenceService {
    private let policy: BetaFeaturePolicy
    private let foundationModels = FoundationModelsEngine()
    private let onDevice = OnDeviceLLMIntelligenceEngine()
    private let openAI = OpenAIIntelligenceEngine()
    private let laya: any IntelligenceService
    private let heuristic = HeuristicEngine()

    init(policy: BetaFeaturePolicy = BetaFeaturePolicy(), laya: (any IntelligenceService)? = nil) {
        self.policy = policy
        self.laya = laya ?? LayaPriorityEngine(policy: policy)
    }

    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext,
        progress: IntelligenceProgressHandler?
    ) async throws -> [PriorityResult] {
        let selectedIDs = CalendarService.taskAnalysisCalendarIDs()
        let events = events.filter { CalendarService.isTaskAnalysisEvent($0, selectedCalendarIDs: selectedIDs) }
        let activeTodos = todos.filter { !$0.isCompleted }
        let decision = IntelligenceProviderRouting.decision(policy: policy)
        let requestedName: String
        switch decision {
        case .rules:
            requestedName = PriorityEngine.heuristic.displayName
        case .providers(let providers):
            requestedName = providers.first?.displayName ?? PriorityEngine.heuristic.displayName
        }
        progress?(.preparing(total: activeTodos.count, requestedProvider: requestedName))

        func heuristicResults(for reason: RuleFallbackReason) async throws -> [PriorityResult] {
            let context = RuleAnalysisContextBuilder.make(
                todos: todos,
                calendarEvents: events,
                persona: persona,
                now: Date(),
                calendar: Calendar.current
            )
            let results = context.candidates
                .filter { !$0.isCompleted && $0.triage == .todo && $0.manualPriority == nil }
                .map { RuleBasedPriorityAnalyzer.classify($0, context: context) }
            let annotated = results.map { result in
                var result = result
                result.executionPath = .rules(reason)
                result.fallbackReason = reason.rawValue
                return result
            }
            progress?(.completed(finalProvider: PriorityEngine.heuristic.displayName, total: annotated.count))
            return annotated
        }

        switch decision {
        case .rules(let reason):
            return try await heuristicResults(for: reason)

        case .providers(let providers):
            guard let provider = providers.first else {
                return try await heuristicResults(for: .noEligibleProvider)
            }
            do {
                let annotatedProgress: IntelligenceProgressHandler?
                if let progress {
                    annotatedProgress = { event in
                        guard CalendarService.taskAnalysisCalendarIDs() == selectedIDs else { return }
                        guard case .result(var result, let index, let total, let title) = event else {
                            progress(event)
                            return
                        }
                        result.requestedProviderRawValue = provider.rawValue
                        if result.engine != .heuristic { result.executionPath = .beta(provider) }
                        progress(.result(result, index: index, total: total, title: title))
                    }
                } else {
                    annotatedProgress = nil
                }
                let results = try await engine(for: provider).prioritize(
                    todos: todos,
                    events: events,
                    persona: persona,
                    progress: annotatedProgress
                )
                guard CalendarService.taskAnalysisCalendarIDs() == selectedIDs else { throw CancellationError() }
                let annotated = results.map { result in
                    var result = result
                    result.requestedProviderRawValue = provider.rawValue
                    if result.engine != .heuristic { result.executionPath = .beta(provider) }
                    return result
                }
                progress?(.completed(finalProvider: provider.displayName, total: annotated.count))
                return annotated
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard CalendarService.taskAnalysisCalendarIDs() == selectedIDs else { throw CancellationError() }
                return try await heuristicResults(
                    for: ProviderErrorMapper.fallbackReason(for: error) ?? .providerExecutionFailed
                )
            }
        }
    }

    private func engine(for provider: PersonaAIProvider) -> any IntelligenceService {
        switch provider {
        case .foundationModels:
            return foundationModels
        case .onDevice:
            return onDevice
        case .openAI:
            return openAI
        case .laya:
            return laya
        }
    }
}

// MARK: - Service Factory

struct IntelligenceServiceFactory {
    /// selectedAIProvider(사용자 선택)를 명시적으로 라우팅한다.
    /// 미지원/알 수 없는 값은 AFM으로 정규화한다.
    static func makeService() -> any IntelligenceService {
        RoutedIntelligenceEngine()
    }
}
