import Foundation
import Testing
import SwiftData
@testable import todo

@Suite("Meeting analysis routing reasons")
@MainActor
struct MeetingAnalysisRoutingTests {
    private let keys = [
        SettingsStore.betaOpenAIEnabledKey,
        SettingsStore.betaSelectedProviderKey
    ]

    private func reset() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }


    private func result() -> MeetingResult {
        MeetingResult(segments: [MeetingSegment(id: "s1", startMs: 0, endMs: 1_000, text: "원문")])
    }


    @Test("remote priority selection keeps meeting analysis local")
    func remoteSelectionUsesLocalMeetingRules() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            SettingsStore.shared.setBetaProvider(.openAI, enabled: true)
            let outcome = try await MeetingAnalysisEngine(policy: BetaFeaturePolicy(
                accessReader: { .disabled }, selectionReader: { .openAI })).analyze(
                meetingID: "123e4567-e89b-12d3-a456-426614174000",
                result: result(),
                sourceLanguageTag: "ko-KR",
                summaryLanguageTag: "pt-BR",
                language: .korean
            )
            #expect(outcome.executionPath == .rules(.noEligibleProvider))
            #expect(outcome.engineSource == .heuristic)
            #expect(outcome.result.segments == result().segments)
        }
    }

    @Test("rules return source excerpts rather than a stale translated summary", arguments: ["আমরা কাল প্রতিবেদন পাঠাব।", "سنرسل التقرير غدًا."])
    func sourcePreservingFallback(text: String) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            let segment = MeetingSegment(id: "evidence", startMs: 0, endMs: 1_000, text: text)
            var input = MeetingResult(segments: [segment])
            input.summary = "A stale English summary"
            input.decisions = ["A stale English decision"]
            input.unresolvedQuestions = ["A stale English question"]
            let outcome = try await MeetingAnalysisEngine(
                policy: BetaFeaturePolicy(accessReader: { .disabled }, selectionReader: { nil })
            ).analyze(
                meetingID: "123e4567-e89b-12d3-a456-426614174000",
                result: input,
                sourceLanguageTag: text.hasPrefix("আমরা") ? "bn-BD" : "ar-SA",
                summaryLanguageTag: "pt-BR",
                language: .english
            )
            #expect(outcome.summaryKind == .sourceExcerpts)
            #expect(!outcome.usedOnDeviceLLM)
            #expect(outcome.result.summary == text)
            #expect(outcome.result.title == text)
            #expect(outcome.result.decisions.isEmpty)
            #expect(outcome.result.unresolvedQuestions.isEmpty)
            #expect(outcome.result.segments == input.segments)
        }
    }

    @Test("supported local source/output locales reach generation without UI substitution")
    func localRequestLanguages() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            let modelKey = "pieroot.todo.onDeviceModelID"
            let previousModel = UserDefaults.standard.object(forKey: modelKey)
            defer {
                reset()
                if let previousModel { UserDefaults.standard.set(previousModel, forKey: modelKey) }
                else { UserDefaults.standard.removeObject(forKey: modelKey) }
            }
            UserDefaults.standard.set("mlx-community/Qwen3.5-2B-MLX-4bit", forKey: modelKey)
            let runtime = MeetingSummaryRecordingRuntime()
            let policy = processingPolicy()
            let llm = OnDeviceLLMService(runtime: runtime, policy: policy)
            await llm.loadModelIfNeeded(use: .meetingAnalysis)
            let segment = MeetingSegment(id: "evidence", startMs: 0, endMs: 1_000, text: "আমরা কাল প্রতিবেদন পাঠাব।")
            let input = MeetingResult(title: "Stale English title", segments: [segment])
            let outcome = try await MeetingAnalysisEngine(localLLM: llm, policy: policy).analyze(
                meetingID: "123e4567-e89b-12d3-a456-426614174000", result: input,
                sourceLanguageTag: "bn-BD", summaryLanguageTag: "ar-SA", language: .english
            )
            let requests = runtime.requests
            #expect(requests.count == 1)
            #expect(requests.first?.system.contains("bn-BD") == true)
            #expect(requests.first?.system.contains("ar-SA") == true)
            #expect(requests.first?.user.contains(segment.text) == true)
            #expect(requests.first?.user.contains("ar-SA") == true)
            #expect(outcome.summaryKind == .generated)
            #expect(outcome.executionPath == .beta(.onDevice))
            #expect(outcome.result.segments == input.segments)
            #expect(outcome.result.title.isEmpty)
            // A preference change cannot lend Qwen capabilities to a different loaded container.
            UserDefaults.standard.set("custom/different-selected-model", forKey: modelKey)
            let mismatched = try await MeetingAnalysisEngine(localLLM: llm, policy: policy).analyze(
                meetingID: "123e4567-e89b-12d3-a456-426614174000", result: input,
                sourceLanguageTag: "bn-BD", summaryLanguageTag: "ar-SA", language: .english
            )
            #expect(runtime.requests.count == 1)
            #expect(mismatched.executionPath == .rules(.modelNotLoaded))
            #expect(mismatched.summaryKind == .sourceExcerpts)
            #expect(mismatched.result.summary == segment.text)
        }
    }

    @Test("unavailable or undocumented local models preserve source with truthful status", arguments: [false, true])
    func unavailableLocalModel(loaded: Bool) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            let modelKey = "pieroot.todo.onDeviceModelID"
            let previousModel = UserDefaults.standard.object(forKey: modelKey)
            defer {
                reset()
                if let previousModel { UserDefaults.standard.set(previousModel, forKey: modelKey) }
                else { UserDefaults.standard.removeObject(forKey: modelKey) }
            }
            UserDefaults.standard.set("custom/undocumented-language-coverage", forKey: modelKey)
            let runtime = MeetingSummaryRecordingRuntime()
            let policy = processingPolicy()
            let llm = OnDeviceLLMService(runtime: runtime, policy: policy)
            if loaded { await llm.loadModelIfNeeded(use: .meetingAnalysis) }
            let input = MeetingResult(segments: [MeetingSegment(id: "evidence", startMs: 0, endMs: 1_000, text: "سنرسل التقرير.")])
            let outcome = try await MeetingAnalysisEngine(localLLM: llm, policy: policy).analyze(
                meetingID: "123e4567-e89b-12d3-a456-426614174000", result: input,
                sourceLanguageTag: "ar-SA", summaryLanguageTag: "pt-BR"
            )
            #expect(runtime.requests.isEmpty)
            #expect(outcome.summaryKind == .sourceExcerpts)
            #expect(outcome.executionPath == .rules(loaded ? .providerNotApplicable : .modelNotLoaded))
            #expect(outcome.result.summary == input.segments[0].text)
            #expect(outcome.result.segments == input.segments)
        }
    }
    @Test("postprocessing commits detected source corrections and independently selected summaries",
          arguments: ["ko", "en"], [false, true])
    func processingCommitsActualLanguage(detectedLanguage: String, automatic: Bool) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            let modelKey = "pieroot.todo.onDeviceModelID"
            let previousModel = UserDefaults.standard.object(forKey: modelKey)
            defer {
                reset()
                if let previousModel { UserDefaults.standard.set(previousModel, forKey: modelKey) }
                else { UserDefaults.standard.removeObject(forKey: modelKey) }
            }
            UserDefaults.standard.set("mlx-community/Qwen3.5-2B-MLX-4bit", forKey: modelKey)
            let policy = processingPolicy()
            for summaryPreference in ["", "ar-SA"] {
                let (context, record) = try processingMeeting(
                    detectedLanguages: [detectedLanguage], automatic: automatic, summaryLanguageTag: summaryPreference
                )
                let original = try #require(record.result)
                let sourceTag = automatic ? detectedLanguage : "fr-FR"
                let outputTag = summaryPreference.isEmpty ? sourceTag : summaryPreference
                let summary: String
                switch outputTag {
                case "ko": summary = "보고서를 보냅니다."
                case "en": summary = "Send the report."
                case "ar-SA": summary = "سنرسل التقرير."
                default: summary = "Nous enverrons le rapport."
                }
                let runtime = MeetingSummaryRecordingRuntime(response:
                    "{\"title\":\"\",\"summary\":\"\(summary)\",\"decisions\":[],\"questions\":[],\"actions\":[]}"
                )
                let llm = OnDeviceLLMService(runtime: runtime, policy: policy)
                await llm.loadModelIfNeeded(use: .meetingAnalysis)
                let refinement = MeetingRefinementEngine(onDeviceProvider: LanguageCheckedRefinementProvider(), policy: policy)
                let analysis = MeetingAnalysisEngine(localLLM: llm, policy: policy)
                let dependencies = MeetingPostProcessor.Dependencies(
                    snapshot: { .empty },
                    refine: { id, input, vocabulary, source, language, allowLoad in
                        try await refinement.refine(meetingID: id, result: input, vocabulary: vocabulary,
                            sourceLanguageTag: source, language: language, allowModelLoad: allowLoad)
                    },
                    analyze: { id, input, hint, source, output, language in
                        try await analysis.analyze(meetingID: id, result: input, glossaryHint: hint,
                            sourceLanguageTag: source, summaryLanguageTag: output, language: language)
                    },
                    save: { try $0.save() },
                    learnCorrections: { _, _ in }
                )
                let outcome = try await MeetingPostProcessor.refineAndAnalyze(
                    record: record, context: context, allowRefine: true, allowModelLoad: false, dependencies: dependencies
                )
                #expect(outcome.refined)
                #expect(outcome.correctionCount == 1)
                #expect(record.result?.segments[0].text == original.segments[0].text + ".")
                #expect(record.result?.transcriptRevision == original.transcriptRevision + 1)
                #expect(record.result?.summary == summary)
                #expect(record.rawResult == original)
                #expect(record.languageTag == (automatic ? "" : "fr-FR"))
                #expect(record.automaticLanguageDetection == automatic)
                #expect(record.asrDetectedLanguages == [detectedLanguage])
                #expect(record.summaryLanguageTag == summaryPreference)
                #expect(record.summaryKindRaw == MeetingAnalysisEngine.SummaryKind.generated.rawValue)
                #expect(record.summaryResultLanguageTag == outputTag)
                #expect(runtime.requests.count == 1)
                #expect(runtime.requests.first?.system.contains("Source language tag: \(sourceTag).") == true)
                #expect(runtime.requests.first?.system.contains("Summary language tag: \(outputTag).") == true)
                let id = record.meetingID
                let persisted = try #require(ModelContext(context.container).fetch(
                    FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == id })
                ).first)
                #expect(persisted.persistenceSnapshot() == record.persistenceSnapshot())
            }
        }
    }

    @Test("mixed and unknown automatic speech commits original excerpts without generating",
          arguments: [["ko", "en", "ko"], [], ["not-a-language"], ["ko", "invalid"], ["und"]])
    func processingPreservesUnsupportedEvidence(evidence: [String]) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            let modelKey = "pieroot.todo.onDeviceModelID"
            let previousModel = UserDefaults.standard.object(forKey: modelKey)
            defer {
                reset()
                if let previousModel { UserDefaults.standard.set(previousModel, forKey: modelKey) }
                else { UserDefaults.standard.removeObject(forKey: modelKey) }
            }
            UserDefaults.standard.set("mlx-community/Qwen3.5-2B-MLX-4bit", forKey: modelKey)
            let policy = processingPolicy()
            let runtime = MeetingSummaryRecordingRuntime()
            let llm = OnDeviceLLMService(runtime: runtime, policy: policy)
            await llm.loadModelIfNeeded(use: .meetingAnalysis)
            let (context, record) = try processingMeeting(
                detectedLanguages: evidence, automatic: true, summaryLanguageTag: "ar-SA"
            )
            let original = try #require(record.result)
            let expectedTag = evidence == ["ko", "en", "ko"] ? "mul" : "und"
            let refinement = MeetingRefinementEngine(onDeviceProvider: LanguageCheckedRefinementProvider(), policy: policy)
            let analysis = MeetingAnalysisEngine(localLLM: llm, policy: policy)
            var learned = false
            let dependencies = MeetingPostProcessor.Dependencies(
                snapshot: { .empty },
                refine: { id, input, vocabulary, source, language, allowLoad in
                    try await refinement.refine(meetingID: id, result: input, vocabulary: vocabulary,
                        sourceLanguageTag: source, language: language, allowModelLoad: allowLoad)
                },
                analyze: { id, input, hint, source, output, language in
                    try await analysis.analyze(meetingID: id, result: input, glossaryHint: hint,
                        sourceLanguageTag: source, summaryLanguageTag: output, language: language)
                },
                save: { try $0.save() },
                learnCorrections: { _, _ in learned = true }
            )
            let outcome = try await MeetingPostProcessor.refineAndAnalyze(
                record: record, context: context, allowRefine: true, allowModelLoad: false, dependencies: dependencies
            )
            #expect(!outcome.refined)
            #expect(!learned)
            #expect(runtime.requests.isEmpty)
            #expect(record.result?.segments == original.segments)
            #expect(record.result?.transcriptRevision == original.transcriptRevision)
            #expect(record.rawResult == original)
            #expect(record.result?.summary == original.segments.map(\.text).joined(separator: "\n"))
            #expect(record.result?.decisions.isEmpty == true)
            #expect(record.result?.unresolvedQuestions.isEmpty == true)
            #expect(record.refinementEngineLabel.isEmpty)
            #expect(record.refinementFallbackReasonRaw == RuleFallbackReason.providerNotApplicable.rawValue)
            #expect(record.summaryFallbackReasonRaw == RuleFallbackReason.providerNotApplicable.rawValue)
            #expect(record.summaryKindRaw == MeetingAnalysisEngine.SummaryKind.sourceExcerpts.rawValue)
            #expect(record.summaryResultLanguageTag == expectedTag)
            #expect(record.languageTag.isEmpty)
            #expect(record.summaryLanguageTag == "ar-SA")
            #expect(record.automaticLanguageDetection)
            #expect(record.asrDetectedLanguages == evidence)
            let id = record.meetingID
            let persisted = try #require(ModelContext(context.container).fetch(
                FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == id })
            ).first)
            #expect(persisted.persistenceSnapshot() == record.persistenceSnapshot())
        }
    }

    private func processingPolicy() -> BetaFeaturePolicy {
        BetaFeaturePolicy(accessReader: {
            BetaProviderAccess(foundationModelsEnabled: false, onDeviceEnabled: true, openAIEnabled: false,
                               layaEnabled: false, meetingVoiceProcessingEnabled: false)
        }, selectionReader: { .onDevice })
    }

    private func processingMeeting(
        detectedLanguages: [String], automatic: Bool, summaryLanguageTag: String
    ) throws -> (ModelContext, MeetingRecord) {
        let configuration = ModelConfiguration(schema: AppDataContainer.meetingSchema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: configuration)
        let context = ModelContext(container)
        let record = MeetingRecord(languageTag: automatic ? "" : "fr-FR", automaticLanguageDetection: automatic,
                                   summaryLanguageTag: summaryLanguageTag)
        let text: String
        if !automatic { text = "Nous enverrons le rapport" }
        else if detectedLanguages == ["en"] { text = "Send the report" }
        else if detectedLanguages == ["ko"] { text = "보고서를 보냅니다" }
        else { text = "보고서를 보냅니다 Send the report" }
        var original = MeetingResult(segments: [
            MeetingSegment(id: "evidence", startMs: 0, endMs: 1_000, text: text)
        ])
        original.summary = "Stale French summary"
        original.decisions = ["Stale decision"]
        original.unresolvedQuestions = ["Stale question"]
        try record.replaceTranscriptionBase(original, status: .ready)
        record.asrDetectedLanguages = detectedLanguages
        context.insert(record)
        try context.save()
        return (context, record)
    }
}

@MainActor
private final class MeetingSummaryRecordingRuntime: OnDeviceModelRuntime {
    struct Request: Sendable {
        let system: String
        let user: String
    }
    private(set) var requests: [Request] = []
    private let response: String
    init(response: String = #"{"title":"","summary":"سنرسل التقرير غدًا.","decisions":[],"questions":[],"actions":[]}"#) {
        self.response = response
    }
    func load() async throws {}
    nonisolated func unload() {}
    func generate(systemPrompt: String, userPrompt: String, maxTokens: Int, contextLength: Int) async throws -> String {
        requests.append(Request(system: systemPrompt, user: userPrompt))
        return response
    }
}

private struct LanguageCheckedRefinementProvider: MeetingRefinementProvider {
    func correct(
        segments: [MeetingSegment], glossaryHint: String, sourceLanguageTag: String, language: AppLanguage
    ) async throws -> TranscriptCorrectionBatchResult {
        try MeetingSummaryLanguages.requireLocalModelSupport(
            modelID: "mlx-community/Qwen3.5-2B-MLX-4bit",
            sourceLanguageTag: sourceLanguageTag, summaryLanguageTag: sourceLanguageTag
        )
        var corrected = segments
        for index in corrected.indices { corrected[index].text += "." }
        return TranscriptCorrectionBatchResult(
            segments: corrected, attemptedBatchCount: 1, succeededBatchCount: 1, failedBatchCount: 0
        )
    }
}
