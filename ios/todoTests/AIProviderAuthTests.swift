import Foundation
import Testing
@testable import todo

@Suite("AI provider selection", .serialized)
@MainActor
struct AIProviderAuthTests {

    @Test("공유 provider 선택은 로컬 전용 빌드에서도 저장값을 유지한다")
    func sharedProviderSelectionRespectsCloudCapability() async {
        await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let keys = ["selectedAIProvider", "selectedAIProvider.isLocal", "pieroot.todo.testCloud.selectedAIProvider"]
            let savedValues = keys.map { ($0, defaults.object(forKey: $0)) }
            defer {
                for (key, value) in savedValues {
                    if let value {
                        defaults.set(value, forKey: key)
                    } else {
                        defaults.removeObject(forKey: key)
                    }
                }
            }
            UserDefaults.standard.set(PersonaAIProvider.openAI.rawValue, forKey: "selectedAIProvider")
            UserDefaults.standard.set(false, forKey: "selectedAIProvider.isLocal")
            SettingsStore.setTestCloudValue(PersonaAIProvider.foundationModels.rawValue, forKey: "selectedAIProvider")

            #if SIFT_LOCAL_ONLY
            #expect(SettingsStore.selectedProvider() == .openAI)
            #else
            #expect(SettingsStore.selectedProvider() == .foundationModels)
            #endif
        }
    }
}
