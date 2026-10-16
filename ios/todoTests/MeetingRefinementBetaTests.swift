import Foundation
import Testing
@testable import todo

@Suite("Meeting refinement beta routing")
@MainActor
struct MeetingRefinementBetaTests {
    private let betaKeys = [
        SettingsStore.betaFoundationModelsEnabledKey,
        SettingsStore.betaOnDeviceModelEnabledKey,
        SettingsStore.betaOpenAIEnabledKey,
        SettingsStore.betaSelectedProviderKey
    ]

    private func resetBeta() {
        betaKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    private func disableAllProviders() {
        UserDefaults.standard.set(false, forKey: SettingsStore.betaFoundationModelsEnabledKey)
        UserDefaults.standard.set(false, forKey: SettingsStore.betaOnDeviceModelEnabledKey)
        UserDefaults.standard.set(false, forKey: SettingsStore.betaOpenAIEnabledKey)
        UserDefaults.standard.removeObject(forKey: SettingsStore.betaSelectedProviderKey)
    }

    private func result() -> MeetingResult {
        MeetingResult(segments: [MeetingSegment(id: "s1", startMs: 0, endMs: 1_000, text: "원문")])
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
        let action: @Sendable ([MeetingSegment]) async throws -> TranscriptCorrectionBatchResult

        func correct(
            segments: [MeetingSegment],
            glossaryHint _: String,
            language _: AppLanguage
        ) async throws -> TranscriptCorrectionBatchResult {
            try await action(segments)
        }
    }

    @Test("off/off and OpenAI-only keep the transcript unchanged with policy reason")
    func noLocalProviderUsesPolicyReason() async throws {
        await AIProviderTestIsolation.shared.withLock {
            resetBeta()
            defer { resetBeta() }
            disableAllProviders()
            let engine = MeetingRefinementEngine()
            let off = try? await engine.refine(
                meetingID: "123e4567-e89b-12d3-a456-426614174000",
                result: result(),
                vocabulary: .empty,
                language: .korean,
                allowModelLoad: false
            )
            #expect(off?.executionPath == .rules(.noEligibleProvider))

            SettingsStore.shared.setBetaProvider(.openAI, enabled: true)
            let openAIOnly = try? await engine.refine(
                meetingID: "123e4567-e89b-12d3-a456-426614174000",
                result: result(),
                vocabulary: .empty,
                language: .korean,
                allowModelLoad: false
            )
            #expect(openAIOnly?.executionPath == .rules(.noEligibleProvider))
        }
    }

    @Test("AFM failure proceeds to enabled on-device provider")
    func localProviderRunsAfterAFMFailure() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            resetBeta()
            defer { resetBeta() }
            SettingsStore.shared.setBetaProvider(.foundationModels, enabled: true)
            SettingsStore.shared.setBetaProvider(.onDevice, enabled: true)
            let calls = ProviderCallRecorder()
            let afm = FakeProvider { _ in
                await calls.append("afm")
                throw IntelligenceRoutingError.backendUnavailable(provider: .foundationModels, reason: "offline")
            }
            let local = FakeProvider { segments in
                await calls.append("onDevice")
                let corrected = await MainActor.run {
                    var corrected = segments
                    corrected[0].text = "교정문"
                    return corrected
                }
                return TranscriptCorrectionBatchResult(
                    segments: corrected,
                    attemptedBatchCount: 1,
                    succeededBatchCount: 1,
                    failedBatchCount: 0
                )
            }
            let outcome = try await MeetingRefinementEngine(afmProvider: afm, onDeviceProvider: local).refine(
                meetingID: "123e4567-e89b-12d3-a456-426614174000",
                result: result(),
                vocabulary: .empty,
                language: .korean,
                allowModelLoad: false
            )
            #expect(await calls.snapshot == ["afm", "onDevice"])
            #expect(outcome.executionPath == .beta(.onDevice))
            #expect(outcome.result.segments[0].text == "교정문")
        }
    }

    @Test("AFM cancellation propagates and does not invoke on-device provider")
    func cancellationStopsProviderChain() async throws {
        await AIProviderTestIsolation.shared.withLock {
            resetBeta()
            defer { resetBeta() }
            SettingsStore.shared.setBetaProvider(.foundationModels, enabled: true)
            SettingsStore.shared.setBetaProvider(.onDevice, enabled: true)
            let localCalls = ProviderCallRecorder()
            let afm = FakeProvider { _ in throw CancellationError() }
            let local = FakeProvider { segments in
                await localCalls.append("onDevice")
                return TranscriptCorrectionBatchResult(
                    segments: segments,
                    attemptedBatchCount: 1,
                    succeededBatchCount: 1,
                    failedBatchCount: 0
                )
            }
            await #expect(throws: CancellationError.self) {
                _ = try await MeetingRefinementEngine(afmProvider: afm, onDeviceProvider: local).refine(
                    meetingID: "123e4567-e89b-12d3-a456-426614174000",
                    result: result(),
                    vocabulary: .empty,
                    language: .korean,
                    allowModelLoad: false
                )
            }
            #expect(await localCalls.snapshot.isEmpty)
        }
    }
}
