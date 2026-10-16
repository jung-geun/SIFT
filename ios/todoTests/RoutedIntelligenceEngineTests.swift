import Foundation
import Testing
@testable import todo

@MainActor
private struct StreamingPriorityService: IntelligenceService {
    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext,
        progress: IntelligenceProgressHandler?
    ) async throws -> [PriorityResult] {
        let result = PriorityResult(
            todoID: todos[0].id,
            score: 0.8,
            reason: "Act now",
            detail: "",
            needsNotification: false,
            recommendedTime: nil,
            personaFit: false,
            engine: .laya
        )
        progress?(.result(result, index: 1, total: 1, title: todos[0].title))
        return [result]
    }
}

@Suite("RoutedIntelligenceEngine", .serialized)
@MainActor
struct RoutedIntelligenceEngineTests {
    private func sampleTodo(_ title: String = "세금 신고") -> Todo {
        let todo = Todo(title: title)
        todo.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        return todo
    }

    @Test("no beta opt-in uses deterministic rules without consulting legacy selection")
    func noProviderOptInUsesRules() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let policy = BetaFeaturePolicy(
                accessReader: { .disabled },
                selectionReader: { .openAI }
            )
            let results = try await RoutedIntelligenceEngine(policy: policy).prioritize(
                todos: [sampleTodo()],
                events: [],
                persona: .empty
            )

            let first = try #require(results.first)
            #expect(first.engine == .heuristic)
            #expect(first.executionPath == .rules(.noProviderOptIn))
            #expect(first.fallbackReason == RuleFallbackReason.noProviderOptIn.rawValue)
        }
    }

    @Test("router exposes only the selected beta provider for standard analysis")
    func routerUsesSingleSelectedProvider() {
        let policy = BetaFeaturePolicy(
            accessReader: {
                BetaProviderAccess(
                    foundationModelsEnabled: true,
                    onDeviceEnabled: true,
                    openAIEnabled: true,
                    layaEnabled: false,
                    meetingVoiceProcessingEnabled: false
                )
            },
            selectionReader: { .onDevice }
        )

        #expect(IntelligenceProviderRouting.decision(policy: policy) == .providers([.onDevice]))
    }

    @Test("streamed Laya results persist selected provider before the final return")
    func streamedResultPreservesProviderAttribution() async throws {
        let policy = BetaFeaturePolicy(
            accessReader: {
                BetaProviderAccess(
                    foundationModelsEnabled: false,
                    onDeviceEnabled: false,
                    openAIEnabled: false,
                    layaEnabled: true,
                    meetingVoiceProcessingEnabled: false
                )
            },
            selectionReader: { .laya }
        )
        let todo = sampleTodo()
        var appliedResultIDs = Set<UUID>()
        let results = try await RoutedIntelligenceEngine(policy: policy, laya: StreamingPriorityService())
            .prioritize(todos: [todo], events: [], persona: .empty) { event in
                guard case .result(let result, _, _, _) = event else { return }
                if !appliedResultIDs.contains(result.todoID) {
                    TodoPriorityScope.apply(result, in: [todo])
                    appliedResultIDs.insert(result.todoID)
                }
            }
        for result in results where !appliedResultIDs.contains(result.todoID) {
            TodoPriorityScope.apply(result, in: [todo])
        }

        #expect(appliedResultIDs == [todo.id])
        #expect(todo.aiRequestedProvider == PersonaAIProvider.laya.rawValue)
        #expect(results.first?.executionPath == .beta(.laya))
    }

    @Test("laya provider without an installed model falls back to heuristic")
    func layaWithoutInstalledModelFallsBackToHeuristic() async throws {
        try await AIProviderTestIsolation.shared.withLock {

            // Isolated install root: guaranteed absent regardless of any previous manual
            // download on this machine's shared LayaDecisionService singleton.
            let emptyRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: emptyRoot) }
            let isolatedService = LayaDecisionService(installRoot: emptyRoot)
            #expect(isolatedService.isModelInstalled == false)

            let policy = BetaFeaturePolicy(
                accessReader: {
                    BetaProviderAccess(
                        foundationModelsEnabled: false,
                        onDeviceEnabled: false,
                        openAIEnabled: false,
                        layaEnabled: true,
                        meetingVoiceProcessingEnabled: false
                    )
                },
                selectionReader: { .laya }
            )
            let results = try await RoutedIntelligenceEngine(
                policy: policy,
                laya: LayaPriorityEngine(service: isolatedService, policy: policy)
            ).prioritize(todos: [sampleTodo()], events: [], persona: .empty)

            let first = try #require(results.first)
            #expect(first.engine == .heuristic)
            #expect(first.executionPath == .rules(.modelNotLoaded))
            #expect(first.fallbackReason == RuleFallbackReason.modelNotLoaded.rawValue)
        }
    }
}
