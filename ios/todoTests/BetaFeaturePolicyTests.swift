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
                SettingsStore.betaOpenAIEnabledKey,
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
            }

            defaults.set(true, forKey: SettingsStore.betaFeaturesKey)
            defaults.set(true, forKey: "pieroot.todo.onDeviceLLMEnabled")
            defaults.set("gemini", forKey: "selectedAIProvider")

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
                openAIEnabled: false,
                layaEnabled: false,
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
                selectionReader: { .openAI }
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
                        openAIEnabled: true,
                        layaEnabled: false,
                        meetingVoiceProcessingEnabled: false
                    )
                },
                selectionReader: { .openAI }
            )

            #expect(
                policy.routingDecision(for: .transcriptRefinement)
                    == .providers([.foundationModels, .onDevice])
            )
            #expect(policy.authorizes(.openAI, for: .transcriptRefinement) == false)
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
                SettingsStore.betaOpenAIEnabledKey,
                SettingsStore.betaMeetingVoiceProcessingEnabledKey,
                SettingsStore.betaSelectedProviderKey,
                SettingsStore.betaLegacySelectionMigratedKey
            ]
            keys.forEach(defaults.removeObject(forKey:))
            defer { keys.forEach(defaults.removeObject(forKey:)) }

            #expect(Set(keys).isDisjoint(with: Set(SettingsStore.syncableKeys)))
            #expect(SettingsStore.betaProviderAccess().foundationModelsEnabled)
            #expect(SettingsStore.betaSelectedProvider() == .foundationModels)

            SettingsStore.shared.setBetaProvider(.openAI, enabled: true)
            #expect(SettingsStore.betaSelectedProvider() == .foundationModels)
            #expect(SettingsStore.betaProviderEnabled(.openAI))

            SettingsStore.shared.setBetaProvider(.foundationModels, enabled: true)
            #expect(SettingsStore.betaSelectedProvider() == .foundationModels)

            SettingsStore.shared.setBetaProvider(.foundationModels, enabled: false)
            #expect(SettingsStore.betaSelectedProvider() == .openAI)

            SettingsStore.shared.setBetaProvider(.openAI, enabled: false)
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
                provider: .openAI,
                reason: "invalid"
            )) == .invalidResponse
        )
        #expect(ProviderErrorMapper.fallbackReason(for: CancellationError()) == nil)
    }

    @Test("laya-only access routes standard analysis and model management to laya")
    func layaOnlyAccessRoutesToLaya() {
        let access = BetaProviderAccess(
            foundationModelsEnabled: false,
            onDeviceEnabled: false,
            openAIEnabled: false,
            layaEnabled: true,
            meetingVoiceProcessingEnabled: false
        )
        let policy = BetaFeaturePolicy(accessReader: { access }, selectionReader: { .laya })
        #expect(policy.routingDecision(for: .standardAnalysis) == .providers([.laya]))
        #expect(policy.routingDecision(for: .transcriptRefinement) == .rules(.noEligibleProvider))
        #expect(policy.routingDecision(for: .layaModelManagement) == .providers([.laya]))
        #expect(policy.authorizes(.laya, for: .standardAnalysis))

        let disabledAccess = BetaProviderAccess(
            foundationModelsEnabled: false,
            onDeviceEnabled: false,
            openAIEnabled: false,
            layaEnabled: false,
            meetingVoiceProcessingEnabled: false
        )
        let disabledPolicy = BetaFeaturePolicy(accessReader: { disabledAccess }, selectionReader: { nil })
        #expect(disabledPolicy.routingDecision(for: .layaModelManagement) == .rules(.providerDisabled))
    }

    @Test("메일 요약은 Laya 우선순위 선택과 독립적으로 AFM 동의를 따른다")
    func emailAnalysisKeepsAFMSeparateFromLayaSelection() {
        let both = BetaProviderAccess(
            foundationModelsEnabled: true,
            onDeviceEnabled: false,
            openAIEnabled: false,
            layaEnabled: true,
            meetingVoiceProcessingEnabled: false
        )
        let policy = BetaFeaturePolicy(accessReader: { both }, selectionReader: { .laya })
        #expect(policy.routingDecision(for: .standardAnalysis) == .providers([.laya]))
        #expect(policy.routingDecision(for: .emailAnalysis) == .providers([.foundationModels]))
        #expect(policy.authorizes(.foundationModels, for: .emailAnalysis))
        #expect(!policy.authorizes(.laya, for: .emailAnalysis))

        let layaOnly = BetaProviderAccess(
            foundationModelsEnabled: false,
            onDeviceEnabled: false,
            openAIEnabled: false,
            layaEnabled: true,
            meetingVoiceProcessingEnabled: false
        )
        let unavailable = BetaFeaturePolicy(accessReader: { layaOnly }, selectionReader: { .laya })
        #expect(unavailable.routingDecision(for: .emailAnalysis) == .rules(.providerDisabled))
    }

    @Test("meeting analysis rejects remote and priority-only providers without changing ordinary priority routing", arguments: [PersonaAIProvider.openAI, .laya])
    func meetingAnalysisIsLocalOnly(selection: PersonaAIProvider) {
        let policy = BetaFeaturePolicy(
            accessReader: {
                BetaProviderAccess(foundationModelsEnabled: true, onDeviceEnabled: true, openAIEnabled: true,
                                   layaEnabled: true, meetingVoiceProcessingEnabled: false)
            },
            selectionReader: { selection }
        )
        #expect(policy.routingDecision(for: .standardAnalysis) == .providers([selection]))
        #expect(policy.routingDecision(for: .meetingAnalysis) == .rules(.providerNotApplicable))
    }
}
