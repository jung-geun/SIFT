import Foundation

// MARK: - Provider

enum PersonaAIProvider: String, CaseIterable, Identifiable, Sendable {
    case foundationModels = "apple"
    case onDevice         = "onDevice"
    case openAI           = "openai"
    case laya             = "laya"

    var id: String { rawValue }

    var displayName: String {
        displayName(language: .current)
    }

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .foundationModels:
            return AppLanguage.localized("beta.foundationModels.toggle", defaultValue: "Apple Foundation Models (AFM)", language: language)
        case .onDevice:
            return AppLanguage.localized("intelligence.engine.onDevice", defaultValue: "On Device AI", language: language)
        case .openAI:
            return "OpenAI · ChatGPT"
        case .laya:
            return AppLanguage.localized("persona.engine.laya", defaultValue: "Laya (on-device)", language: language)
        }
    }

    var systemImage: String {
        switch self {
        case .foundationModels: "apple.logo"
        case .onDevice:         "cpu"
        case .openAI:           "cloud"
        case .laya:             "bolt.circle"
        }
    }
}


struct PersonaRuleDraft: Equatable, Sendable {
    let personaTypes: [PersonaType]
    let descriptionText: String
    let evidence: [String]
    let confidence: BehaviorConfidence
    var processorDescription: String = "Local rules"
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
        language: AppLanguage = .current,
        tier: OpenAIAnalysisTier = .basic
    ) async throws -> PersonaRuleDraft {
        let fallback = generateRuleBased(
            existingPersona: existingPersona,
            todos: todos,
            context: context,
            now: now,
            language: language
        )
        if tier == .advanced || routingDecisionProvider() == .providers([.openAI]) {
            if tier == .basic, !OpenAIPrivacy.allows(.persona) { return fallback }
            let narrative = try await OpenAIAnalysisService().persona(
                existing: existingPersona, draft: fallback, tier: tier, language: language
            )
            return PersonaRuleDraft(
                personaTypes: fallback.personaTypes,
                descriptionText: narrative.descriptionText,
                evidence: fallback.evidence,
                confidence: fallback.confidence,
                processorDescription: "OpenAI · \(tier.modelID)"
            )
        }
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
            return PersonaRuleDraft(
                personaTypes: fallback.personaTypes,
                descriptionText: description,
                evidence: fallback.evidence,
                confidence: fallback.confidence,
                processorDescription: "Apple Foundation Models"
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
        let typeNames = context.personaTypes.map { $0.displayName(language: language) }.joined(separator: ", ")
        let classificationNames = context.behaviorProfile.classifications
            .map { $0.label.rawValue }
            .sorted()
        let metricNames = context.behaviorProfile.insights
            .filter { $0.confidence.allowsPersonalization }
            .map { $0.metric.rawValue }
            .sorted()
        var evidence: [String] = []
        if !topTags.isEmpty {
            evidence.append(String(format: AppLanguage.localized("persona.evidence.frequentTags", defaultValue: "Frequent tags: %@", language: language), locale: language.locale, String(topTags.joined(separator: ", "))))
        }
        if !classificationNames.isEmpty {
            evidence.append(String(format: AppLanguage.localized("persona.evidence.classifications", defaultValue: "Behavior classifications: %@", language: language), locale: language.locale, String(classificationNames.joined(separator: ", "))))
        }
        if !metricNames.isEmpty {
            evidence.append(String(format: AppLanguage.localized("persona.evidence.metrics", defaultValue: "Reliable metrics: %@", language: language), locale: language.locale, String(metricNames.prefix(3).joined(separator: ", "))))
        }
        let existingNote = existingPersona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : AppLanguage.localized("persona.draft.existingPreserved", defaultValue: " Existing description remains unchanged until you apply this draft.", language: language)
        let description = String(format: AppLanguage.localized("persona.draft.description", defaultValue: "Rule-based persona for %@.%@", language: language), locale: language.locale, String(typeNames.isEmpty ? AppLanguage.localized("persona.selectedContext", defaultValue: "the selected life context", language: language) : typeNames), String(existingNote))
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
                String(format: AppLanguage.localized("persona.description.saved", defaultValue: "The user's saved description is '%@'; automatic analysis does not overwrite it.", language: language), locale: language.locale, String(String(trimmedExisting.prefix(80))))
            )
        }

        let evidenceLines = analysis.summary
            .split(separator: "\n")
            .prefix(2)
            .map(String.init)
        if !evidenceLines.isEmpty {
            personaSentences.append(
                String(format: AppLanguage.localized("persona.description.recentRecords", defaultValue: "Recent records show %@.", language: language), locale: language.locale, String(evidenceLines.joined(separator: " / ")))
            )
        }
        if !topTags.isEmpty {
            personaSentences.append(
                String(format: AppLanguage.localized("persona.description.frequentTags", defaultValue: "Frequently used tags in current to-dos: %@.", language: language), locale: language.locale, String(topTags.map { "'\($0)'" }.joined(separator: ", ")))
            )
        }
        if activeCount > 0 {
            personaSentences.append(
                String(format: AppLanguage.localized("persona.description.activeTodos", defaultValue: "There are %@ active to-dos.", language: language), locale: language.locale, String(activeCount))
            )
        }
        personaSentences.append(
            String(format: AppLanguage.localized("persona.description.confidence", defaultValue: "%@ observations support this analysis with %@ confidence; interpret it only as recent behavior.", language: language), locale: language.locale, String(analysis.behaviorProfile.sampleCount), String(analysis.behaviorProfile.confidence.label(language: language)))
        )

        var insights = Array(analysis.insights.prefix(2))
        if !topTags.isEmpty, insights.count < 3 {
            insights.append(
                String(format: AppLanguage.localized("persona.insight.frequentTags", defaultValue: "Frequently used tags in current to-dos: %@", language: language), locale: language.locale, String(topTags.joined(separator: ", ")))
            )
        }
        if activeCount > 0, insights.count < 3 {
            insights.append(
                String(format: AppLanguage.localized("persona.insight.activeTodos", defaultValue: "%@ active to-dos", language: language), locale: language.locale, String(activeCount))
            )
        }
        if insights.isEmpty {
            insights.append(
                AppLanguage.localized("persona.insight.insufficientData", defaultValue: "There is not enough behavior data to infer a trend yet.", language: language)
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
