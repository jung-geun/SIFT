import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(FoundationModels)
@available(iOS 26.0, *)
protocol FoundationModelsRuntime: Sendable {
    func rankTodos(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMPriorityRankingList


    func summarizeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailSummaryOutput

    func reviewEmailActions(candidates: [EmailActionReviewCandidate], sourceSection: String) async throws -> FMEmailActionReviewOutput

    func generatePersonaNarrative(
        instructions: String,
        userPrompt: String
    ) async throws -> FMPersonaNarrativeOutput

    func narrateBehavior(
        instructions: String,
        userPrompt: String
    ) async throws -> FMBehaviorNarrativeOutput


    /// Plain prose generation for long-input tasks where a nested guided schema runs
    /// out of output tokens. Defaults to unavailable so unrelated conformers need no code.
    func respondText(instructions: String, userPrompt: String, maximumResponseTokens: Int) async throws -> String

    func correctTranscript(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMTranscriptCorrectionOutput

}

@available(iOS 26.0, *)
struct LiveFoundationModelsRuntime: FoundationModelsRuntime {
    func rankTodos(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMPriorityRankingList {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(
            to: userPrompt,
            generating: FMPriorityRankingList.self,
            options: options
        ).content
    }


    func summarizeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailSummaryOutput {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(
            to: userPrompt,
            generating: FMEmailSummaryOutput.self
        ).content
    }

    func reviewEmailActions(candidates: [EmailActionReviewCandidate], sourceSection: String) async throws -> FMEmailActionReviewOutput {
        let data = try JSONSerialization.data(withJSONObject: [
            "candidates": candidates.map { ["index": $0.index, "text": $0.text] as [String: Any] },
            "source_section": sourceSection
        ])
        let session = LanguageModelSession(instructions: Prompts.EmailSummaryFM.actionReviewInstruction)
        return try await session.respond(
            to: String(decoding: data, as: UTF8.self), generating: FMEmailActionReviewOutput.self
        ).content
    }

    func generatePersonaNarrative(
        instructions: String,
        userPrompt: String
    ) async throws -> FMPersonaNarrativeOutput {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(
            to: userPrompt,
            generating: FMPersonaNarrativeOutput.self
        ).content
    }

    func narrateBehavior(
        instructions: String,
        userPrompt: String
    ) async throws -> FMBehaviorNarrativeOutput {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(
            to: userPrompt,
            generating: FMBehaviorNarrativeOutput.self
        ).content
    }

    func respondText(instructions: String, userPrompt: String, maximumResponseTokens: Int) async throws -> String {
        // Greedy sampling: fixed input gives fixed output, so a meeting reprocesses
        // to the same notes instead of a different set of tasks each time.
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: userPrompt, options: GenerationOptions(
            samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)).content
    }

    func correctTranscript(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMTranscriptCorrectionOutput {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(
            to: userPrompt,
            generating: FMTranscriptCorrectionOutput.self,
            options: options
        ).content
    }

}

@available(iOS 26.0, *)
extension FoundationModelsRuntime {
    func reviewEmailActions(candidates: [EmailActionReviewCandidate], sourceSection: String) async throws -> FMEmailActionReviewOutput {
        throw IntelligenceRoutingError.backendUnavailable(
            provider: .foundationModels, reason: RuleFallbackReason.unavailable.rawValue)
    }

    func respondText(instructions: String, userPrompt: String, maximumResponseTokens: Int) async throws -> String {
        throw IntelligenceRoutingError.backendUnavailable(
            provider: .foundationModels, reason: RuleFallbackReason.unavailable.rawValue)
    }
}
#endif

protocol OnDeviceModelRuntime: Sendable {
    func load() async throws
    func unload()
    func generate(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        contextLength: Int
    ) async throws -> String
}

struct UnavailableOnDeviceModelRuntime: OnDeviceModelRuntime {
    func load() async throws {}
    func unload() {}
    func generate(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        contextLength: Int
    ) async throws -> String {
        throw OnDeviceLLMService.LLMError.modelNotLoaded
    }
}

/// Corrects recognition errors without translating the source language or script.
/// `sourceLanguageTag` describes the transcript; `language` is only for labels.
protocol MeetingRefinementProvider: Sendable {
    func correct(
        segments: [MeetingSegment],
        glossaryHint: String,
        sourceLanguageTag: String,
        language: AppLanguage
    ) async throws -> TranscriptCorrectionBatchResult
}

