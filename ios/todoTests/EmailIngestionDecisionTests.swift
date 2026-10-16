import Foundation
import Testing
@testable import todo

@Suite("Email to-do candidate decisions")
@MainActor
struct EmailIngestionDecisionTests {
    private func message(
        id: String,
        subject: String,
        body: String,
        labelIds: [String] = ["INBOX"],
        isBulk: Bool = false
    ) -> GmailMessage {
        GmailMessage(
            id: id,
            threadID: "thread-\(id)",
            messageID: "<\(id)@example.com>",
            subject: subject,
            from: "프로젝트 팀 <projects@example.com>",
            snippet: body,
            body: body,
            htmlBody: nil,
            receivedAt: Date(),
            labelIds: labelIds,
            isBulk: isBulk,
            sourceAccountNamespace: "gmail:projects@example.com"
        )
    }

    private func datedMessage(
        id: String,
        labelIds: [String] = ["INBOX"],
        isBulk: Bool = false
    ) -> GmailMessage {
        let future = Date().addingTimeInterval(14 * 24 * 3_600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)
        formatter.dateFormat = "yyyy-MM-dd"
        return message(
            id: id,
            subject: "프로젝트 제출 요청",
            body: "Deadline: \(formatter.string(from: future)) 17:30 UTC+9까지 제출",
            labelIds: labelIds,
            isBulk: isBulk
        )
    }

    private func expectProvenance(_ todo: Todo, from email: GmailMessage) {
        #expect(todo.source == TodoSource.email.rawValue)
        #expect(todo.sourceRef == email.id)
        #expect(todo.sourceMessageID == email.messageID)
        #expect(todo.sourceThreadID == email.threadID)
        #expect(todo.sourceAccountNamespace == email.sourceAccountNamespace)
        #expect(todo.sourceSender == "프로젝트 팀")
        #expect(todo.sourceSenderEmail == "projects@example.com")
    }

    @Test("Laya가 요청 메일로 추천하면 날짜가 없어도 검토 대기열에 기한 없이 보관한다")
    func suggestedUndatedEmailNeedsReviewInsteadOfInventedDeadline() async throws {
        let email = message(
            id: "needs-reply",
            subject: "프로젝트 검토 요청",
            body: "검토 후 의견을 회신해 주세요."
        )
        let engine = EmailIngestionEngine(candidateDecision: { _ in .candidate })

        let todos = try await engine.extractTodos(from: email, allowFoundationModels: false)

        #expect(todos.count == 1)
        let todo = try #require(todos.first)
        #expect(todo.title == "프로젝트 검토 요청")
        #expect(todo.dueDate == nil)
        #expect(todo.triage == .review)
        expectProvenance(todo, from: email)
    }

    @Test("Laya가 정보성 메일로 판단하면 날짜 문구가 있어도 자동 할 일을 만들지 않는다")
    func rejectedEmailDoesNotAutoRegister() async throws {
        let email = datedMessage(id: "status-newsletter")
        let fallback = EmailIngestionEngine(candidateDecision: { _ in nil })
        let datedTodos = try await fallback.extractTodos(from: email, allowFoundationModels: false)
        #expect(datedTodos.count == 1)
        #expect(datedTodos.first?.dueDate != nil)

        let engine = EmailIngestionEngine(candidateDecision: { _ in .notCandidate })

        #expect(try await engine.extractTodos(from: email, allowFoundationModels: false).isEmpty)
    }

    @Test("Positive dated mail still confirms a deterministically evidenced deadline")
    func candidateDatedEmailKeepsAutomaticTriage() async throws {
        let email = datedMessage(id: "candidate-dated")
        let extraction = try #require(EmailContentAnalyzer().analyze(email, now: Date()))
        #expect(extraction.keywordScore > 0)
        let engine = EmailIngestionEngine(candidateDecision: { _ in .candidate })
        let todos = try await engine.extractTodos(from: email, allowFoundationModels: false)
        let todo = try #require(todos.first)

        #expect(todos.count == 1)
        #expect(todo.dueDate == extraction.dueDate)
        #expect(todo.triage == .todo)
        expectProvenance(todo, from: email)
    }

    @Test("Uncertain dated mail keeps the deterministic deadline but never auto-confirms")
    func uncertainDatedEmailNeedsReview() async throws {
        let email = datedMessage(id: "uncertain-dated")
        let fallback = EmailIngestionEngine(candidateDecision: { _ in nil })
        let baseline = try await fallback.extractTodos(from: email, allowFoundationModels: false)
        let baselineTodo = try #require(baseline.first)
        #expect(baseline.count == 1)
        #expect(baselineTodo.dueDate != nil)
        #expect(baselineTodo.triage == .todo)

        let engine = EmailIngestionEngine(candidateDecision: { _ in .uncertain })
        let todos = try await engine.extractTodos(from: email, allowFoundationModels: false)
        let todo = try #require(todos.first)

        #expect(todos.count == 1)
        #expect(todo.dueDate == baselineTodo.dueDate)
        #expect(todo.title == baselineTodo.title)
        #expect(todo.notes == baselineTodo.notes)
        #expect(todo.triage == .review)
        expectProvenance(todo, from: email)
    }

    @Test("Uncertain undated mail uses the candidate manual review draft without a deadline")
    func uncertainUndatedEmailNeedsManualReview() async throws {
        let email = message(
            id: "uncertain-undated",
            subject: "프로젝트 검토 요청",
            body: "검토 후 의견을 회신해 주세요."
        )
        #expect(EmailContentAnalyzer().analyze(email, now: Date()) == nil)
        let candidate = EmailIngestionEngine(candidateDecision: { _ in .candidate })
        let candidateTodos = try await candidate.extractTodos(from: email, allowFoundationModels: false)
        let manualDraft = try #require(candidateTodos.first)
        let engine = EmailIngestionEngine(candidateDecision: { _ in .uncertain })
        let todos = try await engine.extractTodos(from: email, allowFoundationModels: false)
        let todo = try #require(todos.first)

        #expect(todos.count == 1)
        #expect(todo.title == email.subject)
        #expect(todo.title == manualDraft.title)
        #expect(!todo.notes.isEmpty)
        #expect(todo.notes == manualDraft.notes)
        #expect(todo.dueDate == nil)
        #expect(todo.triage == .review)
        expectProvenance(todo, from: email)
    }

    @Test("Unavailable candidate decisions keep the dated deterministic baseline")
    func unavailableDatedEmailKeepsBaseline() async throws {
        let email = datedMessage(id: "unavailable-dated")
        let extraction = try #require(EmailContentAnalyzer().analyze(email, now: Date()))
        #expect(extraction.keywordScore > 0)
        let engine = EmailIngestionEngine(candidateDecision: { _ in nil })
        let todos = try await engine.extractTodos(from: email, allowFoundationModels: false)
        let todo = try #require(todos.first)

        #expect(todos.count == 1)
        #expect(todo.title == email.subject)
        #expect(todo.dueDate == extraction.dueDate)
        #expect(todo.notes == extraction.notes)
        #expect(todo.triage == .todo)
        expectProvenance(todo, from: email)
    }

    @Test("Unavailable candidate decisions do not invent undated tasks")
    func unavailableUndatedEmailKeepsBaseline() async throws {
        let email = message(
            id: "unavailable-undated",
            subject: "프로젝트 검토 요청",
            body: "검토 후 의견을 회신해 주세요."
        )
        #expect(EmailContentAnalyzer().analyze(email, now: Date()) == nil)
        let engine = EmailIngestionEngine(candidateDecision: { _ in nil })

        #expect(try await engine.extractTodos(from: email, allowFoundationModels: false).isEmpty)
    }

    @Test("Promotions and bulk mail stay in review for positive, uncertain, and unavailable decisions")
    func promotionsCannotAutoConfirm() async throws {
        let decisions: [EmailCandidateOutcome?] = [nil, .candidate, .uncertain]
        for isBulk in [false, true] {
            let email = datedMessage(
                id: "promotion-\(isBulk)",
                labelIds: isBulk ? ["INBOX"] : ["INBOX", "CATEGORY_PROMOTIONS"],
                isBulk: isBulk
            )
            let extraction = try #require(EmailContentAnalyzer().analyze(email, now: Date()))
            #expect(extraction.keywordScore > 0)
            for decision in decisions {
                let engine = EmailIngestionEngine(candidateDecision: { _ in decision })
                let todos = try await engine.extractTodos(from: email, allowFoundationModels: false)
                let todo = try #require(todos.first)

                #expect(todos.count == 1)
                #expect(todo.dueDate == extraction.dueDate)
                #expect(todo.triage == .review)
                expectProvenance(todo, from: email)
            }
        }
    }

    @Test("Already cancelled ingestion never calls the candidate provider or produces a draft")
    func cancellationBeforeCandidateProvider() async throws {
        let email = datedMessage(id: "cancel-before-provider")
        var providerCalls = 0
        let engine = EmailIngestionEngine(candidateDecision: { _ in
            providerCalls += 1
            return .uncertain
        })
        // This suite is MainActor-isolated: the child cannot run until we yield below.
        let task = Task {
            _ = try await engine.extractTodos(from: email, allowFoundationModels: false)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(providerCalls == 0)
    }

    @Test("Cancellation after a suspended provider prevents dated and manual review results", arguments: [false, true])
    func cancellationAfterCandidateProvider(dated: Bool) async throws {
        let email = dated
            ? datedMessage(id: "cancel-suspended-dated")
            : message(id: "cancel-suspended-undated", subject: "검토 요청", body: "의견을 회신해 주세요.")
        let decisions: [EmailCandidateOutcome?] = [nil, .candidate, .notCandidate, .uncertain]
        for decision in decisions {
            let provider = SuspendedIngestionCandidateProvider()
            let engine = EmailIngestionEngine(candidateDecision: { _ in await provider.decide() })
            let task = Task {
                _ = try await engine.extractTodos(from: email, allowFoundationModels: false)
            }
            await provider.waitUntilSuspended()
            task.cancel()
            // The provider deliberately ignores cancellation; the engine must reject its result.
            provider.resume(with: decision)

            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }
}

@MainActor
private final class SuspendedIngestionCandidateProvider {
    private var continuation: CheckedContinuation<EmailCandidateOutcome?, Never>?
    private var entered: CheckedContinuation<Void, Never>?

    func decide() async -> EmailCandidateOutcome? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered?.resume()
            entered = nil
        }
    }

    func waitUntilSuspended() async {
        if continuation != nil { return }
        await withCheckedContinuation { entered = $0 }
    }

    func resume(with outcome: EmailCandidateOutcome?) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}
