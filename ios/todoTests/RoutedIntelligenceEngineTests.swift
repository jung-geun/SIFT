import Foundation
import Testing
@testable import todo

@Suite("RoutedIntelligenceEngine", .serialized)
@MainActor
struct RoutedIntelligenceEngineTests {
    private func reset() {
        GeminiProviderService.deleteAPIKey()
        UserDefaults.standard.removeObject(forKey: "selectedAIProvider")
        UserDefaults.standard.removeObject(forKey: "selectedAIProvider.isLocal")
        NSUbiquitousKeyValueStore.default.removeObject(forKey: "selectedAIProvider")
        NSUbiquitousKeyValueStore.default.synchronize()
        UserDefaults.standard.set(false, forKey: "pieroot.todo.iCloudSyncEnabled")
    }

    private func sampleTodo(_ title: String = "세금 신고") -> Todo {
        let todo = Todo(title: title)
        todo.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        return todo
    }


    @Test("Qwen 미가용 + Gemini 키 없음이면 휴리스틱과 폴백 사유를 반환한다")
    func onDeviceWithoutGeminiFallsBackToHeuristic() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            let service = RoutedIntelligenceEngine(requestedProvider: .onDevice)

            let results = try await service.prioritize(
                todos: [sampleTodo()],
                events: [],
                persona: .empty
            )

            let first = try #require(results.first)
            #expect(first.engine == .heuristic)
            #expect(first.requestedProviderRawValue == PersonaAIProvider.onDevice.rawValue)
            #expect(!first.fallbackReason.isEmpty)
        }
    }

    @Test("Gemini 키 없음이어도 크래시하지 않고 AFM 또는 휴리스틱으로 마무리한다")
    func geminiWithoutKeyFallsBackSafely() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            let service = RoutedIntelligenceEngine(requestedProvider: .gemini)

            let results = try await service.prioritize(
                todos: [sampleTodo("출장 정산")],
                events: [],
                persona: .empty
            )

            let first = try #require(results.first)
            #expect(first.requestedProviderRawValue == PersonaAIProvider.gemini.rawValue)
            #expect([PriorityEngine.foundationModels, .heuristic].contains(first.engine))
            #expect(!first.fallbackReason.isEmpty)
        }
    }

    @Test("AFM 요청은 Gemini 키가 있어도 Gemini 폴백 체인을 추가하지 않는다")
    func foundationModelsSkipsGeminiFallbackEvenWithKey() async {
        await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            GeminiProviderService.saveAPIKey("test-gemini-key")

            #expect(IntelligenceProviderRouting.chain(for: .foundationModels, hasGeminiKey: true) == [.foundationModels])
        }
    }

    @Test("progress result 이벤트도 요청 provider와 폴백 사유를 유지한다")
    func progressResultCarriesRoutingMetadata() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            let service = RoutedIntelligenceEngine(requestedProvider: .onDevice)
            var receivedResult: PriorityResult?

            _ = try await service.prioritize(
                todos: [sampleTodo("보험 갱신")],
                events: [],
                persona: .empty,
                progress: { event in
                    if case .result(let result, _, _, _) = event {
                        receivedResult = result
                    }
                }
            )

            let result = try #require(receivedResult)
            #expect(result.requestedProviderRawValue == PersonaAIProvider.onDevice.rawValue)
            #expect(!result.fallbackReason.isEmpty)
        }
    }
}
