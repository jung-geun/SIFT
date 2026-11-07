import Foundation
import SwiftData
import Testing
@testable import todo

@MainActor
@Suite("Mail action capture", .serialized)
struct EmailTaskCaptureTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Todo.self, TaskBehaviorEvent.self])
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    private func message(actions: [String], account: String = "first@example.com") -> EmailMessage {
        let email = EmailMessage(
            id: "mail-1", threadID: "thread-1", subject: "Informational subject, not a task",
            from: "Sender <sender@example.com>", body: "The token expired. Check its settings and renew it if needed.",
            provider: .gmail, isInInbox: true, sourceAccountNamespace: account
        )
        email.bodyContentVersion = 1
        email.analysisState = .analyzed
        email.analysisSummary = "A summary is not an action title."
        email.analysisKeyPoints = ["A fact is not an action title."]
        email.analysisActionItems = actions
        email.analysisVersion = EmailAnalysisContract.summaryContractVersion
        email.analyzedBodyFingerprint = EmailAnalysisContract.fingerprint(subject: email.subject, body: email.body)
        return email
    }

    @Test("Two required actions from one email persist as distinct source-linked tasks")
    func multipleActions() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let actions = ["Check token settings", "Renew the token if needed"]
        let email = message(actions: actions)
        for action in actions {
            let source = try #require(EmailTaskCapture.source(for: email, action: action))
            _ = try EmailTaskCapture.save(source: source, email: email, title: action, notes: "", dueDate: nil, in: context)
        }
        let reopened = ModelContext(container)
        let tasks = try reopened.fetch(FetchDescriptor<Todo>())
        #expect(Set(tasks.map(\.title)) == Set(actions))
        #expect(tasks.allSatisfy { $0.sourceRef == email.todoSourceRef && $0.sourceAccountNamespace == email.sourceAccountNamespace })
        #expect(tasks.allSatisfy { $0.dueDate == nil })
    }

    @Test("No-action analysis cannot propose its subject, summary, or facts")
    func noActionsAllowsOnlyExplicitManualTitle() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = message(actions: [])
        for text in [email.subject, email.analysisSummary] + email.analysisKeyPoints {
            #expect(EmailTaskCapture.source(for: email, action: text) == nil)
        }
        let manual = try #require(EmailTaskCapture.source(for: email, action: nil))
        let saved = try EmailTaskCapture.save(source: manual, email: email, title: "User's own title", notes: "", dueDate: nil, in: context)
        #expect(saved.title == "User's own title")
        #expect(try context.fetch(FetchDescriptor<Todo>()).map(\.title) == ["User's own title"])
    }

    @Test("Reopening cannot save the same action with only whitespace or casing changes")
    func duplicateAfterReopen() throws {
        let container = try makeContainer()
        let email = message(actions: ["Check token settings"])
        let source = try #require(EmailTaskCapture.source(for: email, action: "Check token settings"))
        _ = try EmailTaskCapture.save(source: source, email: email, title: "Check token settings", notes: "", dueDate: nil, in: ModelContext(container))
        let reopened = ModelContext(container)
        #expect(throws: EmailTaskCapture.CaptureError.self) {
            try EmailTaskCapture.save(source: source, email: email, title: "  CHECK  token\nsettings  ", notes: "", dueDate: nil, in: reopened)
        }
        #expect(try reopened.fetch(FetchDescriptor<Todo>()).map(\.title) == ["Check token settings"])
    }

    @Test("An edited task title does not allow the original action to be captured twice")
    func editedTitleRetainsActionIdentity() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = message(actions: ["Check token settings"])
        let source = try #require(EmailTaskCapture.source(for: email, action: "Check token settings"))
        let saved = try EmailTaskCapture.save(
            source: source, email: email, title: "User-reviewed replacement title",
            notes: "", dueDate: nil, in: context
        )
        saved.title = "Later title edit"
        try context.save()
        let reopened = ModelContext(container)
        let offered = try EmailTaskCapture.savedItems(for: email, in: reopened)
        #expect(offered.containsAction("Check token settings"))
        #expect(throws: EmailTaskCapture.CaptureError.self) {
            try EmailTaskCapture.save(
                source: source, email: email, title: "Check token settings",
                notes: "", dueDate: nil, in: reopened
            )
        }
        #expect(try reopened.fetch(FetchDescriptor<Todo>()).map(\.title) == ["Later title edit"])
    }

    @Test("Changed body or regenerated action cannot silently replace a reviewed action")
    func changedSource() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = message(actions: ["Check token settings"])
        let source = try #require(EmailTaskCapture.source(for: email, action: "Check token settings"))
        email.analysisActionItems = ["Delete the token"]
        #expect(throws: EmailTaskCapture.CaptureError.self) {
            try EmailTaskCapture.save(source: source, email: email, title: "Check token settings", notes: "", dueDate: nil, in: context)
        }
        email.analysisActionItems = ["Check token settings"]
        email.body = "Replacement body after a mailbox refresh."
        #expect(throws: EmailTaskCapture.CaptureError.self) {
            try EmailTaskCapture.save(source: source, email: email, title: "Check token settings", notes: "", dueDate: nil, in: context)
        }
        #expect(try context.fetch(FetchDescriptor<Todo>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TaskBehaviorEvent>()).isEmpty)
    }

    @Test("Account identity scopes duplicate checks and binds the reviewed source")
    func accountIsolation() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let first = message(actions: ["Check token settings"])
        let second = message(actions: ["Check token settings"], account: "second@example.com")
        let firstSource = try #require(EmailTaskCapture.source(for: first, action: "Check token settings"))
        #expect(throws: EmailTaskCapture.CaptureError.self) {
            try EmailTaskCapture.save(source: firstSource, email: second, title: "Check token settings", notes: "", dueDate: nil, in: context)
        }
        for email in [first, second] {
            let source = try #require(EmailTaskCapture.source(for: email, action: "Check token settings"))
            _ = try EmailTaskCapture.save(source: source, email: email, title: "Check token settings", notes: "", dueDate: nil, in: context)
        }
        #expect(Set(try context.fetch(FetchDescriptor<Todo>()).map(\.sourceAccountNamespace)) == ["first@example.com", "second@example.com"])
    }

    @Test("Capture keeps independent random identities but still blocks provenance duplicates including legacy rows")
    func captureProvenanceDuplicateGuard() throws {
        let contextA = ModelContext(try makeContainer())
        let contextB = ModelContext(try makeContainer())
        let emailA = message(actions: ["Renew the token if needed"])
        emailA.providerGlobalMessageID = "gmail-global-777"
        let emailB = message(actions: ["Renew the token if needed"], account: "FIRST@EXAMPLE.COM")
        emailB.providerGlobalMessageID = "gmail-global-777"
        let sourceA = try #require(EmailTaskCapture.source(for: emailA, action: "Renew the token if needed"))
        let sourceB = try #require(EmailTaskCapture.source(for: emailB, action: "Renew the token if needed"))
        let todoA = try EmailTaskCapture.save(source: sourceA, email: emailA, title: "Edited A", notes: "", dueDate: nil, in: contextA)
        let todoB = try EmailTaskCapture.save(source: sourceB, email: emailB, title: "Edited B", notes: "", dueDate: nil, in: contextB)
        // User-edited captures are independent records; they are not forced to share a key.
        #expect(todoA.id != todoB.id)

        let legacyContext = ModelContext(try makeContainer())
        let legacyID = UUID()
        let legacyTodo = Todo(id: legacyID, title: "Renew the token if needed", source: .email, sourceRef: emailA.todoSourceRef)
        legacyTodo.sourceAccountNamespace = emailA.sourceAccountNamespace
        legacyTodo.sourceItemID = EmailAnalysisContract.actionIdentifier("Renew the token if needed")
        legacyContext.insert(legacyTodo)
        try legacyContext.save()
        #expect(throws: EmailTaskCapture.CaptureError.self) {
            try EmailTaskCapture.save(source: sourceA, email: emailA, title: "Renew the token if needed", notes: "", dueDate: nil, in: legacyContext)
        }
        let retained = try legacyContext.fetch(FetchDescriptor<Todo>())
        #expect(retained.count == 1 && retained.first?.id == legacyID)
    }
}
