import Foundation

// MARK: - Email Analysis Engine Protocol

struct EmailAnalysisOutcome<Value> {
    let value: Value
    let executionPath: AnalysisExecutionPath
}

/// 이메일 제목·본문·발신자를 받아 마감일 추출 결과를 반환하는 엔진 프로토콜.
///
/// 포그라운드: 별도 활성화된 Apple Intelligence로만 기한·요약을 추출한다.
/// 백그라운드나 비가용 환경: 로컬 NSDataDetector로 기한만 찾는다.
/// 자동 수집에서는 메일 본문을 외부 제공자나 Qwen으로 전달하지 않는다.
protocol EmailAnalysisEngine {
    /// GmailMessage를 분석해 마감일을 추출한다.
    /// - Parameters:
    ///   - msg: 분석할 Gmail 메시지 (subject + body + from 헤더 포함)
    ///   - now: 기준 시각 (테스트·재현 가능성을 위해 주입)
    /// - Returns: 마감일이 감지되면 EmailExtraction, 없으면 nil
    func analyze(
        _ msg: GmailMessage,
        now: Date,
        language: AppLanguage
    ) async throws -> EmailAnalysisOutcome<EmailExtraction?>
}

// MARK: - On-Device Detector Engine (deterministic fallback)

/// NSDataDetector 기반 온디바이스 분석 엔진.
/// EmailContentAnalyzer를 래핑한다. 네트워크·AFM 없이 완전 로컬.
struct OnDeviceDetectorEngine: EmailAnalysisEngine {
    private let analyzer = EmailContentAnalyzer()
    private let fallbackReason: RuleFallbackReason

    init(fallbackReason: RuleFallbackReason = .noProviderOptIn) {
        self.fallbackReason = fallbackReason
    }

    func analyze(
        _ msg: GmailMessage,
        now: Date,
        language: AppLanguage
    ) async throws -> EmailAnalysisOutcome<EmailExtraction?> {
        EmailAnalysisOutcome(
            value: analyzer.analyze(msg, now: now, language: language),
            executionPath: .rules(fallbackReason)
        )
    }
}

// MARK: - Foundation Models Email Engine

struct FoundationModelsEmailEngine: EmailAnalysisEngine {
    func analyze(
        _ msg: GmailMessage,
        now: Date,
        language: AppLanguage
    ) async throws -> EmailAnalysisOutcome<EmailExtraction?> {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelsAvailability.isAvailable {
            do {
                let value = try await FoundationModelsService().analyzeEmail(
                    msg,
                    now: now,
                    language: language
                )
                return EmailAnalysisOutcome(value: value, executionPath: .beta(.foundationModels))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return EmailAnalysisOutcome(
                    value: EmailContentAnalyzer().analyze(msg, now: now, language: language),
                    executionPath: .rules(ProviderErrorMapper.fallbackReason(for: error) ?? .providerExecutionFailed)
                )
            }
        }
        #endif
        return EmailAnalysisOutcome(
            value: EmailContentAnalyzer().analyze(msg, now: now, language: language),
            executionPath: .rules(.unavailable)
        )
    }
}

// MARK: - Email Analysis Engine Factory

/// - Foreground: Apple Intelligence when its separate email-analysis gate is enabled.
/// - Background or unavailable AFM: local date detector; automatic mail stays local.
enum EmailAnalysisEngineFactory {
    static func makeEngine(allowFoundationModels: Bool = true) -> any EmailAnalysisEngine {
        guard allowFoundationModels else { return OnDeviceDetectorEngine(fallbackReason: .providerDisabled) }

        switch BetaFeaturePolicy().routingDecision(for: .emailAnalysis) {
        case .rules(let reason):
            return OnDeviceDetectorEngine(fallbackReason: reason)
        case .providers:
            return FoundationModelsEmailEngine()
        }
    }
}
