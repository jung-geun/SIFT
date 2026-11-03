import Foundation
import Testing
@testable import todo

@Suite("Email action-only ingestion")
@MainActor
struct EmailIngestionDecisionTests {
    private func message(body: String = "Please review the plan and reply.") -> GmailMessage {
        GmailMessage(
            id: "message", threadID: "thread", messageID: "<message@example.com>",
            subject: "An interesting subject is not a task", from: "Project Team <projects@example.com>",
            snippet: "Please do not analyze this preview instead of the body.", body: body,
            htmlBody: nil, receivedAt: Date(), labelIds: ["INBOX"], isBulk: false,
            sourceAccountNamespace: "gmail:projects@example.com"
        )
    }

    @Test("Required actions alone become exact, separate review titles", arguments: [
        ["Review the plan"], ["Review the plan", "Reply with approval"], []
    ])
    func canonicalActions(actions: [String]) async throws {
        let email = message()
        var calls = 0
        let engine = EmailIngestionEngine(summaryProvider: { source, _, _ in
            calls += 1
            #expect(source.body == email.body)
            return EmailSummaryResult(summary: "Check the exciting launch!", keyPoints: ["Friday deadline"], actionItems: actions)
        })
        let todos = try await engine.extractTodos(from: email)
        #expect(calls == 1)
        #expect(todos.map(\.title) == actions)
        for todo in todos {
            #expect(todo.triage == .review)
            #expect(todo.dueDate == nil)
            #expect(todo.source == TodoSource.email.rawValue)
            #expect(todo.sourceRef == email.id)
            #expect(todo.sourceMessageID == email.messageID)
            #expect(todo.sourceThreadID == email.threadID)
            #expect(todo.sourceAccountNamespace == email.sourceAccountNamespace)
            #expect(todo.sourceSenderEmail == "projects@example.com")
        }
    }

    @Test("Late and quoted sections reach the single structured provider intact")
    func lateBodyActions() async throws {
        let body = String(repeating: "Status detail.\n", count: 1_000)
            + "--\nThe token has expired. Check the integration and renew the token if it is still needed.\n> Earlier context."
        let email = message(body: body)
        let actions = ["Check the integration", "Renew the token if it is still needed"]
        let engine = EmailIngestionEngine(summaryProvider: { source, _, _ in
            #expect(source.body == body)
            return EmailSummaryResult(summary: "The token expired.", keyPoints: [], actionItems: actions)
        })
        #expect(try await engine.extractTodos(from: email).map(\.title) == actions)
    }

    @Test("An absent body never promotes a preview or subject into analyzed evidence")
    func noSnippetFallback() async throws {
        var calls = 0
        let engine = EmailIngestionEngine(summaryProvider: { _, _, _ in
            calls += 1
            return EmailSummaryResult(summary: "not reached", keyPoints: [], actionItems: ["not reached"])
        })
        #expect(try await engine.extractTodos(from: message(body: " \n")).isEmpty)
        #expect(calls == 0)
    }

    @Test("Duplicate and empty action items do not create additional tasks")
    func uniqueActions() async throws {
        let engine = EmailIngestionEngine(summaryProvider: { _, _, _ in
            EmailSummaryResult(summary: "A request", keyPoints: [], actionItems: [" Reply exactly. ", "", "Reply exactly."])
        })
        #expect(try await engine.extractTodos(from: message()).map(\.title) == ["Reply exactly."])
    }

    @Test("Disabled model use does not fall back to subject/date-based task creation")
    func noActionlessFallback() async throws {
        #expect(try await EmailIngestionEngine().extractTodos(
            from: message(body: "The launch deadline is 2099-12-24. This is information only."),
            allowFoundationModels: false
        ).isEmpty)
    }

    @Test("Cancellation before and after provider suspension prevents task creation", arguments: [false, true])
    func cancellationFence(beforeStart: Bool) async throws {
        let provider = SuspendedIngestionSummaryProvider()
        var calls = 0
        let engine = EmailIngestionEngine(summaryProvider: { _, _, _ in
            calls += 1
            return await provider.summarize()
        })
        let email = message()
        let task = Task { @MainActor in _ = try await engine.extractTodos(from: email) }
        if beforeStart {
            task.cancel()
        } else {
            await provider.waitUntilSuspended()
            task.cancel()
            provider.resume()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls == (beforeStart ? 0 : 1))
    }
}

@MainActor
private final class SuspendedIngestionSummaryProvider {
    private var continuation: CheckedContinuation<EmailSummaryResult, Never>?

    func summarize() async -> EmailSummaryResult {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async {
        while continuation == nil { await Task.yield() }
    }

    func resume() {
        continuation?.resume(returning: EmailSummaryResult(summary: "A request", keyPoints: [], actionItems: ["Reply"]))
        continuation = nil
    }
}
