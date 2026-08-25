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

    func analyzeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailOutput

    func summarizeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailSummaryOutput

    func generatePersonaNarrative(
        instructions: String,
        userPrompt: String
    ) async throws -> FMPersonaNarrativeOutput

    func narrateBehavior(
        instructions: String,
        userPrompt: String
    ) async throws -> FMBehaviorNarrativeOutput


    func analyzeMeeting(
        instructions: String,
        userPrompt: String
    ) async throws -> FMMeetingExtractionOutput

    func correctTranscript(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMTranscriptCorrectionOutput

    func draftTodoFromEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailTodoDraftOutput
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

    func analyzeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailOutput {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: userPrompt, generating: FMEmailOutput.self).content
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

    func analyzeMeeting(
        instructions: String,
        userPrompt: String
    ) async throws -> FMMeetingExtractionOutput {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: userPrompt, generating: FMMeetingExtractionOutput.self).content
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

    func draftTodoFromEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailTodoDraftOutput {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: userPrompt, generating: FMEmailTodoDraftOutput.self).content
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

protocol MeetingRefinementProvider: Sendable {
    func correct(
        segments: [MeetingSegment],
        glossaryHint: String,
        language: AppLanguage
    ) async throws -> TranscriptCorrectionBatchResult
}

protocol GeminiHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionGeminiHTTPTransport: GeminiHTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
