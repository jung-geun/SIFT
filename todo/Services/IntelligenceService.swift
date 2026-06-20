import Foundation

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
    let score: Double          // 0.0 ~ 1.0
    let reason: String         // 40자 이내 한 줄 요약
    let detail: String         // 세부 설명 (빈 문자열 가능)
    let needsNotification: Bool
    let recommendedTime: Date? // nil = 추천 없음
    let personaFit: Bool       // 페르소나 부합 여부
    let engine: PriorityEngine // 실제 산출 엔진 식별자 (UI 배지용)
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
    ) async -> [PriorityResult]
}

// MARK: - Heuristic Engine (항상 동작하는 규칙 기반 fallback)

struct HeuristicEngine: IntelligenceService {

    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext
    ) async -> [PriorityResult] {
        todos.map { todo in
            PriorityResult(
                todoID: todo.id,
                score: heuristicScore(todo: todo, persona: persona),
                reason: heuristicReason(todo: todo, persona: persona),
                detail: "",
                needsNotification: isNearDeadline(todo: todo),
                recommendedTime: nil,
                personaFit: isPersonaFit(todo: todo, persona: persona),
                engine: .heuristic
            )
        }
    }

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
    }

    private func heuristicScore(todo: Todo, persona: PersonaContext) -> Double {
        var base: Double
        if let dueDate = todo.dueDate {
            let hours = dueDate.timeIntervalSinceNow / 3600
            switch hours {
            case ..<0:    base = 1.00
            case ..<1:    base = 0.97
            case ..<6:    base = 0.90
            case ..<24:   base = 0.78
            case ..<72:   base = 0.60
            case ..<168:  base = 0.40
            case ..<720:  base = 0.25
            default:      base = 0.15
            }
        } else {
            base = 0.20
        }

        let importantTags = ["업무", "work", "마감", "중요", "긴급"]
        let tagBoost = todo.tags.contains(where: importantTags.contains) ? 0.08 : 0.0

        // 페르소나 유형 키워드 가중치 — API 키 없이 온디바이스로 즉시 반영 (다중 유형 합산)
        let personaKeywords = persona.weightedKeywords
        let personaMatch = !personaKeywords.isEmpty && (
            todo.tags.contains(where: { personaKeywords.contains($0) }) ||
            personaKeywords.contains(where: { todo.title.localizedCaseInsensitiveContains($0) })
        )
        let personaBoost = personaMatch ? 0.06 : 0.0

        // MemoryService 빠른 태그 부스트 (사용 패턴 미세 조정)
        let fastTags = MemoryService.shared.fastTags
        let memoryBoost = !fastTags.isEmpty && todo.tags.contains(where: { fastTags.contains($0) }) ? 0.04 : 0.0

        return min(1.0, base + tagBoost + personaBoost + memoryBoost)
    }

    private func heuristicReason(todo: Todo, persona: PersonaContext) -> String {
        let personaKeywords = persona.weightedKeywords
        let personaMatch = !personaKeywords.isEmpty && (
            todo.tags.contains(where: { personaKeywords.contains($0) }) ||
            personaKeywords.contains(where: { todo.title.localizedCaseInsensitiveContains($0) })
        )
        let personaSuffix = personaMatch && !persona.displayNames.isEmpty
            ? " · 페르소나(\(persona.displayNames)) 관련" : ""

        guard let due = todo.dueDate else {
            return personaMatch
                ? "마감 없음\(personaSuffix)"
                : "마감 없음 — 낮은 기본 우선순위"
        }
        let hours = due.timeIntervalSinceNow / 3600
        let dueStr: String
        switch hours {
        case ..<0:    dueStr = "마감 초과"
        case ..<1:    dueStr = "1시간 이내 마감"
        case ..<6:    dueStr = "6시간 이내 마감"
        case ..<24:   dueStr = "오늘 마감"
        case ..<72:   dueStr = "3일 이내 마감"
        case ..<168:  dueStr = "이번 주 마감"
        default:      dueStr = "\(Int(hours / 24))일 후 마감"
        }
        return dueStr + personaSuffix
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
    ) async -> [PriorityResult] {
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
            } catch {
                print("[FoundationModelsEngine] FM 실패 (\(error.localizedDescription)) — Heuristic fallback 사용")
            }
        }
        #endif
        return await fallback.prioritize(todos: todos, events: events, persona: persona)
    }
}

// MARK: - On-Device LLM Intelligence Engine (스텁 — Phase B에서 실 구현)

/// Qwen 4B MLX 온디바이스 LLM 기반 우선순위 산출 엔진 스텁.
///
/// Phase A: 모델 미설치 → HeuristicEngine으로 폴백.
/// Phase B: OnDeviceLLMService 모델 로드 후 실제 LLM 추론.
///          입력: 제목/마감/태그/페르소나/캘린더 메타데이터 (본문 아님 — CloudIntelligenceEngine과 동일 수준)
///          출력 JSON 파싱: CloudIntelligenceEngine.parseRankings 패턴 재사용.
final class OnDeviceLLMIntelligenceEngine: IntelligenceService {
    // D: Qwen 실패 시 AFM으로 폴백 (AFM 보편 기본값 — Qwen→AFM→Heuristic 체인)
    private let fallback = FoundationModelsEngine()

    private static func buildSystemPrompt(persona: PersonaContext) -> String {
        var lines = [
            "당신은 개인 스케줄 비서입니다. 할 일 목록의 우선순위를 분석하세요.",
            "반드시 아래 JSON 형식으로만 답하세요 (Markdown 없이 순수 JSON):",
            "{\"rankings\":[{\"todoID\":\"<UUID>\",\"score\":0.0,\"reason\":\"<40자 이내 한국어>\",\"detail\":\"<세부 이유, 빈문자 가능>\",\"needsNotification\":false,\"recommendedISO\":\"<ISO8601 또는 빈문자>\",\"personaFit\":false}]}",
            "score는 0.0(가장 낮음)~1.0(최우선). 절대 0.0으로 두지 말 것 — 마감 없어도 중요도(교수·관계·제출·미팅)에 따라 0.3 이상 부여. 페르소나 부합 시 높게, personaFit:true, reason에 '페르소나 관련' 포함.",
            "고정 일정 여부는 오직 할 일에 '고정(주기)' 표기가 있는 경우에만 판단. 출처:직접입력 항목을 '필수'·'고정'·'반드시'로 단정하지 말 것 — 사용자의 자발적 선택이므로 선호로 표현.",
            "needsNotification: 오늘 마감/마감 임박/중요 키워드 있으면 true.",
            "recommendedISO: 처리 추천 시각(ISO8601). 오전 업무라면 당일 09:00, 저녁이라면 17:00 등. 확실하지 않으면 빈문자."
        ]
        if !persona.types.isEmpty       { lines.append("사용자 유형: \(persona.displayNames)") }
        if !persona.description.isEmpty { lines.append("사용자 가치관:\n\(persona.description)") }
        // MemoryService 사용자 행동 패턴 주입 (CloudIntelligenceEngine과 동일)
        let memory = MemoryService.shared.summary
        if !memory.isEmpty { lines.append("사용자 행동 패턴 (참고):\n\(memory)") }
        return lines.joined(separator: "\n")
    }

    private static func buildUserPrompt(todos: [Todo], events: [CalendarService.CalendarEventSummary]) -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["현재 시각: \(iso.string(from: Date()))"]
        if !events.isEmpty {
            lines.append("\n[캘린더 이벤트 (향후 7일)]")
            for e in events.prefix(10) { lines.append("• \(e.title) — \(iso.string(from: e.startDate))") }
        }
        lines.append("\n[우선순위 평가 대상 할 일]")
        for todo in todos {
            var ps = ["ID:\(todo.id.uuidString)", "제목:\(todo.title)"]
            if let due = todo.dueDate { ps.append("마감:\(iso.string(from: due))") }
            if !todo.tags.isEmpty     { ps.append("태그:\(todo.tags.joined(separator: ","))") }
            let sourceLabel: String
            switch todo.todoSource {
            case .manual:   sourceLabel = "직접입력"
            case .email:    sourceLabel = "이메일"
            case .calendar: sourceLabel = "캘린더"
            }
            ps.append("출처:\(sourceLabel)")
            if todo.isFixedSchedule  { ps.append("고정(주기)") }
            lines.append("• " + ps.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext
    ) async -> [PriorityResult] {
        let service = OnDeviceLLMService.shared
        // 모델이 디스크에 있지만 메모리에 없는 경우(백그라운드 후 복귀 등) 자동 로드
        if !service.isModelLoaded && service.isModelCachedOnDisk {
            await service.loadModelIfNeeded()
        }
        guard service.isModelLoaded else {
            return await fallback.prioritize(todos: todos, events: events, persona: persona)
        }
        // 최대 20개 캡: 항목 과다 시 JSON이 maxTokens를 초과해 파싱 실패하는 것 방지.
        // 마감 있는 항목을 우선 정렬해 가장 중요한 todo가 LLM 입력에 포함되도록 함.
        let sortedActive = todos.filter { !$0.isCompleted }.sorted {
            switch ($0.dueDate, $1.dueDate) {
            case (let a?, let b?): return a < b
            case (.some, .none):   return true
            default:               return false
            }
        }
        let active = Array(sortedActive.prefix(20))
        guard !active.isEmpty else { return [] }

        // 항목 수에 비례해 maxTokens 조정 (항목당 ~80 토큰, 최소 512 최대 1536)
        // 20개 JSON ≈ 1500 토큰으로 상한 하향. 메모리 절약 + 생성 속도 개선.
        let maxTokens = max(512, min(1536, active.count * 80))
        do {
            let text = try await service.generate(
                systemPrompt: Self.buildSystemPrompt(persona: persona),
                userPrompt: Self.buildUserPrompt(todos: active, events: events),
                maxTokens: maxTokens
            )
            let parsed = parseRankings(text: text)
            guard !parsed.isEmpty else {
                return await fallback.prioritize(todos: todos, events: events, persona: persona)
            }
            // 점수 보정: 휴리스틱 baseline blend + personaFit/notification floor
            // 4B 모델이 score:0.0을 반환해도 결정론적 하한을 보장 (버그 A 수정)
            let baselineResults = await fallback.prioritize(todos: active, events: events, persona: persona)
            let baselineMap = Dictionary(uniqueKeysWithValues: baselineResults.map { ($0.todoID, $0.score) })
            return parsed.map { r in
                let baseline = baselineMap[r.todoID] ?? 0.0
                var s = max(r.score, baseline)
                if r.personaFit             { s = max(s, 0.6) }
                else if r.needsNotification { s = max(s, 0.5) }
                return PriorityResult(
                    todoID: r.todoID,
                    score: min(1.0, s),
                    reason: r.reason,
                    detail: r.detail,
                    needsNotification: r.needsNotification,
                    recommendedTime: r.recommendedTime,
                    personaFit: r.personaFit,
                    engine: .onDeviceMLX
                )
            }
        } catch {
            return await fallback.prioritize(todos: todos, events: events, persona: persona)
        }
    }

    private func parseRankings(text: String) -> [PriorityResult] {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = t.range(of: "{"), let e = t.range(of: "}", options: .backwards) {
            t = String(t[s.lowerBound...e.lowerBound])
        }
        guard let data     = t.data(using: .utf8),
              let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rankings = json["rankings"] as? [[String: Any]]
        else { return [] }
        let isoParser = ISO8601DateFormatter()
        return rankings.compactMap { ranking in
            guard let idStr = ranking["todoID"] as? String,
                  let uuid  = UUID(uuidString: idStr),
                  let score = ranking["score"] as? Double else { return nil }
            let detail            = ranking["detail"] as? String ?? ""
            let needsNotification = ranking["needsNotification"] as? Bool ?? false
            let recommendedISO    = ranking["recommendedISO"] as? String ?? ""
            let recommendedTime   = recommendedISO.isEmpty ? nil : isoParser.date(from: recommendedISO)
            let personaFit        = ranking["personaFit"] as? Bool ?? false
            return PriorityResult(
                todoID: uuid,
                score:  max(0.0, min(1.0, score)),
                reason: ranking["reason"] as? String ?? "",
                detail: detail,
                needsNotification: needsNotification,
                recommendedTime: recommendedTime,
                personaFit: personaFit,
                engine: .onDeviceMLX
            )
        }
    }
}

// MARK: - Cloud Intelligence Engine (Claude / OpenAI / Gemini)

/// AFM 미지원 기기 대응 — 클라우드 REST API로 우선순위 산출.
/// 파싱/네트워크 실패 시 HeuristicEngine으로 자동 fallback.
final class CloudIntelligenceEngine: IntelligenceService {

    private let provider: PersonaAIProvider
    private let apiKey:   String
    private let model:    String
    private let fallback  = HeuristicEngine()

    init(provider: PersonaAIProvider, apiKey: String, model: String) {
        self.provider = provider
        self.apiKey   = apiKey
        self.model    = model
    }

    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext
    ) async -> [PriorityResult] {
        let active = todos.filter { !$0.isCompleted }
        guard !active.isEmpty else { return [] }

        let instructions = buildInstructions(persona: persona)
        let prompt       = buildPrompt(todos: active, events: events)

        do {
            let text   = try await callAPI(instructions: instructions, prompt: prompt)
            let parsed = parseRankings(text: text)
            return parsed.isEmpty
                ? await fallback.prioritize(todos: todos, events: events, persona: persona)
                : parsed
        } catch {
            print("[CloudIntelligence] 오류: \(error.localizedDescription) — fallback 사용")
            return await fallback.prioritize(todos: todos, events: events, persona: persona)
        }
    }

    // MARK: API Dispatch

    private func callAPI(instructions: String, prompt: String) async throws -> String {
        switch provider {
        case .foundationModels: throw URLError(.unsupportedURL)
        case .onDevice:         throw URLError(.unsupportedURL)
        case .claude:           return try await callClaude(instructions: instructions, prompt: prompt)
        case .openai:           return try await callOpenAI(instructions: instructions, prompt: prompt)
        case .gemini:           return try await callGemini(instructions: instructions, prompt: prompt)
        }
    }

    private func callClaude(instructions: String, prompt: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 1024,
            "system": instructions,
            "messages": [["role": "user", "content": prompt]]
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text    = content.first?["text"] as? String
        else { throw URLError(.cannotParseResponse) }
        return text
    }

    private func callOpenAI(instructions: String, prompt: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user",   "content": prompt]
            ]
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text    = message["content"] as? String
        else { throw URLError(.cannotParseResponse) }
        return text
    }

    private func callGemini(instructions: String, prompt: String) async throws -> String {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "system_instruction": ["parts": [["text": instructions]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 1024]
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = json["candidates"] as? [[String: Any]],
              let cont  = cands.first?["content"] as? [String: Any],
              let parts = cont["parts"] as? [[String: Any]],
              let text  = parts.first?["text"] as? String
        else { throw URLError(.cannotParseResponse) }
        return text
    }

    // MARK: Prompt Building

    private func buildInstructions(persona: PersonaContext) -> String {
        var parts = [
            "당신은 개인 스케줄 비서입니다. 할 일 목록의 우선순위를 분석하세요.",
            "반드시 아래 JSON 형식으로만 답하세요 (Markdown 없이 순수 JSON):",
            "{\"rankings\":[{\"todoID\":\"<UUID>\",\"score\":0.0,\"reason\":\"<40자 이내 한국어>\",\"detail\":\"<세부 이유, 빈문자 가능>\",\"needsNotification\":false,\"recommendedISO\":\"<ISO8601 또는 빈문자>\",\"personaFit\":false}]}",
            "score는 0.0(가장 낮음)~1.0(최우선). 절대 0.0으로 두지 말 것 — 마감 없어도 중요도(교수·관계·제출·미팅)에 따라 0.3 이상 부여. 페르소나 부합 시 높게, personaFit:true, reason에 '페르소나 관련' 포함.",
            "고정 일정 여부는 오직 할 일에 '고정(주기)' 표기가 있는 경우에만 판단. 출처:직접입력 항목을 '필수'·'고정'·'반드시'로 단정하지 말 것 — 사용자의 자발적 선택이므로 선호로 표현.",
            "needsNotification: 오늘 마감/마감 임박/중요 키워드 있으면 true.",
            "recommendedISO: 처리 추천 시각(ISO8601). 오전 업무라면 당일 09:00, 저녁이라면 17:00 등. 확실하지 않으면 빈문자."
        ]
        if !persona.types.isEmpty {
            parts.append("\n사용자 유형: \(persona.displayNames)")
        }
        if !persona.description.isEmpty {
            parts.append("\n사용자 가치관:\n\(persona.description)")
        }
        let memory = MemoryService.shared.summary
        if !memory.isEmpty { parts.append("\n사용자 행동 패턴 (참고):\n\(memory)") }
        return parts.joined(separator: "\n")
    }

    private func buildPrompt(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary]
    ) -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["현재 시각: \(iso.string(from: Date()))"]
        if !events.isEmpty {
            lines.append("\n[캘린더 이벤트 (향후 7일)]")
            for e in events.prefix(10) { lines.append("• \(e.title) — \(iso.string(from: e.startDate))") }
        }
        lines.append("\n[우선순위 평가 대상 할 일]")
        for todo in todos {
            var ps = ["ID:\(todo.id.uuidString)", "제목:\(todo.title)"]
            if let due = todo.dueDate { ps.append("마감:\(iso.string(from: due))") }
            if !todo.tags.isEmpty     { ps.append("태그:\(todo.tags.joined(separator: ","))") }
            let sourceLabel: String
            switch todo.todoSource {
            case .manual:   sourceLabel = "직접입력"
            case .email:    sourceLabel = "이메일"
            case .calendar: sourceLabel = "캘린더"
            }
            ps.append("출처:\(sourceLabel)")
            if todo.isFixedSchedule  { ps.append("고정(주기)") }
            lines.append("• " + ps.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: JSON Parser

    private func parseRankings(text: String) -> [PriorityResult] {
        // Markdown 코드 블록 또는 순수 JSON 모두 처리
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = t.range(of: "{"), let e = t.range(of: "}", options: .backwards) {
            t = String(t[s.lowerBound...e.lowerBound])
        }
        guard let data     = t.data(using: .utf8),
              let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rankings = json["rankings"] as? [[String: Any]]
        else { return [] }

        let isoParser = ISO8601DateFormatter()
        return rankings.compactMap { ranking in
            guard let idStr = ranking["todoID"] as? String,
                  let uuid  = UUID(uuidString: idStr),
                  let score = ranking["score"] as? Double else { return nil }
            let detail            = ranking["detail"] as? String ?? ""
            let needsNotification = ranking["needsNotification"] as? Bool ?? false
            let recommendedISO    = ranking["recommendedISO"] as? String ?? ""
            let recommendedTime   = recommendedISO.isEmpty ? nil : isoParser.date(from: recommendedISO)
            let personaFit        = ranking["personaFit"] as? Bool ?? false
            return PriorityResult(
                todoID: uuid,
                score:  max(0.0, min(1.0, score)),
                reason: ranking["reason"] as? String ?? "",
                detail: detail,
                needsNotification: needsNotification,
                recommendedTime: recommendedTime,
                personaFit: personaFit,
                engine: .cloud
            )
        }
    }
}

// MARK: - Service Factory

struct IntelligenceServiceFactory {
    /// selectedAIProvider(사용자 선택)가 우선 — AFM 기본, Qwen/클라우드 선택 시 해당 모델이 먼저.
    ///
    /// D: 라우팅 반전 — onDeviceLLMEnabled 제거, selectedProvider 단독 구동.
    ///   .onDevice       → OnDeviceLLMIntelligenceEngine (Qwen→AFM→Heuristic 체인)
    ///   .claude/.openai/.gemini + 키 → CloudIntelligenceEngine (메타데이터 전용)
    ///   .foundationModels(기본) 또는 클라우드 키 없음 → FoundationModelsEngine
    static func makeService() -> any IntelligenceService {
        let raw      = UserDefaults.standard.string(forKey: "selectedAIProvider") ?? ""
        let provider = PersonaAIProvider(rawValue: raw) ?? .foundationModels

        switch provider {
        case .onDevice:
            // Qwen이 AFM보다 먼저 동작. Qwen 미로드 시 fallback=FoundationModelsEngine.
            return OnDeviceLLMIntelligenceEngine()

        case .claude, .openai, .gemini:
            if let key = provider.storedAPIKey(), !key.isEmpty {
                let modelKey = "aiModel.\(provider.rawValue)"
                let stored   = UserDefaults.standard.string(forKey: modelKey) ?? ""
                let model    = stored.isEmpty ? provider.defaultModel : stored
                return CloudIntelligenceEngine(provider: provider, apiKey: key, model: model)
            }
            // 키 없음 → AFM 폴백
            return FoundationModelsEngine()

        case .foundationModels:
            return FoundationModelsEngine()
        }
    }
}
