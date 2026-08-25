import Foundation
import Testing
@testable import todo

struct PersonaGenerationServiceTests {
    @Test("rule persona drafts use selected types and content-free aggregates")
    @MainActor
    func draftDoesNotLeakTodoText() async throws {
        let todo = Todo(title: "private title", notes: "private notes")
        todo.tags = ["업무"]
        let persona = Persona()
        persona.descriptionText = "기존 설명"
        let originalDescription = persona.descriptionText
        let now = Date()
        let analysis = MemoryService.computeAnalysis(todos: [todo], now: now, language: .korean)
        let context = BehaviorAnalysisContextBuilder.make(
            todos: [todo],
            auditEvents: [],
            behaviorEvents: [],
            now: now,
            calendar: Calendar.current,
            behaviorProfile: analysis.behaviorProfile,
            personaTypes: [.officeWorker]
        )

        let draft = try await PersonaGenerationService().generate(
            existingPersona: "기존 설명",
            todos: [todo],
            context: context,
            now: now,
            language: .korean
        )

        #expect(draft.personaTypes == [PersonaType.officeWorker])
        #expect(persona.descriptionText == originalDescription)
        #expect(!draft.descriptionText.contains("private title"))
        #expect(!draft.descriptionText.contains("private notes"))
        #expect(draft.descriptionText.contains("규칙 기반"))
    }

    @Test("AFM enriches only the persona narrative and preserves deterministic fields")
    @MainActor
    func AFMEnrichmentPreservesDeterministicFields() async throws {
        let todo = Todo(title: "confidential task")
        let now = Date()
        let analysis = MemoryService.computeAnalysis(todos: [todo], now: now, language: .english)
        let context = BehaviorAnalysisContextBuilder.make(
            todos: [todo],
            auditEvents: [],
            behaviorEvents: [],
            now: now,
            calendar: Calendar.current,
            behaviorProfile: analysis.behaviorProfile,
            personaTypes: [.officeWorker]
        )
        let service = PersonaGenerationService(
            narrativeProvider: { _, _, _, _ in
                PersonaNarrative(
                    descriptionText: "  Grounded persona narrative.  ",
                    evidence: ["  Observed completion pattern. ", ""]
                )
            },
            routingDecisionProvider: { .providers([.foundationModels]) },
            availabilityProvider: { true }
        )

        let draft = try await service.generate(
            existingPersona: "",
            todos: [todo],
            context: context,
            now: now,
            language: .english
        )

        #expect(draft.descriptionText == "Grounded persona narrative.")
        #expect(draft.evidence == ["Observed completion pattern."])
        #expect(draft.personaTypes == [.officeWorker])
        #expect(draft.confidence == analysis.behaviorProfile.confidence)
    }

    @Test("explicit local selection retains the deterministic persona draft")
    @MainActor
    func explicitLocalSelectionDoesNotInvokeAFM() async throws {
        let todo = Todo(title: "private title")
        let now = Date()
        let analysis = MemoryService.computeAnalysis(todos: [todo], now: now, language: .english)
        let context = BehaviorAnalysisContextBuilder.make(
            todos: [todo],
            auditEvents: [],
            behaviorEvents: [],
            now: now,
            calendar: Calendar.current,
            behaviorProfile: analysis.behaviorProfile,
            personaTypes: [.officeWorker]
        )
        let service = PersonaGenerationService(
            narrativeProvider: { _, _, _, _ in
                throw CancellationError()
            },
            routingDecisionProvider: { .providers([.onDevice]) },
            availabilityProvider: { true }
        )

        let draft = try await service.generate(
            existingPersona: "",
            todos: [todo],
            context: context,
            now: now,
            language: .english
        )

        #expect(draft.descriptionText.contains("Rule-based"))
    }
}
