import Foundation

struct EmailIngestionEngine {
    typealias SummaryProvider = @MainActor (GmailMessage, Bool, AppLanguage) async throws -> EmailSummaryResult

    private let summaryProvider: SummaryProvider

    init(summaryProvider: @escaping SummaryProvider = { message, allowFoundationModels, language in
        try await EmailMessageAnalysisService.shared.summarizeContent(
            subject: message.subject, sender: message.from, body: message.body,
            allowFoundationModels: allowFoundationModels, language: language
        )
    }) {
        self.summaryProvider = summaryProvider
    }

    /// Only the already opted-in ingestion pipeline calls this method. Every task
    /// is an exact structured action and stays in review; no second title model,
    /// subject fallback, guessed deadline or calendar registration is introduced.
    func extractTodos(
        from message: GmailMessage,
        allowFoundationModels: Bool = true,
        language: AppLanguage = .current
    ) async throws -> [Todo] {
        try Task.checkCancellation()
        guard Set(message.labelIds).isDisjoint(with: ["CATEGORY_SOCIAL", "CATEGORY_FORUMS"]),
              !EmailAnalysisContract.normalizedBody(message.body).isEmpty else { return [] }
        let result = try await summaryProvider(message, allowFoundationModels, language).normalized
        try Task.checkCancellation()
        let analyzer = EmailContentAnalyzer()
        return result.actionItems.map { action in
            let todo = Todo(
                title: action,
                notes: ([result.summary] + result.keyPoints).filter { !$0.isEmpty }.joined(separator: "\n"),
                dueDate: nil,
                source: .email,
                sourceRef: message.id
            )
            todo.sourceSender = analyzer.parseSender(from: message.from)
            todo.sourceSenderEmail = analyzer.parseSenderEmail(from: message.from)
            todo.sourceMessageID = message.messageID
            todo.sourceThreadID = message.threadID
            todo.sourceAccountNamespace = message.sourceAccountNamespace
            todo.sourceItemID = EmailAnalysisContract.actionIdentifier(action)
            todo.triageStatus = TodoTriage.review.rawValue
            return todo
        }
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

}
