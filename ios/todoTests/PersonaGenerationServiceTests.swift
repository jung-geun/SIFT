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
    }



    @Test("health inputs leave learned persona drafts, evidence, and heuristics unchanged")
    @MainActor
    func mixedHealthPreservesOrdinaryLearning() {
        let ordinary = makeTodos(count: 24, completed: true) + makeTodos(count: 6, completed: false)
        let baselineContext = makeContext(todos: ordinary)
        let service = PersonaGenerationService()
        let baseline = service.generateRuleBased(
            existingPersona: "Saved description", todos: ordinary, context: baselineContext,
            now: fixtureNow, language: .english
        )
        let baselineHeuristic = service.generateHeuristicPersona(
            existingPersona: "Saved description", todos: ordinary, now: fixtureNow, language: .english
        )

        // Positive controls: ordinary tags, timing, and reliable metrics still inform personas.
        #expect(baseline.evidence.count == 3)
        #expect(baseline.evidence.contains { $0.contains("work") })
        #expect(baseline.evidence.contains { $0.contains(BehaviorLabel.morning.rawValue) })
        #expect(baselineContext.behaviorProfile.insight(for: .completionConcentrationHour)?.denominator == 24)
        #expect(baselineContext.behaviorProfile.insight(for: .nearTermBacklog)?.denominator == 6)
        #expect(baselineHeuristic.personaText.contains("work"))
        #expect(!baselineHeuristic.insights.isEmpty)

        for provenance in HealthProvenance.allCases {
            let mixed = ordinary + makeHealthTodos(provenance: provenance)
            let mixedContext = makeContext(todos: mixed)
            let draft = service.generateRuleBased(
                existingPersona: "Saved description", todos: mixed, context: mixedContext,
                now: fixtureNow, language: .english
            )
            let heuristic = service.generateHeuristicPersona(
                existingPersona: "Saved description", todos: mixed, now: fixtureNow, language: .english
            )

            #expect(mixedContext.todos == baselineContext.todos)
            #expect(mixedContext.behaviorProfile == baselineContext.behaviorProfile)
            #expect(draft == baseline)
            #expect(heuristic.personaText == baselineHeuristic.personaText)
            #expect(heuristic.insights == baselineHeuristic.insights)
        }
    }

    @Test("health records cannot cross persona tag or reliable-evidence thresholds", arguments: [0, 4, 19], [false, true])
    @MainActor
    func healthCannotUnlockEvidence(ordinaryCount: Int, completed: Bool) {
        let ordinary = makeTodos(count: ordinaryCount, completed: completed)
        let context = makeContext(todos: ordinary)
        let service = PersonaGenerationService()
        let baseline = service.generateRuleBased(
            existingPersona: "", todos: ordinary, context: context, now: fixtureNow, language: .english
        )
        let baselineHeuristic = service.generateHeuristicPersona(
            existingPersona: "", todos: ordinary, now: fixtureNow, language: .english
        )

        // Four tag observations cannot reach five; nineteen metric samples cannot reach medium confidence.
        #expect(context.behaviorProfile.classifications.isEmpty)
        #expect(context.behaviorProfile.insights.allSatisfy { !$0.confidence.allowsPersonalization })
        #expect(baseline.evidence.count == (ordinaryCount >= 5 ? 1 : 0))

        for provenance in HealthProvenance.allCases {
            let health = makeHealthTodos(provenance: provenance)
            let mixed = ordinary + health
            let mixedContext = makeContext(todos: mixed)
            let draft = service.generateRuleBased(
                existingPersona: "", todos: mixed, context: mixedContext, now: fixtureNow, language: .english
            )
            let heuristic = service.generateHeuristicPersona(
                existingPersona: "", todos: mixed, now: fixtureNow, language: .english
            )

            #expect(mixedContext.behaviorProfile == context.behaviorProfile)
            #expect(draft == baseline)
            #expect(heuristic.personaText == baselineHeuristic.personaText)
            #expect(heuristic.insights == baselineHeuristic.insights)
        }
    }

    @Test("narrative providers cannot change evidence or use health records", arguments: [PersonaAIProvider.foundationModels, .onDevice])
    @MainActor
    func narrativeProviderBoundaryExcludesHealthEvidence(provider: PersonaAIProvider) async throws {
        let ordinary = makeTodos(count: 24, completed: true) + makeTodos(count: 6, completed: false)
        let context = makeContext(todos: ordinary)
        let expectedProfile = context.behaviorProfile
        let expectedDraft = PersonaGenerationService().generateRuleBased(
            existingPersona: "Saved description", todos: ordinary, context: context,
            now: fixtureNow, language: .english
        )
        let narrative: PersonaGenerationService.NarrativeProvider = { existing, draft, profile, language in
                #expect(existing == "Saved description")
                #expect(language == .english)
                #expect(draft == expectedDraft)
                #expect(profile == expectedProfile)
                return PersonaNarrative(descriptionText: "Ordinary-only narrative", evidence: ["Provider evidence"])
        }
        let service = PersonaGenerationService(
            narrativeProvider: narrative,
            routingDecisionProvider: { .providers([provider]) },
            availabilityProvider: { provider == .foundationModels },
            localNarrativeProvider: narrative
        )
        let baseline = try await service.generate(
            existingPersona: "Saved description", todos: ordinary, context: context,
            now: fixtureNow, language: .english
        )

        #expect(baseline.descriptionText == "Ordinary-only narrative")
        #expect(baseline.evidence == expectedDraft.evidence)
        #expect(baseline.confidence == expectedDraft.confidence)
        for provenance in HealthProvenance.allCases {
            let mixed = ordinary + makeHealthTodos(provenance: provenance)
            let draft = try await service.generate(
                existingPersona: "Saved description", todos: mixed, context: makeContext(todos: mixed),
                now: fixtureNow, language: .english
            )
            #expect(draft == baseline)
        }
    }

    private enum HealthProvenance: CaseIterable {
        case reference, mixedCaseReference, calendarOrigin
    }

    private var fixtureCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var fixtureNow: Date {
        fixtureCalendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 9))!
    }

    @MainActor
    private func makeTodos(count: Int, completed: Bool, health: HealthProvenance? = nil) -> [Todo] {
        (0..<count).map { index in
            let todo = Todo(
                title: health == nil ? "Ordinary task \(index)" : "Private health title \(index)",
                notes: health == nil ? "Ordinary notes" : "Private health notes",
                tags: health == nil ? ["work"] : ["work", "private-health-tag"]
            )
            todo.createdAt = fixtureNow.addingTimeInterval(-48 * 3600)
            todo.updatedAt = fixtureNow
            todo.isCompleted = completed
            // Health records would change time-of-day, deadline, and backlog evidence if admitted.
            todo.completedAt = completed ? (health == nil ? fixtureNow : fixtureNow.addingTimeInterval(-9 * 3600)) : nil
            todo.dueDate = fixtureNow.addingTimeInterval(health == nil ? 24 * 3600 : -24 * 3600)
            switch health {
            case .reference:
                todo.sourceRef = "health:private-routine-\(index)"
            case .mixedCaseReference:
                todo.sourceRef = "HeAlTh:private-routine-\(index)"
            case .calendarOrigin:
                // A restored/imported record may no longer retain the sourceRef marker.
                todo.source = TodoSource.calendar.rawValue
                todo.sourceRef = "external-calendar-\(index)"
                todo.calendarEventOrigin = CalendarEventOrigin.siftHealth.rawValue
            case nil:
                break
            }
            return todo
        }
    }

    @MainActor
    private func makeHealthTodos(provenance: HealthProvenance) -> [Todo] {
        makeTodos(count: 30, completed: true, health: provenance)
            + makeTodos(count: 30, completed: false, health: provenance)
    }

    @MainActor
    private func makeContext(todos: [Todo]) -> BehaviorAnalysisContext {
        let analysis = MemoryService.computeAnalysis(
            todos: todos, now: fixtureNow, calendar: fixtureCalendar, language: .english
        )
        return BehaviorAnalysisContextBuilder.make(
            todos: todos, auditEvents: [], behaviorEvents: [], now: fixtureNow,
            calendar: fixtureCalendar, behaviorProfile: analysis.behaviorProfile, personaTypes: [.officeWorker]
        )
    }
}
