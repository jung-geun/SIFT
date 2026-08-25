import Foundation

nonisolated enum BetaProvider: String, CaseIterable, Identifiable, Sendable {
    case foundationModels
    case onDevice
    case gemini

    var id: String { rawValue }

    var personaProvider: PersonaAIProvider {
        switch self {
        case .foundationModels: .foundationModels
        case .onDevice: .onDevice
        case .gemini: .gemini
        }
    }

    init?(_ provider: PersonaAIProvider) {
        switch provider {
        case .foundationModels: self = .foundationModels
        case .onDevice: self = .onDevice
        case .gemini: self = .gemini
        }
    }
}

nonisolated struct BetaProviderAccess: Equatable, Sendable {
    let foundationModelsEnabled: Bool
    let onDeviceEnabled: Bool
    let geminiEnabled: Bool
    let meetingVoiceProcessingEnabled: Bool

    static let disabled = BetaProviderAccess(
        foundationModelsEnabled: false,
        onDeviceEnabled: false,
        geminiEnabled: false,
        meetingVoiceProcessingEnabled: false
    )

    func isEnabled(_ provider: PersonaAIProvider) -> Bool {
        switch provider {
        case .foundationModels: foundationModelsEnabled
        case .onDevice: onDeviceEnabled
        case .gemini: geminiEnabled
        }
    }
}

nonisolated enum ProviderUse: Sendable {
    case standardAnalysis
    case transcriptRefinement
    case modelManagement
}

nonisolated enum RuleFallbackReason: String, Equatable, Sendable {
    case noProviderOptIn
    case noEligibleProvider
    case providerDisabled
    case unavailable
    case modelNotLoaded
    case credentialMissing
    case consentMissing
    case invalidResponse
    case providerExecutionFailed
}

extension RuleFallbackReason {
    func localizedDescription(language: AppLanguage) -> String {
        let values: (korean: String, english: String)
        switch self {
        case .noProviderOptIn:
            values = ("활성화된 베타 provider가 없습니다.", "No beta provider is enabled.")
        case .noEligibleProvider:
            values = ("사용 가능한 provider가 없습니다.", "No eligible provider is available.")
        case .providerDisabled:
            values = ("선택한 provider가 비활성화되어 있습니다.", "The selected provider is disabled.")
        case .unavailable:
            values = ("이 기기에서 provider를 사용할 수 없습니다.", "The provider is unavailable on this device.")
        case .modelNotLoaded:
            values = ("온디바이스 모델이 로드되지 않았습니다.", "The on-device model is not loaded.")
        case .credentialMissing:
            values = ("provider 인증 정보가 없습니다.", "Provider credentials are missing.")
        case .consentMissing:
            values = ("이메일 전송 동의가 필요합니다.", "Email sharing consent is required.")
        case .invalidResponse:
            values = ("provider 응답을 해석하지 못했습니다.", "The provider returned an invalid response.")
        case .providerExecutionFailed:
            values = ("provider 분석을 완료하지 못했습니다.", "The provider could not complete the analysis.")
        }
        return AppLanguage.localized(
            "mail.analysis.fallback.\(rawValue)",
            defaultValue: language == .english ? values.english : values.korean,
            language: language,
            comment: "Email analysis fallback reason."
        )
    }
}

nonisolated enum AnalysisExecutionPath: Equatable, Sendable {
    case rules(RuleFallbackReason)
    case beta(PersonaAIProvider)
}

nonisolated enum ProviderRoutingDecision: Equatable, Sendable {
    case rules(RuleFallbackReason)
    case providers([PersonaAIProvider])
}

nonisolated struct BetaFeaturePolicy: Sendable {
    typealias AccessReader = @Sendable () -> BetaProviderAccess
    typealias SelectionReader = @Sendable () -> PersonaAIProvider?

    private let accessReader: AccessReader
    private let selectionReader: SelectionReader

    init(
        accessReader: @escaping AccessReader = { SettingsStore.betaProviderAccess() },
        selectionReader: @escaping SelectionReader = { SettingsStore.betaSelectedProvider() }
    ) {
        self.accessReader = accessReader
        self.selectionReader = selectionReader
    }

    func routingDecision(for use: ProviderUse) -> ProviderRoutingDecision {
        let access = accessReader()

        switch use {
        case .standardAnalysis:
            guard access.foundationModelsEnabled || access.onDeviceEnabled || access.geminiEnabled else {
                return .rules(.noProviderOptIn)
            }
            guard let selection = selectionReader(), access.isEnabled(selection) else {
                return .rules(.providerDisabled)
            }
            return .providers([selection])

        case .transcriptRefinement:
            let providers = [PersonaAIProvider.foundationModels, .onDevice]
                .filter(access.isEnabled)
            return providers.isEmpty ? .rules(.noEligibleProvider) : .providers(providers)

        case .modelManagement:
            return access.onDeviceEnabled
                ? .providers([.onDevice])
                : .rules(.providerDisabled)
        }
    }

    func authorizes(_ provider: PersonaAIProvider, for use: ProviderUse) -> Bool {
        switch routingDecision(for: use) {
        case .rules:
            return false
        case .providers(let providers):
            return providers.contains(provider)
        }
    }
}

nonisolated enum ProviderErrorMapper {
    static func fallbackReason(for error: Error) -> RuleFallbackReason? {
        if error is CancellationError {
            return nil
        }

        if let error = error as? IntelligenceRoutingError {
            switch error {
            case .backendUnavailable(_, let reason):
                return RuleFallbackReason(rawValue: reason) ?? .unavailable
            case .backendNotConfigured(_, let reason):
                return RuleFallbackReason(rawValue: reason) ?? .credentialMissing
            case .parseFailed:
                return .invalidResponse
            case .generationFailed:
                return .providerExecutionFailed
            }
        }

        if let error = error as? OnDeviceLLMService.LLMError {
            switch error {
            case .modelNotLoaded:
                return .modelNotLoaded
            default:
                return .providerExecutionFailed
            }
        }

        if let error = error as? MeetingRefinementEngine.RefinementError {
            switch error {
            case .engineUnavailable:
                return .unavailable
            case .localModelUnavailable:
                return .modelNotLoaded
            case .invalidModelResponse:
                return .invalidResponse
            }
        }

        return .providerExecutionFailed
    }
}
