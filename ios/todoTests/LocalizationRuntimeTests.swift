import Foundation
import Testing
@testable import todo

struct LocalizationRuntimeTests {
    @Test("App language resolution keeps supported tags stable")
    func resolvesLanguageTags() {
        #expect(AppLanguage.resolve(languageTag: "en-US") == .english)
        #expect(AppLanguage.resolve(languageTag: "en_GB") == .english)
        #expect(AppLanguage.resolve(languageTag: "ko-KR") == .korean)
        #expect(AppLanguage.resolve(preferredLocalizations: []) == .korean)
        #expect(AppLanguage.resolve(preferredLocalizations: ["fr-FR"]) == .korean)
    }

    @Test("User locale override wins over system preference and unsupported values fall back")
    func userLocaleOverrideAndFallback() {
        #expect(
            AppLanguage.resolve(preferredLocalizations: ["ko-KR"], userOverride: "en-US")
                == .english
        )
        #expect(
            AppLanguage.resolve(preferredLocalizations: ["fr-FR"], userOverride: "en-US")
                == .english
        )
        #expect(
            AppLanguage.resolve(preferredLocalizations: ["fr-FR"], userOverride: "fr-FR")
                == .korean
        )
        #expect(AppLanguage.supported.contains(.english))
        #expect(AppLanguage.supported.contains(.korean))
    }

    @Test("Selected language supplies the matching formatting locale")
    func selectedLanguageLocale() {
        #expect(AppLanguage.english.locale.language.languageCode?.identifier == "en")
        #expect(AppLanguage.korean.locale.language.languageCode?.identifier == "ko")
        #expect(AppLanguage.english.outputLanguageName == "English")
    }

    @Test("Missing localized resources use the supplied fallback")
    func missingResourceFallback() {
        #expect(
            AppLanguage.localized(
                "localization.runtime.missing.sentinel",
                defaultValue: "Sentinel fallback",
                language: .english
            ) == "Sentinel fallback"
        )
    }

    @Test("Explicit locale controls deadline and reminder copy")
    func explicitLanguageFormatting() {
        let now = Date(timeIntervalSince1970: 1_783_680_000)
        let due = now.addingTimeInterval(2 * 3_600)
        #expect(AppDateFormat.remainingTimeDescription(for: due, now: now, language: .english) == "Due in 2 hours")
        #expect(AppDateFormat.remainingTimeDescription(for: now.addingTimeInterval(3_600), now: now, language: .english) == "Due in 1 hour")
        #expect(AppDateFormat.remainingTimeDescription(for: now.addingTimeInterval(2 * 60), now: now, language: .english) == "Due in 2 minutes")
        #expect(AppDateFormat.remainingTimeDescription(for: now.addingTimeInterval(60), now: now, language: .english) == "Due in 1 minute")
        #expect(AppDateFormat.remainingTimeDescription(for: now.addingTimeInterval(2 * 86_400), now: now, language: .english) == "Due in 2 days")
        #expect(AppDateFormat.remainingTimeDescription(for: now.addingTimeInterval(86_400), now: now, language: .english) == "Due in 1 day")
        #expect(AppDateFormat.remainingTimeDescription(for: due, now: now, language: .korean) == "2시간 후 마감")
        #expect(ReminderTiming.durationText(for: -2 * 3_600, language: .english) == "2 hours")
        #expect(ReminderTiming.detailLabel(for: -2 * 3_600, language: .english).contains("2 hours"))
    }

    @Test("Localized display names preserve persisted raw values")
    func stableRawValuesAndDisplayNames() {
        #expect(TodoPriority.critical.rawValue == 5)
        #expect(TodoPriority.critical.displayName(language: .english) == "Critical")
        #expect(PersonaType.officeWorker.rawValue == "officeWorker")
        #expect(PersonaType.officeWorker.displayName(language: .english) == "Office Worker")
        #expect(PersonaType.officeWorker.weightedKeywords.contains("회의"))
        #expect(PersonaType.officeWorker.weightedKeywords.contains("meeting"))
        #expect(BehaviorConfidence.high.label(language: .english) == "High confidence")
    }

    @Test("Localized app-owned errors use the selected language")
    func localizedErrors() {
        #expect(CalendarError.notAuthorized.errorDescription(language: .english) == "Calendar access is not authorized. Allow access in Settings > Privacy & Security.")
        #expect(CalendarError.notAuthorized.errorDescription(language: .korean) == "캘린더 접근 권한이 없습니다. 설정 > 개인정보 보호에서 허용해주세요.")
        #expect(EmailError.apiFailed.errorDescription(language: .english) == "The Gmail API request failed.")
        #expect(EmailError.apiFailed.errorDescription(language: .korean) == "Gmail API 호출에 실패했습니다.")
        #expect(IntelligenceRoutingError.backendUnavailable(provider: .foundationModels, reason: "ignored").errorDescription(language: .english) == "Apple Foundation Models (AFM) is unavailable on this device.")
        #expect(IntelligenceRoutingError.backendUnavailable(provider: .foundationModels, reason: "ignored").errorDescription(language: .korean) == "Apple Foundation Models (AFM)을 이 기기에서 사용할 수 없습니다.")
        #expect(PriorityEngine.heuristic.rawValue == "휴리스틱")
        #expect(PriorityEngine.heuristic.displayName(language: .english) == "Heuristic")
    }

    @Test("Review fixes keep engine IDs stable and user errors generic")
    @MainActor
    func reviewFixContracts() {
        #expect(PriorityEngine(rawValue: "휴리스틱")?.displayName(language: .english) == "Heuristic")
        #expect(MeetingRefinementEngine.Source.appleIntelligence.rawValue == "apple-intelligence")
        #expect(MeetingRefinementEngine.Source.qwen.displayName(language: .english) == "On-Device LLM (Qwen)")
        let diagnostic = NSError(domain: "AVFAudio", code: 42, userInfo: [NSLocalizedDescriptionKey: "device detail"])
        let message = MeetingAudioPlaybackController.userFacingErrorMessage(
            MeetingAudioPlaybackController.PlaybackError.operation("decode", diagnostic),
            language: .english
        )
        #expect(message == "The meeting recording could not be played.")
        #expect(!message.contains("AVFAudio"))
        #expect(!message.contains("42"))
        let controller = MeetingAudioPlaybackController()
        controller.report(diagnostic)
        #expect(
            controller.errorMessage
                == MeetingAudioPlaybackController.userFacingErrorMessage(diagnostic, language: .current)
        )
    }


    @Test("Explicit locale lookup is independent of ambient app language")
    func explicitResourceLookup() {
        let english = AppLanguage.localized(
            "calendar.todoDeadline",
            defaultValue: "To-Do Deadline",
            language: .english,
            comment: "Calendar fallback title"
        )
        let korean = AppLanguage.localized(
            "calendar.todoDeadline",
            defaultValue: "할 일 마감",
            language: .korean,
            comment: "Calendar fallback title"
        )
        #expect(AppLanguage.localized("calendar.permissionUnavailable", defaultValue: "Calendar Access Unavailable", language: .english) == "Calendar Access Unavailable")
        #expect(AppLanguage.localized("calendar.permissionUnavailable", defaultValue: "캘린더 접근 권한 없음", language: .korean) == "캘린더 접근 권한 없음")
        #expect(english == "To-Do Deadline")
        #expect(korean == "할 일 마감")
    }
    @Test("Reminder plural values and presets use localized units")
    func reminderPluralAndPresets() {
        #expect(ReminderTiming.durationText(for: -60, language: .english) == "1 minute")
        #expect(ReminderTiming.durationText(for: -120, language: .english) == "2 minutes")
        #expect(ReminderTiming.durationText(for: -3_600, language: .english) == "1 hour")
        #expect(ReminderTiming.durationText(for: -7_200, language: .english) == "2 hours")
        #expect(NotificationService.presetOffsets(language: .english).map(\.label).contains("1 hour before due"))
        #expect(NotificationService.presetOffsets(language: .korean).map(\.label).contains("마감 1시간 전"))
    }

    @Test("English email fallback preserves source content")
    func emailFallback() async {
        let message = GmailMessage(
            id: "localization-message",
            threadID: "localization-thread",
            messageID: "<localization@example.com>",
            subject: "",
            from: "Sender <sender@example.com>",
            snippet: "",
            body: "",
            htmlBody: nil,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            labelIds: [],
            isBulk: false
        )
        let todo = await EmailIngestionEngine().makeManualTodo(
            from: message,
            allowFoundationModels: false,
            language: .english
        )
        #expect(todo.title == "Check Email")
        #expect(todo.notes.contains("[Email Summary]"))
        #expect(todo.notes.contains("[Sender]"))
        #expect(todo.sourceSenderEmail == "sender@example.com")
    }

    @Test("English and Korean display models retain semantic data")
    @MainActor
    func modelDisplayAndDateCopy() {
        let date = Date(timeIntervalSince1970: 1_783_680_000)
        let englishDate = AppDateFormat.deadlineString(from: date, isAllDay: false, language: .english)
        let koreanDate = AppDateFormat.deadlineString(from: date, isAllDay: false, language: .korean)
        #expect(!englishDate.contains("년"))
        #expect(koreanDate.contains("년") || koreanDate.contains("월"))
        #expect(PersonaType.officeWorker.weightedKeywords.contains("meeting"))
        #expect(PersonaType.officeWorker.weightedKeywords.contains("회의"))
        #expect(BehaviorConfidence.high.label(language: .english) == "High confidence")
    }
    @Test("Heuristic priority reasons follow explicit language")
    @MainActor
    func heuristicPriorityReasonLanguage() {
        let todo = Todo(title: "Read book")
        let persona = PersonaContext(types: [.officeWorker], description: "")
        let engine = HeuristicEngine()
        #expect(engine.heuristicReason(todo: todo, persona: persona, language: .english) == "No deadline — low default priority")
        #expect(engine.heuristicReason(todo: todo, persona: persona, language: .korean) == "마감 없음 — 낮은 기본 우선순위")
    }

    @Test("Email fetch status uses localized plural resources")
    func emailFetchStatusPlural() {
        let one = EmailDetailView.fetchStatusMessage(
            todoCount: 1,
            eventCount: 0,
            failures: [],
            language: .english
        )
        let many = EmailDetailView.fetchStatusMessage(
            todoCount: 2,
            eventCount: 0,
            failures: [],
            language: .english
        )
        let oneEvent = EmailDetailView.fetchStatusMessage(
            todoCount: 0,
            eventCount: 1,
            failures: [],
            language: .english
        )
        let korean = EmailDetailView.fetchStatusMessage(
            todoCount: 2,
            eventCount: 1,
            failures: [],
            language: .korean
        )
        #expect(one == "1 To-Do extracted")
        #expect(!one.contains("To-Dos"))
        #expect(oneEvent == "1 Calendar Event extracted")
        #expect(many == "2 To-Dos extracted")
        #expect(korean == "할 일 2개, 일정 1개 추출됨")
    }
    @Test("Mail and meeting correction counts preserve singular and plural")
    func mailAndMeetingPluralResources() {
        #expect(MailTabView.pendingTrashMessage(count: 1, language: .english) == "1 message will move to Trash")
        #expect(MailTabView.pendingTrashMessage(count: 2, language: .english) == "2 messages will move to Trash")
        #expect(MeetingDetailView.proofreadChangedText(corrections: 1, engineLabel: "Apple Intelligence (On Device)", language: .english) == "Proofreading complete · 1 correction · Apple Intelligence (On Device)")
        #expect(MeetingDetailView.proofreadChangedText(corrections: 2, engineLabel: "Apple Intelligence (On Device)", language: .english) == "Proofreading complete · 2 corrections · Apple Intelligence (On Device)")
    }

    @Test("Imported item count uses exact singular and plural forms")
    func importedItemPlural() {
        #expect(
            AppLanguage.localizedCount(
                "todo.icloud.importedCount",
                count: 1,
                defaultValue: "%lld item imported",
                language: .english
            ) == "1 item imported"
        )
        #expect(
            AppLanguage.localizedCount(
                "todo.icloud.importedCount",
                count: 2,
                defaultValue: "%lld items imported",
                language: .english
            ) == "2 items imported"
        )
    }
    @Test("English prioritization UI uses semantic catalog resources")
    func englishPrioritizationCopy() {
        #expect(
            AppLanguage.localized(
                "action.prioritize",
                defaultValue: "AI 정리",
                language: .english,
                comment: "Prioritize with AI action."
            ) == "Prioritize with AI"
        )
        #expect(
            AppLanguage.localized(
                "todo.ai.initial",
                defaultValue: "AI 우선순위 정리 중…",
                language: .english,
                comment: "Initial AI prioritization progress."
            ) == "Prioritization in progress…"
        )
        #expect(
            AppLanguage.localized(
                "todo.priority.backgroundWarning",
                defaultValue: "앱을 나가거나 화면을 끄면 분석이 중단됩니다",
                language: .english,
                comment: "Background analysis warning."
            ) == "Analysis stops if you leave the app or turn off the screen."
        )
    }
    @Test("Capture status follows app language independently of meeting language")
    func captureStatusResourcesSupportOppositeLanguage() {
        let english = AppLanguage.localized(
            "meeting.capture.finalization.transcript",
            defaultValue: "전사 결과를 확정하는 중",
            language: .english,
            comment: "Meeting transcript finalization status."
        )
        let korean = AppLanguage.localized(
            "meeting.capture.finalization.transcript",
            defaultValue: "전사 결과를 확정하는 중",
            language: .korean,
            comment: "Meeting transcript finalization status."
        )
        let englishWarning = AppLanguage.localized(
            "meeting.capture.transcription.warning",
            defaultValue: "실시간 전사가 중단됐습니다.",
            language: .english,
            comment: "Live transcription warning."
        )
        let koreanWarning = AppLanguage.localized(
            "meeting.capture.transcription.warning",
            defaultValue: "실시간 전사가 중단됐습니다.",
            language: .korean,
            comment: "Live transcription warning."
        )
        #expect(english == "Finalizing the transcript")
        #expect(korean == "전사 결과를 확정하는 중")
        #expect(englishWarning.hasPrefix("Live transcription stopped."))
        #expect(koreanWarning.hasPrefix("실시간 전사가 중단됐습니다."))
    }
}
