import Foundation
import Testing
import SwiftData
@testable import todo

// MARK: - Foundation Models availability and deterministic adapters
//
// Adapter tests inject typed runtime responses; native model quality and guardrail
// behavior belong to manual smoke runs, not the default regression suite.


#if canImport(FoundationModels)
import FoundationModels


@available(iOS 26.0, *)
private final class CapturingEmailRuntime: @unchecked Sendable, FoundationModelsRuntime {
    private let lock = NSLock()
    private var summaryCount = 0
    private let summaryOutputs: [FMEmailSummaryOutput]
    private var summaryFailureIndex: Int?
    private var reviewDispositions: [FMEmailActionDisposition] = []
    private var reviewCount = 0



    init(outputs: [FMEmailSummaryOutput], failingAt index: Int? = nil,
         reviewDispositions: [FMEmailActionDisposition] = []) {
        precondition(!outputs.isEmpty)
        self.summaryOutputs = outputs
        self.summaryFailureIndex = index
        self.reviewDispositions = reviewDispositions
    }

    func rankTodos(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMPriorityRankingList { fatalError("unexpected runtime call") }


    func summarizeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailSummaryOutput {
        let index = lock.withLock {
            let index = summaryCount
            summaryCount += 1
            return index
        }
        if index == summaryFailureIndex { throw NSError(domain: "section-failure", code: 1) }
        return summaryOutputs[min(index, summaryOutputs.count - 1)]
    }

    func reviewEmailActions(candidates: [EmailActionReviewCandidate], sourceSection: String) async throws -> FMEmailActionReviewOutput {
        let index = lock.withLock {
            let index = reviewCount
            reviewCount += 1
            return index
        }
        let disposition: FMEmailActionDisposition = reviewDispositions.isEmpty ? .unaffected
            : reviewDispositions[min(index, reviewDispositions.count - 1)]
        return FMEmailActionReviewOutput(reviews: candidates.map {
            FMEmailActionReview(actionIndex: $0.index, disposition: disposition)
        })
    }


    func generatePersonaNarrative(
        instructions: String,
        userPrompt: String
    ) async throws -> FMPersonaNarrativeOutput { fatalError("unexpected runtime call") }

    func narrateBehavior(
        instructions: String,
        userPrompt: String
    ) async throws -> FMBehaviorNarrativeOutput { fatalError("unexpected runtime call") }

    func correctTranscript(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMTranscriptCorrectionOutput { fatalError("unexpected runtime call") }


}

@available(iOS 26.0, *)
private struct NarrativeRuntime: FoundationModelsRuntime {
    let personaOutput: FMPersonaNarrativeOutput
    let behaviorOutput: FMBehaviorNarrativeOutput

    func rankTodos(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMPriorityRankingList { fatalError("unexpected runtime call") }


    func summarizeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailSummaryOutput { fatalError("unexpected runtime call") }

    func generatePersonaNarrative(
        instructions: String,
        userPrompt: String
    ) async throws -> FMPersonaNarrativeOutput { personaOutput }

    func narrateBehavior(
        instructions: String,
        userPrompt: String
    ) async throws -> FMBehaviorNarrativeOutput { behaviorOutput }

    func correctTranscript(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMTranscriptCorrectionOutput { fatalError("unexpected runtime call") }

}

@Suite("FM email summary adapter", .serialized)
@MainActor
struct FMEmailSummaryAdapterTests {

    @Test("A late action survives informational sections; a failed later section never returns partial analysis",
          arguments: [false, true])
    func lateActionsAndSectionFailure(failLater: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        try await AIProviderTestIsolation.shared.withLock {
            let body = String(repeating: "Informational status.\n", count: 300)
                + "Please check access and renew the token if needed."
            let chunks = EmailAnalysisContract.bodyChunks(body)
            let outputs = chunks.indices.map { index in
                FMEmailSummaryOutput(
                    summary: index == 0 ? "Integration status." : "",
                    keyPoints: [],
                    actionItems: index == chunks.count - 1 ? ["Check access", "Renew the token if needed"] : []
                )
            }
            let runtime = CapturingEmailRuntime(outputs: outputs, failingAt: failLater ? chunks.count - 1 : nil)
            let service = FoundationModelsService(runtime: runtime, policy: AIProviderTestIsolation.foundationPolicy)
            if failLater {
                await #expect(throws: (any Error).self) {
                    try await service.summarizeEmail(subject: "Status", sender: "Team", body: body, language: .english)
                }
            } else {
                let result = try await service.summarizeEmail(subject: "Status", sender: "Team", body: body, language: .english)
                #expect(result.actionItems == ["Check access", "Renew the token if needed"])
            }
        }
    }

    @Test("A withdrawal beyond the overlap removes an earlier request; unresolved conditions cannot propose it",
          arguments: [false, true])
    func reconcilesDistantWithdrawal(unresolvedCondition: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        try await AIProviderTestIsolation.shared.withLock {
            let action = "Send the approval response."
            let body = "Please send the approval response.\n"
                + String(repeating: "Unrelated factual context.\n", count: 240)
                + (unresolvedCondition
                   ? "The earlier request now depends on an approval whose status is unknown."
                   : "The earlier request is cancelled; no response needed.")
            let chunks = EmailAnalysisContract.bodyChunks(body)
            #expect(chunks.count > 2)
            let outputs = chunks.indices.map { index in
                FMEmailSummaryOutput(
                    summary: index == 0 ? "Approval response requested." : "Later source context.",
                    keyPoints: [],
                    actionItems: index == 0 ? [action] : []
                )
            }
            let reviews = chunks.indices.map { index -> FMEmailActionDisposition in
                index == chunks.count - 1 ? (unresolvedCondition ? .unresolved : .withdrawn) : .unaffected
            }
            let runtime = CapturingEmailRuntime(outputs: outputs, reviewDispositions: reviews)
            let provider = FoundationModelsService(runtime: runtime, policy: AIProviderTestIsolation.foundationPolicy)
            let schema = Schema([EmailMessage.self])
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ])
            let context = ModelContext(container)
            let email = EmailMessage(id: "distant-withdrawal", subject: "Approval", body: body)
            email.bodyContentVersion = 1
            context.insert(email)
            let analysis = EmailMessageAnalysisService(
                foundationModelsSummaryProvider: { subject, sender, body, language in
                    try await provider.summarizeEmail(subject: subject, sender: sender, body: body, language: language)
                },
                foundationModelsEnabledProvider: { true },
                foundationModelsAvailabilityProvider: { true }
            )
            try await analysis.analyze(email, context: context)
            #expect(EmailAnalysisContract.currentActionItems(for: email).isEmpty)
            #expect(EmailAnalysisContract.todoCandidate(for: email) == (unresolvedCondition ? nil : false))
            if unresolvedCondition {
                #expect(email.analysisFailureReasonRaw == RuleFallbackReason.invalidResponse.rawValue)
            } else {
                #expect(email.analysisFailureReasonRaw == nil)
                #expect(email.analysisActionItems.isEmpty)
            }
        }
    }

    @Test("Guided Generation outputs map to persona and behavior narratives")
    func mapsNarrativeOutputs() async throws {
        guard #available(iOS 26.0, *) else { return }
        try await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let selectedKey = SettingsStore.betaSelectedProviderKey
            let originalSelection = defaults.object(forKey: selectedKey)
            defer {
                if let originalSelection { defaults.set(originalSelection, forKey: selectedKey) }
                else { defaults.removeObject(forKey: selectedKey) }
            }
            defaults.set(PersonaAIProvider.foundationModels.rawValue, forKey: selectedKey)

            let runtime = NarrativeRuntime(
                personaOutput: FMPersonaNarrativeOutput(
                    descriptionText: "Grounded persona.",
                    evidence: ["Observed evidence."]
                ),
                behaviorOutput: FMBehaviorNarrativeOutput(
                    summary: "Observed behavior summary.",
                    insights: ["Observed insight."]
                )
            )
            let service = FoundationModelsService(runtime: runtime, policy: AIProviderTestIsolation.foundationPolicy)
            let baseline = MemoryService.computeAnalysis(todos: [], language: .english)
            let persona = try await service.generatePersonaNarrative(
                existingPersona: "",
                fallback: PersonaRuleDraft(
                    personaTypes: [],
                    descriptionText: "Rule draft.",
                    evidence: [],
                    confidence: baseline.behaviorProfile.confidence
                ),
                behaviorProfile: baseline.behaviorProfile,
                language: .english
            )
            let behavior = try await service.narrateBehavior(
                baseline: baseline,
                language: .english
            )

            #expect(persona == PersonaNarrative(
                descriptionText: "Grounded persona.",
                evidence: ["Observed evidence."]
            ))
            #expect(behavior == BehaviorNarrative(
                summary: "Observed behavior summary.",
                insights: ["Observed insight."]
            ))
        }
    }
}



#endif // canImport(FoundationModels)
