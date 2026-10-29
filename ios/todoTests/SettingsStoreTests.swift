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


    @Test("Nemotron defaults on without changing a saved opt-out; Whisper stays optional")
    func meetingModelChoicesPreserveOptOut() async {
        await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let keys = [SettingsStore.betaMeetingDiarizationEnabledKey,
                        SettingsStore.betaMeetingAdvancedTranscriptionEnabledKey]
            let originals = keys.map { defaults.object(forKey: $0) }
            defer {
                for (key, value) in zip(keys, originals) {
                    if let value { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }
            keys.forEach(defaults.removeObject(forKey:))
            let settings = SettingsStore.shared
            #expect(settings.effectiveMeetingDiarizationEnabled)
            #expect(!settings.meetingAdvancedTranscriptionEnabled)
            settings.meetingDiarizationEnabled = false
            settings.meetingAdvancedTranscriptionEnabled = true
            #expect(!settings.effectiveMeetingDiarizationEnabled)
            #expect(settings.meetingAdvancedTranscriptionEnabled)
        }
    }

    @Test("Installed local models do not authorize inference without Beta opt-in")
    func localFallbackRequiresChoice() async {
        await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let key = SettingsStore.localModelFallbackEnabledKey
            let original = defaults.object(forKey: key)
            defer {
                if let original { defaults.set(original, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            defaults.removeObject(forKey: key)
            #expect(!SettingsStore.betaProviderAccess().onDeviceEnabled)
            SettingsStore.shared.localModelFallbackEnabled = true
            #expect(SettingsStore.betaProviderAccess().onDeviceEnabled
                == !FoundationModelsAvailability.isDeviceEligible)
            SettingsStore.shared.localModelFallbackEnabled = false
            #expect(!BetaFeaturePolicy().authorizes(.onDevice, for: .modelManagement))
        }
    }

    @Test("Disabling local fallback also blocks a previously enabled Laya model")
    func localOptOutDisablesLaya() async {
        await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let keys = [SettingsStore.localModelFallbackEnabledKey, SettingsStore.betaLayaEnabledKey]
            let originals = keys.map { defaults.object(forKey: $0) }
            defer {
                for (key, original) in zip(keys, originals) {
                    if let original { defaults.set(original, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }
            defaults.set(true, forKey: SettingsStore.betaLayaEnabledKey)
            defaults.set(true, forKey: SettingsStore.localModelFallbackEnabledKey)
            #expect(SettingsStore.betaProviderAccess().layaEnabled == !FoundationModelsAvailability.isDeviceEligible)
            SettingsStore.shared.localModelFallbackEnabled = false
            #expect(!BetaFeaturePolicy().authorizes(.laya, for: .layaModelManagement))
            #expect(!SettingsStore.betaProviderAccess().onDeviceEnabled)
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
