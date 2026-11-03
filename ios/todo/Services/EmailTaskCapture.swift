import Foundation
import SwiftData

/// Captures the exact mail/action the user reviewed; subject and summary never
/// become task-title suggestions. An explicit manual capture has no action.
@MainActor
enum EmailTaskCapture {
    struct Source {
        let key: EmailMessageKey
        let fingerprint: String
        let action: String?
        let itemID: String
    }

    struct SavedItems {
        let titles: Set<String>
        let sourceItemIDs: Set<String>

        func containsAction(_ action: String) -> Bool {
            sourceItemIDs.contains(EmailAnalysisContract.actionIdentifier(action))
                || titles.contains(EmailAnalysisContract.normalizedActionText(action))
        }

        func contains(action: String?, title: String) -> Bool {
            titles.contains(EmailAnalysisContract.normalizedActionText(title))
                || (action.map(containsAction) ?? false)
        }
    }

    enum CaptureError: LocalizedError {
        case sourceChanged
        case duplicate
        case emptyTitle

        var errorDescription: String? {
            switch self {
            case .sourceChanged:
                AppLanguage.localized("mail.register.sourceChanged", defaultValue: "The email or its required actions changed. Reopen the review before saving.", language: .current)
            case .duplicate:
                AppLanguage.localized("mail.register.actionDuplicate", defaultValue: "This action from this email is already saved.", language: .current)
            case .emptyTitle:
                AppLanguage.localized("mail.register.titleRequired", defaultValue: "Enter a to-do title.", language: .current)
            }
        }
    }

    static func source(for email: EmailMessage, action: String?) -> Source? {
        if let action, !EmailAnalysisContract.currentActionItems(for: email).contains(action) {
            return nil
        }
        return Source(
            key: EmailMessageKey(email),
            fingerprint: EmailAnalysisContract.fingerprint(subject: email.subject, body: email.body),
            action: action,
            itemID: action.map(EmailAnalysisContract.actionIdentifier) ?? "manual:\(UUID().uuidString)"
        )
    }

    static func isCurrent(_ source: Source, for email: EmailMessage) -> Bool {
        guard source.key == EmailMessageKey(email),
              source.fingerprint == EmailAnalysisContract.fingerprint(subject: email.subject, body: email.body)
        else { return false }
        return source.action.map { EmailAnalysisContract.currentActionItems(for: email).contains($0) } ?? true
    }

    static func savedItems(for email: EmailMessage, in context: ModelContext) throws -> SavedItems {
        let ref = email.todoSourceRef
        let namespace = email.sourceAccountNamespace
        let emailSource = TodoSource.email.rawValue
        let descriptor = FetchDescriptor<Todo>(predicate: #Predicate {
            $0.source == emailSource && $0.sourceRef == ref && $0.sourceAccountNamespace == namespace
        })
        let tasks = try context.fetch(descriptor)
        return SavedItems(
            titles: Set(tasks.map { normalizedTitle($0.title) }),
            sourceItemIDs: Set(tasks.map(\.sourceItemID).filter { !$0.isEmpty })
        )
    }

    static func normalizedTitle(_ title: String) -> String {
        EmailAnalysisContract.normalizedActionText(title)
    }

    static func save(
        source: Source,
        email: EmailMessage,
        title: String,
        notes: String,
        dueDate: Date?,
        in context: ModelContext
    ) throws -> Todo {
        guard isCurrent(source, for: email) else { throw CaptureError.sourceChanged }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CaptureError.emptyTitle }
        let saved = try savedItems(for: email, in: context)
        guard !saved.sourceItemIDs.contains(source.itemID),
              !saved.titles.contains(normalizedTitle(title)) else {
            throw CaptureError.duplicate
        }
        let analyzer = EmailContentAnalyzer()
        let todo = Todo(title: title, notes: notes, dueDate: dueDate, source: .email, sourceRef: email.todoSourceRef)
        todo.sourceAccountNamespace = email.sourceAccountNamespace
        todo.sourceItemID = source.itemID
        todo.sourceSender = analyzer.parseSender(from: email.from)
        todo.sourceSenderEmail = analyzer.parseSenderEmail(from: email.from)
        todo.sourceMessageID = email.provider == .outlook ? email.providerGlobalMessageID : ""
        todo.sourceThreadID = email.threadID
        context.insert(todo)
        TaskBehaviorRecorder.recordCreation(of: todo, actor: .user, in: context)
        try context.save()
        return todo
    }
}
