import Foundation
import Testing
@testable import todo

@Suite("Meeting content language capabilities")
struct MeetingSummaryLanguagesTests {
    @Test("saved output is independent of source and UI; legacy output follows source")
    func legacyAndSelectedOutput() {
        #expect(MeetingSummaryLanguages.requestedLanguageTag(sourceLanguageTag: "bn-BD", savedSummaryLanguageTag: nil) == "bn-BD")
        #expect(MeetingSummaryLanguages.requestedLanguageTag(sourceLanguageTag: "ar-SA", savedSummaryLanguageTag: "") == "ar-SA")
        #expect(MeetingSummaryLanguages.requestedLanguageTag(sourceLanguageTag: "bn-BD", savedSummaryLanguageTag: "pt-BR") == "pt-BR")
    }


    @Test("provider locale fallback cannot authorize mixed, unknown or nonlinguistic content", arguments: ["und", "MUL", "zxx", "mul-IN", "und_US"], [false, true])
    func rejectsUnspecifiedLanguage(tag: String, asOutput: Bool) {
        #expect(throws: IntelligenceRoutingError.self) {
            try MeetingSummaryLanguages.requireSupport(
                provider: .foundationModels,
                sourceLanguageTag: asOutput ? "en-US" : tag,
                summaryLanguageTag: asOutput ? tag : "en-US"
            ) { _ in true }
        }
    }

    @Test("unsupported input or output does not silently become English", arguments: ["bn-BD", "ar-SA"])
    func unsupportedEitherLocale(unsupported: String) {
        #expect(throws: IntelligenceRoutingError.self) {
            try MeetingSummaryLanguages.requireSupport(
                provider: .foundationModels, sourceLanguageTag: "bn-BD", summaryLanguageTag: "ar-SA"
            ) { $0 != Locale(identifier: unsupported) }
        }
    }

    @Test("each selectable local checkpoint has its own documented coverage")
    @MainActor
    func localModelCoverage() {
        for model in OnDeviceLLMService.modelCatalog {
            let tags = MeetingSummaryLanguages.languageTags(forLocalModelID: model.id)
            #expect(!tags.isEmpty)
            for tag in tags {
                #expect(MeetingSummaryLanguages.supportsLocalModel(modelID: model.id, languageTag: tag))
            }
        }
        let miniCPM = "mlx-community/MiniCPM5-1B-4bit"
        #expect(MeetingSummaryLanguages.supportsLocalModel(modelID: miniCPM, languageTag: "en-GB"))
        #expect(MeetingSummaryLanguages.supportsLocalModel(modelID: miniCPM, languageTag: "zh-CN"))
        #expect(!MeetingSummaryLanguages.supportsLocalModel(modelID: miniCPM, languageTag: "bn-BD"))
        #expect(!MeetingSummaryLanguages.supportsLocalModel(modelID: miniCPM, languageTag: "ar-SA"))
        for model in ["mlx-community/Qwen3.5-2B-MLX-4bit", "mlx-community/Qwen3.5-4B-MLX-4bit"] {
            for tag in ["bn-BD", "ar-SA", "pt-BR", "zh-Hant-TW", "ta-IN", "sw-KE"] {
                #expect(MeetingSummaryLanguages.supportsLocalModel(modelID: model, languageTag: tag))
            }
        }
        #expect(!MeetingSummaryLanguages.supportsLocalModel(modelID: "custom/unknown", languageTag: "en-US"))
        #expect(!MeetingSummaryLanguages.supportsLocalModel(modelID: miniCPM, languageTag: "not a language"))
    }

    @Test("local request requires support for source and requested summary independently")
    func localRequestGate() throws {
        let miniCPM = "mlx-community/MiniCPM5-1B-4bit"
        try MeetingSummaryLanguages.requireLocalModelSupport(modelID: miniCPM, sourceLanguageTag: "en-US", summaryLanguageTag: "zh-Hans")
        #expect(throws: IntelligenceRoutingError.self) {
            try MeetingSummaryLanguages.requireLocalModelSupport(modelID: miniCPM, sourceLanguageTag: "bn-BD", summaryLanguageTag: "en-US")
        }
        #expect(throws: IntelligenceRoutingError.self) {
            try MeetingSummaryLanguages.requireLocalModelSupport(modelID: miniCPM, sourceLanguageTag: "en-US", summaryLanguageTag: "ar-SA")
        }
    }

    @Test("Summary choices come only from the selected runnable model, never the download catalog")
    func selectedRunnableLocalModelInventory() {
        let mini = "mlx-community/MiniCPM5-1B-4bit"
        let qwen = "mlx-community/Qwen3.5-2B-MLX-4bit"
        let miniOptions = MeetingSummaryLanguages.options(provider: .onDevice,
            selectedLocalModelID: mini, loadedLocalModelID: mini, foundationModelLanguageTags: ["ko", "fr"])
        #expect(Set(miniOptions.map(\.id)) == Set(MeetingSummaryLanguages.languageTags(forLocalModelID: mini)))
        #expect(!miniOptions.contains { MeetingLanguageOption(id: $0.id).isEquivalent(to: "ko-KR") })
        #expect(MeetingSummaryLanguages.options(provider: .onDevice,
            selectedLocalModelID: qwen, loadedLocalModelID: nil).isEmpty)
        #expect(MeetingSummaryLanguages.options(provider: .onDevice,
            selectedLocalModelID: mini, loadedLocalModelID: qwen).isEmpty)
        #expect(MeetingSummaryLanguages.options(provider: .onDevice,
            selectedLocalModelID: "custom/unknown", loadedLocalModelID: "custom/unknown").isEmpty)
        let qwenOptions = MeetingSummaryLanguages.options(provider: .onDevice,
            selectedLocalModelID: qwen, loadedLocalModelID: qwen)
        #expect(qwenOptions.contains { MeetingLanguageOption(id: $0.id).isEquivalent(to: "ko-KR") })
        #expect(qwenOptions.allSatisfy { MeetingSummaryLanguages.supportsLocalModel(modelID: qwen, languageTag: $0.id) })
    }

    @Test("Unavailable and inapplicable summary providers expose no hypothetical local languages")
    func unavailableSummaryInventory() {
        let model = "mlx-community/Qwen3.5-2B-MLX-4bit"
        let providers: [PersonaAIProvider?] = [nil, .openAI, .laya]
        for provider in providers {
            #expect(MeetingSummaryLanguages.options(provider: provider,
                selectedLocalModelID: model, loadedLocalModelID: model,
                foundationModelLanguageTags: ["en", "ko"]).isEmpty)
        }
        #expect(MeetingSummaryLanguages.options(provider: .foundationModels,
            selectedLocalModelID: model, loadedLocalModelID: model).isEmpty)
    }

    @Test("Apple summary inventory excludes the unselected local model and merges equivalent locales")
    func foundationSummaryInventory() {
        let model = "mlx-community/Qwen3.5-2B-MLX-4bit"
        let options = MeetingSummaryLanguages.options(provider: .foundationModels,
            selectedLocalModelID: model, loadedLocalModelID: model,
            foundationModelLanguageTags: ["en", "en-US", "ko", "ko-KR", "zh-Hans", "zh-Hant"])
            .map { MeetingLanguageOption(id: $0.id) }
        #expect(options.count == 4)
        #expect(options.filter { $0.isEquivalent(to: "ko-KR") }.count == 1)
        #expect(options.contains { $0.isEquivalent(to: "zh-Hans") })
        #expect(options.contains { $0.isEquivalent(to: "zh-Hant") })
        #expect(!options.contains { $0.isEquivalent(to: "bn-BD") })
    }
}
