import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Meeting content languages are independent of the app's eight UI languages.
/// Local entries describe documented coverage, not a guarantee of summary quality.
nonisolated enum MeetingSummaryLanguages {
    struct Option: Identifiable, Hashable, Sendable {
        let id: String

        var displayName: String {
            Locale(identifier: id).localizedString(forIdentifier: id) ?? id
        }
    }

    /// The selectable MiniCPM5 checkpoint documents English and Chinese only.
    /// Do not infer Qwen coverage merely because both models run through MLX.
    /// https://huggingface.co/openbmb/MiniCPM5-1B
    private static let miniCPMTags = ["en", "zh-Hans"]

    /// Conservative, enumerated subset of Qwen3.5's advertised 201 languages.
    /// The 3.5 release says coverage expands from the 119 languages/dialects
    /// enumerated by Qwen3; do not invent a complete 201-locale inventory.
    /// https://qwen.ai/blog?id=qwen3.5
    /// https://qwenlm.github.io/blog/qwen3/#key-features
    private static let qwenTags = """
    en fr pt de ro sv da bg ru cs el uk es nl sk hr pl lt nb nn fa sl gu lv it oc ne mr be sr lb vec as cy szl ast hne awa mai bho sd ga fo hi pa bn or tg yi lmo lij scn fur sc gl ca is sq prs af mk si ur mag bs hy
    zh-Hans zh-Hant yue my ar ars apc arz ary acm acq aeb he mt
    id ms tl ceb jv su min ban bjn pag ilo war ta te kn ml tr az uz kk ba tt
    th lo fi et hu vi km ja ko ka eu ht pap kea tpi sw
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    private static let qwenCodes = Set(qwenTags.map { Locale(identifier: $0).language.languageCode?.identifier ?? $0 })

    static func languageTags(forLocalModelID modelID: String) -> [String] {
        switch modelID {
        case "mlx-community/MiniCPM5-1B-4bit": miniCPMTags
        case "mlx-community/Qwen3.5-2B-MLX-4bit", "mlx-community/Qwen3.5-4B-MLX-4bit": qwenTags
        default: [] // A custom model ID is not evidence of multilingual support.
        }
    }

    /// Match MeetingAnalysisEngine's routing and loaded-model guard. Downloadable
    /// checkpoints, stale loaded models and unselected providers add no choices.
    @MainActor
    static var supported: [Option] {
        guard case .providers(let providers) = BetaFeaturePolicy().routingDecision(for: .meetingAnalysis),
              let provider = providers.first else { return [] }
        let local = OnDeviceLLMService.shared
        var foundationTags: [String] = []
        #if canImport(FoundationModels)
        if provider == .foundationModels,
           #available(iOS 26.0, macOS 26.0, *), FoundationModelsAvailability.isAvailable {
            foundationTags = SystemLanguageModel.default.supportedLanguages.map(\.minimalIdentifier)
        }
        #endif
        return options(provider: provider, selectedLocalModelID: local.modelID,
            loadedLocalModelID: local.loadedModelIdentifier, foundationModelLanguageTags: foundationTags)
    }

    static func options(
        provider: PersonaAIProvider?,
        selectedLocalModelID: String,
        loadedLocalModelID: String?,
        foundationModelLanguageTags: [String] = []
    ) -> [Option] {
        let tags: [String]
        switch provider {
        case .foundationModels:
            tags = foundationModelLanguageTags
        case .onDevice where loadedLocalModelID == selectedLocalModelID:
            tags = languageTags(forLocalModelID: selectedLocalModelID)
        default:
            tags = []
        }
        return MeetingLanguageOption.deduplicated(tags.map { MeetingLanguageOption(id: $0) })
            .map { Option(id: $0.id) }
    }

    /// Menu capability uses the same selected provider, loaded checkpoint and
    /// two-language validation as generation, not merely a nonempty output list.
    @MainActor
    static func canSummarize(sourceLanguageTag: String, summaryLanguageTag: String) -> Bool {
        guard case .providers(let providers) = BetaFeaturePolicy().routingDecision(for: .meetingAnalysis),
              let provider = providers.first else { return false }
        do {
            switch provider {
            case .foundationModels:
                guard #available(iOS 26.0, macOS 26.0, *), FoundationModelsAvailability.isAvailable else { return false }
                try requireFoundationModelsSupport(sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: summaryLanguageTag)
            case .onDevice:
                let local = OnDeviceLLMService.shared
                guard local.isModelLoaded, let loaded = local.loadedModelIdentifier,
                      loaded == local.modelID else { return false }
                try requireLocalModelSupport(modelID: loaded,
                    sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: summaryLanguageTag)
            case .openAI, .laya:
                return false
            }
            return true
        } catch {
            return false
        }
    }

    static func requestedLanguageTag(sourceLanguageTag: String, savedSummaryLanguageTag: String?) -> String {
        guard let savedSummaryLanguageTag,
              !savedSummaryLanguageTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return sourceLanguageTag
        }
        return savedSummaryLanguageTag
    }

    static func supportsLocalModel(modelID: String, languageTag: String) -> Bool {
        guard isLanguageTag(languageTag) else { return false }
        let language = Locale(identifier: languageTag).language
        guard let code = language.languageCode?.identifier else { return false }
        switch modelID {
        case "mlx-community/MiniCPM5-1B-4bit":
            return code == "en" || (code == "zh" && language.script?.identifier == "Hans")
        case "mlx-community/Qwen3.5-2B-MLX-4bit", "mlx-community/Qwen3.5-4B-MLX-4bit":
            return qwenCodes.contains(code)
        default:
            return false
        }
    }

    static func requireLocalModelSupport(modelID: String, sourceLanguageTag: String, summaryLanguageTag: String) throws {
        try requireSupport(provider: .onDevice, sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: summaryLanguageTag) {
            supportsLocalModel(modelID: modelID, languageTag: $0.identifier)
        }
    }

    /// Use Apple's locale fallback-aware API, not a static app-language allowlist
    /// or exact comparison against supportedLanguages (which loses regional aliases).
    @available(iOS 26.0, macOS 26.0, *)
    static func requireFoundationModelsSupport(sourceLanguageTag: String, summaryLanguageTag: String) throws {
        #if canImport(FoundationModels)
        try requireSupport(provider: .foundationModels, sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: summaryLanguageTag) {
            SystemLanguageModel.default.supportsLocale($0)
        }
        #else
        throw IntelligenceRoutingError.backendUnavailable(provider: .foundationModels, reason: RuleFallbackReason.unavailable.rawValue)
        #endif
    }

    static func requireSupport(
        provider: PersonaAIProvider,
        sourceLanguageTag: String,
        summaryLanguageTag: String,
        supportsLocale: (Locale) -> Bool
    ) throws {
        for tag in [sourceLanguageTag, summaryLanguageTag] {
            guard isLanguageTag(tag), supportsLocale(Locale(identifier: tag)) else {
                throw IntelligenceRoutingError.backendUnavailable(
                    provider: provider,
                    reason: RuleFallbackReason.providerNotApplicable.rawValue
                )
            }
        }
    }

    private static func isLanguageTag(_ tag: String) -> Bool {
        guard tag.range(of: #"^[A-Za-z]{2,8}([_-][A-Za-z0-9]{1,8})*$"#, options: .regularExpression) != nil else { return false }
        // These valid BCP-47 meta-tags are not a concrete language capability.
        // A provider's region/locale fallback cannot authorize mixed or unknown input.
        let base = tag.prefix { $0 != "-" && $0 != "_" }
        return base.caseInsensitiveCompare("und") != .orderedSame
            && base.caseInsensitiveCompare("mul") != .orderedSame
            && base.caseInsensitiveCompare("zxx") != .orderedSame
    }
}
