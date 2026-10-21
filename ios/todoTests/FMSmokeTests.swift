import Foundation
import Testing
@testable import todo

// MARK: - Foundation Models availability and deterministic adapters
//
// Adapter tests inject typed runtime responses; native model quality and guardrail
// behavior belong to manual smoke runs, not the default regression suite.

// MARK: - 가용성 메시징

@Suite("FM availability messaging")
struct FMAvailabilityMessagingTests {

    @Test("available returns nil")
    func availableReturnsNil() {
        let reason = FoundationModelsAvailability.unavailableExplanation(
            isAvailable: true,
            iOSMajorVersion: 27,
            isSimulator: false,
            frameworkLinked: true
        )
        #expect(reason == nil)
    }

    @Test("simulator returns simulator copy")
    func simulatorReturnsSimulatorCopy() {
        let reason = FoundationModelsAvailability.unavailableExplanation(
            isAvailable: false,
            iOSMajorVersion: 27,
            isSimulator: true,
            frameworkLinked: true,
            language: .korean
        )
        #expect(reason == "시뮬레이터에서는 Apple Foundation Models를 비활성화합니다. 실기기에서 Apple Intelligence 및 Siri 설정을 확인하세요.")
    }

    @Test("missing framework returns support copy")
    func missingFrameworkReturnsSupportCopy() {
        let reason = FoundationModelsAvailability.unavailableExplanation(
            isAvailable: false,
            iOSMajorVersion: 27,
            isSimulator: false,
            frameworkLinked: false,
            language: .korean
        )
        #expect(reason == "Apple Foundation Models는 iOS 26 이상 및 FoundationModels.framework가 있는 빌드에서만 사용할 수 있습니다.")
    }

    @Test("iOS 26 returns Apple Intelligence activation copy")
    func iOS26ReturnsAppleIntelligenceActivationCopy() {
        let reason = FoundationModelsAvailability.unavailableExplanation(
            isAvailable: false,
            iOSMajorVersion: 26,
            isSimulator: false,
            frameworkLinked: true,
            language: .korean
        )
        #expect(reason == "Apple Foundation Models는 Apple Intelligence를 사용할 수 있고 활성화된 기기에서만 사용할 수 있습니다. 설정 > Apple Intelligence 및 Siri에서 활성화 상태를 확인하세요.")
    }

    @Test("iOS 27 returns Siri AI language copy")
    func iOS27ReturnsSiriAILanguageCopy() {
        let reason = FoundationModelsAvailability.unavailableExplanation(
            isAvailable: false,
            iOSMajorVersion: 27,
            isSimulator: false,
            frameworkLinked: true,
            language: .korean
        )
        #expect(reason == "Apple Foundation Models는 현재 Siri AI를 사용할 수 있는 영어권 Siri 언어 및 Apple Intelligence 활성화 환경에서만 사용할 수 있습니다. 설정 > Apple Intelligence 및 Siri에서 언어와 활성화 상태를 확인하세요.")
    }
}

#if canImport(FoundationModels)
import FoundationModels


@available(iOS 26.0, *)
private final class CapturingEmailRuntime: @unchecked Sendable, FoundationModelsRuntime {
    private enum Output {
        case summary(FMEmailSummaryOutput)
        case deadline(FMEmailOutput)
    }

    private let output: Output
    private let lock = NSLock()
    private var lastInstructions = ""
    private var lastPrompt = ""

    init(output: FMEmailSummaryOutput) {
        self.output = .summary(output)
    }

    init(output: FMEmailOutput) {
        self.output = .deadline(output)
    }

    func rankTodos(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMPriorityRankingList { fatalError("unexpected runtime call") }

    func analyzeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailOutput {
        guard case .deadline(let output) = output else { fatalError("unexpected runtime call") }
        lock.withLock {
            lastInstructions = instructions
            lastPrompt = userPrompt
        }
        return output
    }

    func summarizeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailSummaryOutput {
        guard case .summary(let output) = output else { fatalError("unexpected runtime call") }
        lock.withLock {
            lastInstructions = instructions
            lastPrompt = userPrompt
        }
        return output
    }

    func generatePersonaNarrative(
        instructions: String,
        userPrompt: String
    ) async throws -> FMPersonaNarrativeOutput { fatalError("unexpected runtime call") }

    func narrateBehavior(
        instructions: String,
        userPrompt: String
    ) async throws -> FMBehaviorNarrativeOutput { fatalError("unexpected runtime call") }


    func analyzeMeeting(
        instructions: String,
        userPrompt: String
    ) async throws -> FMMeetingExtractionOutput { fatalError("unexpected runtime call") }

    func correctTranscript(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMTranscriptCorrectionOutput { fatalError("unexpected runtime call") }

    func draftTodoFromEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailTodoDraftOutput { fatalError("unexpected runtime call") }

    func request() async -> (instructions: String, prompt: String) {
        lock.withLock {
            (lastInstructions, lastPrompt)
        }
    }
}

@available(iOS 26.0, *)
private struct NarrativeRuntime: FoundationModelsRuntime {
    let personaOutput: FMPersonaNarrativeOutput
    let behaviorOutput: FMBehaviorNarrativeOutput

    func rankTodos(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMPriorityRankingList { fatalError("unexpected runtime call") }

    func analyzeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailOutput { fatalError("unexpected runtime call") }

    func summarizeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailSummaryOutput { fatalError("unexpected runtime call") }

    func generatePersonaNarrative(
        instructions: String,
        userPrompt: String
    ) async throws -> FMPersonaNarrativeOutput { personaOutput }

    func narrateBehavior(
        instructions: String,
        userPrompt: String
    ) async throws -> FMBehaviorNarrativeOutput { behaviorOutput }

    func analyzeMeeting(
        instructions: String,
        userPrompt: String
    ) async throws -> FMMeetingExtractionOutput { fatalError("unexpected runtime call") }

    func correctTranscript(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMTranscriptCorrectionOutput { fatalError("unexpected runtime call") }

    func draftTodoFromEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailTodoDraftOutput { fatalError("unexpected runtime call") }
}

@Suite("FM email summary adapter", .serialized)
@MainActor
struct FMEmailSummaryAdapterTests {
    @Test("Guided Generation output is normalized into a detail-card summary")
    func summarizesEmailWithTypedOutput() async throws {
        guard #available(iOS 26.0, *) else { return }
        try await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let selectedKey = SettingsStore.betaSelectedProviderKey
            let originalSelection = defaults.object(forKey: selectedKey)
            defer {
                if let originalSelection {
                    defaults.set(originalSelection, forKey: selectedKey)
                } else {
                    defaults.removeObject(forKey: selectedKey)
                }
            }
            defaults.set(PersonaAIProvider.foundationModels.rawValue, forKey: selectedKey)

            let body = String(repeating: "x", count: 1_500) + "TRUNCATED"
            let runtime = CapturingEmailRuntime(
                output: FMEmailSummaryOutput(
                    summary: "  Submit the proposal by Friday.  ",
                    keyPoints: [" Deadline: Friday ", "", "Owner: Product team"],
                    actionItems: [" Reply with the final proposal ", ""]
                )
            )
            let service = FoundationModelsService(runtime: runtime, policy: BetaFeaturePolicy(selectionReader: { .foundationModels }))
            let result = try await service.summarizeEmail(
                subject: "Proposal review",
                sender: "Product team <product@example.com>",
                body: body,
                language: .english
            )
            let request = await runtime.request()

            #expect(result.summary == "Submit the proposal by Friday.")
            #expect(result.keyPoints == ["Deadline: Friday", "Owner: Product team"])
            #expect(result.actionItems == ["Reply with the final proposal"])
            #expect(request.instructions.contains("single email"))
            #expect(request.instructions.contains("untrusted data"))
            #expect(request.prompt.contains("<email>"))
            #expect(request.prompt.contains("</email>"))
            #expect(request.prompt.contains("Proposal review"))
            #expect(request.prompt.contains("Product team <product@example.com>"))
            #expect(request.prompt.contains(String(repeating: "x", count: 1_500)))
            #expect(!request.prompt.contains("TRUNCATED"))
        }
    }

    @Test("Guided Generation outputs map to persona and behavior narratives")
    func mapsNarrativeOutputs() async throws {
        guard #available(iOS 26.0, *) else { return }
        try await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let selectedKey = SettingsStore.betaSelectedProviderKey
            let originalSelection = defaults.object(forKey: selectedKey)
            defer {
                if let originalSelection { defaults.set(originalSelection, forKey: selectedKey) }
                else { defaults.removeObject(forKey: selectedKey) }
            }
            defaults.set(PersonaAIProvider.foundationModels.rawValue, forKey: selectedKey)

            let runtime = NarrativeRuntime(
                personaOutput: FMPersonaNarrativeOutput(
                    descriptionText: "Grounded persona.",
                    evidence: ["Observed evidence."]
                ),
                behaviorOutput: FMBehaviorNarrativeOutput(
                    summary: "Observed behavior summary.",
                    insights: ["Observed insight."]
                )
            )
            let service = FoundationModelsService(runtime: runtime, policy: BetaFeaturePolicy(selectionReader: { .foundationModels }))
            let baseline = MemoryService.computeAnalysis(todos: [], language: .english)
            let persona = try await service.generatePersonaNarrative(
                existingPersona: "",
                fallback: PersonaRuleDraft(
                    personaTypes: [],
                    descriptionText: "Rule draft.",
                    evidence: [],
                    confidence: baseline.behaviorProfile.confidence
                ),
                behaviorProfile: baseline.behaviorProfile,
                language: .english
            )
            let behavior = try await service.narrateBehavior(
                baseline: baseline,
                language: .english
            )

            #expect(persona == PersonaNarrative(
                descriptionText: "Grounded persona.",
                evidence: ["Observed evidence."]
            ))
            #expect(behavior == BehaviorNarrative(
                summary: "Observed behavior summary.",
                insights: ["Observed insight."]
            ))
        }
    }
}


@Suite("FM email deadline adapter")
@MainActor
struct FMEmailDeadlineAdapterTests {
    @Test("An empty typed deadline produces no email extraction")
    func missingDeadlineDoesNotInventExtraction() async throws {
        guard #available(iOS 26.0, *) else { return }
        let now = Date(timeIntervalSince1970: 1_782_432_000)
        let runtime = CapturingEmailRuntime(output: FMEmailOutput(
            dueDateISO: "",
            isAllDay: false,
            sender: "동료",
            senderEmail: "colleague@company.com",
            keywordScore: 0,
            deadlineSentence: "",
            notes: "점심 메뉴 추천"
        ))
        let policy = BetaFeaturePolicy(accessReader: {
            BetaProviderAccess(
                foundationModelsEnabled: true,
                onDeviceEnabled: false,
                openAIEnabled: false,
                layaEnabled: false,
                meetingVoiceProcessingEnabled: false
            )
        }, selectionReader: { .foundationModels })
        let service = FoundationModelsService(runtime: runtime, policy: policy)
        let message = GmailMessage(
            id: "no-deadline", threadID: "thread", messageID: "<no-deadline@test>",
            subject: "점심 메뉴 추천",
            from: "동료 <colleague@company.com>",
            snippet: "오늘 점심 뭐 먹을까요?",
            body: "오늘 점심 메뉴 추천해주세요. 한식? 중식?",
            htmlBody: nil,
            receivedAt: now,
            labelIds: [], isBulk: false
        )

        let result = try await service.analyzeEmail(message, now: now, language: .korean)
        let request = await runtime.request()

        // Prove the nonempty message reached the adapter, rather than an early nil return.
        #expect(request.prompt.contains(message.body))
        #expect(result == nil)
    }
}

#endif // canImport(FoundationModels)
