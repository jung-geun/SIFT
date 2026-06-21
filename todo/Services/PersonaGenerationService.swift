import Foundation
import Security

// MARK: - Provider

enum PersonaAIProvider: String, CaseIterable, Identifiable {
    case foundationModels = "apple"
    case claude           = "claude"
    case openai           = "openai"
    case gemini           = "gemini"
    case onDevice         = "onDevice"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .foundationModels: "Apple Foundation Models (AFM)"
        case .claude:           "Claude (Anthropic)"
        case .openai:           "GPT (OpenAI)"
        case .gemini:           "Gemini (Google)"
        case .onDevice:         "온디바이스 AI (Qwen)"
        }
    }

    var systemImage: String {
        switch self {
        case .foundationModels: "apple.logo"
        case .claude:           "a.circle.fill"
        case .openai:           "sparkle"
        case .gemini:           "g.circle.fill"
        case .onDevice:         "cpu"
        }
    }

    var requiresAPIKey: Bool { self != .foundationModels && self != .onDevice }

    /// 기본 모델 식별자
    var defaultModel: String {
        switch self {
        case .foundationModels: ""
        case .claude:           "claude-haiku-4-5-20251001"
        case .openai:           "gpt-5-mini"
        case .gemini:           "gemini-2.0-flash"
        case .onDevice:         ""
        }
    }

    /// Keychain 저장 키
    var keychainKey: String { "pieroot.todo.persona.key.\(rawValue)" }

    /// Keychain에서 저장된 API 키 읽기
    func storedAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainKey,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Service

struct PersonaGenerationService {

    // MARK: Entry Point

    /// 사용자 패턴을 분석해 페르소나를 생성하거나 점진적으로 개선합니다.
    func generate(
        existingPersona: String,
        todos: [Todo],
        provider: PersonaAIProvider,
        apiKey: String? = nil,
        model: String? = nil
    ) async throws -> (personaText: String, insights: [String]) {
        let instructions   = buildInstructions(existingPersona: existingPersona)
        let prompt         = buildPrompt(existingPersona: existingPersona, todos: todos)
        let effectiveModel = model?.isEmpty == false ? model! : provider.defaultModel

        switch provider {
        case .foundationModels:
            return try await withAFM(existingPersona: existingPersona, todos: todos)
        case .gemini:
            guard let key = apiKey, !key.isEmpty else { throw PersonaError.missingAPIKey }
            return try await withGemini(instructions: instructions, prompt: prompt, apiKey: key)
        case .claude:
            guard let key = apiKey, !key.isEmpty else { throw PersonaError.missingAPIKey }
            return try await withClaude(instructions: instructions, prompt: prompt, apiKey: key, model: effectiveModel)
        case .openai:
            guard let key = apiKey, !key.isEmpty else { throw PersonaError.missingAPIKey }
            return try await withOpenAI(instructions: instructions, prompt: prompt, apiKey: key, model: effectiveModel)
        case .onDevice:
            return try await generateWithOnDeviceLLM(existingPersona: existingPersona, todos: todos)
        }
    }

    // MARK: Apple Foundation Models

    private func withAFM(existingPersona: String, todos: [Todo]) async throws -> (String, [String]) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelsService.isAvailable {
            return try await FoundationModelsService().generatePersona(
                existingPersona: existingPersona,
                todos: todos
            )
        }
        #endif
        throw PersonaError.afmUnavailable
    }

    // MARK: Google Gemini

    private func withGemini(instructions: String, prompt: String, apiKey: String) async throws -> (String, [String]) {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent") else {
            throw PersonaError.apiFailed("잘못된 URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "system_instruction": ["parts": [["text": instructions]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0.7, "maxOutputTokens": 1024]
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw PersonaError.apiFailed("Gemini \(code) 오류. API 키와 모델 접근 권한을 확인하세요.")
        }
        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = json["candidates"] as? [[String: Any]],
              let cont  = cands.first?["content"] as? [String: Any],
              let parts = cont["parts"] as? [[String: Any]],
              let text  = parts.first?["text"] as? String
        else { throw PersonaError.apiFailed("Gemini 응답 파싱 실패") }

        return parsePersonaJSON(text)
    }

    // MARK: Anthropic Claude

    private func withClaude(instructions: String, prompt: String, apiKey: String, model: String) async throws -> (String, [String]) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1024,
            "system": instructions,
            "messages": [["role": "user", "content": prompt]]
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw PersonaError.apiFailed("Claude \(code) 오류. API 키를 확인하세요.")
        }
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text    = content.first?["text"] as? String
        else { throw PersonaError.apiFailed("Claude 응답 파싱 실패") }

        return parsePersonaJSON(text)
    }

    // MARK: OpenAI

    private func withOpenAI(instructions: String, prompt: String, apiKey: String, model: String) async throws -> (String, [String]) {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user",   "content": prompt]
            ]
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw PersonaError.apiFailed("OpenAI \(code) 오류. API 키를 확인하세요.")
        }
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text    = message["content"] as? String
        else { throw PersonaError.apiFailed("OpenAI 응답 파싱 실패") }

        return parsePersonaJSON(text)
    }

    // MARK: On-Device LLM

    /// 온디바이스 Qwen/MLX 모델로 페르소나를 생성·개선한다.
    ///
    /// ⚠️ 프라이버시 불변식: buildPrompt는 메타데이터·통계만 사용 (이메일 본문 아님).
    /// 모델이 캐시됐지만 언로드된 경우(백그라운드 복귀 등) 자동으로 로드를 시도한다.
    func generateWithOnDeviceLLM(
        existingPersona: String,
        todos: [Todo]
    ) async throws -> (personaText: String, insights: [String]) {
        // FM(ANE) 우선: 2.9GB MLX 상주 모델 불필요 → 메모리 경고 취소 없음
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelsService.isAvailable {
            do {
                print("[PersonaGen] FM(ANE) 경로 사용")
                return try await withAFM(existingPersona: existingPersona, todos: todos)
            } catch {
                print("[PersonaGen] FM 실패 (\(error.localizedDescription)) — MLX 폴백")
            }
        }
        #endif

        // MLX(Qwen) 폴백
        let service = OnDeviceLLMService.shared
        // 캐시됐지만 메모리에 없으면 자동 로드 (백그라운드 후 언로드된 경우)
        if !service.isModelLoaded && service.isModelCachedOnDisk {
            await service.loadModelIfNeeded()
        }
        guard service.isModelLoaded else { throw PersonaError.onDeviceModelNotLoaded }

        let systemPrompt = buildInstructions(existingPersona: existingPersona)
        let userPrompt   = buildPrompt(existingPersona: existingPersona, todos: todos)
        let text = try await service.generate(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: 512
        )
        return parsePersonaJSON(text)
    }

    // MARK: Prompt Building

    private func buildInstructions(existingPersona: String) -> String {
        var text = Prompts.PersonaCloud.baseInstruction
        if !existingPersona.isEmpty { text += "\n\n" + Prompts.PersonaCloud.refinementSuffix }
        return text
    }

    private func buildPrompt(existingPersona: String, todos: [Todo]) -> String {
        var lines: [String] = []

        if !existingPersona.isEmpty {
            lines += ["[기존 페르소나]", existingPersona, ""]
        }

        // 행동 패턴 메모리 주입 (MemoryService가 분석한 결과)
        let memory = MemoryService.shared.summary
        if !memory.isEmpty {
            lines += ["[행동 패턴 메모리]", memory, ""]
        }

        // 완료 시간대 패턴
        let cal   = Calendar.current
        let times = todos.filter { $0.isCompleted }.compactMap { $0.completedAt }
        if !times.isEmpty {
            let byHour = Dictionary(grouping: times) { cal.component(.hour, from: $0) }
            let top = byHour.sorted { $0.value.count > $1.value.count }.prefix(3)
                .map { "\($0.key)시(\($0.value.count)건)" }.joined(separator: ", ")
            lines += ["[완료 시간대 패턴]", top, ""]
        }

        // 태그 빈도
        let allTags = todos.flatMap { $0.tags }
        if !allTags.isEmpty {
            let freq = Dictionary(allTags.map { ($0, 1) }, uniquingKeysWith: +)
            let top  = freq.sorted { $0.value > $1.value }.prefix(6)
                .map { "\($0.key)(\($0.value)회)" }.joined(separator: ", ")
            lines += ["[자주 쓰는 태그]", top, ""]
        }

        // 최근 완료 할 일 (패턴 파악)
        let done = todos.filter { $0.isCompleted }.prefix(15)
        if !done.isEmpty {
            lines.append("[최근 완료 할 일]")
            lines += done.map {
                var s = "• \($0.title)"
                if !$0.tags.isEmpty { s += " [\($0.tags.joined(separator: ","))]" }
                return s
            }
            lines.append("")
        }

        // 현재 미완료 할 일
        let active = todos.filter { !$0.isCompleted }.prefix(20)
        if !active.isEmpty {
            lines.append("[현재 할 일 (\(todos.filter { !$0.isCompleted }.count)개)]")
            let rf = RelativeDateTimeFormatter()
            rf.unitsStyle = .abbreviated
            lines += active.map {
                var s = "• \($0.title)"
                if let d = $0.dueDate { s += " [마감: \(rf.localizedString(for: d, relativeTo: Date()))]" }
                if !$0.tags.isEmpty  { s += " [\($0.tags.joined(separator: ","))]" }
                return s
            }
            lines.append("")
        }

        lines.append("위 데이터를 바탕으로 페르소나를 \(existingPersona.isEmpty ? "생성" : "개선")해주세요.")
        return lines.joined(separator: "\n")
    }

    // MARK: JSON Parser (PersonaCloud)

    /// PersonaCloud JSON 출력 파싱: {"persona":"...","insights":["...","..."]}
    /// JSON 파싱 실패 시 raw 전체를 persona로, insights는 빈 배열로 fallback.
    func parsePersonaJSON(_ raw: String) -> (String, [String]) {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = t.range(of: "{"), let e = t.range(of: "}", options: .backwards) {
            t = String(t[s.lowerBound...e.lowerBound])
        }
        guard let data   = t.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let fallback = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return (fallback.isEmpty ? raw : fallback, [])
        }
        let persona  = (parsed["persona"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let insights = (parsed["insights"] as? [String] ?? []).filter { !$0.isEmpty }
        return (persona.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : persona, insights)
    }
}

// MARK: - Error

enum PersonaError: LocalizedError {
    case afmUnavailable
    case onDeviceModelNotLoaded
    case missingAPIKey
    case apiFailed(String)

    var errorDescription: String? {
        switch self {
        case .afmUnavailable:
            "Apple Intelligence를 사용할 수 없습니다. iPhone 15 Pro+ / M-시리즈 Mac이 필요하거나 Siri 언어 설정을 확인하세요. 다른 AI를 선택하세요."
        case .onDeviceModelNotLoaded:
            "온디바이스 모델이 로드되지 않았습니다. 설정 > 온디바이스 모델 관리에서 모델을 다운로드하거나 상태를 확인하세요."
        case .missingAPIKey:
            "API 키를 입력하고 저장해주세요."
        case .apiFailed(let msg):
            msg
        }
    }
}
