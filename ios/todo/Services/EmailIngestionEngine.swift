import Foundation

struct SyncedMailAnalysis: Sendable {
    let providerGlobalMessageID: String
    let summary: String
    let keyPoints: [String]
    let actionItems: [String]

    /// Only an exact current-source, failure-free analysis may suppress a model call.
    @MainActor
    init?(_ email: EmailMessage, subject: String, body: String) {
        guard EmailAnalysisContract.matchesAnalysis(email, subject: subject, body: body),
              email.analysisFailureReasonRaw == nil else { return nil }
        providerGlobalMessageID = email.providerGlobalMessageID
        summary = email.analysisSummary
        keyPoints = email.analysisKeyPoints
        actionItems = email.analysisActionItems
    }
}

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
        language: AppLanguage = .current,
        existingAnalysis: SyncedMailAnalysis? = nil
    ) async throws -> [Todo] {
        try Task.checkCancellation()
        guard Set(message.labelIds).isDisjoint(with: ["CATEGORY_SOCIAL", "CATEGORY_FORUMS"]),
              !EmailAnalysisContract.normalizedBody(message.body).isEmpty else { return [] }
        let result: EmailSummaryResult
        if let existingAnalysis {
            result = EmailSummaryResult(
                summary: existingAnalysis.summary,
                keyPoints: existingAnalysis.keyPoints,
                actionItems: existingAnalysis.actionItems
            ).normalized
        } else {
            result = try await summaryProvider(message, allowFoundationModels, language).normalized
            try Task.checkCancellation()
        }
        let analyzer = EmailContentAnalyzer()
        let canonicalAccount = message.sourceAccountNamespace
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Provider-stable identity only; the RFC header is not equally available to
        // every device or to the user capture path.
        let canonicalMessageID = [
            existingAnalysis?.providerGlobalMessageID ?? "",
            message.providerMessageID,
            message.id
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? message.id
        return result.actionItems.map { action in
            let itemID = EmailAnalysisContract.actionIdentifier(action)
            let todoID = EmailAnalysisContract.deterministicTodoID(
                provider: message.provider,
                sourceAccountNamespace: canonicalAccount,
                messageID: canonicalMessageID,
                itemIdentity: itemID
            )
            let todo = Todo(
                id: todoID,
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
            todo.sourceAccountNamespace = canonicalAccount
            todo.sourceItemID = itemID
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
