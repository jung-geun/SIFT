import Foundation
import Testing
@testable import todo

@Suite("Beta provider policy")
@MainActor
struct BetaFeaturePolicyTests {
    @Test("legacy provider settings do not override the default AFM provider")
    func legacySettingsRemainInert() async {
        await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let betaKeys = [
                SettingsStore.betaFoundationModelsEnabledKey,
                SettingsStore.betaOnDeviceModelEnabledKey,
                SettingsStore.betaGeminiEnabledKey,
                SettingsStore.betaMeetingVoiceProcessingEnabledKey,
                SettingsStore.betaSelectedProviderKey,
                SettingsStore.betaLegacySelectionMigratedKey
            ]
            let legacyKeys = [
                SettingsStore.betaFeaturesKey,
                "pieroot.todo.onDeviceLLMEnabled",
                "selectedAIProvider"
            ]
            (betaKeys + legacyKeys).forEach(defaults.removeObject(forKey:))
            defer {
                (betaKeys + legacyKeys).forEach(defaults.removeObject(forKey:))
                GeminiProviderService.deleteAPIKey()
            }

            defaults.set(true, forKey: SettingsStore.betaFeaturesKey)
            defaults.set(true, forKey: "pieroot.todo.onDeviceLLMEnabled")
            defaults.set(PersonaAIProvider.gemini.rawValue, forKey: "selectedAIProvider")
            GeminiProviderService.saveAPIKey("legacy-gemini-key")

            let policy = BetaFeaturePolicy()
            #expect(SettingsStore.betaProviderAccess().foundationModelsEnabled)
            #expect(SettingsStore.betaSelectedProvider() == .foundationModels)
            #expect(policy.routingDecision(for: .standardAnalysis) == .providers([.foundationModels]))
            #expect(policy.routingDecision(for: .transcriptRefinement) == .providers([.foundationModels]))
            #expect(policy.authorizes(.foundationModels, for: .standardAnalysis))
        }
    }

    @Test("standard analysis requires an enabled local selection")
    func standardAnalysisUsesOnlyEnabledSelection() async {
        await AIProviderTestIsolation.shared.withLock {
            let enabled = BetaProviderAccess(
                foundationModelsEnabled: true,
                onDeviceEnabled: true,
                geminiEnabled: false,
                meetingVoiceProcessingEnabled: false
            )

            let selected = BetaFeaturePolicy(
                accessReader: { enabled },
                selectionReader: { .onDevice }
            )
            #expect(selected.routingDecision(for: .standardAnalysis) == .providers([.onDevice]))
            #expect(selected.authorizes(.foundationModels, for: .standardAnalysis) == false)
            #expect(selected.authorizes(.onDevice, for: .standardAnalysis))

            let missing = BetaFeaturePolicy(
                accessReader: { enabled },
                selectionReader: { nil }
            )
            #expect(missing.routingDecision(for: .standardAnalysis) == .rules(.providerDisabled))

            let disabled = BetaFeaturePolicy(
                accessReader: { enabled },
                selectionReader: { .gemini }
            )
            #expect(disabled.routingDecision(for: .standardAnalysis) == .rules(.providerDisabled))
        }
    }

    @Test("transcript refinement uses enabled local providers in deterministic order")
    func transcriptRefinementUsesLocalProvidersOnly() async {
        await AIProviderTestIsolation.shared.withLock {
            let policy = BetaFeaturePolicy(
                accessReader: {
                    BetaProviderAccess(
                        foundationModelsEnabled: true,
                        onDeviceEnabled: true,
                        geminiEnabled: true,
                        meetingVoiceProcessingEnabled: false
                    )
                },
                selectionReader: { .gemini }
            )

            #expect(
                policy.routingDecision(for: .transcriptRefinement)
                    == .providers([.foundationModels, .onDevice])
            )
            #expect(policy.authorizes(.gemini, for: .transcriptRefinement) == false)
            #expect(policy.authorizes(.onDevice, for: .modelManagement))
        }
    }

    @Test("beta keys are local and selection is corrected after disabling provider")
    func betaSettingsAreLocalAndCorrectSelection() async {
        await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let keys = [
                SettingsStore.betaFoundationModelsEnabledKey,
                SettingsStore.betaOnDeviceModelEnabledKey,
                SettingsStore.betaGeminiEnabledKey,
                SettingsStore.betaMeetingVoiceProcessingEnabledKey,
                SettingsStore.betaSelectedProviderKey,
                SettingsStore.betaLegacySelectionMigratedKey
            ]
            keys.forEach(defaults.removeObject(forKey:))
            defer { keys.forEach(defaults.removeObject(forKey:)) }

            #expect(Set(keys).isDisjoint(with: Set(SettingsStore.syncableKeys)))
            #expect(SettingsStore.betaProviderAccess().foundationModelsEnabled)
            #expect(SettingsStore.betaSelectedProvider() == .foundationModels)

            SettingsStore.shared.setBetaProvider(.gemini, enabled: true)
            #expect(SettingsStore.betaSelectedProvider() == .foundationModels)
            #expect(SettingsStore.betaProviderEnabled(.gemini))

            SettingsStore.shared.setBetaProvider(.foundationModels, enabled: true)
            #expect(SettingsStore.betaSelectedProvider() == .foundationModels)

            SettingsStore.shared.setBetaProvider(.foundationModels, enabled: false)
            #expect(SettingsStore.betaSelectedProvider() == .gemini)

            SettingsStore.shared.setBetaProvider(.gemini, enabled: false)
            #expect(SettingsStore.betaSelectedProvider() == nil)
        }

    }

    @Test("enabling the on-device model does not replace AFM without direct selection")
    func onDeviceEnableKeepsAFMSelected() async {
        await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let keys = [
                SettingsStore.betaFoundationModelsEnabledKey,
                SettingsStore.betaOnDeviceModelEnabledKey,
                SettingsStore.betaSelectedProviderKey,
                SettingsStore.betaLegacySelectionMigratedKey
            ]
            keys.forEach(defaults.removeObject(forKey:))
            defer { keys.forEach(defaults.removeObject(forKey:)) }

            SettingsStore.shared.setBetaProvider(.onDevice, enabled: true)
            #expect(SettingsStore.betaSelectedProvider() == .foundationModels)

            SettingsStore.shared.setBetaSelectedProvider(.onDevice)
            #expect(SettingsStore.betaSelectedProvider() == .onDevice)
        }
    }
    @Test("legacy migration sets default AFM when selection is absent and preserves valid onDevice selection")
    func legacyMigrationSetsDefaultAFMAndPreservesValidOnDevice() async {
        await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let keys = [
                SettingsStore.betaFoundationModelsEnabledKey,
                SettingsStore.betaOnDeviceModelEnabledKey,
                SettingsStore.betaSelectedProviderKey,
                SettingsStore.betaLegacySelectionMigratedKey
            ]
            keys.forEach(defaults.removeObject(forKey:))
            defer { keys.forEach(defaults.removeObject(forKey:)) }

            // Case A: Absent selection defaults to AFM
            SettingsStore.shared.migrateLegacyBetaSelectedProviderIfNeeded()
            SettingsStore.shared.normalizeBetaSelectedProvider()
            #expect(SettingsStore.betaSelectedProvider() == .foundationModels)
            #expect(defaults.bool(forKey: SettingsStore.betaLegacySelectionMigratedKey))

            // Case B: Existing valid onDevice selection is preserved non-destructively
            keys.forEach(defaults.removeObject(forKey:))
            defaults.set(PersonaAIProvider.onDevice.rawValue, forKey: SettingsStore.betaSelectedProviderKey)
            defaults.set(true, forKey: SettingsStore.betaOnDeviceModelEnabledKey)
            SettingsStore.shared.migrateLegacyBetaSelectedProviderIfNeeded()
            SettingsStore.shared.normalizeBetaSelectedProvider()
            #expect(SettingsStore.betaSelectedProvider() == .onDevice)
            #expect(defaults.bool(forKey: SettingsStore.betaLegacySelectionMigratedKey))
        }
    }

    @Test("explicit on-device selection persists across migration and normalization calls")
    func explicitOnDeviceSelectionPersistsAcrossMigrationAndNormalization() async {
        await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let keys = [
                SettingsStore.betaFoundationModelsEnabledKey,
                SettingsStore.betaOnDeviceModelEnabledKey,
                SettingsStore.betaSelectedProviderKey,
                SettingsStore.betaLegacySelectionMigratedKey
            ]
            keys.forEach(defaults.removeObject(forKey:))
            defer { keys.forEach(defaults.removeObject(forKey:)) }

            SettingsStore.shared.migrateLegacyBetaSelectedProviderIfNeeded()
            #expect(defaults.bool(forKey: SettingsStore.betaLegacySelectionMigratedKey))

            SettingsStore.shared.setBetaProvider(.onDevice, enabled: true)
            SettingsStore.shared.setBetaSelectedProvider(.onDevice)
            #expect(SettingsStore.betaSelectedProvider() == .onDevice)

            SettingsStore.shared.migrateLegacyBetaSelectedProviderIfNeeded()
            SettingsStore.shared.normalizeBetaSelectedProvider()
            #expect(SettingsStore.betaSelectedProvider() == .onDevice)
        }
    }


    @Test("provider errors retain stable fallback reasons and preserve cancellation")
    func providerErrorsMapToFallbackReasons() {
        #expect(
            ProviderErrorMapper.fallbackReason(for: IntelligenceRoutingError.backendUnavailable(
                provider: .foundationModels,
                reason: "unavailable"
            )) == .unavailable
        )
        #expect(
            ProviderErrorMapper.fallbackReason(for: IntelligenceRoutingError.parseFailed(
                provider: .gemini,
                reason: "invalid"
            )) == .invalidResponse
        )
        #expect(ProviderErrorMapper.fallbackReason(for: CancellationError()) == nil)
    }
}
