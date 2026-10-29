import Foundation
import Testing
@testable import todo

@Suite("Meeting refinement beta routing")
@MainActor
struct MeetingRefinementBetaTests {
    private let betaKeys = [
        SettingsStore.betaOpenAIEnabledKey,
        SettingsStore.betaSelectedProviderKey
    ]

    private func resetBeta() {
        betaKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }


    private func result(text: String = "원문") -> MeetingResult {
        MeetingResult(segments: [MeetingSegment(id: "s1", startMs: 0, endMs: 1_000, text: text)])
    }

    private actor ProviderCallRecorder {
        private var calls = [String]()

        func append(_ provider: String) {
            calls.append(provider)
        }

        var snapshot: [String] {
            calls
        }
    }

    private struct FakeProvider: MeetingRefinementProvider {
        let action: @Sendable ([MeetingSegment], String, AppLanguage) async throws -> TranscriptCorrectionBatchResult

        func correct(
            segments: [MeetingSegment],
            glossaryHint _: String,
            sourceLanguageTag: String,
            language: AppLanguage
        ) async throws -> TranscriptCorrectionBatchResult {
            try await action(segments, sourceLanguageTag, language)
        }
    }

    @Test("routing without local providers keeps the transcript unchanged")
    func noLocalProviderUsesPolicyReason() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            resetBeta()
            defer { resetBeta() }
            let engine = MeetingRefinementEngine(
                policy: BetaFeaturePolicy(accessReader: { .disabled }, selectionReader: { nil })
            )
            let off = try await engine.refine(
                meetingID: "123e4567-e89b-12d3-a456-426614174000",
                result: result(),
                vocabulary: .empty,
                sourceLanguageTag: "ko-KR",
                language: .korean,
                allowModelLoad: false
            )
            #expect(off.executionPath == .rules(.noEligibleProvider))
        }
    }

    @Test("Apple failure never invokes an installed fallback model", arguments: ["bn-BD", "ar-SA"])
    func appleFailureDoesNotLoadLocalModel(sourceLanguageTag: String) async {
        await AIProviderTestIsolation.shared.withLock {
            resetBeta()
            defer { resetBeta() }
            let sourceText = sourceLanguageTag == "bn-BD" ? "বাংলা এবং العربية SIFT" : "العربية এবং বাংলা SIFT"
            let calls = ProviderCallRecorder()
            let afm = FakeProvider { _, tag, language in
                await calls.append("afm:\(tag)")
                #expect(language == .korean)
                throw IntelligenceRoutingError.backendUnavailable(provider: .foundationModels, reason: "offline")
            }
            let local = FakeProvider { segments, tag, language in
                await calls.append("onDevice:\(tag)")
                #expect(language == .korean)
                let corrected = await MainActor.run {
                    var corrected = segments
                    corrected[0].text = sourceText + "."
                    return corrected
                }
                return TranscriptCorrectionBatchResult(
                    segments: corrected,
                    attemptedBatchCount: 1,
                    succeededBatchCount: 1,
                    failedBatchCount: 0
                )
            }
            let policy = BetaFeaturePolicy(accessReader: {
                BetaProviderAccess(foundationModelsEnabled: true, onDeviceEnabled: true,
                    openAIEnabled: false, layaEnabled: false, meetingVoiceProcessingEnabled: false)
            })
            await #expect(throws: IntelligenceRoutingError.self) {
                _ = try await MeetingRefinementEngine(afmProvider: afm, onDeviceProvider: local, policy: policy).refine(
                    meetingID: "123e4567-e89b-12d3-a456-426614174000",
                    result: result(text: sourceText), vocabulary: .empty,
                    sourceLanguageTag: sourceLanguageTag, language: .korean, allowModelLoad: false
                )
            }
            #expect(await calls.snapshot == ["afm:\(sourceLanguageTag)"])
        }
    }

    @Test("AFM cancellation propagates and does not invoke on-device provider")
    func cancellationStopsProviderChain() async throws {
        await AIProviderTestIsolation.shared.withLock {
            resetBeta()
            defer { resetBeta() }
            let localCalls = ProviderCallRecorder()
            let afm = FakeProvider { _, _, _ in throw CancellationError() }
            let local = FakeProvider { segments, _, _ in
                await localCalls.append("onDevice")
                return TranscriptCorrectionBatchResult(
                    segments: segments,
                    attemptedBatchCount: 1,
                    succeededBatchCount: 1,
                    failedBatchCount: 0
                )
            }
            await #expect(throws: CancellationError.self) {
                _ = try await MeetingRefinementEngine(afmProvider: afm, onDeviceProvider: local,
                    policy: BetaFeaturePolicy(accessReader: {
                        BetaProviderAccess(foundationModelsEnabled: true, onDeviceEnabled: false,
                            openAIEnabled: false, layaEnabled: false, meetingVoiceProcessingEnabled: false)
                    })).refine(
                    meetingID: "123e4567-e89b-12d3-a456-426614174000",
                    result: result(),
                    vocabulary: .empty,
                    sourceLanguageTag: "ko-KR",
                    language: .korean,
                    allowModelLoad: false
                )
            }
            #expect(await localCalls.snapshot.isEmpty)
        }
    }

    @Test("Bengali/Arabic source tags reach either injected provider independently of English UI labels", arguments: ["bn-BD", "ar-SA"], [false, true])
    func sourceLanguageReachesSelectedProvider(sourceLanguageTag: String, useFoundationModels: Bool) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            resetBeta()
            defer { resetBeta() }
            let sourceText = sourceLanguageTag == "bn-BD" ? "আগামীকাল SIFT নিয়ে আলোচনা করব العربية" : "سنناقش SIFT غدًا বাংলা"
            let calls = ProviderCallRecorder()
            let provider = FakeProvider { segments, tag, language in
                await calls.append(tag)
                #expect(language == .english)
                return TranscriptCorrectionBatchResult(
                    segments: segments,
                    attemptedBatchCount: 1,
                    succeededBatchCount: 1,
                    failedBatchCount: 0
                )
            }
            let engine = MeetingRefinementEngine(
                afmProvider: useFoundationModels ? provider : nil,
                onDeviceProvider: useFoundationModels ? nil : provider,
                policy: BetaFeaturePolicy(accessReader: {
                    BetaProviderAccess(
                        foundationModelsEnabled: useFoundationModels,
                        onDeviceEnabled: !useFoundationModels,
                        openAIEnabled: false,
                        layaEnabled: false,
                        meetingVoiceProcessingEnabled: false
                    )
                })
            )
            let outcome = try await engine.refine(
                meetingID: "123e4567-e89b-12d3-a456-426614174000",
                result: result(text: sourceText),
                vocabulary: .empty,
                sourceLanguageTag: sourceLanguageTag,
                language: .english,
                allowModelLoad: false
            )
            #expect(await calls.snapshot == [sourceLanguageTag])
            #expect(outcome.executionPath == .beta(useFoundationModels ? .foundationModels : .onDevice))
            #expect(outcome.providerRan)
            #expect(!outcome.changed)
            #expect(outcome.result.segments[0].text == sourceText)
        }
    }
}
