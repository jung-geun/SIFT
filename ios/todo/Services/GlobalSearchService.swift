import Foundation
import SwiftData

// MARK: - Core Value Types

nonisolated enum GlobalSearchSource: String, CaseIterable, Hashable, Sendable, Identifiable {
    case todo
    case mail
    case meeting

    var id: String { rawValue }
}

nonisolated enum GlobalSearchRecordKey: Hashable, Sendable {
    case todo(UUID)
    case mail(EmailMessageKey)
    case meeting(String)
}

nonisolated struct GlobalSearchDocument: Hashable, Sendable, Identifiable {
    let key: GlobalSearchRecordKey
    let source: GlobalSearchSource
    let stableSortKey: String
    let title: String
    let subtitle: String
    let date: Date
    let content: [String]

    var id: GlobalSearchRecordKey { key }

    init(
        key: GlobalSearchRecordKey,
        source: GlobalSearchSource,
        stableSortKey: String,
        title: String,
        subtitle: String,
        date: Date,
        content: [String] = []
    ) {
        self.key = key
        self.source = source
        self.stableSortKey = stableSortKey
        self.title = title
        self.subtitle = subtitle
        self.date = date
        self.content = content
    }
}

nonisolated struct GlobalSearchResult: Hashable, Sendable, Identifiable {
    let document: GlobalSearchDocument

    var id: GlobalSearchRecordKey { document.key }
    var key: GlobalSearchRecordKey { document.key }
    var source: GlobalSearchSource { document.source }
    var title: String { document.title }
    var subtitle: String { document.subtitle }
    var date: Date { document.date }

    init(document: GlobalSearchDocument) {
        self.document = document
    }
}

// MARK: - Pure Search Service

nonisolated enum GlobalSearchService {
    static func search(
        query: String,
        source: GlobalSearchSource? = nil,
        documents: [GlobalSearchDocument],
        limit: Int = 100
    ) -> [GlobalSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let effectiveLimit = min(max(limit, 0), 100)
        guard effectiveLimit > 0 else { return [] }

        let normalizedQuery = normalize(trimmedQuery)
        let queryTokens = trimmedQuery
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { normalize($0) }
        guard !queryTokens.isEmpty else { return [] }

        let candidates = source != nil ? documents.filter { $0.source == source } : documents

        struct ScoredMatch {
            let doc: GlobalSearchDocument
            let score: Int
        }

        var matched: [ScoredMatch] = []
        matched.reserveCapacity(candidates.count)

        for doc in candidates {
            let normTitle = normalize(doc.title)
            let normSubtitle = normalize(doc.subtitle)
            let normContent = doc.content.map { normalize($0) }

            let matchesAllTokens = queryTokens.allSatisfy { token in
                normTitle.contains(token) ||
                normSubtitle.contains(token) ||
                normContent.contains { $0.contains(token) }
            }
            guard matchesAllTokens else { continue }

            let score: Int
            if normTitle == normalizedQuery {
                score = 5
            } else if normTitle.hasPrefix(normalizedQuery) {
                score = 4
            } else if queryTokens.allSatisfy({ normTitle.contains($0) }) {
                score = 3
            } else if queryTokens.contains(where: { normSubtitle.contains($0) }) {
                score = 2
            } else {
                score = 1
            }

            matched.append(ScoredMatch(doc: doc, score: score))
        }

        matched.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.doc.date != rhs.doc.date {
                return lhs.doc.date > rhs.doc.date
            }
            if lhs.doc.source != rhs.doc.source {
                return sourceOrder(lhs.doc.source) < sourceOrder(rhs.doc.source)
            }
            return lhs.doc.stableSortKey < rhs.doc.stableSortKey
        }

        return Array(matched.prefix(effectiveLimit)).map { GlobalSearchResult(document: $0.doc) }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func sourceOrder(_ source: GlobalSearchSource) -> Int {
        switch source {
        case .todo: return 0
        case .mail: return 1
        case .meeting: return 2
        }
    }
}

// MARK: - MainActor Resolution & Corpus Builder

@MainActor
enum GlobalSearchResolvedRecord {
    case todo(Todo)
    case mail(EmailMessage)
    case meeting(MeetingRecord)
}

@MainActor
enum GlobalSearchCorpusBuilder {
    static func build(
        appContainer: ModelContainer,
        emailContainer: ModelContainer,
        meetingContainer: ModelContainer,
        mailAccess: MailboxCachedProviderAccess?
    ) throws -> [GlobalSearchDocument] {
        var documents: [GlobalSearchDocument] = []

        // 1. Todo Corpus
        let appContext = appContainer.mainContext
        let todos = try appContext.fetch(FetchDescriptor<Todo>())
        for todo in todos {
            documents.append(buildTodoDocument(todo))
        }

        // 2. Mail Corpus (Inbox only + Access check)
        if let mailAccess {
            let emailContext = emailContainer.mainContext
            let emailDescriptor = FetchDescriptor<EmailMessage>(
                predicate: #Predicate<EmailMessage> { $0.isInInbox == true }
            )
            let emails = try emailContext.fetch(emailDescriptor)
            for email in emails {
                guard mailAccess.permits(provider: email.provider, sourceAccountNamespace: email.sourceAccountNamespace) else {
                    continue
                }
                documents.append(buildMailDocument(email))
            }
        }

        // 3. Meeting Corpus (Decoded result + Nonempty outcome check)
        let meetingContext = meetingContainer.mainContext
        let meetings = try meetingContext.fetch(FetchDescriptor<MeetingRecord>())
        for meeting in meetings {
            guard let result = meeting.result else { continue }
            if let doc = buildMeetingDocument(meeting, result: result) {
                documents.append(doc)
            }
        }

        return documents
    }

    static func resolve(
        _ key: GlobalSearchRecordKey,
        appContainer: ModelContainer,
        emailContainer: ModelContainer,
        meetingContainer: ModelContainer,
        mailAccess: MailboxCachedProviderAccess?
    ) throws -> GlobalSearchResolvedRecord? {
        switch key {
        case .todo(let uuid):
            let context = appContainer.mainContext
            let descriptor = FetchDescriptor<Todo>(
                predicate: #Predicate<Todo> { $0.id == uuid }
            )
            guard let todo = try context.fetch(descriptor).first else { return nil }
            return .todo(todo)

        case .mail(let mailKey):
            let context = emailContainer.mainContext
            let providerRaw = mailKey.providerRawValue
            let messageID = mailKey.providerMessageID
            let descriptor = FetchDescriptor<EmailMessage>(
                predicate: #Predicate<EmailMessage> { email in
                    email.providerRawValue == providerRaw &&
                    (email.rawMessageID == messageID || email.id == messageID)
                }
            )
            let candidates = try context.fetch(descriptor)
            guard let email = candidates.first(where: { EmailMessageKey($0) == mailKey }),
                  email.isInInbox,
                  let mailAccess,
                  mailAccess.permits(
                    provider: email.provider,
                    sourceAccountNamespace: email.sourceAccountNamespace
                  ) else {
                return nil
            }
            return .mail(email)

        case .meeting(let meetingID):
            let context = meetingContainer.mainContext
            let descriptor = FetchDescriptor<MeetingRecord>(
                predicate: #Predicate<MeetingRecord> { $0.meetingID == meetingID }
            )
            guard let meeting = try context.fetch(descriptor).first else { return nil }
            return .meeting(meeting)
        }
    }

    private static func buildTodoDocument(_ todo: Todo) -> GlobalSearchDocument {
        var subtitleParts: [String] = []
        if let due = todo.dueDate {
            let formattedDue = AppDateFormat.deadlineString(from: due, isAllDay: false, language: AppLanguage.current)
            subtitleParts.append(formattedDue)
        }
        let sender = todo.sourceSender.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sender.isEmpty {
            subtitleParts.append(sender)
        }
        let subtitle = subtitleParts.joined(separator: " • ")
        let rawTitle = todo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.isEmpty
            ? AppLanguage.localized(
                "todo.noTitle",
                defaultValue: AppLanguage.current == .english ? "(No Title)" : "(제목 없음)",
                language: .current,
                comment: "Untitled to-do placeholder."
            )
            : rawTitle

        var content: [String] = []
        let notes = todo.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            content.append(notes)
        }
        for tag in todo.tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                content.append(trimmed)
            }
        }
        if !sender.isEmpty {
            content.append(sender)
        }

        return GlobalSearchDocument(
            key: .todo(todo.id),
            source: .todo,
            stableSortKey: todo.id.uuidString,
            title: title,
            subtitle: subtitle,
            date: todo.updatedAt,
            content: content
        )
    }

    private static func buildMailDocument(_ email: EmailMessage) -> GlobalSearchDocument {
        var content: [String] = []
        let snippet = email.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if !snippet.isEmpty {
            content.append(snippet)
        }
        let summary = email.analysisSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            content.append(summary)
        }
        for point in email.analysisKeyPoints {
            let trimmed = point.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                content.append(trimmed)
            }
        }
        for action in email.analysisActionItems {
            let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                content.append(trimmed)
            }
        }

        let rawSubject = email.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawSubject.isEmpty
            ? AppLanguage.localized(
                "(제목 없음)",
                defaultValue: AppLanguage.current == .english ? "(No Title)" : "(제목 없음)",
                language: .current,
                comment: "Untitled mail placeholder."
            )
            : rawSubject

        return GlobalSearchDocument(
            key: .mail(EmailMessageKey(email)),
            source: .mail,
            stableSortKey: email.localListID,
            title: title,
            subtitle: email.from,
            date: email.receivedAt,
            content: content
        )
    }

    private static func buildMeetingDocument(_ meeting: MeetingRecord, result: MeetingResult) -> GlobalSearchDocument? {
        guard !meeting.isAudioTrackGroup else { return nil }
        let rawTitle = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let decisions = result.decisions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let questions = result.unresolvedQuestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        var actionDraftParts: [String] = []
        for draft in result.actionDrafts {
            let dTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !dTitle.isEmpty { actionDraftParts.append(dTitle) }
            let dNotes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !dNotes.isEmpty { actionDraftParts.append(dNotes) }
            if let assignee = draft.assignee?.trimmingCharacters(in: .whitespacesAndNewlines), !assignee.isEmpty {
                actionDraftParts.append(assignee)
            }
        }

        let hasOutcomeField = !rawTitle.isEmpty || !summary.isEmpty || !decisions.isEmpty || !questions.isEmpty || !actionDraftParts.isEmpty
        guard hasOutcomeField else { return nil }

        let defaultTitle = AppLanguage.localized(
            "meeting.title.untitled",
            defaultValue: AppLanguage.current == .english ? "Meeting" : "회의",
            language: AppLanguage.current
        )
        let title = rawTitle.isEmpty ? defaultTitle : rawTitle

        var content: [String] = []
        if !summary.isEmpty {
            content.append(summary)
        }
        content.append(contentsOf: decisions)
        content.append(contentsOf: questions)
        content.append(contentsOf: actionDraftParts)

        return GlobalSearchDocument(
            key: .meeting(meeting.meetingID),
            source: .meeting,
            stableSortKey: meeting.meetingID,
            title: title,
            subtitle: meeting.parentMeetingID == nil ? summary
                : [meeting.audioTrackDisplayName, summary].filter { !$0.isEmpty }.joined(separator: " · "),
            date: meeting.updatedAt,
            content: content
        )
    }
}
