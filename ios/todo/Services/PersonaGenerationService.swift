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


struct PersonaRuleDraft: Equatable, Sendable {
    let personaTypes: [PersonaType]
    let descriptionText: String
    let evidence: [String]
    let confidence: BehaviorConfidence
}

/// AFM may improve only the narrative of a deterministic persona draft.
struct PersonaNarrative: Equatable, Sendable {
    let descriptionText: String
    let evidence: [String]
}


// MARK: - Service

struct PersonaGenerationService {
    typealias NarrativeProvider = @Sendable (
        _ existingPersona: String,
        _ fallback: PersonaRuleDraft,
        _ behaviorProfile: BehaviorProfile,
        _ language: AppLanguage
    ) async throws -> PersonaNarrative
    typealias RoutingDecisionProvider = @Sendable () -> ProviderRoutingDecision
    typealias AvailabilityProvider = () -> Bool

    private let narrativeProvider: NarrativeProvider
    private let routingDecisionProvider: RoutingDecisionProvider
    private let availabilityProvider: AvailabilityProvider

    init(
        narrativeProvider: @escaping NarrativeProvider = Self.liveNarrative,
        routingDecisionProvider: @escaping RoutingDecisionProvider = {
            BetaFeaturePolicy().routingDecision(for: .standardAnalysis)
        },
        availabilityProvider: @escaping AvailabilityProvider = {
            FoundationModelsAvailability.isAvailable
        }
    ) {
        self.narrativeProvider = narrativeProvider
        self.routingDecisionProvider = routingDecisionProvider
        self.availabilityProvider = availabilityProvider
    }


    // MARK: Entry Point

    func generate(
        existingPersona: String,
        todos: [Todo],
        context: BehaviorAnalysisContext,
        now: Date,
        language: AppLanguage = .current
    ) async throws -> PersonaRuleDraft {
        let fallback = generateRuleBased(
            existingPersona: existingPersona,
            todos: todos,
            context: context,
            now: now,
            language: language
        )
        guard routingDecisionProvider() == .providers([.foundationModels]),
              availabilityProvider()
        else {
            return fallback
        }

        do {
            let narrative = try await narrativeProvider(
                existingPersona,
                fallback,
                context.behaviorProfile,
                language
            )
            let description = narrative.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else { return fallback }
            let evidence = narrative.evidence
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return PersonaRuleDraft(
                personaTypes: fallback.personaTypes,
                descriptionText: description,
                evidence: evidence.isEmpty ? fallback.evidence : Array(evidence.prefix(3)),
                confidence: fallback.confidence
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return fallback
        }

    }

    func generateRuleBased(
        existingPersona: String,
        todos _: [Todo],
        context: BehaviorAnalysisContext,
        now _: Date,
        language: AppLanguage = .current
    ) -> PersonaRuleDraft {
        let tagCounts = context.todos
            .filter { !$0.isDeleted && $0.triage == .todo }
            .flatMap(\.tags)
            .reduce(into: [String: Int]()) { counts, tag in counts[tag, default: 0] += 1 }
        let topTags = tagCounts
            .filter { $0.value >= 5 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3)
            .map(\.key)
        let typeNames = context.personaTypes.map { $0.displayName }.joined(separator: language == .english ? ", " : ", ")
        let classificationNames = context.behaviorProfile.classifications
            .map { $0.label.rawValue }
            .sorted()
        let metricNames = context.behaviorProfile.insights
            .filter { $0.confidence.allowsPersonalization }
            .map { $0.metric.rawValue }
            .sorted()
        var evidence: [String] = []
        if !topTags.isEmpty {
            evidence.append(language == .english
                ? "Frequent tags: \(topTags.joined(separator: ", "))"
                : "자주 사용한 태그: \(topTags.joined(separator: ", "))")
        }
        if !classificationNames.isEmpty {
            evidence.append(language == .english
                ? "Behavior classifications: \(classificationNames.joined(separator: ", "))"
                : "행동 분류: \(classificationNames.joined(separator: ", "))")
        }
        if !metricNames.isEmpty {
            evidence.append(language == .english
                ? "Reliable metrics: \(metricNames.prefix(3).joined(separator: ", "))"
                : "신뢰 가능한 지표: \(metricNames.prefix(3).joined(separator: ", "))")
        }
        let existingNote = existingPersona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : language == .english ? " Existing description remains unchanged until you apply this draft." : " 적용하기 전까지 기존 설명은 변경되지 않는다."
        let description = language == .english
            ? "Rule-based persona for \(typeNames.isEmpty ? "the selected life context" : typeNames).\(existingNote)"
            : "\(typeNames.isEmpty ? "선택된 생활 맥락" : typeNames)을 위한 규칙 기반 페르소나이다.\(existingNote)"
        return PersonaRuleDraft(
            personaTypes: context.personaTypes,
            descriptionText: description,
            evidence: Array(evidence.prefix(3)),
            confidence: context.behaviorProfile.confidence
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

    private static func liveNarrative(
        existingPersona: String,
        fallback: PersonaRuleDraft,
        behaviorProfile: BehaviorProfile,
        language: AppLanguage
    ) async throws -> PersonaNarrative {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), FoundationModelsAvailability.isAvailable else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .foundationModels,
                reason: RuleFallbackReason.unavailable.rawValue
            )
        }
        return try await FoundationModelsService().generatePersonaNarrative(
            existingPersona: existingPersona,
            fallback: fallback,
            behaviorProfile: behaviorProfile,
            language: language
        )
        #else
        throw IntelligenceRoutingError.backendUnavailable(
            provider: .foundationModels,
            reason: RuleFallbackReason.unavailable.rawValue
        )
        #endif
    }

}
