import Foundation
import Testing
@testable import todo

@Suite("AI provider selection", .serialized)
@MainActor
struct AIProviderAuthTests {

    private func reset() {
        UserDefaults.standard.removeObject(forKey: "selectedAIProvider")
        UserDefaults.standard.removeObject(forKey: "selectedAIProvider.isLocal")
        SettingsStore.setTestCloudValue(nil, forKey: "selectedAIProvider")
        UserDefaults.standard.set(false, forKey: "pieroot.todo.iCloudSyncEnabled")
        GeminiProviderService.deleteAPIKey()
    }

    @Test("지원하는 TODO 정렬 AI에 Gemini가 포함된다")
    func supportedProvidersIncludeGemini() async {
        await AIProviderTestIsolation.shared.withLock {
            reset()
            #expect(PersonaAIProvider.allCases == [.foundationModels, .onDevice, .gemini])
        }
    }

    @Test("알 수 없는 저장값은 AFM 요청으로 정규화된 RoutedIntelligenceEngine을 사용한다")
    func factoryFallsBackForUnknownStoredProvider() async {
        await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            UserDefaults.standard.set("legacy-cloud-provider", forKey: "selectedAIProvider")

            let service = IntelligenceServiceFactory.makeService()
            #expect(String(describing: type(of: service)).contains("RoutedIntelligenceEngine"))
        }
    }

    @Test("Gemini 선택값도 RoutedIntelligenceEngine을 사용한다")
    func factoryUsesRoutedEngineForGemini() async {
        await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            UserDefaults.standard.set(PersonaAIProvider.gemini.rawValue, forKey: "selectedAIProvider")

            let service = IntelligenceServiceFactory.makeService()
            #expect(String(describing: type(of: service)).contains("RoutedIntelligenceEngine"))
        }
    }

    @Test("공유 selectedAIProvider는 iCloud 값을 우선 읽는다")
    func selectedProviderPrefersGlobalValueWhenKeyIsShared() async {
        await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            UserDefaults.standard.set(PersonaAIProvider.gemini.rawValue, forKey: "selectedAIProvider")
            UserDefaults.standard.set(false, forKey: "selectedAIProvider.isLocal")
            SettingsStore.setTestCloudValue(PersonaAIProvider.foundationModels.rawValue, forKey: "selectedAIProvider")

            #expect(SettingsStore.selectedProvider() == .foundationModels)
        }
    }
}
