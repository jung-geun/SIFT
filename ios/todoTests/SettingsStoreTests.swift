import Foundation
import Testing
@testable import todo

@Suite("SettingsStore legacy data migration")
@MainActor
struct SettingsStoreTests {

    @Test("legacy memory payload maps into MemoryAnalysis")
    func legacyMemoryPayloadMapsIntoMemoryAnalysis() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let payload: [String: Any] = [
            "pieroot.todo.memorySummary": "  완료 패턴 요약  ",
            "pieroot.todo.memoryInsights": ["아침 완료가 많음", "마감 전 처리"],
            "pieroot.todo.memoryDate": createdAt,
            "pieroot.todo.memoryFastTags": ["업무", "학습"],
            "pieroot.todo.memoryOverdueRate": 0.25,
            "pieroot.todo.memoryProductiveHour": 10
        ]

        let analysis = SettingsStore.legacyMemoryAnalysis { payload[$0] }

        #expect(analysis?.summary == "완료 패턴 요약")
        #expect(analysis?.insights == ["아침 완료가 많음", "마감 전 처리"])
        #expect(analysis?.fastTags == ["업무", "학습"])
        #expect(analysis?.createdAt == createdAt)
        #expect(analysis?.overdueRate == 0.25)
        #expect(analysis?.productiveHour == 10)
    }

    @Test("obsolete local provider flags cannot disable platform or installed-model routing", arguments: [false, true])
    func obsoleteLocalOptOutCannotDisableImplicitProviders(restoredFromFullStorage: Bool) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let keys = [
                "pieroot.todo.beta.foundationModelsEnabled",
                "pieroot.todo.beta.onDeviceModelEnabled",
                SettingsStore.betaOpenAIEnabledKey,
                SettingsStore.betaLayaEnabledKey
            ]
            let originals = keys.map { defaults.object(forKey: $0) }
            defer {
                for (key, original) in zip(keys, originals) {
                    if let original { defaults.set(original, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }
            keys.forEach { defaults.set(false, forKey: $0) }
            if restoredFromFullStorage {
                let payload = try JSONEncoder().encode(CloudPreferenceValue.boolean(false))
                for key in keys.prefix(2) {
                    defaults.removeObject(forKey: key)
                    try CloudPreferenceStore.apply(
                        key: CloudPreferenceStore.prefix + key,
                        payload: payload,
                        expectedDigest: nil,
                        defaults: defaults
                    )
                }
            }

            let access = SettingsStore.betaProviderAccess()
            let readyLocal = BetaProviderReadiness(
                foundationModelsAvailable: true, onDeviceModelUsable: true,
                openAIAccountConnected: true, openAIPlanPermitted: true, layaModelUsable: false
            )
            #expect(readyLocal.selectableProviders(access: access) == [.foundationModels, .onDevice])
            #expect(readyLocal.normalizedSelection(.onDevice, access: access) == .onDevice)
            #expect(readyLocal.normalizedSelection(.openAI, access: access) == .foundationModels)
            let unavailable = BetaProviderReadiness(
                foundationModelsAvailable: false, onDeviceModelUsable: false,
                openAIAccountConnected: true, openAIPlanPermitted: true, layaModelUsable: false
            )
            #expect(unavailable.selectableProviders(access: access).isEmpty)

            let policy = BetaFeaturePolicy(selectionReader: { .foundationModels })
            #expect(policy.routingDecision(for: .emailAnalysis) == .providers([.foundationModels]))
            #expect(policy.routingDecision(for: .transcriptRefinement) == .providers([.foundationModels, .onDevice]))
            #expect(policy.authorizes(.onDevice, for: .modelManagement))
            #expect(!policy.authorizes(.openAI, for: .standardAnalysis))
        }
    }

    @Test("beta audio preferences default independently and retain explicit choices")
    func betaAudioPreferencesRetainChoices() async {
        await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let keys = [SettingsStore.betaMeetingVoiceProcessingEnabledKey, SettingsStore.meetingAutoRefineKey]
            let originals = keys.map { defaults.object(forKey: $0) }
            defer {
                for (key, original) in zip(keys, originals) {
                    if let original { defaults.set(original, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }
            keys.forEach(defaults.removeObject(forKey:))
            let settings = SettingsStore.shared
            #expect(!settings.meetingVoiceProcessingEnabled)
            #expect(!settings.effectiveMeetingVoiceProcessingEnabled)
            #expect(settings.meetingAutoRefineEnabled)

            settings.meetingVoiceProcessingEnabled = true
            settings.meetingAutoRefineEnabled = false
            #expect(defaults.bool(forKey: SettingsStore.betaMeetingVoiceProcessingEnabledKey))
            #expect(defaults.object(forKey: SettingsStore.meetingAutoRefineKey) as? Bool == false)
            #expect(settings.effectiveMeetingVoiceProcessingEnabled)
            #expect(!settings.meetingAutoRefineEnabled)

            settings.meetingVoiceProcessingEnabled = false
            settings.meetingAutoRefineEnabled = true
            #expect(!settings.effectiveMeetingVoiceProcessingEnabled)
            #expect(settings.meetingAutoRefineEnabled)
        }
    }

}
