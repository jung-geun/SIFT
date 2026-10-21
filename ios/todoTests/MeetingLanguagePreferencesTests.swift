import Foundation
import Testing
@testable import todo

@Suite("Shared meeting language preferences")
@MainActor
struct MeetingLanguagePreferencesTests {
    // Representative runtime Apple IDs; no Speech authorization or installed assets required.
    private var recording: [MeetingLanguageOption] {
        ["en-US", "en-GB", "ko-KR", "bn-BD", "fil-PH", "zh-Hans-CN", "zh-Hant-TW"]
            .map { MeetingLanguageOption(id: $0) }
    }

    private var whisperImport: [MeetingLanguageOption] {
        MeetingTranscriptionLanguages.whisper
    }

    private func summaryOptions(modelID: String = "mlx-community/Qwen3.5-2B-MLX-4bit") -> [MeetingLanguageOption] {
        MeetingSummaryLanguages.options(provider: .onDevice,
            selectedLocalModelID: modelID, loadedLocalModelID: modelID)
            .map { MeetingLanguageOption(id: $0.id) }
    }

    @Test("Reopening recording and import restores independent source and summary choices")
    func restoresIndependentChoicesAcrossConsumers() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.cleanUp() }
        let preferences = MeetingLanguagePreferences(defaults: fixture.defaults)
        preferences.selectSource("ko-KR")
        preferences.selectSummary("fr-CA")

        let reopened = try fixture.reopen()
        #expect(reopened.sourceSelection(options: recording, preferredLanguages: ["en-US"]) == "ko-KR")
        #expect(reopened.sourceSelection(options: whisperImport, preferredLanguages: ["en-US"]) == "ko")
        #expect(reopened.summarySelection(options: summaryOptions(), preferredLanguages: ["en-US"]) == "fr")
        #expect(reopened.sourceLanguageTag == "ko-KR")
        #expect(reopened.summaryLanguageTag == "fr-CA")

        reopened.selectSummary("zh-Hant-TW")
        let nextMeeting = try fixture.reopen()
        #expect(nextMeeting.sourceSelection(options: recording, preferredLanguages: ["en-US"]) == "ko-KR")
        #expect(nextMeeting.summarySelection(options: summaryOptions(), preferredLanguages: ["en-US"]) == "zh-Hant")
    }

    @Test("Saved regional provider aliases remain usable in both recording and Whisper import")
    func restoresProviderAliases() throws {
        for (saved, decoderCode) in [("fil-PH", "tl"), ("jv-ID", "jw"), ("nb-NO", "no")] {
            let fixture = try DefaultsFixture()
            defer { fixture.cleanUp() }
            let preferences = MeetingLanguagePreferences(defaults: fixture.defaults)
            preferences.selectSource(saved)
            preferences.selectSummary("en-GB")

            let reopened = try fixture.reopen()
            let recordingOptions = ["en-US", saved].map { MeetingLanguageOption(id: $0) }
            #expect(reopened.sourceSelection(options: recordingOptions, preferredLanguages: ["en-US"]) == saved)
            #expect(reopened.sourceSelection(options: whisperImport, preferredLanguages: ["en-US"]) == decoderCode)
            #expect(reopened.summarySelection(options: summaryOptions(), preferredLanguages: ["ko-KR"]) == "en")
            #expect(reopened.sourceLanguageTag == saved)
        }
    }

    @Test("Unselected consumers use injected OS languages, not the app language, without persisting defaults")
    func resolvesSystemDefaultsWithoutWriting() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(["fr"], forKey: "AppleLanguages")
        let before = fixture.domain
        let preferences = MeetingLanguagePreferences(defaults: fixture.defaults)
        #expect(preferences.sourceLanguageTag.isEmpty)
        #expect(preferences.summaryLanguageTag.isEmpty)
        #expect(!preferences.automaticLanguageDetection)
        #expect(fixture.domain == before)

        // Bengali is a content language outside the app's UI-language catalog.
        #expect(preferences.sourceSelection(options: recording, preferredLanguages: ["bn-IN", "en-US"]) == "bn-BD")
        #expect(preferences.sourceSelection(options: whisperImport, preferredLanguages: ["bn-IN", "en-US"]) == "bn")
        #expect(preferences.summarySelection(options: summaryOptions(), preferredLanguages: ["bn-IN", "en-US"]) == "bn")
        for (systemLanguage, expected) in [
            ("en-GB", "en-GB"), ("EN_gb", "en-GB"), ("zh-TW", "zh-Hant-TW")
        ] {
            #expect(preferences.sourceSelection(options: recording, preferredLanguages: [systemLanguage]) == expected)
        }
        #expect(preferences.summarySelection(options: summaryOptions(), preferredLanguages: ["zh-TW"]) == "zh-Hant")
        #expect(preferences.sourceSelection(options: recording, preferredLanguages: ["xx-ZZ"]).isEmpty)
        #expect(preferences.summarySelection(options: summaryOptions(), preferredLanguages: ["xx-ZZ"]).isEmpty)
        #expect(preferences.sourceSelection(options: recording, preferredLanguages: []).isEmpty)
        #expect(preferences.summarySelection(options: summaryOptions(), preferredLanguages: []).isEmpty)
        #expect(fixture.domain == before)

        // A later OS-language change must still take effect; the first fallback was not a user choice.
        let reopened = try fixture.reopen()
        #expect(reopened.sourceSelection(options: recording, preferredLanguages: ["ko-KR"]) == "ko-KR")
        #expect(reopened.summarySelection(options: summaryOptions(), preferredLanguages: ["ko-KR"]) == "ko")
        #expect(fixture.domain == before)
    }

    @Test("Saved exact and compatible script choices outrank OS defaults but never cross scripts")
    func resolvesSavedChoicesBeforeSystemDefaults() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.cleanUp() }
        let preferences = MeetingLanguagePreferences(defaults: fixture.defaults)
        preferences.selectSource("en-GB")
        preferences.selectSummary("zh-Hant-TW")
        let before = fixture.domain
        #expect(preferences.sourceSelection(options: recording, preferredLanguages: ["en-US"]) == "en-GB")
        #expect(preferences.sourceSelection(options: whisperImport, preferredLanguages: ["ko-KR"]) == "en")
        #expect(preferences.summarySelection(options: summaryOptions(), preferredLanguages: ["zh-CN", "en-US"]) == "zh-Hant")
        let simplifiedOnly = [MeetingLanguageOption(id: "zh-Hans")]
        #expect(preferences.summarySelection(options: simplifiedOnly, preferredLanguages: ["zh-TW"]).isEmpty)
        #expect(preferences.summarySelection(options: simplifiedOnly, preferredLanguages: ["zh-CN"]) == "zh-Hans")
        #expect(fixture.domain == before)
    }

    @Test("Empty and narrowed engine catalogs preserve choices through fallback and relaunch")
    func unavailableChoicesReturnAfterExpansion() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.cleanUp() }
        let preferences = MeetingLanguagePreferences(defaults: fixture.defaults)
        preferences.selectSource("bn-BD")
        preferences.selectSummary("fr-CA")
        let before = fixture.domain
        let englishRecording = [MeetingLanguageOption(id: "en-US")]
        let miniCPM = summaryOptions(modelID: "mlx-community/MiniCPM5-1B-4bit")

        for current in [preferences, try fixture.reopen()] {
            #expect(current.sourceSelection(options: [], preferredLanguages: ["en-US"]).isEmpty)
            #expect(current.summarySelection(options: [], preferredLanguages: ["en-US"]).isEmpty)
            #expect(current.sourceSelection(options: englishRecording, preferredLanguages: ["en-US"]) == "en-US")
            #expect(current.summarySelection(options: miniCPM, preferredLanguages: ["en-US"]) == "en")
            #expect(current.sourceLanguageTag == "bn-BD")
            #expect(current.summaryLanguageTag == "fr-CA")
            #expect(fixture.domain == before)
        }

        let expanded = try fixture.reopen()
        #expect(expanded.sourceSelection(options: recording, preferredLanguages: ["en-US"]) == "bn-BD")
        #expect(expanded.sourceSelection(options: whisperImport, preferredLanguages: ["en-US"]) == "bn")
        #expect(expanded.summarySelection(options: summaryOptions(), preferredLanguages: ["en-US"]) == "fr")
        #expect(fixture.domain == before)
    }

    @Test("Explicit user choices replace unavailable saved choices instead of preserving a stale preference")
    func explicitOverrideReplacesUnavailableChoices() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.cleanUp() }
        let preferences = MeetingLanguagePreferences(defaults: fixture.defaults)
        preferences.selectSource("bn-BD")
        preferences.selectSummary("fr-CA")
        #expect(preferences.sourceSelection(options: [MeetingLanguageOption(id: "en-US")], preferredLanguages: ["en-US"]) == "en-US")
        #expect(preferences.summarySelection(options: summaryOptions(modelID: "mlx-community/MiniCPM5-1B-4bit"), preferredLanguages: ["en-US"]) == "en")

        preferences.selectSource("en-US")
        preferences.selectSummary("en")
        let reopened = try fixture.reopen()
        #expect(reopened.sourceLanguageTag == "en-US")
        #expect(reopened.summaryLanguageTag == "en")
        #expect(reopened.sourceSelection(options: recording, preferredLanguages: ["bn-BD"]) == "en-US")
        #expect(reopened.sourceSelection(options: whisperImport, preferredLanguages: ["bn-BD"]) == "en")
        #expect(reopened.summarySelection(options: summaryOptions(), preferredLanguages: ["fr-CA"]) == "en")
    }

    @Test("Automatic mode alone persists without capturing any effective source or summary default")
    func automaticModeDoesNotCaptureFallbacks() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.cleanUp() }
        let preferences = MeetingLanguagePreferences(defaults: fixture.defaults)
        preferences.selectAutomaticDetection(true)
        let automaticOnly = fixture.domain
        #expect(automaticOnly.count == 1)
        #expect(preferences.sourceSelection(options: recording, preferredLanguages: ["ko-KR"]) == "ko-KR")
        #expect(preferences.summarySelection(options: summaryOptions(), preferredLanguages: ["en-US"]) == "en")
        #expect(fixture.domain == automaticOnly)

        let reopened = try fixture.reopen()
        #expect(reopened.automaticLanguageDetection)
        #expect(reopened.sourceLanguageTag.isEmpty)
        #expect(reopened.summaryLanguageTag.isEmpty)
        #expect(reopened.sourceSelection(options: [], preferredLanguages: ["en-US"]).isEmpty)
        #expect(reopened.sourceSelection(options: whisperImport, preferredLanguages: ["bn-BD"]) == "bn")
        #expect(reopened.summarySelection(options: [], preferredLanguages: ["en-US"]).isEmpty)
        #expect(reopened.automaticLanguageDetection)
        #expect(fixture.domain == automaticOnly)

        reopened.selectAutomaticDetection(false)
        let manual = try fixture.reopen()
        #expect(!manual.automaticLanguageDetection)
        #expect(manual.sourceLanguageTag.isEmpty)
        #expect(manual.summaryLanguageTag.isEmpty)
        #expect(manual.sourceSelection(options: recording, preferredLanguages: ["en-GB"]) == "en-GB")
    }

    @Test("Summary changes and catalog fallback preserve automatic mode; manual source selection disables it")
    func automaticModeAndLanguageChoicesStayIndependent() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.cleanUp() }
        let preferences = MeetingLanguagePreferences(defaults: fixture.defaults)
        preferences.selectSource("bn-BD")
        preferences.selectSummary("fr-CA")
        preferences.selectAutomaticDetection(true)
        let before = fixture.domain
        let reopened = try fixture.reopen()
        #expect(reopened.automaticLanguageDetection)
        #expect(reopened.sourceSelection(options: [], preferredLanguages: ["en-US"]).isEmpty)
        #expect(reopened.sourceSelection(options: [MeetingLanguageOption(id: "en-US")], preferredLanguages: ["en-US"]) == "en-US")
        #expect(reopened.summarySelection(options: [], preferredLanguages: ["en-US"]).isEmpty)
        #expect(reopened.automaticLanguageDetection)
        #expect(fixture.domain == before)

        reopened.selectSummary("zh-Hant-TW")
        let changedSummary = try fixture.reopen()
        #expect(changedSummary.automaticLanguageDetection)
        #expect(changedSummary.sourceSelection(options: whisperImport, preferredLanguages: ["en-US"]) == "bn")
        #expect(changedSummary.summarySelection(options: summaryOptions(), preferredLanguages: ["en-US"]) == "zh-Hant")
        changedSummary.selectAutomaticDetection(false)
        #expect(changedSummary.sourceLanguageTag == "bn-BD")
        changedSummary.selectAutomaticDetection(true)
        changedSummary.selectSource("ko-KR")

        let manual = try fixture.reopen()
        #expect(!manual.automaticLanguageDetection)
        #expect(manual.sourceSelection(options: recording, preferredLanguages: ["bn-BD"]) == "ko-KR")
        #expect(manual.sourceSelection(options: whisperImport, preferredLanguages: ["bn-BD"]) == "ko")
        #expect(manual.summarySelection(options: summaryOptions(), preferredLanguages: ["bn-BD"]) == "zh-Hant")
    }

    @MainActor
    private struct DefaultsFixture {
        let suite: String
        let defaults: UserDefaults

        init() throws {
            let suiteName = "MeetingLanguagePreferencesTests.\(UUID().uuidString)"
            suite = suiteName
            defaults = try #require(UserDefaults(suiteName: suiteName))
        }

        var domain: NSDictionary {
            (defaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary
        }

        func reopen() throws -> MeetingLanguagePreferences {
            MeetingLanguagePreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
