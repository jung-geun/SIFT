import Foundation

struct EmailIngestionEngine {
    func makeManualTodo(
        from message: GmailMessage,
        allowFoundationModels: Bool = true,
        language: AppLanguage = .current
    ) async -> Todo {
        let analyzer = EmailContentAnalyzer()
        var draft: EmailTodoDraft?

        if allowFoundationModels {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *), FoundationModelsAvailability.isAvailable {
                do {
                    draft = try await FoundationModelsService().draftTodoFromEmail(
                        message,
                        now: Date(),
                        language: language
                    )
                } catch {
                    print("[EmailService] draftTodoFromEmail failed: \(error.localizedDescription)")
                }
            }
            #endif
        }

        let finalDraft = draft ?? makeFallbackManualDraft(
            from: message,
            analyzer: analyzer,
            language: language
        )

        let todo = Todo(
            title: finalDraft.title,
            notes: finalDraft.notes,
            dueDate: finalDraft.dueDate,
            source: .email,
            sourceRef: message.id
        )
        todo.sourceSender = finalDraft.sender.isEmpty ? analyzer.parseSender(from: message.from) : finalDraft.sender
        todo.sourceSenderEmail = finalDraft.senderEmail.isEmpty ? analyzer.parseSenderEmail(from: message.from) : finalDraft.senderEmail
        todo.sourceMessageID = message.messageID
        todo.sourceThreadID = message.threadID
        todo.sourceAccountNamespace = message.sourceAccountNamespace
        todo.triageStatus = TodoTriage.todo.rawValue
        return todo
    }

    func extractTodos(
        from message: GmailMessage,
        allowFoundationModels: Bool = true,
        language: AppLanguage = .current
    ) async throws -> [Todo] {
        let engine = EmailAnalysisEngineFactory.makeEngine(allowFoundationModels: allowFoundationModels)
        let outcome = try await engine.analyze(
            message,
            now: Date(),
            language: language
        )
        guard let extraction = outcome.value else {
            return []
        }

        let labels = Set(message.labelIds)
        let dropLabels: Set<String> = ["CATEGORY_SOCIAL", "CATEGORY_FORUMS"]
        let reviewLabels: Set<String> = ["CATEGORY_PROMOTIONS"]

        if !labels.isDisjoint(with: dropLabels) {
            return []
        }

        let isPromotion = !labels.isDisjoint(with: reviewLabels) || message.isBulk
        let triage: TodoTriage = (isPromotion || extraction.keywordScore == 0) ? .review : .todo

        let todo = Todo(
            title: message.subject,
            notes: extraction.notes,
            dueDate: extraction.dueDate,
            source: .email,
            sourceRef: message.id
        )
        todo.sourceSender = extraction.sender
        todo.sourceSenderEmail = extraction.senderEmail
        todo.sourceMessageID = message.messageID
        todo.sourceThreadID = message.threadID
        todo.sourceAccountNamespace = message.sourceAccountNamespace
        todo.triageStatus = triage.rawValue
        return [todo]
    }

    func extractCalendarEvents(from messages: [GmailMessage]) async throws -> [(event: ExtractedEmailEvent, sourceRef: String)] {
        let analyzer = EmailContentAnalyzer()
        let iso = ISO8601DateFormatter()
        var results: [(ExtractedEmailEvent, String)] = []
        for msg in messages {
            guard let extraction = analyzer.analyze(
                msg,
                now: Date(),
                language: .current
            ) else { continue }
            let notesText = extraction.sender.isEmpty
                ? msg.snippet
                : "[\(extraction.sender)] \(msg.snippet)"
            let event = ExtractedEmailEvent(
                title: msg.subject,
                startISO: iso.string(from: extraction.dueDate),
                endISO: "",
                location: "",
                notes: notesText,
                isAllDay: extraction.isAllDay
            )
            results.append((event, msg.id))
        }
        return results
    }

    private func makeFallbackManualDraft(
        from message: GmailMessage,
        analyzer: EmailContentAnalyzer,
        language: AppLanguage
    ) -> EmailTodoDraft {
        let sender = analyzer.parseSender(from: message.from)
        let snippet = collapsedWhitespace(message.snippet)
        let body = collapsedWhitespace(message.body)
        let summaryText = !snippet.isEmpty ? snippet : String(body.prefix(500))
        let summary = summaryText.isEmpty
            ? AppLanguage.localized(
                "mail.noBodySummary",
                defaultValue: language == .english ? "No body to summarize" : "요약할 본문 없음",
                language: language,
                comment: "Email fallback summary"
            )
            : summaryText
        let title = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSender = sender.isEmpty
            ? message.from
            : sender
        let senderFormat = AppLanguage.localized(
            "mail.sender",
            defaultValue: language == .english ? "[Sender] %@" : "[발신자] %@",
            language: language,
            comment: "Email sender label"
        )

        return EmailTodoDraft(
            title: title.isEmpty
                ? AppLanguage.localized(
                    "mail.checkEmail",
                    defaultValue: language == .english ? "Check Email" : "메일 확인",
                    language: language,
                    comment: "Email fallback Todo title"
                )
                : title,
            notes: [
                AppLanguage.localized(
                    "mail.summaryHeader",
                    defaultValue: language == .english ? "[Email Summary]" : "[메일 요약]",
                    language: language,
                    comment: "Email summary header"
                ),
                summary,
                "",
                String(
                    format: senderFormat,
                    locale: language.locale,
                    resolvedSender
                )
            ].joined(separator: "\n"),
            dueDate: nil,
            isAllDay: false,
            sender: resolvedSender,
            senderEmail: analyzer.parseSenderEmail(from: message.from)
        )
    }

    private func collapsedWhitespace(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
