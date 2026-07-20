import Foundation

// MARK: - Provider

enum PersonaAIProvider: String, CaseIterable, Identifiable, Sendable {
    case foundationModels = "apple"
    case onDevice         = "onDevice"
    case gemini           = "gemini"

    var id: String { rawValue }

    var displayName: String {
        displayName(language: .current)
    }

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .foundationModels:
            return language == .english ? "Apple Foundation Models (AFM)" : "Apple Foundation Models (AFM)"
        case .onDevice:
            return language == .english ? "On Device AI" : "온디바이스 AI"
        case .gemini:
            return "Gemini API"
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

    func generate(
        existingPersona: String,
        todos: [Todo],
        auditEvents: [TaskAuditEvent] = [],
        behaviorEvents: [TaskBehaviorEvent] = [],
        provider _: PersonaAIProvider,
        language: AppLanguage = .current
    ) async throws -> (personaText: String, insights: [String]) {
        generateHeuristicPersona(
            existingPersona: existingPersona,
            todos: todos,
            auditEvents: auditEvents,
            behaviorEvents: behaviorEvents,
            language: language
        )
    }

    func generateHeuristicPersona(
        existingPersona: String,
        todos: [Todo],
        auditEvents: [TaskAuditEvent] = [],
        behaviorEvents: [TaskBehaviorEvent] = [],
        now: Date = Date(),
        language: AppLanguage = .current
    ) -> (personaText: String, insights: [String]) {
        let analysis = MemoryService.computeAnalysis(
            todos: todos,
            auditEvents: auditEvents,
            behaviorEvents: behaviorEvents,
            now: now,
            language: language
        )
        let activeCount = todos.filter { !$0.isCompleted && $0.triage == .todo }.count
        var tagCounts: [String: Int] = [:]
        for todo in todos where todo.triage == .todo {
            for tag in todo.tags where !tag.isEmpty {
                tagCounts[tag, default: 0] += 1
            }
        }
        let sortedTags: [(key: String, value: Int)] = tagCounts.sorted { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value > rhs.value
            }
            return lhs.key.localizedCompare(rhs.key) == .orderedAscending
        }
        let topTags = sortedTags.filter { $0.value >= 5 }.prefix(3).map(\.key)

        var personaSentences: [String] = []
        let trimmedExisting = existingPersona.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExisting.isEmpty {
            personaSentences.append(
                language == .english
                    ? "The user's saved description is '\(String(trimmedExisting.prefix(80)))'; automatic analysis does not overwrite it."
                    : "사용자가 저장한 기존 설명은 '\(String(trimmedExisting.prefix(80)))'이며 자동 분석은 이를 덮어쓰지 않는다."
            )
        }

        let evidenceLines = analysis.summary
            .split(separator: "\n")
            .prefix(2)
            .map(String.init)
        if !evidenceLines.isEmpty {
            personaSentences.append(
                language == .english
                    ? "Recent records show \(evidenceLines.joined(separator: " / "))."
                    : "최근 기록에서는 \(evidenceLines.joined(separator: " / "))이 관찰됐다."
            )
        }
        if !topTags.isEmpty {
            personaSentences.append(
                language == .english
                    ? "Frequently used tags in current to-dos: \(topTags.map { "'\($0)'" }.joined(separator: ", "))."
                    : "현재 TODO에서 자주 사용된 태그는 \(topTags.map { "'\($0)'" }.joined(separator: ", "))이다."
            )
        }
        if activeCount > 0 {
            personaSentences.append(
                language == .english
                    ? "There are \(activeCount) active to-dos."
                    : "현재 등록된 미완료 TODO는 \(activeCount)건이다."
            )
        }
        personaSentences.append(
            language == .english
                ? "\(analysis.behaviorProfile.sampleCount) observations support this analysis with \(analysis.behaviorProfile.confidence.label(language: language)) confidence; interpret it only as recent behavior."
                : "분석 근거 \(analysis.behaviorProfile.sampleCount)건의 신뢰도는 \(analysis.behaviorProfile.confidence.label)이며, 결과는 최근 행동 관찰로만 해석한다."
        )

        var insights = Array(analysis.insights.prefix(2))
        if !topTags.isEmpty, insights.count < 3 {
            insights.append(
                language == .english
                    ? "Frequently used tags in current to-dos: \(topTags.joined(separator: ", "))"
                    : "현재 TODO에서 자주 사용된 태그: \(topTags.joined(separator: ", "))"
            )
        }
        if activeCount > 0, insights.count < 3 {
            insights.append(
                language == .english
                    ? "\(activeCount) active to-dos"
                    : "현재 등록된 미완료 TODO \(activeCount)건"
            )
        }
        if insights.isEmpty {
            insights.append(
                language == .english
                    ? "There is not enough behavior data to infer a trend yet."
                    : "행동 경향을 단정하기에는 아직 관찰 데이터가 부족함"
            )
        }

        return (
            personaText: Array(personaSentences.prefix(4)).joined(separator: " "),
            insights: Array(insights.prefix(3))
        )
    }

}
