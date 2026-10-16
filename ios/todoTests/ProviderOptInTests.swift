import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import Testing
@testable import todo


private final class CountingOnDeviceRuntime: OnDeviceModelRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0
    private var generations = 0

    func load() async throws {
        lock.withLock {
            loads += 1
        }
    }

    func unload() {}

    func generate(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        contextLength: Int
    ) async throws -> String {
        lock.withLock {
            generations += 1
        }
        throw CancellationError()
    }

    func counts() -> (loads: Int, generations: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (loads, generations)
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private struct UncalledFoundationRuntime: FoundationModelsRuntime {
    func rankTodos(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMPriorityRankingList { fatalError("runtime must not be called") }
    func analyzeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailOutput { fatalError("runtime must not be called") }
    func summarizeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailSummaryOutput { fatalError("runtime must not be called") }
    func generatePersonaNarrative(
        instructions: String,
        userPrompt: String
    ) async throws -> FMPersonaNarrativeOutput { fatalError("runtime must not be called") }
    func narrateBehavior(
        instructions: String,
        userPrompt: String
    ) async throws -> FMBehaviorNarrativeOutput { fatalError("runtime must not be called") }
    func analyzeMeeting(
        instructions: String,
        userPrompt: String
    ) async throws -> FMMeetingExtractionOutput { fatalError("runtime must not be called") }
    func correctTranscript(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMTranscriptCorrectionOutput { fatalError("runtime must not be called") }
    func draftTodoFromEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailTodoDraftOutput { fatalError("runtime must not be called") }
}
#endif

@Suite("Provider opt-in boundaries", .serialized)
@MainActor
struct ProviderOptInTests {

    private func reset() {
        UserDefaults.standard.removeObject(forKey: SettingsStore.betaSelectedProviderKey)
        UserDefaults.standard.removeObject(forKey: SettingsStore.betaFoundationModelsEnabledKey)
        UserDefaults.standard.removeObject(forKey: SettingsStore.betaOnDeviceModelEnabledKey)
    }


    @Test("Disabled on-device provider performs zero load/generate calls")
    func disabledOnDeviceMakesNoCalls() async throws {
        await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            let runtime = CountingOnDeviceRuntime()
            let service = OnDeviceLLMService(runtime: runtime)
            await service.loadModelIfNeeded(use: .standardAnalysis)
            do {
                _ = try await service.generate(
                    systemPrompt: "system",
                    userPrompt: "user",
                    use: .standardAnalysis
                )
                Issue.record("Expected disabled provider error")
            } catch {
                #expect(ProviderErrorMapper.fallbackReason(for: error) == .providerDisabled)
            }
            let counts = runtime.counts()
            #expect(counts.loads == 0)
            #expect(counts.generations == 0)
        }
    }
    @Test("Disabled Foundation Models performs zero runtime calls")
    @available(iOS 26.0, *)
    func disabledFoundationModelsMakesNoCalls() async throws {
        await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            UserDefaults.standard.set(false, forKey: SettingsStore.betaFoundationModelsEnabledKey)
            let service = FoundationModelsService(runtime: UncalledFoundationRuntime())
            do {
                _ = try await service.rankTodos(
                    todos: [],
                    events: [],
                    persona: .empty,
                    language: .english
                )
                Issue.record("Expected disabled provider error")
            } catch {
                #expect(ProviderErrorMapper.fallbackReason(for: error) == .providerDisabled)
            }
        }
    }
}
