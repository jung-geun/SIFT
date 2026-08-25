import Foundation
import Testing
@testable import todo

@Suite("Meeting analysis routing reasons")
@MainActor
struct MeetingAnalysisRoutingTests {
    private let keys = [
        SettingsStore.betaFoundationModelsEnabledKey,
        SettingsStore.betaOnDeviceModelEnabledKey,
        SettingsStore.betaGeminiEnabledKey,
        SettingsStore.betaSelectedProviderKey
    ]

    private func reset() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        GeminiProviderService.deleteAPIKey()
    }

    private func result() -> MeetingResult {
        MeetingResult(segments: [MeetingSegment(id: "s1", startMs: 0, endMs: 1_000, text: "원문")])
    }

    @Test("off providers preserve no-provider reason")
    func noProviderReason() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            let outcome = try await MeetingAnalysisEngine().analyze(
                meetingID: "123e4567-e89b-12d3-a456-426614174000",
                result: result(),
                language: .korean
            )
            #expect(outcome.executionPath == .rules(.noProviderOptIn))
        }
    }

    @Test("Gemini without credentials preserves credential reason")
    func missingGeminiCredentialReason() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            SettingsStore.shared.setBetaProvider(.gemini, enabled: true)
            let outcome = try await MeetingAnalysisEngine().analyze(
                meetingID: "123e4567-e89b-12d3-a456-426614174000",
                result: result(),
                language: .korean
            )
            #expect(outcome.executionPath == .rules(.credentialMissing))
        }
    }
}
