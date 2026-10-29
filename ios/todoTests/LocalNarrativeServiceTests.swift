import Foundation
import Testing
@testable import todo

@MainActor
private final class NarrativeLifecycleRuntime: OnDeviceModelRuntime {
    private var loadStarted = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var loadWaiter: CheckedContinuation<Void, Never>?
    private let suspendsLoad: Bool
    private let suspendsGeneration: Bool
    private var generationStartWaiter: CheckedContinuation<Void, Never>?
    private var generationWaiter: CheckedContinuation<Void, Never>?
    private(set) var generations = 0

    init(suspendsLoad: Bool = false, suspendsGeneration: Bool = false) {
        self.suspendsLoad = suspendsLoad
        self.suspendsGeneration = suspendsGeneration
    }
    func load() async {
        loadStarted = true
        startWaiter?.resume()
        startWaiter = nil
        if suspendsLoad { await withCheckedContinuation { loadWaiter = $0 } }
    }
    nonisolated func unload() {}
    func waitUntilLoading() async {
        if !loadStarted { await withCheckedContinuation { startWaiter = $0 } }
    }
    func finishLoad() { loadWaiter?.resume(); loadWaiter = nil }
    func waitUntilGenerating() async {
        if generations == 0 { await withCheckedContinuation { generationStartWaiter = $0 } }
    }
    func finishGeneration() { generationWaiter?.resume(); generationWaiter = nil }
    func generate(systemPrompt: String, userPrompt: String, maxTokens: Int, contextLength: Int) async throws -> String {
        generations += 1
        generationStartWaiter?.resume()
        generationStartWaiter = nil
        if suspendsGeneration { await withCheckedContinuation { generationWaiter = $0 } }
        // Deliberately return late output; authorization and cancellation belong to the service boundary.
        return "{\"description\":\"Untrusted old-model output\"}"
    }
}

@Suite("Local narrative model boundaries")
@MainActor
struct LocalNarrativeServiceTests {
    private var policy: BetaFeaturePolicy {
        BetaFeaturePolicy(accessReader: {
            BetaProviderAccess(foundationModelsEnabled: false, onDeviceEnabled: true,
                openAIEnabled: false, layaEnabled: false, meetingVoiceProcessingEnabled: false)
        }, selectionReader: { .onDevice })
    }

    @Test("A cancelled load cannot publish model readiness after its backend returns")
    func cancelledLoadDoesNotPublishReadyModel() async {
        await AIProviderTestIsolation.shared.withLock {
            let runtime = NarrativeLifecycleRuntime(suspendsLoad: true)
            let model = OnDeviceLLMService(runtime: runtime, policy: policy)
            let load = Task { await model.loadModelIfNeeded(use: .personalNarrative) }
            await runtime.waitUntilLoading()
            load.cancel()
            runtime.finishLoad()
            await load.value
            #expect(!model.isModelLoaded)
            #expect(model.loadedModelIdentifier == nil)
        }
    }

    @Test("Cloud-restored local-model permission is rechecked after deferred generation",
          arguments: [ProviderUse.standardAnalysis, .meetingAnalysis, .transcriptRefinement], [false, true])
    func cloudRestoredOptOutRejectsInFlightOutput(use: ProviderUse, restoredEnabled: Bool) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let suite = "SIFTLocalGenerationRevocation-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let preference = SettingsStore.localModelFallbackEnabledKey
            defaults.set(true, forKey: preference)
            // Inject only hardware eligibility; the live permission still comes from cloud-restored storage.
            let restoredPolicy = BetaFeaturePolicy(accessReader: {
                BetaProviderAccess(foundationModelsEnabled: false,
                    onDeviceEnabled: UserDefaults(suiteName: suite)?.bool(forKey: preference) == true,
                    openAIEnabled: false, layaEnabled: false, meetingVoiceProcessingEnabled: false)
            }, selectionReader: { .onDevice })
            let runtime = NarrativeLifecycleRuntime(suspendsGeneration: true)
            let model = OnDeviceLLMService(runtime: runtime, policy: restoredPolicy)
            defer { model.unloadModel() }
            let generation = Task {
                try await model.generate(systemPrompt: "Return JSON.", userPrompt: "Synthetic input.", use: use)
            }
            defer {
                generation.cancel()
                runtime.finishGeneration()
            }
            await runtime.waitUntilGenerating()
            #expect(runtime.generations == 1)

            let recordKey = CloudPreferenceStore.prefix + preference
            let before = try #require(CloudPreferenceStore.capture(defaults: defaults)[recordKey])
            let remote = try JSONEncoder().encode(CloudPreferenceValue.boolean(restoredEnabled))
            try CloudPreferenceStore.apply(key: recordKey, payload: remote,
                expectedDigest: CloudFileStore.digest(before), defaults: defaults)
            #expect(defaults.bool(forKey: preference) == restoredEnabled)
            // The restore bypasses SettingsStore's setter and does not cancel this task.
            #expect(!generation.isCancelled)
            runtime.finishGeneration()

            if restoredEnabled {
                #expect(try await generation.value == "{\"description\":\"Untrusted old-model output\"}")
            } else {
                await #expect(throws: CancellationError.self) { try await generation.value }
            }
        }
    }

    @Test("A restored selection cannot run narrative inference with previously loaded weights")
    func changedSelectionRejectsStaleWeights() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let key = "pieroot.todo.onDeviceModelID"
            let original = defaults.object(forKey: key)
            defer {
                if let original { defaults.set(original, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            defaults.set(OnDeviceLLMService.defaultModelID, forKey: key)
            let runtime = NarrativeLifecycleRuntime()
            let model = OnDeviceLLMService(runtime: runtime, policy: policy)
            await model.loadModelIfNeeded(use: .personalNarrative)
            #expect(model.loadedModelIdentifier == OnDeviceLLMService.defaultModelID)
            // Cloud restore can change this preference without using the model picker.
            defaults.set("sift-test/uncached-selection-\(UUID().uuidString)", forKey: key)
            let baseline = MemoryService.computeAnalysis(todos: [], language: .english)
            let service = BehaviorNarrationService(
                routingDecisionProvider: { .providers([.onDevice]) },
                availabilityProvider: { false },
                localNarrativeProvider: { input, locale in
                    try await LocalNarrativeService.behavior(baseline: input, language: locale, model: model)
                }
            )
            let output = try await service.enrich(baseline, language: .english)
            #expect(output.summary == baseline.summary)
            #expect(output.behaviorProfile == baseline.behaviorProfile)
            #expect(runtime.generations == 0)
            model.unloadModel()
        }
    }
    @Test("MiniCPM unsupported narration languages retain local rule results without inference",
          arguments: [AppLanguage.korean, .japanese, .french])
    func unsupportedNarrativeLanguageKeepsRules(language: AppLanguage) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let key = "pieroot.todo.onDeviceModelID"
            let original = defaults.object(forKey: key)
            defer {
                if let original { defaults.set(original, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            defaults.set(OnDeviceLLMService.miniCPMModelID, forKey: key)
            let runtime = NarrativeLifecycleRuntime()
            let model = OnDeviceLLMService(runtime: runtime, policy: policy)
            await model.loadModelIfNeeded(use: .personalNarrative)
            defer { model.unloadModel() }
            let now = Date(timeIntervalSince1970: 1_793_275_200)
            let baseline = MemoryService.computeAnalysis(todos: [], now: now, language: language)
            let behavior = BehaviorNarrationService(
                routingDecisionProvider: { .providers([.onDevice]) },
                availabilityProvider: { false },
                localNarrativeProvider: { input, locale in
                    try await LocalNarrativeService.behavior(baseline: input, language: locale, model: model)
                }
            )
            let output = try await behavior.enrich(baseline, language: language)
            #expect(output.summary == baseline.summary)
            #expect(output.insights == baseline.insights)
            #expect(output.behaviorProfile == baseline.behaviorProfile)
            let context = BehaviorAnalysisContextBuilder.make(todos: [], auditEvents: [], behaviorEvents: [],
                now: now, calendar: .current, behaviorProfile: baseline.behaviorProfile, personaTypes: [.officeWorker])
            let persona = PersonaGenerationService(
                routingDecisionProvider: { .providers([.onDevice]) },
                availabilityProvider: { false },
                localNarrativeProvider: { existing, draft, profile, locale in
                    try await LocalNarrativeService.persona(existing: existing, draft: draft,
                        profile: profile, language: locale, model: model)
                }
            )
            let expected = persona.generateRuleBased(existingPersona: "", todos: [], context: context, now: now, language: language)
            let actual = try await persona.generate(existingPersona: "", todos: [], context: context, now: now, language: language)
            #expect(actual == expected)
            #expect(runtime.generations == 0)
        }
    }
}
