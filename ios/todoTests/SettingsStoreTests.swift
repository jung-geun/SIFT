import Foundation
import Testing
@testable import todo

@Suite("SettingsStore syncable keys")
@MainActor
struct SettingsStoreTests {
    @Test("syncableKeys includes Gemini and analyzed message settings without duplicates")
    func syncableKeysContainExpectedAISettings() {
        #expect(SettingsStore.syncableKeys.contains("pieroot.todo.analyzedMessageIDs"))
        #expect(SettingsStore.syncableKeys.contains("selectedAIProvider"))
        #expect(SettingsStore.syncableKeys.contains("pieroot.todo.geminiModelID"))
        #expect(SettingsStore.syncableKeys.contains("pieroot.todo.providerEmailAnalysisEnabled"))
        #expect(Set(SettingsStore.syncableKeys).count == SettingsStore.syncableKeys.count)
    }

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
        #expect(analysis?.recordTitle == "이전 행동 패턴 분석")
        #expect(analysis?.accessScopeSummary == "레거시 설정 저장소에서 이전됨")
        #expect(analysis?.processorDescription == "레거시 저장소")
    }
}
