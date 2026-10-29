import Foundation
import Testing
@testable import todo


#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
private final class CapturingMeetingLanguageRuntime: FoundationModelsRuntime, @unchecked Sendable {
    struct Request {
        let instructions: String
        let prompt: String
    }

    private let lock = NSLock()
    private var requests: [Request] = []

    func capturedRequests() -> [Request] {
        lock.withLock { requests }
    }

    func analyzeMeeting(instructions: String, userPrompt: String) async throws -> FMMeetingExtractionOutput {
        lock.withLock { requests.append(Request(instructions: instructions, prompt: userPrompt)) }
        return FMMeetingExtractionOutput(
            title: "خطة المشروع",
            summary: "سيشارك الفريق التقرير.",
            decisions: ["تم اعتماد الخطة."],
            unresolvedQuestions: ["متى نلتقي؟"],
            actions: [FMMeetingActionItem(
                title: "إرسال التقرير",
                notes: "إلى فريق SIFT.",
                dueDateISO: "2026-10-20T00:00:00.000Z",
                sourceSegmentNumber: 1
            )]
        )
    }

    func correctTranscript(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMTranscriptCorrectionOutput {
        lock.withLock { requests.append(Request(instructions: instructions, prompt: userPrompt)) }
        return FMTranscriptCorrectionOutput(corrections: [])
    }

    func rankTodos(instructions: String, userPrompt: String, options: GenerationOptions) async throws -> FMPriorityRankingList {
        fatalError("unexpected non-meeting runtime call")
    }
    func analyzeEmail(instructions: String, userPrompt: String) async throws -> FMEmailOutput {
        fatalError("unexpected non-meeting runtime call")
    }
    func summarizeEmail(instructions: String, userPrompt: String) async throws -> FMEmailSummaryOutput {
        fatalError("unexpected non-meeting runtime call")
    }
    func generatePersonaNarrative(instructions: String, userPrompt: String) async throws -> FMPersonaNarrativeOutput {
        fatalError("unexpected non-meeting runtime call")
    }
    func narrateBehavior(instructions: String, userPrompt: String) async throws -> FMBehaviorNarrativeOutput {
        fatalError("unexpected non-meeting runtime call")
    }
    func draftTodoFromEmail(instructions: String, userPrompt: String) async throws -> FMEmailTodoDraftOutput {
        fatalError("unexpected non-meeting runtime call")
    }
}

@Suite("FM meeting language adapter", .serialized)
@MainActor
struct FMMeetingLanguageAdapterTests {
    private func withFoundationModelsSelection(_ operation: () async throws -> Void) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let keys = [SettingsStore.betaSelectedProviderKey]
            let originals = keys.map { defaults.object(forKey: $0) }
            defer {
                for (key, original) in zip(keys, originals) {
                    if let original {
                        defaults.set(original, forKey: key)
                    } else {
                        defaults.removeObject(forKey: key)
                    }
                }
            }
            defaults.set(PersonaAIProvider.foundationModels.rawValue, forKey: SettingsStore.betaSelectedProviderKey)
            try await operation()
        }
    }

    private var segment: MeetingSegment {
        MeetingSegment(id: "bengali-arabic", startMs: 0, endMs: 1_000, text: "SIFT রিপোর্ট পাঠাব। سنرسل التقرير.")
    }

    @Test("Supported non-AppLanguage source and output reach the injected summary runtime unchanged")
    @available(iOS 26.0, *)
    func supportedSummaryReachesRuntime() async throws {
        try await withFoundationModelsSelection {
            let runtime = CapturingMeetingLanguageRuntime()
            let service = FoundationModelsService(runtime: runtime, policy: AIProviderTestIsolation.foundationPolicy)
            var checkedLanguages: [String] = []
            let result = try await service.analyzeMeeting(
                meetingID: "meeting-language-test",
                segments: [segment],
                sourceLanguageTag: "bn-BD",
                summaryLanguageTag: "ar-SA",
                language: .french,
                supportsLocale: {
                    checkedLanguages.append($0.language.languageCode?.identifier ?? "")
                    return true
                }
            )
            let request = try #require(runtime.capturedRequests().first)
            #expect(runtime.capturedRequests().count == 1)
            #expect(checkedLanguages.contains("bn"))
            #expect(checkedLanguages.contains("ar"))
            for prompt in [request.instructions, request.prompt] {
                #expect(prompt.contains("bn-BD"))
                #expect(prompt.contains("ar-SA"))
            }
            #expect(request.prompt.contains(segment.text))
            #expect(result.title == "خطة المشروع")
            #expect(result.summary == "سيشارك الفريق التقرير.")
            #expect(result.decisions == ["تم اعتماد الخطة."])
            #expect(result.unresolvedQuestions == ["متى نلتقي؟"])
            let action = try #require(result.actionDrafts.first)
            #expect(action.title == "إرسال التقرير")
            #expect(action.notes == "إلى فريق SIFT.")
            #expect(action.sourceSegmentIDs == [segment.id])
            #expect(action.dueAtISO8601 == "2026-10-20T00:00:00.000Z")
        }
    }

    @Test("Unsupported source or output language never reaches summary runtime", arguments: ["bn", "ar"])
    @available(iOS 26.0, *)
    func unsupportedSummaryStopsBeforeRuntime(unsupported: String) async throws {
        try await withFoundationModelsSelection {
            let runtime = CapturingMeetingLanguageRuntime()
            let service = FoundationModelsService(runtime: runtime, policy: AIProviderTestIsolation.foundationPolicy)
            do {
                _ = try await service.analyzeMeeting(
                    meetingID: "unsupported-language-test",
                    segments: [segment],
                    sourceLanguageTag: "bn-BD",
                    summaryLanguageTag: "ar-SA",
                    language: .english,
                    supportsLocale: { $0.language.languageCode?.identifier != unsupported }
                )
                Issue.record("Expected unsupported meeting language rejection")
            } catch {
                #expect(ProviderErrorMapper.fallbackReason(for: error) == .providerNotApplicable)
            }
            #expect(runtime.capturedRequests().isEmpty)
        }
    }

    @Test("Correction preserves mixed-language source evidence instead of using UI language")
    @available(iOS 26.0, *)
    func supportedCorrectionReachesRuntime() async throws {
        try await withFoundationModelsSelection {
            let runtime = CapturingMeetingLanguageRuntime()
            let result = try await FoundationModelsService(runtime: runtime, policy: AIProviderTestIsolation.foundationPolicy).correctTranscript(
                segments: [segment],
                sourceLanguageTag: "bn-BD",
                language: .german,
                supportsLocale: { _ in true }
            )
            let request = try #require(runtime.capturedRequests().first)
            #expect(runtime.capturedRequests().count == 1)
            #expect(request.instructions.contains("bn-BD"))
            #expect(request.prompt.contains("bn-BD"))
            #expect(request.prompt.contains(segment.text))
            #expect(result.segments == [segment])
            #expect(result.succeededBatchCount == 1)
        }
    }

    @Test("Unsupported correction source fails before the batch runtime")
    @available(iOS 26.0, *)
    func unsupportedCorrectionStopsBeforeRuntime() async throws {
        try await withFoundationModelsSelection {
            let runtime = CapturingMeetingLanguageRuntime()
            do {
                _ = try await FoundationModelsService(runtime: runtime, policy: AIProviderTestIsolation.foundationPolicy).correctTranscript(
                    segments: [segment],
                    sourceLanguageTag: "bn-BD",
                    language: .english,
                    supportsLocale: { _ in false }
                )
                Issue.record("Expected unsupported correction language rejection")
            } catch {
                #expect(ProviderErrorMapper.fallbackReason(for: error) == .providerNotApplicable)
            }
            #expect(runtime.capturedRequests().isEmpty)
        }
    }

}
#endif
