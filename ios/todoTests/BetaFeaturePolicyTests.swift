import Foundation
import Testing
@testable import todo

@Suite("Beta provider policy")
@MainActor
struct BetaFeaturePolicyTests {

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

    @Test("Apple transcript refinement never loads a second model after failure")
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
                    == .providers([.foundationModels])
            )
            #expect(policy.authorizes(.openAI, for: .transcriptRefinement) == false)
            #expect(policy.authorizes(.onDevice, for: .modelManagement))
        }
    }


    private var allProvidersEnabled: BetaProviderAccess {
        BetaProviderAccess(
            foundationModelsEnabled: true, onDeviceEnabled: true, openAIEnabled: true,
            layaEnabled: true, meetingVoiceProcessingEnabled: false
        )
    }

    private func readiness(
        afm: Bool = false, downloaded: Bool = false, connected: Bool = false,
        plan: Bool = false, laya: Bool = false
    ) -> BetaProviderReadiness {
        BetaProviderReadiness(
            foundationModelsAvailable: afm, onDeviceModelUsable: downloaded,
            openAIAccountConnected: connected, openAIPlanPermitted: plan,
            layaModelUsable: laya
        )
    }

    @Test("OpenAI selection requires opt-in, an active account, and plan permission", arguments: [false, true])
    func openAIReadinessRequiresEveryPermission(enabled: Bool) {
        let access = BetaProviderAccess(
            foundationModelsEnabled: false, onDeviceEnabled: false, openAIEnabled: enabled,
            layaEnabled: false, meetingVoiceProcessingEnabled: false
        )
        for connected in [false, true] {
            for plan in [false, true] {
                let state = readiness(connected: connected, plan: plan)
                let permitted = enabled && connected && plan
                #expect(state.selectableProviders(access: access) == (permitted ? [.openAI] : []))
                #expect(state.normalizedSelection(.openAI, access: access) == (permitted ? .openAI : nil))
            }
        }
    }

    @Test("Local providers require usable models and AFM follows availability", arguments: [false, true])
    func localReadinessIsSeparateFromOptIn(usable: Bool) {
        let state = readiness(afm: usable, downloaded: usable, laya: usable)
        #expect(state.selectableProviders(access: allProvidersEnabled)
            == (usable ? [.foundationModels, .onDevice, .laya] : []))
        #expect(state.selectableProviders(access: .disabled).isEmpty)

        let access = allProvidersEnabled
        let policy = BetaFeaturePolicy(accessReader: { access }, selectionReader: { nil })
        // Missing model assets must not block installing or managing them.
        #expect(policy.authorizes(.onDevice, for: .modelManagement))
        #expect(policy.authorizes(.laya, for: .layaModelManagement))
    }

    @Test("Readiness never automatically selects OpenAI, but preserves explicit permitted selection")
    func remoteReadinessDoesNotSelectRemoteProvider() {
        let state = readiness(connected: true, plan: true)
        #expect(state.selectableProviders(access: allProvidersEnabled) == [.openAI])
        #expect(state.normalizedSelection(nil, access: allProvidersEnabled) == nil)
        #expect(state.normalizedSelection(.onDevice, access: allProvidersEnabled) == nil)
        #expect(state.normalizedSelection(.openAI, access: allProvidersEnabled) == .openAI)
    }

    @Test("Disconnect, plan loss, and local model removal normalize to a ready local provider or none")
    func staleSelectionUsesConservativeFallback() {
        #expect(readiness(afm: true).normalizedSelection(.openAI, access: allProvidersEnabled) == .foundationModels)
        #expect(readiness(downloaded: true, connected: true).normalizedSelection(.openAI, access: allProvidersEnabled) == .onDevice)
        #expect(readiness(laya: true).normalizedSelection(.onDevice, access: allProvidersEnabled) == .laya)
        #expect(readiness(downloaded: true).normalizedSelection(.laya, access: allProvidersEnabled) == .onDevice)
        #expect(readiness().normalizedSelection(.laya, access: allProvidersEnabled) == nil)
        #expect(readiness().normalizedSelection(.onDevice, access: allProvidersEnabled) == nil)
        #expect(readiness(plan: true).normalizedSelection(.openAI, access: allProvidersEnabled) == nil)
    }

    @Test("A ready explicit local selection survives normalization without preferring AFM")
    func normalizationPreservesReadySelection() {
        let state = readiness(afm: true, downloaded: true, laya: true)
        #expect(state.normalizedSelection(.onDevice, access: allProvidersEnabled) == .onDevice)
        #expect(state.normalizedSelection(.laya, access: allProvidersEnabled) == .laya)
        #expect(state.normalizedSelection(nil, access: allProvidersEnabled) == .foundationModels)
    }

    @Test("Existing policy reads readiness changes without being recreated")
    func connectionChangesRefreshSelectionAndRuntimeRouting() {
        let access = allProvidersEnabled
        let state = ProviderReadinessState(readiness: readiness(afm: true))
        let policy = BetaFeaturePolicy(
            accessReader: { access },
            selectionReader: { state.readiness.normalizedSelection(state.selected, access: access) }
        )
        #expect(!state.readiness.selectableProviders(access: access).contains(.openAI))
        state.readiness = readiness(afm: true, connected: true, plan: true)
        #expect(state.readiness.selectableProviders(access: access).contains(.openAI))
        #expect(policy.routingDecision(for: .standardAnalysis) == .providers([.foundationModels]))
        state.selected = .openAI
        #expect(policy.routingDecision(for: .standardAnalysis) == .providers([.openAI]))
        state.readiness = readiness(afm: true)
        #expect(!state.readiness.selectableProviders(access: access).contains(.openAI))
        #expect(policy.routingDecision(for: .standardAnalysis) == .providers([.foundationModels]))
        state.readiness = readiness()
        #expect(policy.routingDecision(for: .standardAnalysis) == .rules(.providerDisabled))
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

    @Test("메일 요약은 Laya 우선순위 선택과 독립적으로 AFM을 사용한다")
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

    @Test("Meeting and personal analysis keep Apple regardless of priority provider", arguments: [PersonaAIProvider.openAI, .laya])
    func meetingAnalysisIsLocalOnly(selection: PersonaAIProvider) {
        let policy = BetaFeaturePolicy(
            accessReader: {
                BetaProviderAccess(foundationModelsEnabled: true, onDeviceEnabled: true, openAIEnabled: true,
                                   layaEnabled: true, meetingVoiceProcessingEnabled: false)
            },
            selectionReader: { selection }
        )
        #expect(policy.routingDecision(for: .standardAnalysis) == .providers([selection]))
        #expect(policy.routingDecision(for: .meetingAnalysis) == .providers([.foundationModels]))
        #expect(policy.routingDecision(for: .personalNarrative) == .providers([.foundationModels]))
    }
}

@MainActor
private final class ProviderReadinessState {
    var readiness: BetaProviderReadiness
    var selected: PersonaAIProvider?

    init(readiness: BetaProviderReadiness) {
        self.readiness = readiness
    }
}
