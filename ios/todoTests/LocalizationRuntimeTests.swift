import Foundation
import Testing
@testable import todo

@MainActor
@Suite(.serialized)
struct LocalizationRuntimeTests {
    private static let identifiers = ["ko", "en", "es", "ja", "zh-Hans", "fr", "it", "de"]

    @Test("Every shipped locale is selectable exactly once and retains its canonical identifier")
    func supportedSelections() {
        #expect(AppLanguage.supportedIdentifiers == Self.identifiers)
        #expect(Set(AppLanguage.supported.map(\.rawValue)) == Set(Self.identifiers))
        #expect(AppLanguage.supported.count == Self.identifiers.count)
        for identifier in Self.identifiers {
            #expect(AppLanguage.resolve(languageTag: identifier).rawValue == identifier)
        }
    }

    @Test("Regional aliases, casing, underscores and Chinese script selection are canonicalized")
    func regionalAndScriptAliases() {
        let aliases = [
            "ko-KR": "ko", "en_GB": "en", "es-MX": "es", "es-419": "es",
            "ja-JP": "ja", "zh": "zh-Hans", "zh_CN": "zh-Hans", "zh-SG": "zh-Hans",
            "zh-Hans-CN": "zh-Hans", "zh-Hans-TW": "zh-Hans", " ZH_hAnS ": "zh-Hans",
            "zh-CN-u-nu-latn": "zh-Hans", "fr-CA": "fr", "it-CH": "it", "de-AT": "de"
        ]
        for (alias, expected) in aliases {
            #expect(AppLanguage.supportedLanguage(for: alias)?.rawValue == expected)
        }
        for unsupported in ["", "  ", "pt-BR", "ar", "zh-Hant", "zh-Hant-CN", "zh-TW", "zh-HK", "zh-MO"] {
            #expect(AppLanguage.supportedLanguage(for: unsupported) == nil)
        }
        #expect(AppLanguage.resolve(preferredLocalizations: ["zh-Hant-TW", "fr-CA", "en-US"]) == .french)
        #expect(AppLanguage.resolve(preferredLocalizations: []) == .korean)
        #expect(AppLanguage.resolve(preferredLocalizations: ["pt-BR"]) == .korean)
    }

    @Test("Supported overrides win; unsupported overrides defer to the system preference list")
    func overrideResolution() {
        #expect(AppLanguage.resolve(preferredLocalizations: ["ko-KR"], userOverride: "es-MX") == .spanish)
        #expect(AppLanguage.resolve(preferredLocalizations: ["fr-FR"], userOverride: "zh-Hant") == .french)
        #expect(AppLanguage.resolve(preferredLocalizations: ["pt-BR", "de-CH"], userOverride: "invalid") == .german)
    }

    @Test("Every selection persists canonically and reset restores system mode")
    func persistedLanguageOverride() {
        preservingOverride {
            for identifier in Self.identifiers {
                let language = AppLanguage(rawValue: identifier)
                AppLanguage.setUserOverride(language)
                #expect(AppLanguage.userOverride == language)
                #expect(AppLanguage.current == language)
                #expect(UserDefaults.standard.string(forKey: AppLanguage.userOverrideKey) == identifier)
            }
            UserDefaults.standard.set("fr-CA", forKey: AppLanguage.userOverrideKey)
            #expect(AppLanguage.userOverride == .french)
            AppLanguage.setUserOverride(AppLanguage(rawValue: "es-MX"))
            #expect(UserDefaults.standard.string(forKey: AppLanguage.userOverrideKey) == "es")
            AppLanguage.setUserOverride(nil)
            #expect(AppLanguage.userOverride == nil)
            #expect(UserDefaults.standard.object(forKey: AppLanguage.userOverrideKey) == nil)
        }
    }

    @Test("Native picker labels, speech tags and English machine language names are distinct contracts")
    func languageMetadata() {
        let metadata: [(AppLanguage, String, String, String)] = [
            (.korean, "한국어", "ko-KR", "Korean"),
            (.english, "English", "en-US", "English"),
            (.spanish, "Español", "es-ES", "Spanish"),
            (.japanese, "日本語", "ja-JP", "Japanese"),
            (.simplifiedChinese, "简体中文", "zh-CN", "Simplified Chinese"),
            (.french, "Français", "fr-FR", "French"),
            (.italian, "Italiano", "it-IT", "Italian"),
            (.german, "Deutsch", "de-DE", "German")
        ]
        for (language, nativeName, speechTag, outputName) in metadata {
            #expect(language.displayName == nativeName)
            #expect(language.speechLanguageTag == speechTag)
            #expect(language.outputLanguageName == outputName)
            #expect(AppLanguage.resolve(languageTag: speechTag) == language)
            #expect(language.locale.language.languageCode == Locale(identifier: language.rawValue).language.languageCode)
        }
        #expect(AppLanguage.simplifiedChinese.locale.language.script?.identifier == "Hans")
    }

    @Test("Missing resources honor fallback while a translation identical to its key is not missing")
    func resourceFallbackBoundaries() {
        for identifier in Self.identifiers {
            let language = AppLanguage(rawValue: identifier)
            #expect(AppLanguage.localized("localization.runtime.missing.sentinel", defaultValue: "sentinel", language: language) == "sentinel")
        }
        // This source-key equality is a lookup regression, not a wording snapshot.
        let sourceKey = "녹음 시작"
        #expect(AppLanguage.localized(sourceKey, defaultValue: "missing", language: .korean) == sourceKey)
        #expect(AppLanguage.localized(sourceKey, defaultValue: "missing", language: .english) != sourceKey)
    }

    @Test("Each shipped locale has its own compiled resources rather than relying on fallback")
    func compiledLocaleResources() throws {
        let hostBundle = Bundle(for: MeetingAudioPlaybackController.self)
        for identifier in Self.identifiers {
            let path = try #require(hostBundle.path(forResource: identifier, ofType: "lproj"))
            let resources = try #require(Bundle(path: path))
            let language = AppLanguage(rawValue: identifier)
            for key in ["calendar.todoDeadline", "todo.priority.critical", "mail.summaryHeader", "date.deadline.overdue"] {
                let selected = resources.localizedString(forKey: key, value: "missing", table: "Localizable")
                #expect(selected != "missing")
                #expect(selected != key)
                #expect(AppLanguage.localized(key, defaultValue: "missing", language: language) == selected)
            }
        }
    }

    @Test("Explicit catalog lookups ignore an opposing ambient app language")
    func explicitResourceLookup() {
        preservingOverride {
            for identifier in Self.identifiers {
                let language = AppLanguage(rawValue: identifier)
                AppLanguage.setUserOverride(language == .korean ? .english : .korean)
                let actual = AppLanguage.localized("calendar.todoDeadline", defaultValue: "missing", language: language)
                #expect(actual != "missing")
                #expect(actual != "calendar.todoDeadline")
                if language != .korean {
                    #expect(actual != AppLanguage.localized("calendar.todoDeadline", defaultValue: "missing", language: .korean))
                }
            }
        }
    }

    @Test("Deadline formatting uses the selected Foundation locale without changing the date")
    func deadlineFormatting() {
        let date = Date(timeIntervalSince1970: 1_783_680_000)
        for identifier in Self.identifiers {
            let language = AppLanguage(rawValue: identifier)
            for allDay in [true, false] {
                let expected = DateFormatter()
                expected.locale = language.locale
                expected.dateStyle = .long
                expected.timeStyle = allDay ? .none : .short
                #expect(AppDateFormat.deadlineString(from: date, isAllDay: allDay, language: language) == expected.string(from: date))
            }
        }
        // Machine dates stay language-independent and round-trip the same instant.
        let machineDate = AppDateFormat.llmString(from: date)
        #expect(AppDateFormat.parseLLMDate(machineDate) == date)
    }

    @Test("Deadline unit transitions and zero/minimum count behavior use catalog plural resources")
    func deadlineUnitBoundaries() {
        let now = Date(timeIntervalSince1970: 1_783_680_000)
        let boundaries: [(TimeInterval, String, Int)] = [
            (0, "date.deadline.minutes", 1), (59, "date.deadline.minutes", 1),
            (60, "date.deadline.minutes", 1), (120, "date.deadline.minutes", 2),
            (3_599, "date.deadline.minutes", 59), (3_600, "date.deadline.hours", 1),
            (7_200, "date.deadline.hours", 2), (86_399, "date.deadline.hours", 23),
            (86_400, "date.deadline.days", 1), (172_800, "date.deadline.days", 2)
        ]
        for identifier in Self.identifiers {
            let language = AppLanguage(rawValue: identifier)
            for (offset, key, count) in boundaries {
                let expected = AppLanguage.localizedCount(key, count: count, defaultValue: "missing %lld", language: language)
                #expect(!expected.contains("missing"))
                #expect(!expected.contains("%lld"))
                #expect(AppDateFormat.remainingTimeDescription(for: now.addingTimeInterval(offset), now: now, language: language) == expected)
            }
            #expect(AppDateFormat.remainingTimeDescription(for: now.addingTimeInterval(-1), now: now, language: language)
                == AppLanguage.localized("date.deadline.overdue", defaultValue: "missing", language: language))
        }
    }

    @Test("Reminder locale affects presentation, not offsets or minimum-duration semantics")
    func reminderSemantics() {
        let offsets: [Double] = [-900, -3_600, -21_600, -86_400, -259_200]
        for identifier in Self.identifiers {
            let language = AppLanguage(rawValue: identifier)
            #expect(NotificationService.presetOffsets(language: language).map(\.offset) == offsets)
            #expect(ReminderTiming.durationText(for: -3_600, language: language) == ReminderTiming.durationText(for: 3_600, language: language))
            #expect(ReminderTiming.durationText(for: 0, language: language) == ReminderTiming.durationText(for: -60, language: language))
            let duration = ReminderTiming.durationText(for: -120, language: language)
            #expect(!duration.isEmpty)
            #expect(ReminderTiming.detailLabel(for: -120, language: language).contains(duration))
        }
    }

    @Test("Domain display localization never changes persisted identifiers or source keywords")
    func stableDomainData() {
        #expect(TodoPriority.critical.rawValue == 5)
        #expect(PersonaType.officeWorker.rawValue == "officeWorker")
        #expect(PersonaType.officeWorker.weightedKeywords.contains("회의"))
        #expect(PersonaType.officeWorker.weightedKeywords.contains("meeting"))
        #expect(PriorityEngine.heuristic.rawValue == "휴리스틱")
        #expect(MeetingRefinementEngine.Source.appleIntelligence.rawValue == "apple-intelligence")
        for identifier in Self.identifiers {
            let language = AppLanguage(rawValue: identifier)
            #expect(TodoPriority.critical.displayName(language: language)
                == AppLanguage.localized("todo.priority.critical", defaultValue: "missing", language: language))
            if language != .korean {
                #expect(BehaviorConfidence.high.label(language: language) != BehaviorConfidence.high.label(language: .korean))
                #expect(PersonaType.officeWorker.displayName(language: language) != PersonaType.officeWorker.displayName(language: .korean))
            }
        }
    }

    @Test("Meeting draft localization preserves source transcript and canonical action identity")
    func meetingDraftSourceIdentity() throws {
        let meetingID = "00000000-0000-4000-8000-000000000001"
        let source = MeetingResult(transcriptRevision: 7, segments: [
            MeetingSegment(id: "source_segment", startMs: 0, endMs: 1_000, text: "Please send the original report")
        ])
        let analyzer = MeetingTranscriptAnalysisService()
        let baseline = try #require(analyzer.analyze(meetingID: meetingID, result: source, language: .english).actionDrafts.first)
        for identifier in Self.identifiers {
            let language = AppLanguage(rawValue: identifier)
            let result = analyzer.analyze(meetingID: meetingID, result: source, language: language)
            let draft = try #require(result.actionDrafts.first)
            #expect(result.segments == source.segments)
            #expect(result.transcriptRevision == source.transcriptRevision)
            #expect(draft.id == baseline.id)
            #expect(draft.title == baseline.title)
            #expect(draft.sourceSegmentIDs == ["source_segment"])
            #expect(draft.notes.contains(source.segments[0].text))
            #expect(draft.requiresReview)
        }
        // Unsupported deterministic source grammar is preserved, not guessed or translated.
        let unmatched = MeetingResult(segments: [
            MeetingSegment(id: "french-source", startMs: 0, endMs: 1_000, text: "Veuillez envoyer le rapport")
        ])
        let unchanged = analyzer.analyze(meetingID: meetingID, result: unmatched, language: .french)
        #expect(unchanged.segments == unmatched.segments)
        #expect(unchanged.actionDrafts.isEmpty)
    }

    @Test("Offline transcription accepts shipped language aliases but never silently chooses Korean")
    func offlineTranscriptionLanguageBoundary() throws {
        #expect(try MeetingOfflineTranscriptionService.languageCode(for: nil) == nil)
        let aliases = ["ko-KR": "ko", "en-GB": "en", "es-MX": "es", "ja-JP": "ja",
                       "zh-Hans": "zh", "zh-CN": "zh", "fr-CA": "fr", "it-CH": "it", "de-AT": "de"]
        for (tag, expectedCode) in aliases {
            #expect(try MeetingOfflineTranscriptionService.languageCode(for: tag) == expectedCode)
        }
        for unsupported in ["", "pt-BR", "zh-Hant", "zh-TW"] {
            #expect(throws: MeetingOfflineTranscriptionService.Failure.unsupportedLanguage) {
                try MeetingOfflineTranscriptionService.languageCode(for: unsupported)
            }
        }
    }

    @Test("Selecting an app language cannot bypass speech backend locale and asset capability checks")
    func speechBackendCapabilityBoundary() async {
        for identifier in Self.identifiers {
            let language = AppLanguage(rawValue: identifier)
            for capability in [MeetingTranscriptionCapability.unsupportedLocale, .unsupportedAsset, .unavailable] {
                let factory = DefaultMeetingTranscriptionSessionFactory(
                    foundationModelsAvailable: { true },
                    capabilityProbe: { _, requested in
                        #expect(requested.language.languageCode == language.locale.language.languageCode)
                        return capability
                    },
                    sessionBuilder: { _, _, _, _ in
                        Issue.record("An unsupported speech capability must not build a session")
                        throw MeetingTranscriptionError.runtimeFailed
                    },
                    snapshotProvider: { .empty },
                    forcedBackend: nil)
                do {
                    _ = try await factory.make(languageTag: language.speechLanguageTag, purpose: .live)
                    Issue.record("An unsupported speech capability must be rejected")
                } catch let error as MeetingTranscriptionError {
                    switch capability {
                    case .unsupportedLocale: #expect(error == .unsupportedLocale(language.speechLanguageTag))
                    case .unsupportedAsset: #expect(error == .staticAssetUnavailable(language.speechLanguageTag))
                    default: #expect(error == .backendUnavailable)
                    }
                } catch {
                    Issue.record("Unexpected capability error: \(error)")
                }
            }
        }
    }

    @Test("App-owned errors hide provider diagnostics in every selected locale")
    func errorDiagnosticBoundary() {
        let diagnostic = NSError(domain: "AVFAudio-private-detail", code: 42, userInfo: [NSLocalizedDescriptionKey: "private backend diagnostic"])
        for identifier in Self.identifiers {
            let language = AppLanguage(rawValue: identifier)
            let message = MeetingAudioPlaybackController.userFacingErrorMessage(
                MeetingAudioPlaybackController.PlaybackError.operation("decode", diagnostic), language: language)
            #expect(!message.isEmpty)
            #expect(!message.contains(diagnostic.domain))
            #expect(!message.contains("private backend diagnostic"))
            let routing = IntelligenceRoutingError.backendUnavailable(provider: .foundationModels, reason: "private backend diagnostic")
                .errorDescription(language: language)
            #expect(!routing.contains("private backend diagnostic"))
            if language != .korean {
                #expect(CalendarError.notAuthorized.errorDescription(language: language) != CalendarError.notAuthorized.errorDescription(language: .korean))
                #expect(EmailError.apiFailed.errorDescription(language: language) != EmailError.apiFailed.errorDescription(language: .korean))
            }
        }
    }


    @Test("Manual email fallback retains source text and identity in every output language")
    func emailSourcePreservation() async {
        let message = GmailMessage(
            id: "localization-message", threadID: "localization-thread", messageID: "<localization@example.com>",
            subject: "Original source 제목 — untouched", from: "Source Sender <sender@example.com>",
            snippet: "Original body 本文 — untouched", body: "Body with source facts", htmlBody: nil,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000), labelIds: [], isBulk: false)
        for identifier in Self.identifiers {
            let language = AppLanguage(rawValue: identifier)
            let todo = await EmailIngestionEngine().makeManualTodo(from: message, allowFoundationModels: false, language: language)
            #expect(todo.title == message.subject)
            #expect(todo.notes.contains(message.snippet))
            #expect(todo.sourceRef == message.id)
            #expect(todo.sourceMessageID == message.messageID)
            #expect(todo.sourceThreadID == message.threadID)
            #expect(todo.sourceSenderEmail == "sender@example.com")
            #expect(todo.notes.contains(AppLanguage.localized("mail.summaryHeader", defaultValue: "missing", language: language)))
        }
    }

    private func preservingOverride(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: AppLanguage.userOverrideKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppLanguage.userOverrideKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.userOverrideKey)
            }
            NotificationCenter.default.post(name: AppLanguage.didChangeNotification, object: nil)
        }
        body()
    }
}
