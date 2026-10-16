import Foundation
import Testing
@testable import todo

@Suite("SettingsStore syncable keys")
@MainActor
struct SettingsStoreTests {
    @Test("tutorial completion flag stays device local")
    func tutorialCompletionFlagIsNotSyncable() {
        #expect(SettingsStore.syncableKeys.contains("pieroot.todo.hasCompletedTutorial") == false)
    }

    @Test("legacy memory keys are no longer syncable")
    func legacyMemoryKeysAreNotSyncable() {
        for key in SettingsStore.legacyMemoryKeys {
            #expect(SettingsStore.syncableKeys.contains(key) == false)
        }
    }

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

    #if SIFT_LOCAL_ONLY
    @Test("local-only provider selection preserves local writes despite stale cloud preference")
    func localOnlyProviderSelectionPreservesLocalWrites() async {
        await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let key = "selectedAIProvider"
            let markerKey = "\(key).isLocal"
            let cloudKey = "pieroot.todo.testCloud.\(key)"
            let syncKey = "pieroot.todo.iCloudSyncEnabled"
            let keys = [key, markerKey, cloudKey, syncKey]
            let previous = keys.map { defaults.object(forKey: $0) }
            defer {
                for (savedKey, value) in zip(keys, previous) {
                    if let value {
                        defaults.set(value, forKey: savedKey)
                    } else {
                        defaults.removeObject(forKey: savedKey)
                    }
                }
            }

            // An existing shared setting must remain visible even when the
            // persisted preference and an old cloud value disagree with it.
            defaults.set(true, forKey: syncKey)
            defaults.set(false, forKey: markerKey)
            defaults.set(PersonaAIProvider.openAI.rawValue, forKey: key)
            SettingsStore.setTestCloudValue(PersonaAIProvider.foundationModels.rawValue, forKey: key)
            #expect(SettingsStore.selectedProvider() == .openAI)

            // Explicit cloud callers must still commit a usable local setting.
            SettingsStore.shared.setGlobal(key, value: PersonaAIProvider.onDevice.rawValue)
            #expect(SettingsStore.selectedProvider() == .onDevice)
            SettingsStore.shared.set(key, value: PersonaAIProvider.openAI.rawValue)
            #expect(SettingsStore.selectedProvider() == .openAI)
            #expect(defaults.bool(forKey: syncKey))
        }
    }
    #endif
}
