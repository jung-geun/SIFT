import Foundation
import Testing
@testable import todo

@Suite("AI provider selection", .serialized)
struct AIProviderAuthTests {

    init() {
        reset()
    }

    private func reset() {
        UserDefaults.standard.removeObject(forKey: "selectedAIProvider")
    }

    @Test("지원하는 TODO 정렬 AI는 온디바이스 제공자만 노출한다")
    func supportedProvidersAreLocalOnly() {
        #expect(PersonaAIProvider.allCases == [.foundationModels, .onDevice])
    }

    @Test("알 수 없는 저장값은 AFM으로 폴백한다")
    func factoryFallsBackForUnknownStoredProvider() {
        defer { reset() }
        UserDefaults.standard.set("legacy-cloud-provider", forKey: "selectedAIProvider")

        let service = IntelligenceServiceFactory.makeService()
        #expect(String(describing: type(of: service)).contains("FoundationModelsEngine"))
    }

    @Test("온디바이스 선택값은 온디바이스 엔진을 사용한다")
    func factoryUsesOnDeviceEngine() {
        defer { reset() }
        UserDefaults.standard.set(PersonaAIProvider.onDevice.rawValue, forKey: "selectedAIProvider")

        let service = IntelligenceServiceFactory.makeService()
        #expect(String(describing: type(of: service)).contains("OnDeviceLLMIntelligenceEngine"))
    }
}
