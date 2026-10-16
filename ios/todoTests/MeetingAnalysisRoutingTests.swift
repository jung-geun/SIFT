import Foundation
import Testing
@testable import todo

@Suite("Meeting analysis routing reasons")
@MainActor
struct MeetingAnalysisRoutingTests {
    private let keys = [
        SettingsStore.betaFoundationModelsEnabledKey,
        SettingsStore.betaOnDeviceModelEnabledKey,
        SettingsStore.betaOpenAIEnabledKey,
        SettingsStore.betaSelectedProviderKey
    ]

    private func reset() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
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

    @Test("off providers preserve no-provider reason")
    func noProviderReason() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            disableAllProviders()
            let outcome = try await MeetingAnalysisEngine().analyze(
                meetingID: "123e4567-e89b-12d3-a456-426614174000",
                result: result(),
                language: .korean
            )
            #expect(outcome.executionPath == .rules(.noProviderOptIn))
        }
    }

    @Test("remote priority selection keeps meeting analysis local")
    func remoteSelectionUsesLocalMeetingRules() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            disableAllProviders()
            SettingsStore.shared.setBetaProvider(.openAI, enabled: true)
            let outcome = try await MeetingAnalysisEngine().analyze(
                meetingID: "123e4567-e89b-12d3-a456-426614174000",
                result: result(),
                language: .korean
            )
            #expect(outcome.executionPath == .rules(.providerNotApplicable))
            #expect(outcome.engineSource == .heuristic)
            #expect(outcome.result.segments == result().segments)
        }
    }
}
