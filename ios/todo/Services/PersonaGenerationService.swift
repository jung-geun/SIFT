import Foundation

// MARK: - Provider

enum PersonaAIProvider: String, CaseIterable, Identifiable, Sendable {
    case foundationModels = "apple"
    case onDevice         = "onDevice"
    case gemini           = "gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .foundationModels: "Apple Foundation Models (AFM)"
        case .onDevice:         "온디바이스 AI (Qwen)"
        case .gemini:           "Gemini API"
        }
    }

    var systemImage: String {
        switch self {
        case .foundationModels: "apple.logo"
        case .onDevice:         "cpu"
        case .gemini:           "cloud"
        }
    }
}

// MARK: - Service

struct PersonaGenerationService {

    // MARK: Entry Point

    /// 사용자 패턴을 분석해 페르소나를 생성하거나 점진적으로 개선합니다.
    /// AFM 또는 로컬 AI를 사용할 수 없을 때만 휴리스틱으로 생성합니다.
    func generate(
        existingPersona: String,
        todos: [Todo],
        provider: PersonaAIProvider
    ) async throws -> (personaText: String, insights: [String]) {
        guard let backend = usablePersonaBackend(preferred: provider) else {
            return generateHeuristicPersona(existingPersona: existingPersona, todos: todos)
        }

        switch backend {
        case .foundationModels:
            return try await withAFM(existingPersona: existingPersona, todos: todos)
        case .onDevice:
            return try await generateWithOnDeviceLLM(existingPersona: existingPersona, todos: todos)
        case .gemini:
            return generateHeuristicPersona(existingPersona: existingPersona, todos: todos)
        }
    }

    // MARK: Apple Foundation Models

    private func withAFM(existingPersona: String, todos: [Todo]) async throws -> (String, [String]) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelsAvailability.isAvailable {
            return try await FoundationModelsService().generatePersona(
                existingPersona: existingPersona,
                todos: todos
            )
        }
        #endif
        throw PersonaError.afmUnavailable
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
        let service = OnDeviceLLMService.shared
        guard service.isCapable else { throw PersonaError.onDeviceUnavailable }
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

    @MainActor
    private func usablePersonaBackend(preferred provider: PersonaAIProvider) -> PersonaAIProvider? {
        let foundationModelsAvailable: Bool = {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *), FoundationModelsAvailability.isAvailable {
                return true
            }
            #endif
            return false
        }()

        let onDeviceAvailable: Bool = {
            let service = OnDeviceLLMService.shared
            return service.isCapable && (service.isModelLoaded || service.isModelCachedOnDisk)
        }()

        switch provider {
        case .foundationModels where foundationModelsAvailable:
            return .foundationModels
        case .onDevice where onDeviceAvailable:
            return .onDevice
        default:
            break
        }

        if foundationModelsAvailable { return .foundationModels }
        if onDeviceAvailable { return .onDevice }
        return nil
    }

    func generateHeuristicPersona(
        existingPersona: String,
        todos: [Todo]
    ) -> (personaText: String, insights: [String]) {
        let completed = todos
            .filter { $0.isCompleted }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        let activeCount = todos.filter { !$0.isCompleted }.count

        let completionHours = Dictionary(
            grouping: completed.compactMap { $0.completedAt },
            by: { Calendar.current.component(.hour, from: $0) }
        )
        let topHours = completionHours
            .sorted { $0.value.count > $1.value.count }
            .prefix(2)
            .map { "\($0.key)시" }

        let allTags = todos.flatMap { $0.tags }.filter { !$0.isEmpty }
        let topTags = Dictionary(allTags.map { ($0, 1) }, uniquingKeysWith: +)
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)

        let recentTitles = completed
            .prefix(3)
            .map { String($0.title.prefix(24)) }

        let memorySummary = MemoryService.shared.summary
            .split(separator: "\n")
            .prefix(2)
            .joined(separator: " ")

        let keywordSource = todos.flatMap { todo in
            [todo.title] + todo.tags
        }
        let likelyTypes = PersonaType.selectable
            .map { type in
                let hits = type.weightedKeywords.reduce(0) { count, keyword in
                    count + keywordSource.filter { $0.localizedCaseInsensitiveContains(keyword) }.count
                }
                return (type, hits)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(2)
            .map { $0.0.displayName }

        var personaSentences: [String] = []
        let trimmedExisting = existingPersona.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExisting.isEmpty {
            personaSentences.append("기존 페르소나는 \(String(trimmedExisting.prefix(48)))를 중심으로 유지되고 있다.")
        }
        if !memorySummary.isEmpty {
            personaSentences.append("행동 패턴 메모리에는 \(String(memorySummary.prefix(80)))라는 흐름이 누적돼 있다.")
        }
        if !topHours.isEmpty {
            personaSentences.append("완료 기록은 주로 \(topHours.joined(separator: ", ")) 전후에 몰린다.")
        }
        if !topTags.isEmpty {
            personaSentences.append("할 일은 \(topTags.map { "'\($0)'" }.joined(separator: ", ")) 관련 주제로 자주 모인다.")
        }
        if !recentTitles.isEmpty {
            personaSentences.append("최근에는 \(recentTitles.joined(separator: ", ")) 같은 일을 마무리했다.")
        }
        if !likelyTypes.isEmpty {
            personaSentences.append("제목과 태그 기준으로는 \(likelyTypes.joined(separator: ", ")) 성격의 키워드가 두드러진다.")
        }
        if activeCount > 0 {
            personaSentences.append("현재 미완료 할 일은 \(activeCount)건으로 여러 흐름을 동시에 관리하는 상태다.")
        }
        if personaSentences.count < 2 {
            personaSentences.append("완료 기록과 남은 할 일의 분포를 함께 관리하는 패턴이 반복된다.")
        }
        if personaSentences.count < 2 {
            personaSentences.append("최근 데이터는 일정과 작업 맥락이 비교적 선명하게 축적된 상태다.")
        }

        var insights: [String] = []
        if !topHours.isEmpty {
            insights.append("완료 시간대는 \(topHours.joined(separator: ", "))에 가장 자주 집중된다.")
        }
        if !topTags.isEmpty {
            insights.append("반복 태그는 \(topTags.joined(separator: ", ")) 순으로 두드러진다.")
        }
        if !likelyTypes.isEmpty {
            insights.append("\(likelyTypes.joined(separator: ", ")) 관련 키워드가 제목과 태그에 반복된다.")
        }
        if activeCount > 0 {
            insights.append("현재 미완료 할 일 \(activeCount)건이 남아 있어 동시 진행 흐름이 유지되고 있다.")
        }
        if !recentTitles.isEmpty {
            insights.append("최근 완료 예시는 \(recentTitles.joined(separator: ", "))이다.")
        }
        if insights.count < 2 {
            insights.append("메모리 요약과 최근 완료 기록이 비슷한 패턴으로 이어지고 있다.")
        }

        return (
            personaText: Array(personaSentences.prefix(4)).joined(separator: " "),
            insights: Array(insights.prefix(3))
        )
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
            t = String(t[s.lowerBound..<e.upperBound])
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
    case onDeviceUnavailable
    case onDeviceModelNotLoaded

    var errorDescription: String? {
        switch self {
        case .afmUnavailable:
            "Apple Intelligence를 사용할 수 없습니다. iPhone 15 Pro+ / M-시리즈 Mac이 필요하거나 Siri 언어 설정을 확인하세요."
        case .onDeviceUnavailable:
            "이 기기는 현재 Qwen 로컬 실행 기준(메모리 6GB 이상)을 충족하지 않습니다."
        case .onDeviceModelNotLoaded:
            "온디바이스 모델이 로드되지 않았습니다. 설정 > 온디바이스 모델 관리에서 모델을 다운로드하거나 상태를 확인하세요."
        }
    }
}
