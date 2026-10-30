import Foundation
import Testing
@testable import todo

@Suite("Feedback consent, retry and cancellation")
@MainActor
struct FeedbackComposerTests {
    private let app = FeedbackAppMetadata(
        version: "1.2.3", build: "42", platform: "iOS", osVersion: "18.0", language: "ko"
    )
    private let diagnostics = Data(" \n{\"text\":\"한글 café\",\"escaped\":\"\\t\"}\n".utf8)
    private let delivered = FeedbackReceipt(
        ticketID: "2f4ce4cc-2fa9-4e8f-9fa6-9cde589ebdec", receivedAt: "2026-10-16T10:20:30Z"
    )

    private func composer(service: QueuedFeedbackSubmitter, kind: FeedbackKind = .bug) -> FeedbackComposer {
        let composer = FeedbackComposer(initialKind: kind, preparedDiagnostics: diagnostics, app: app, service: service)
        composer.title = "  Report title  "
        composer.message = "\nReport details 한글\n"
        return composer
    }

    @Test("Preparation is local and sending requires both review and explicit consent")
    func preparationNeverSubmitsAndConsentIsRequired() async throws {
        let service = QueuedFeedbackSubmitter(outcomes: [.success(delivered)])
        let composer = composer(service: service)
        composer.consent = true
        #expect(await composer.send() == nil) // Consent alone is not a reviewed payload.
        #expect(composer.prepareReview())
        let frozen = try #require(composer.submission)
        #expect(frozen.title == "Report title")
        #expect(frozen.message == "Report details 한글")
        #expect(frozen.diagnostics.map { Data($0.utf8) } == diagnostics)
        #expect(composer.consent == false) // Preparing a preview cannot imply consent.
        #expect(await service.callCount == 0)
        #expect(await composer.send() == nil)
        #expect(await service.callCount == 0)
        composer.consent = true
        #expect(await composer.send() == delivered)
        #expect(composer.receipt == delivered)
        #expect(await service.callCount == 1)
        #expect(await composer.send() == nil) // Delivered reports cannot be submitted twice.
        #expect(await service.callCount == 1)
    }

    @Test("Invalid review never invokes the submitting service or creates a receipt")
    func invalidPreparationDoesNotSubmit() async {
        let service = QueuedFeedbackSubmitter(outcomes: [])
        let composer = composer(service: service)
        composer.title = " \t\n"
        #expect(composer.prepareReview() == false)
        #expect(composer.failure == .invalidInput)
        composer.consent = true
        #expect(await composer.send() == nil)
        #expect(composer.submission == nil)
        #expect(composer.receipt == nil)
        #expect(await service.callCount == 0)
        #expect(composer.preparedDiagnostics == diagnostics)
    }

    @Test("Prepared diagnostic reports can reach local review without mandatory manual text entry")
    func preparedDiagnosticCanBeReviewedWithoutManualEntry() async throws {
        let service = QueuedFeedbackSubmitter(outcomes: [.success(delivered)])
        let composer = FeedbackComposer(preparedDiagnostics: diagnostics, app: app, service: service)
        #expect(composer.prepareReview())
        let frozen = try #require(composer.submission)
        #expect(frozen.diagnostics.map { Data($0.utf8) } == diagnostics)
        #expect(!composer.consent)
        #expect(await composer.send() == nil)
        #expect(await service.callCount == 0)
        composer.consent = true
        #expect(await composer.send() == delivered)
        #expect(await service.callCount == 1)
    }

    @Test("A manual retry reuses the exact frozen payload and submission ID")
    func manualRetryReusesFrozenBytesAndID() async throws {
        let service = QueuedFeedbackSubmitter(outcomes: [.failure(.transport(code: nil)), .success(delivered)])
        let composer = composer(service: service)
        #expect(composer.prepareReview())
        let frozen = try #require(composer.submission)
        composer.consent = true
        #expect(await composer.send() == nil)
        #expect(composer.failure == .transport(code: nil))
        #expect(composer.receipt == nil)
        #expect(await service.callCount == 1)
        #expect(composer.prepareReview())
        #expect(composer.consent == false)
        #expect(await service.callCount == 1)
        composer.consent = true
        #expect(await composer.send() == delivered)
        let calls = await service.submissions
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.submissionID == frozen.submissionID && $0.body == frozen.body })
        #expect(calls.allSatisfy { $0.diagnostics.map { Data($0.utf8) } == diagnostics })
        #expect(composer.failure == nil)
        #expect(composer.receipt == delivered)
    }

    @Test("Editing a failed draft revokes consent and produces a new submission ID")
    func editingCreatesNewSubmissionID() async throws {
        let service = QueuedFeedbackSubmitter(outcomes: [.failure(.unavailable), .success(delivered)])
        let composer = composer(service: service)
        #expect(composer.prepareReview())
        let original = try #require(composer.submission)
        composer.consent = true
        #expect(await composer.send() == nil)
        composer.message = "Edited details"
        #expect(composer.submission == nil)
        #expect(composer.consent == false)
        #expect(composer.receipt == nil)
        #expect(await composer.send() == nil)
        #expect(await service.callCount == 1)
        #expect(composer.prepareReview())
        let edited = try #require(composer.submission)
        #expect(edited.submissionID != original.submissionID)
        #expect(edited.body != original.body)
        #expect(edited.message == "Edited details")
        composer.consent = true
        #expect(await composer.send() == delivered)
        let calls = await service.submissions
        #expect(calls.map(\.submissionID) == [original.submissionID, edited.submissionID])
    }

    @Test("Changing any reviewed field invalidates consent and freezes a fresh payload")
    func reviewedEditsInvalidatePayload() throws {
        let service = QueuedFeedbackSubmitter(outcomes: [])
        let composer = composer(service: service)
        let edits: [(FeedbackComposer) -> Void] = [
            { $0.title = "Different title" },
            { $0.message = "Different message" },
            { $0.includeDiagnostics = false },
            { $0.kind = .feature },
            { $0.returnToEditing() }
        ]
        for edit in edits {
            #expect(composer.prepareReview())
            let before = try #require(composer.submission)
            composer.consent = true
            edit(composer)
            #expect(composer.submission == nil)
            #expect(composer.consent == false)
            #expect(composer.prepareReview())
            #expect(composer.submission?.submissionID != before.submissionID)
        }
    }

    @Test("Failures including malformed responses preserve draft and diagnostic bytes without a receipt")
    func failuresPreserveDraftWithoutReceipt() async throws {
        let failures: [FeedbackFailure] = [
            .invalidResponse(status: nil), .invalidResponse(status: 502),
            .transport(code: nil), .transport(code: URLError.timedOut.rawValue),
            .cancelled, .configuration, .rejected,
            .conflict, .requestTooLarge, .rateLimited(retryAfter: 60), .unavailable
        ]
        for failure in failures {
            let service = QueuedFeedbackSubmitter(outcomes: [.failure(failure)])
            let composer = composer(service: service)
            #expect(composer.prepareReview())
            let frozen = try #require(composer.submission)
            composer.consent = true
            #expect(await composer.send() == nil)
            #expect(composer.failure == failure)
            #expect(composer.receipt == nil)
            #expect(composer.isSending == false)
            expectDraftPreserved(composer, frozen: frozen)
            #expect(await service.callCount == 1)
        }
    }

    @Test("Feature review omits prepared diagnostics even when attachment is requested")
    func featureReviewCannotAttachPreparedDiagnostics() async throws {
        let service = QueuedFeedbackSubmitter(outcomes: [.success(delivered)])
        let composer = composer(service: service, kind: .feature)
        composer.includeDiagnostics = true
        #expect(composer.prepareReview())
        let frozen = try #require(composer.submission)
        #expect(frozen.kind == .feature)
        #expect(frozen.diagnostics == nil)
        let body = try #require(JSONSerialization.jsonObject(with: frozen.body) as? [String: Any])
        #expect(body["diagnostics"] == nil)
        #expect(await service.callCount == 0)
        composer.consent = true
        #expect(await composer.send() == delivered)
        let calls = await service.submissions
        #expect(calls.count == 1)
        #expect(calls.first?.includesDiagnostics == false)
        #expect(composer.preparedDiagnostics == diagnostics)
    }

    @Test("Opting out removes diagnostics from the sent payload without deleting the prepared report")
    func diagnosticOptOutDoesNotDeletePreparedReport() async throws {
        let service = QueuedFeedbackSubmitter(outcomes: [.success(delivered)])
        let composer = composer(service: service)
        composer.includeDiagnostics = false
        #expect(composer.prepareReview())
        #expect(composer.submission?.includesDiagnostics == false)
        composer.consent = true
        #expect(await composer.send() == delivered)
        #expect(await service.submissions.first?.diagnostics == nil)
        #expect(composer.preparedDiagnostics == diagnostics)
    }

    @Test("Cancel ignores late success and preserves the same payload for explicit manual retry")
    func cancelIgnoresLateSuccessAndPreservesRetry() async throws {
        let service = QueuedFeedbackSubmitter(outcomes: [.heldSuccess(delivered), .success(delivered)])
        let composer = composer(service: service)
        #expect(composer.prepareReview())
        let frozen = try #require(composer.submission)
        composer.consent = true
        let sending = Task { await composer.send() }
        await service.waitUntilCalls(1)
        #expect(composer.isSending)
        #expect(await composer.send() == nil) // Concurrent taps cannot create a second attempt.
        #expect(composer.prepareReview() == false)
        #expect(await service.callCount == 1)
        composer.cancel()
        #expect(composer.isSending == false)
        #expect(composer.failure == .cancelled)
        #expect(composer.receipt == nil)
        expectDraftPreserved(composer, frozen: frozen)
        await service.releaseHeldSuccess() // Fake deliberately returns success despite cancellation.
        #expect(await sending.value == nil)
        #expect(await service.cancelledCallCount == 1)
        #expect(composer.receipt == nil)
        #expect(composer.failure == .cancelled)
        expectDraftPreserved(composer, frozen: frozen)
        #expect(composer.prepareReview())
        composer.consent = true
        #expect(await composer.send() == delivered)
        let calls = await service.submissions
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.body == frozen.body && $0.submissionID == frozen.submissionID })
    }

    @Test("Cancelling the caller task prevents late delivery and preserves the draft")
    func callerCancellationPreventsLateReceipt() async throws {
        let service = QueuedFeedbackSubmitter(outcomes: [.heldSuccess(delivered)])
        let composer = composer(service: service)
        #expect(composer.prepareReview())
        let frozen = try #require(composer.submission)
        composer.consent = true
        let sending = Task { await composer.send() }
        await service.waitUntilCalls(1)
        sending.cancel()
        await service.releaseHeldSuccess()
        #expect(await sending.value == nil)
        #expect(await service.cancelledCallCount == 1)
        #expect(composer.failure == .cancelled)
        #expect(composer.receipt == nil)
        #expect(composer.isSending == false)
        expectDraftPreserved(composer, frozen: frozen)
    }

    @Test("Editing during an in-flight send prevents its stale receipt from completing the new draft")
    func editingDuringSendDiscardsStaleReceipt() async throws {
        let service = QueuedFeedbackSubmitter(outcomes: [.heldSuccess(delivered)])
        let composer = composer(service: service)
        #expect(composer.prepareReview())
        let originalID = try #require(composer.submission?.submissionID)
        composer.consent = true
        let sending = Task { await composer.send() }
        await service.waitUntilCalls(1)
        composer.title = "Replacement title"
        #expect(composer.isSending == false)
        #expect(composer.consent == false)
        #expect(composer.submission == nil)
        await service.releaseHeldSuccess()
        #expect(await sending.value == nil)
        #expect(composer.receipt == nil)
        #expect(composer.title == "Replacement title")
        #expect(composer.preparedDiagnostics == diagnostics)
        #expect(composer.prepareReview())
        #expect(composer.submission?.submissionID != originalID)
        #expect(await service.callCount == 1)
    }

    @Test("An already cancelled send never invokes the service")
    func preCancelledSendDoesNotSubmit() async throws {
        let service = QueuedFeedbackSubmitter(outcomes: [])
        let composer = composer(service: service)
        #expect(composer.prepareReview())
        let frozen = try #require(composer.submission)
        composer.consent = true
        let sending = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await composer.send()
        }
        #expect(await sending.value == nil)
        #expect(composer.failure == .cancelled)
        #expect(composer.receipt == nil)
        #expect(await service.callCount == 0)
        expectDraftPreserved(composer, frozen: frozen)
    }

    private func expectDraftPreserved(_ composer: FeedbackComposer, frozen: FeedbackSubmission) {
        #expect(composer.title == "  Report title  ")
        #expect(composer.message == "\nReport details 한글\n")
        #expect(composer.preparedDiagnostics == diagnostics)
        #expect(composer.includeDiagnostics)
        #expect(composer.submission?.submissionID == frozen.submissionID)
        #expect(composer.submission?.body == frozen.body)
        #expect(composer.submission?.diagnostics.map { Data($0.utf8) } == diagnostics)
    }
}

private actor QueuedFeedbackSubmitter: FeedbackSubmitting {
    enum Outcome: Sendable {
        case success(FeedbackReceipt)
        case failure(FeedbackFailure)
        case heldSuccess(FeedbackReceipt)
    }

    private var outcomes: [Outcome]
    private(set) var submissions: [FeedbackSubmission] = []
    private(set) var cancelledCallCount = 0
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var held: CheckedContinuation<Void, Never>?
    var callCount: Int { submissions.count }

    init(outcomes: [Outcome]) { self.outcomes = outcomes }

    func submit(_ submission: FeedbackSubmission) async throws -> FeedbackReceipt {
        submissions.append(submission)
        guard !outcomes.isEmpty else {
            Issue.record("Unexpected feedback submission: no queued outcome")
            throw FeedbackFailure.transport(code: nil)
        }
        let outcome = outcomes.removeFirst()
        switch outcome {
        case let .success(receipt):
            notifyObservers()
            return receipt
        case let .failure(failure):
            notifyObservers()
            throw failure
        case let .heldSuccess(receipt):
            await withCheckedContinuation { continuation in
                held = continuation
                notifyObservers()
            }
            if Task.isCancelled { cancelledCallCount += 1 }
            return receipt // Intentionally ignores cancellation to exercise stale-success protection.
        }
    }

    func waitUntilCalls(_ count: Int) async {
        if submissions.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func releaseHeldSuccess() {
        let continuation = held
        held = nil
        continuation?.resume()
    }

    private func notifyObservers() {
        let ready = observers.filter { $0.0 <= submissions.count }
        observers.removeAll { $0.0 <= submissions.count }
        for (_, observer) in ready { observer.resume() }
    }
}
