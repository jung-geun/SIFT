import Foundation
import Testing
@testable import todo

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
                selectionReader: { .gemini }
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
                    geminiEnabled: true,
                    meetingVoiceProcessingEnabled: false
                )
            },
            selectionReader: { .onDevice }
        )

        #expect(IntelligenceProviderRouting.decision(policy: policy) == .providers([.onDevice]))
    }
}
