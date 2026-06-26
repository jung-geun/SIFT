import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Engine Source

/// 우선순위 산출 실제 주체. Todo.aiEngine에 rawValue로 저장되어 UI 배지에 표시된다.
/// "휴리스틱"이면 LLM 경로가 실패(메모리 경고·미설치 등)해 규칙 기반으로 폴백됐음을 의미한다.
enum PriorityEngine: String, Sendable {
    case foundationModels = "Apple AI"    // ANE 실행 — 메모리 경고 없음
    case onDeviceMLX      = "Qwen AI"     // GPU/MLX 실행 — 메모리 경고 가능
    case cloud            = "클라우드 AI"  // REST API
    case heuristic        = "휴리스틱"    // LLM 실패 폴백 — 규칙 기반
}

// MARK: - Result

struct PriorityResult: Sendable {
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
}

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
        Array(Set(types.flatMap(\.weightedKeywords)))
    }

    var displayNames: String {
        types.isEmpty ? "" : types.map(\.displayName).joined(separator: ", ")
    }
}

// MARK: - Protocol

/// 페르소나·캘린더 컨텍스트 기반 할 일 우선순위 산출 서비스.
/// HeuristicEngine ↔ FoundationModelsEngine 교체 가능.
@MainActor
protocol IntelligenceService: Sendable {
    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext
    ) async throws -> [PriorityResult]
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
        persona: PersonaContext
    ) async throws -> [PriorityResult] {
        let hw     = HeuristicWeights.adaptive(persona: persona, memory: MemoryService.shared)
        let schedW = ScheduleWeights.adaptive()
        let memory = MemoryService.shared
        return todos.map { todo in
            let axes  = heuristicAxes(todo: todo, persona: persona, memory: memory, allTodos: todos, weights: hw)
            let score = ScheduleScorer.normalizedScore(axes, weights: schedW)
            return PriorityResult(
                todoID:            todo.id,
                score:             score,
                reason:            heuristicReason(todo: todo, persona: persona),
                detail:            "",
                needsNotification: isNearDeadline(todo: todo),
                recommendedTime:   productiveHourTime(from: memory),
                personaFit:        isPersonaFit(todo: todo, persona: persona),
                engine:            .heuristic,
                axes:              axes,
                chainingDetail:    ""
            )
        }
    }

    // MARK: - 4축 산출

    private func heuristicAxes(
        todo: Todo,
        persona: PersonaContext,
        memory: MemoryService,
        allTodos: [Todo],
        weights: HeuristicWeights
    ) -> AxisScores {

        // 1. deadlineProximity (0~10): 잔여 시간 기반 × deadlineMultiplier
        let rawDeadline: Double
        if let dueDate = todo.dueDate {
            let hours = dueDate.timeIntervalSinceNow / 3600
            switch hours {
            case ..<0:   rawDeadline = 10.0
            case ..<1:   rawDeadline = 9.7
            case ..<6:   rawDeadline = 9.0
            case ..<24:  rawDeadline = 7.8
            case ..<72:  rawDeadline = 6.0
            case ..<168: rawDeadline = 4.0
            case ..<720: rawDeadline = 2.5
            default:     rawDeadline = 1.5
            }
        } else {
            rawDeadline = 2.0
        }
        let deadlineProximity = min(10.0, rawDeadline * weights.deadlineMultiplier)

        // 2. urgency (0~10): 즉시성 신호 (마감근접과 의도적으로 분리)
        let urgencyKeywords = ["긴급", "즉시", "오늘", "마감", "asap", "urgent", "지금", "바로"]
        let hasUrgentKeyword = urgencyKeywords.contains(where: {
            todo.title.localizedCaseInsensitiveContains($0)
                || todo.notes.localizedCaseInsensitiveContains($0)
        })
        let isEmailSource = todo.todoSource == .email
        var urgency = deadlineProximity * 0.7
        if hasUrgentKeyword { urgency += weights.urgencyKeywordBoost }
        if isEmailSource    { urgency += weights.emailSourceBoost }
        urgency = min(10.0, urgency)

        // 3. importance (0~10): 태그·페르소나(제목+메모)·fastTags
        let importantTags  = ["업무", "work", "마감", "중요", "긴급"]
        let personaKeywords = persona.weightedKeywords
        let titleTagMatch  = !personaKeywords.isEmpty && (
            todo.tags.contains(where: { personaKeywords.contains($0) }) ||
            personaKeywords.contains(where: { todo.title.localizedCaseInsensitiveContains($0) })
        )
        let notesMatch     = !personaKeywords.isEmpty &&
            personaKeywords.contains(where: { todo.notes.localizedCaseInsensitiveContains($0) })
        let fastTags = memory.fastTags
        var importance = 5.0
        if todo.tags.contains(where: importantTags.contains) { importance += weights.importantTagBoost }
        if titleTagMatch  { importance += weights.personaKeywordBoost }
        else if notesMatch { importance += weights.notesPersonaBoost }
        if !fastTags.isEmpty && todo.tags.contains(where: { fastTags.contains($0) }) {
            importance += weights.fastTagBoost
        }
        importance = min(10.0, importance)

        // 4. chaining (0~10): 이메일 스레드 기반 (휴리스틱 한계 인정, 보수적)
        let chaining: Double
        if !todo.sourceThreadID.isEmpty {
            let hasFollowUp = allTodos.contains {
                $0.id != todo.id && $0.sourceThreadID == todo.sourceThreadID && !$0.isCompleted
            }
            chaining = hasFollowUp ? 9.0 : 6.0
        } else {
            chaining = 2.0
        }

        return AxisScores(
            deadlineProximity: deadlineProximity,
            urgency:           urgency,
            importance:        importance,
            chaining:          chaining
        )
    }

    // MARK: - 보조

    private func isNearDeadline(todo: Todo) -> Bool {
        guard let due = todo.dueDate else { return false }
        let hours = due.timeIntervalSinceNow / 3600
        return hours >= 0 && hours < 24
    }

    private func isPersonaFit(todo: Todo, persona: PersonaContext) -> Bool {
        let kw = persona.weightedKeywords
        guard !kw.isEmpty else { return false }
        return todo.tags.contains(where: { kw.contains($0) })
            || kw.contains(where: { todo.title.localizedCaseInsensitiveContains($0) })
            || kw.contains(where: { todo.notes.localizedCaseInsensitiveContains($0) })
    }

    private func heuristicReason(todo: Todo, persona: PersonaContext) -> String {
        let personaKeywords = persona.weightedKeywords
        let personaMatch    = !personaKeywords.isEmpty && (
            todo.tags.contains(where: { personaKeywords.contains($0) }) ||
            personaKeywords.contains(where: { todo.title.localizedCaseInsensitiveContains($0) }) ||
            personaKeywords.contains(where: { todo.notes.localizedCaseInsensitiveContains($0) })
        )
        let personaSuffix = personaMatch && !persona.displayNames.isEmpty
            ? " · 페르소나(\(persona.displayNames)) 관련" : ""

        guard let due = todo.dueDate else {
            return personaMatch ? "마감 없음\(personaSuffix)" : "마감 없음 — 낮은 기본 우선순위"
        }
        let hours = due.timeIntervalSinceNow / 3600
        let dueStr: String
        switch hours {
        case ..<0:   dueStr = "마감 초과"
        case ..<1:   dueStr = "1시간 이내 마감"
        case ..<6:   dueStr = "6시간 이내 마감"
        case ..<24:  dueStr = "오늘 마감"
        case ..<72:  dueStr = "3일 이내 마감"
        case ..<168: dueStr = "이번 주 마감"
        default:     dueStr = "\(Int(hours / 24))일 후 마감"
        }
        return dueStr + personaSuffix
    }

    /// productiveHour 있으면 당일 해당 시각. 이미 지났으면 nil.
    private func productiveHourTime(from memory: MemoryService) -> Date? {
        guard let hour = memory.productiveHour else { return nil }
        var comps    = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour   = hour
        comps.minute = 0
        comps.second = 0
        guard let date = Calendar.current.date(from: comps), date > Date() else { return nil }
        return date
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
    private let fallback = HeuristicEngine()

    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext
    ) async throws -> [PriorityResult] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelsService.isAvailable {
            let sorted = todos.filter { !$0.isCompleted }.sorted {
                switch ($0.dueDate, $1.dueDate) {
                case (let a?, let b?): return a < b
                case (.some, .none):   return true
                default:               return false
                }
            }
            let active = Array(sorted.prefix(20))
            guard !active.isEmpty else { return [] }
            do {
                return try await FoundationModelsService().rankTodos(
                    todos: active,
                    events: events,
                    persona: persona
                )
            } catch let genErr as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize(let tokenCount) = genErr {
                    print("[FoundationModelsEngine] 컨텍스트 초과 (\(tokenCount) 토큰 / 4096 한도)")
                } else {
                    print("[FoundationModelsEngine] FM GenerationError: \(genErr.localizedDescription)")
                }
                throw genErr
            } catch {
                print("[FoundationModelsEngine] FM 실패: \(error.localizedDescription)")
                throw error
            }
        }
        #endif
        // AFM 미가용 기기 → 휴리스틱 (알림 없음)
        return try await fallback.prioritize(todos: todos, events: events, persona: persona)
    }
}

// MARK: - On-Device LLM Intelligence Engine (timesorter-v9 / MLX)

/// timesorter-scheduler-v9-ko MLX 파인튜닝 모델 기반 우선순위 산출 엔진.
///
/// 입력: ScheduleInput JSON (current_time / user_persona / tasks[]).
/// 출력: ScheduleResponseV9 JSON (4축 scoring + reasoning + recommended_schedule).
/// total_score는 모델 출력값을 무시하고 ScheduleScorer + 적응형 가중치로 재산출.
/// 파싱 실패 시 FoundationModelsEngine(AFM) → HeuristicEngine 폴백 체인.
final class OnDeviceLLMIntelligenceEngine: IntelligenceService {
    private let fallback = FoundationModelsEngine()

    // ScheduleResponseV9 JSON 출력 지시 — Prompts.swift에서 수정 가능
    private static let systemPrompt = Prompts.Schedule.systemInstruction

    // MARK: ScheduleInput JSON 직렬화

    private static func buildScheduleInput(
        todos: [Todo],
        persona: PersonaContext,
        events: [CalendarService.CalendarEventSummary]
    ) -> String {
        let memory = MemoryService.shared

        let availability: String
        if let h = memory.productiveHour {
            let end  = min(23, h + 8)
            availability = String(format: "%02d:00-%02d:00", h, end)
        } else {
            availability = "09:00-22:00"
        }

        let bioValue = persona.types.isEmpty
            ? persona.description
            : persona.types.map { $0.displayName }.joined(separator: ", ")

        let personaDict: [String: Any] = [
            "occupations":     persona.types.map { $0.displayName },
            "detailed_status": persona.description,
            "bio":             bioValue,
            "availability":    availability
        ]

        let tasks: [[String: Any]] = todos.map { todo in
            let sourceStr: String
            switch todo.todoSource {
            case .manual:   sourceStr = "memo_app"
            case .email:    sourceStr = "email"
            case .calendar: sourceStr = "calendar"
            }
            return [
                "task_id":                    todo.id.uuidString,
                "title":                      todo.title,
                "memo":                       todo.notes,
                "source":                     sourceStr,
                "deadline":                   todo.dueDate.map { AppDateFormat.llmString(from: $0) } as Any,
                "estimated_duration_minutes": todo.estimatedDurationMinutes
            ]
        }

        let input: [String: Any] = [
            "current_time": AppDateFormat.llmString(from: Date()),
            "user_persona": personaDict,
            "tasks":        tasks
        ]
        let data = (try? JSONSerialization.data(withJSONObject: input, options: .prettyPrinted)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: ScheduleResponseV9 관대 파싱

    func parseScheduleResponseV9(
        text: String,
        todos: [Todo],
        persona: PersonaContext
    ) -> [PriorityResult]? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.range(of: "{"),
              let last  = t.range(of: "}", options: .backwards)
        else { return nil }
        t = String(t[first.lowerBound...last.lowerBound])

        guard let data           = t.data(using: .utf8),
              let json           = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scheduledTasks = json["scheduled_tasks"] as? [[String: Any]]
        else { return nil }

        let weights   = ScheduleWeights.adaptive()
        var results   = [PriorityResult]()

        for taskDict in scheduledTasks {
            guard let taskID = taskDict["task_id"] as? String,
                  let uuid   = UUID(uuidString: taskID)
            else { continue }

            let scoring = taskDict["scoring"] as? [String: Any] ?? [:]
            let axes    = AxisScores(
                deadlineProximity: max(0, min(10, (scoring["deadline_proximity"] as? Double) ?? 2.0)),
                urgency:           max(0, min(10, (scoring["urgency"]             as? Double) ?? 5.0)),
                importance:        max(0, min(10, (scoring["task_importance"]     as? Double) ?? 5.0)),
                chaining:          max(0, min(10, (scoring["task_chaining"]       as? Double) ?? 2.0))
            )
            let score = ScheduleScorer.normalizedScore(axes, weights: weights)

            let reasoning      = taskDict["reasoning"] as? [String: Any] ?? [:]
            let summary        = reasoning["summary"]         as? String ?? ""
            let chainingDetail = reasoning["chaining_detail"] as? String ?? ""

            var recommendedTime: Date? = nil
            if let sched    = taskDict["recommended_schedule"] as? [String: Any],
               let startISO = sched["start_time"]              as? String,
               !startISO.isEmpty {
                recommendedTime = AppDateFormat.parseLLMDate(startISO)
            }

            let personaKeywords = persona.weightedKeywords
            let personaFit: Bool
            if let todo = todos.first(where: { $0.id == uuid }) {
                personaFit = !personaKeywords.isEmpty && (
                    todo.tags.contains(where: { personaKeywords.contains($0) }) ||
                    personaKeywords.contains(where: { todo.title.localizedCaseInsensitiveContains($0) })
                )
            } else {
                personaFit = false
            }

            results.append(PriorityResult(
                todoID:            uuid,
                score:             score,
                reason:            String(summary.prefix(80)),
                detail:            summary,
                needsNotification: axes.deadlineProximity >= 7.0 || axes.urgency >= 7.0,
                recommendedTime:   recommendedTime,
                personaFit:        personaFit,
                engine:            .onDeviceMLX,
                axes:              axes,
                chainingDetail:    chainingDetail
            ))
        }
        return results.isEmpty ? nil : results
    }

    // MARK: prioritize

    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext
    ) async throws -> [PriorityResult] {
        let service = OnDeviceLLMService.shared
        if !service.isModelLoaded && service.isModelCachedOnDisk {
            await service.loadModelIfNeeded()
        }
        guard service.isModelLoaded else {
            return try await fallback.prioritize(todos: todos, events: events, persona: persona)
        }

        let sortedActive = todos.filter { !$0.isCompleted }.sorted {
            switch ($0.dueDate, $1.dueDate) {
            case (let a?, let b?): return a < b
            case (.some, .none):   return true
            default:               return false
            }
        }
        let active = Array(sortedActive.prefix(15))
        guard !active.isEmpty else { return [] }

        // V9 출력은 항목당 ~120 토큰 (4축 + reasoning + schedule)
        let maxTokens = max(512, min(2048, active.count * 120))

        do {
            let text = try await service.generate(
                systemPrompt: Self.systemPrompt,
                userPrompt:   Self.buildScheduleInput(todos: active, persona: persona, events: events),
                maxTokens:    maxTokens
            )
            if let parsed = parseScheduleResponseV9(text: text, todos: active, persona: persona),
               !parsed.isEmpty {
                return parsed
            }
        } catch {}

        return try await fallback.prioritize(todos: todos, events: events, persona: persona)
    }
}


// MARK: - Service Factory

struct IntelligenceServiceFactory {
    /// selectedAIProvider(사용자 선택)가 우선 — AFM 기본, Qwen 선택 시 해당 모델이 먼저.
    /// 미지원/알 수 없는 값은 AFM으로 폴백한다.
    static func makeService() -> any IntelligenceService {
        let raw      = UserDefaults.standard.string(forKey: "selectedAIProvider") ?? ""
        let provider = PersonaAIProvider(rawValue: raw) ?? .foundationModels

        switch provider {
        case .onDevice:
            // Qwen이 AFM보다 먼저 동작. Qwen 미로드 시 fallback=FoundationModelsEngine.
            return OnDeviceLLMIntelligenceEngine()

        case .foundationModels:
            return FoundationModelsEngine()
        }
    }
}
