import Foundation

struct EmailIngestionEngine {
    func makeManualTodo(from message: GmailMessage, allowFoundationModels: Bool = true) async -> Todo {
        let analyzer = EmailContentAnalyzer()
        var draft: EmailTodoDraft?

        if allowFoundationModels {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *), FoundationModelsService.isAvailable {
                do {
                    draft = try await FoundationModelsService().draftTodoFromEmail(message, now: Date())
                } catch {
                    print("[EmailService] draftTodoFromEmail failed: \(error.localizedDescription)")
                }
            }
            #endif
        }

        let finalDraft = draft ?? makeFallbackManualDraft(from: message, analyzer: analyzer)

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
        todo.triageStatus = TodoTriage.todo.rawValue
        return todo
    }

    func extractTodos(from message: GmailMessage, allowFoundationModels: Bool = true) async throws -> [Todo] {
        let engine = EmailAnalysisEngineFactory.makeEngine(allowFoundationModels: allowFoundationModels)
        guard let extraction = await engine.analyze(message, now: Date()) else {
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
        todo.triageStatus = triage.rawValue
        return [todo]
    }

    func extractCalendarEvents(from messages: [GmailMessage]) async throws -> [(event: ExtractedEmailEvent, sourceRef: String)] {
        let analyzer = EmailContentAnalyzer()
        let iso = ISO8601DateFormatter()
        var results: [(ExtractedEmailEvent, String)] = []
        for msg in messages {
            guard let extraction = analyzer.analyze(msg, now: Date()) else { continue }
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

    private func makeFallbackManualDraft(from message: GmailMessage, analyzer: EmailContentAnalyzer) -> EmailTodoDraft {
        let sender = analyzer.parseSender(from: message.from)
        let snippet = collapsedWhitespace(message.snippet)
        let body = collapsedWhitespace(message.body)
        let summaryText = !snippet.isEmpty ? snippet : String(body.prefix(500))
        let summary = summaryText.isEmpty ? "요약할 본문 없음" : summaryText
        let title = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)

        return EmailTodoDraft(
            title: title.isEmpty ? "메일 확인" : title,
            notes: "[메일 요약]\n\(summary)\n\n[발신자] \(sender.isEmpty ? message.from : sender)",
            dueDate: nil,
            isAllDay: false,
            sender: sender.isEmpty ? message.from : sender,
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
