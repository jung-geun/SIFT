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
}
