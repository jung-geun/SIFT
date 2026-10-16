import Foundation

/// A local model recommendation, not proof of an obligation. Uncertainty requires review.
nonisolated enum EmailCandidateOutcome: Equatable, Sendable {
    case candidate
    case notCandidate
    case uncertain
}

/// On-device email triage using the explicitly enabled, already installed Laya model.
/// Does not install assets, send mail remotely, generate summaries/dates, or fall back to rules.
/// The encoder bounds raw fields head+tail and flags omissions; incomplete evidence is uncertain.
/// The caller owns review, unavailable-provider fallback, and persistence.
@MainActor
final class LayaEmailDecisionService {
    private static var cachedTokenizer: (directory: URL, tokenizer: LayaPriorityTokenizer)?

    /// Uses the native email predicate (false index 0, true index 1), retaining ambiguity.
    /// Throws for disabled/unavailable/unverified models, encoding/inference failures, or cancellation.
    func candidateOutcome(subject: String, sender: String, body: String) async throws -> EmailCandidateOutcome {
        try Task.checkCancellation()
        try requireAvailability()
        let service = LayaDecisionService.shared
        let modelDirectory = try await service.verifiedModelDirectory()
        try Task.checkCancellation()
        try requireAvailability()
        let tokenizer: LayaPriorityTokenizer
        if let cached = Self.cachedTokenizer, cached.directory == modelDirectory {
            tokenizer = cached.tokenizer
        } else {
            tokenizer = try await LayaPriorityTokenizer(modelDirectory: modelDirectory)
            try Task.checkCancellation()
            try requireAvailability()
            Self.cachedTokenizer = (modelDirectory, tokenizer)
        }
        try Task.checkCancellation()

        // Pass original evidence, not a prefix excerpt or a generated summary. The shared
        // field-aware encoder bounds work before tokenization and preserves both ends.
        let input = try tokenizer.encode(
            state: Self.decisionState(subject: subject, sender: sender, body: body),
            question: .emailCandidate
        )
        try Task.checkCancellation()
        // Recheck after suspension: opt-out or model removal must not silently permit inference.
        try requireAvailability()
        let answer = try await LayaCoreMLRunner.shared.predict(input, modelDirectory: modelDirectory)
        try Task.checkCancellation()
        try requireAvailability()
        return try Self.outcome(for: answer)
    }

    /// Keep original text for field-aware packing; `context` carries the sender identity.
    nonisolated static func decisionState(subject: String, sender: String, body: String) -> LayaDecisionState {
        LayaDecisionState(
            title: subject.allSatisfy(\.isWhitespace) ? "Email" : subject,
            details: body,
            context: sender
        )
    }

    /// Interpret only this native predicate. Ties, escalation, and omissions are not negatives.
    nonisolated static func outcome(for answer: LayaAnswer) throws -> EmailCandidateOutcome {
        guard answer.question == .emailCandidate else {
            throw LayaCoreMLRunner.Failure.invalidOutput
        }
        guard answer.isDecisive else { return .uncertain }
        return answer.selectedIndex == 1 ? .candidate : .notCandidate
    }

    private func requireAvailability() throws {
        guard BetaFeaturePolicy().authorizes(.laya, for: .layaModelManagement) else {
            Self.cachedTokenizer = nil
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .laya, reason: RuleFallbackReason.providerDisabled.rawValue
            )
        }
        guard LayaDecisionService.shared.isCapable else {
            Self.cachedTokenizer = nil
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .laya, reason: RuleFallbackReason.unavailable.rawValue
            )
        }
        guard LayaDecisionService.shared.isModelInstalled,
              !LayaDecisionService.shared.isLoading,
              !LayaDecisionService.shared.isDeleting else {
            Self.cachedTokenizer = nil
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .laya, reason: RuleFallbackReason.modelNotLoaded.rawValue
            )
        }
    }
}
