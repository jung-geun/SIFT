import Foundation
import SwiftData
import Testing
@testable import todo

private enum MailboxMutationTestError: Error {
    case remote
    case save
}

@MainActor
@Suite("Mailbox mutations", .serialized)
struct MailboxMutationTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([EmailMessage.self])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MailboxMutationTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suiteName))
    }

    private func insertEmail(
        provider: MailProvider,
        into context: ModelContext
    ) throws -> EmailMessage {
        let email = EmailMessage(
            id: provider == .gmail ? "gmail-imap:global-message-id" : "message-id",
            subject: "Subject",
            provider: provider,
            rawMessageID: "message-id",
            labelIDs: provider == .gmail ? ["INBOX", "UNREAD"] : [],
            isInInbox: true,
            outlookInferenceClassificationRawValue: provider == .outlook ? "focused" : "",
            providerFolderID: provider == .outlook ? "inbox-folder" : ""
        )
        context.insert(email)
        try context.save()
        return email
    }

    @Test("read는 remote 호출 전에 optimistic 표시하고 성공 뒤 한 번 저장한다")
    func testMarkAsReadOptimisticSuccess() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = try insertEmail(provider: .gmail, into: context)
        var saveCount = 0
        var remoteCallCount = 0
        var observedOptimisticState = false
        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: {
                saveCount += 1
                try $0.save()
            }
        )

        try await store.markAsRead(email, in: context) {
            remoteCallCount += 1
            observedOptimisticState = email.isRead
                && !email.labelIDs.contains("UNREAD")
        }

        #expect(observedOptimisticState)
        #expect(remoteCallCount == 1)
        #expect(saveCount == 1)
        #expect(email.isRead)
        #expect(!email.labelIDs.contains("UNREAD"))
    }

    @Test("read remote 실패는 read와 Gmail UNREAD label을 rollback한다")
    func testMarkAsReadRemoteFailureRollsBack() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = try insertEmail(provider: .gmail, into: context)
        var saveCount = 0
        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: {
                saveCount += 1
                try $0.save()
            }
        )

        await #expect(throws: MailboxMutationTestError.remote) {
            try await store.markAsRead(email, in: context) {
                throw MailboxMutationTestError.remote
            }
        }
        #expect(!email.isRead)
        #expect(email.labelIDs.contains("UNREAD"))
        #expect(saveCount == 0)
    }

    @Test("read local save 실패는 pending을 남기고 relaunch replay로 수렴한다")
    func testMarkAsReadLocalSaveFailureReplaysWithoutRemoteRetry() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = try insertEmail(provider: .gmail, into: context)
        let defaults = try makeDefaults()
        var remoteCallCount = 0
        let failingStore = MailboxLocalStore(
            defaults: defaults,
            saveContext: { _ in throw MailboxMutationTestError.save }
        )

        do {
            try await failingStore.markAsRead(email, in: context) {
                remoteCallCount += 1
            }
            Issue.record("Expected local save failure")
        } catch let error as MailboxMutationError {
            guard case .remoteCommittedLocalSaveFailed(let provider, let action) = error else {
                Issue.record("Unexpected mailbox mutation error")
                return
            }
            #expect(provider == .gmail)
            #expect(action == .markAsRead)
        }
        #expect(remoteCallCount == 1)
        #expect(email.isRead)
        #expect(
            MailboxMutationStore(defaults: defaults, queue: .acknowledged).mutations == [
                PendingMailboxMutation(
                    providerRawValue: MailProvider.gmail.rawValue,
                    providerMessageID: "message-id",
                    action: .markAsRead,
                    expectedGlobalMessageID: "global-message-id"
                )
            ]
        )

        context.rollback()
        let replayFailureContext = ModelContext(container)
        let replayFailureStore = MailboxLocalStore(
            defaults: defaults,
            saveContext: { _ in throw MailboxMutationTestError.save }
        )
        #expect(throws: MailboxMutationTestError.save) {
            try replayFailureStore.replayPendingMutations(in: replayFailureContext)
        }
        let stillUnread = try #require(
            replayFailureContext.fetch(FetchDescriptor<EmailMessage>()).first
        )
        #expect(!stillUnread.isRead)
        #expect(!MailboxMutationStore(defaults: defaults, queue: .acknowledged).mutations.isEmpty)

        let replayContext = ModelContext(container)
        let replayStore = MailboxLocalStore(
            defaults: defaults,
            saveContext: { try $0.save() }
        )
        try replayStore.replayPendingMutations(in: replayContext)
        let replayed = try #require(
            replayContext.fetch(FetchDescriptor<EmailMessage>()).first
        )
        #expect(replayed.isRead)
        #expect(!replayed.labelIDs.contains("UNREAD"))
        #expect(MailboxMutationStore(defaults: defaults, queue: .acknowledged).mutations.isEmpty)
        #expect(remoteCallCount == 1)
    }

    @Test("trash remote failure keeps the row and success hides its retained cache")
    func testTrashOrderingAndRemoteFailure() async throws {
        let failedContainer = try makeContainer()
        let failedContext = ModelContext(failedContainer)
        let failedEmail = try insertEmail(provider: .gmail, into: failedContext)
        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: { try $0.save() }
        )

        await #expect(throws: MailboxMutationTestError.remote) {
            try await store.trash(failedEmail, in: failedContext) {
                throw MailboxMutationTestError.remote
            }
        }
        #expect(failedEmail.isInInbox)
        #expect(try failedContext.fetch(FetchDescriptor<EmailMessage>()).count == 1)

        let successContainer = try makeContainer()
        let successContext = ModelContext(successContainer)
        let successEmail = try insertEmail(provider: .gmail, into: successContext)
        successEmail.analysisKeyPoints = ["Retained after trash"]
        try successContext.save()
        var observedBeforeLocalHide = false
        var remoteCallCount = 0
        try await store.trash(successEmail, in: successContext) {
            remoteCallCount += 1
            observedBeforeLocalHide = successEmail.isInInbox
                && !successEmail.isDeleted
        }
        #expect(observedBeforeLocalHide)
        #expect(remoteCallCount == 1)
        let retained = try #require(successContext.fetch(FetchDescriptor<EmailMessage>()).first)
        #expect(!retained.isInInbox)
        #expect(retained.analysisKeyPoints == ["Retained after trash"])
    }

    @Test("trash local save failure leaves pending and replay hides the retained row")
    func testTrashLocalSaveFailureReplaysWithoutRemoteRetry() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = try insertEmail(provider: .gmail, into: context)
        email.analysisKeyPoints = ["Retained after replay"]
        try context.save()
        let defaults = try makeDefaults()
        var remoteCallCount = 0
        let failingStore = MailboxLocalStore(
            defaults: defaults,
            saveContext: { _ in throw MailboxMutationTestError.save }
        )

        do {
            try await failingStore.trash(email, in: context) {
                remoteCallCount += 1
            }
            Issue.record("Expected local save failure")
        } catch let error as MailboxMutationError {
            guard case .remoteCommittedLocalSaveFailed(let provider, let action) = error else {
                Issue.record("Unexpected mailbox mutation error")
                return
            }
            #expect(provider == .gmail)
            #expect(action == .trash)
        }
        #expect(remoteCallCount == 1)
        #expect(!email.isInInbox)
        #expect(
            MailboxMutationStore(defaults: defaults, queue: .acknowledged).mutations.contains(
                PendingMailboxMutation(
                    providerRawValue: MailProvider.gmail.rawValue,
                    providerMessageID: "message-id",
                    action: .trash,
                    expectedGlobalMessageID: "global-message-id"
                )
            )
        )

        context.rollback()
        let replayContext = ModelContext(container)
        let replayStore = MailboxLocalStore(
            defaults: defaults,
            saveContext: { try $0.save() }
        )
        try replayStore.replayPendingMutations(in: replayContext)
        let replayed = try #require(replayContext.fetch(FetchDescriptor<EmailMessage>()).first)
        #expect(!replayed.isInInbox)
        #expect(replayed.analysisKeyPoints == ["Retained after replay"])
        #expect(MailboxMutationStore(defaults: defaults, queue: .acknowledged).mutations.isEmpty)
        #expect(remoteCallCount == 1)
    }

    @Test("new deletion replaces the undo action and returns the superseded batch for commit")
    func testLatestDeletionReplacesUndoAction() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let first = try insertEmail(provider: .gmail, into: context)
        let second = try insertEmail(provider: .outlook, into: context)
        var queue = MailTrashUndoQueue()

        let firstBatch = queue.enqueue([first])
        let replacement = queue.replaceUndoableBatch(with: [second], mutations: [])

        #expect(replacement.superseded.map(\.id) == [firstBatch.id])
        #expect(queue.latestUndoableBatch?.id == replacement.latest.id)
        #expect(queue.pendingEmailIDs == Set([second.localListID]))

        let committing = queue.beginCommit(id: replacement.latest.id)
        #expect(committing?.phase == .committing)
        #expect(queue.latestUndoableBatch == nil)
    }

    @Test("local-first trash hides immediately and undo restores the cached row")
    func testStageTrashAndUndoAreLocalFirst() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = try insertEmail(provider: .gmail, into: context)
        let defaults = try makeDefaults()
        let store = MailboxLocalStore(
            defaults: defaults,
            saveContext: { try $0.save() }
        )

        let mutations = try store.stageTrash([email], in: context)

        #expect(!email.isInInbox)
        #expect(try context.fetch(FetchDescriptor<EmailMessage>()).count == 1)
        #expect(store.stagedTrashMutations == mutations)

        #expect(try store.restoreStagedTrash([email], mutations: mutations, in: context))

        #expect(email.isInInbox)
        #expect(store.stagedTrashMutations.isEmpty)
    }

    @Test("detail-style trash hides locally before the remote IMAP request")
    func testDetailStyleTrashHidesBeforeRemoteFlush() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = try insertEmail(provider: .gmail, into: context)
        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: { try $0.save() }
        )

        let mutations = try store.stageTrash([email], in: context)
        #expect(!email.isInInbox)

        var remoteObservedLocalHide = false
        let flushed = await store.flushStagedTrash(
            mutations,
            now: .distantFuture
        ) { _ in
            remoteObservedLocalHide = !email.isInInbox
        }

        #expect(flushed == 1)
        #expect(remoteObservedLocalHide)
        #expect(store.stagedTrashMutations.isEmpty)
    }

    @Test("Outlook trash without a persisted Message-ID is rejected before local staging")
    func testStageTrashRejectsOutlookWithoutMessageIdentity() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = try insertEmail(provider: .outlook, into: context)
        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: { try $0.save() }
        )

        #expect(throws: MailboxMutationError.self) {
            _ = try store.stageTrash([email], in: context)
        }
        #expect(email.isInInbox)
        #expect(store.stagedTrashMutations.isEmpty)
    }

    @Test("an Outlook UID reuse cannot apply a staged-trash mask to a new Message-ID")
    func testStagedOutlookTrashMaskRequiresOriginalMessageIdentity() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = try insertEmail(provider: .outlook, into: context)
        email.providerGlobalMessageID = "original-message-id"
        try context.save()
        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: { try $0.save() }
        )
        let mutations = try store.stageTrash([email], in: context, now: .distantPast)

        email.providerGlobalMessageID = "reused-uid-new-message-id"
        email.isInInbox = true
        try context.save()
        try store.replayPendingMutations(in: context)

        #expect(email.isInInbox)
        #expect(store.stagedTrashMutations == mutations)
    }

    @Test("Outlook UID reuse in upsert clears stale body and analysis when identity changes")
    func testOutlookUIDReuseClearsStaleBodyAndAnalysis() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = try insertEmail(provider: .outlook, into: context)
        email.providerGlobalMessageID = "msg-1"
        email.body = "Old body"
        email.htmlBody = "<p>Old body</p>"
        email.analysisState = .analyzed
        email.analysisSummary = "Old summary"
        try context.save()

        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: { try $0.save() }
        )

        let newMetadata = MailboxMessageMetadata(
            provider: .outlook,
            providerMessageID: email.providerMessageID,
            providerGlobalMessageID: "msg-2",
            sourceAccountNamespace: email.sourceAccountNamespace,
            threadID: "",
            subject: "New Subject",
            from: "sender@outlook.com",
            snippet: "New snippet",
            receivedAt: Date(),
            isRead: false,
            isInInbox: true,
            gmailLabelIDs: [],
            outlookInferenceClassificationRawValue: "",
            providerCategoryNames: [],
            providerFolderID: "INBOX"
        )

        try store.upsert(MailboxPage(messages: [newMetadata], nextCursor: nil), into: context)

        #expect(email.providerGlobalMessageID == "msg-2")
        #expect(email.subject == "New Subject")
        #expect(email.body.isEmpty)
        #expect(email.htmlBody == nil)
        #expect(email.analysisState == .unanalyzed)
        #expect(email.analysisSummary.isEmpty)
    }
    @Test("legacy Outlook row without providerGlobalMessageID clears body and analysis on UID reuse with header mismatch")
    func testLegacyOutlookUIDReuseClearsBodyAndAnalysisOnHeaderMismatch() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = try insertEmail(provider: .outlook, into: context)
        email.providerGlobalMessageID = ""
        email.subject = "Old Legacy Subject"
        email.from = "old@example.com"
        email.receivedAt = Date(timeIntervalSince1970: 1_000)
        email.body = "Old legacy body"
        email.htmlBody = "<p>Old legacy body</p>"
        email.analysisState = .analyzed
        email.analysisSummary = "Old summary"
        try context.save()

        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: { try $0.save() }
        )

        let newMetadata = MailboxMessageMetadata(
            provider: .outlook,
            providerMessageID: email.providerMessageID,
            providerGlobalMessageID: "msg-reused-uid",
            sourceAccountNamespace: email.sourceAccountNamespace,
            threadID: "",
            subject: "Reused UID New Subject",
            from: "new@example.com",
            snippet: "New snippet",
            receivedAt: Date(timeIntervalSince1970: 2_000),
            isRead: false,
            isInInbox: true,
            gmailLabelIDs: [],
            outlookInferenceClassificationRawValue: "",
            providerCategoryNames: [],
            providerFolderID: "INBOX"
        )

        try store.upsert(MailboxPage(messages: [newMetadata], nextCursor: nil), into: context)

        #expect(email.providerGlobalMessageID == "msg-reused-uid")
        #expect(email.subject == "Reused UID New Subject")
        #expect(email.body.isEmpty)
        #expect(email.htmlBody == nil)
        #expect(email.analysisState == .unanalyzed)
        #expect(email.analysisSummary.isEmpty)
    }

    @Test("updateContent rejects mismatched providerGlobalMessageID")
    func testUpdateContentRejectsMismatchedGlobalMessageID() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = try insertEmail(provider: .outlook, into: context)
        email.providerGlobalMessageID = "msg-1"
        try context.save()

        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: { try $0.save() }
        )

        let contentMetadata = MailboxMessageMetadata(
            provider: .outlook,
            providerMessageID: email.providerMessageID,
            providerGlobalMessageID: "msg-2",
            sourceAccountNamespace: email.sourceAccountNamespace,
            threadID: "",
            subject: "New Subject",
            from: "sender@outlook.com",
            snippet: "New snippet",
            receivedAt: Date(),
            isRead: false,
            isInInbox: true,
            gmailLabelIDs: [],
            outlookInferenceClassificationRawValue: "",
            providerCategoryNames: [],
            providerFolderID: "INBOX"
        )
        let content = MailboxMessageContent(metadata: contentMetadata, body: "New body", htmlBody: "")

        #expect(throws: MailboxLocalStoreError.contentIdentityMismatch) {
            try store.updateContent(content, for: email, in: context)
        }
    }

    @Test("superseded trash flushes immediately before its undo deadline")
    func testSupersededTrashForcesImmediateRemoteFlush() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = try insertEmail(provider: .gmail, into: context)
        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: { try $0.save() }
        )
        let mutations = try store.stageTrash([email], in: context)
        var remoteCalls = 0

        let flushed = await store.flushStagedTrash(
            mutations,
            now: .distantFuture
        ) { _ in
            remoteCalls += 1
        }

        #expect(flushed == 1)
        #expect(remoteCalls == 1)
        #expect(store.stagedTrashMutations.isEmpty)
    }

    @Test("deferred trash flush retries remote failures without restoring the local row")
    func testStagedTrashFlushPersistsUntilRemoteSuccess() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = try insertEmail(provider: .gmail, into: context)
        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: { try $0.save() }
        )
        let stagedAt = Date(timeIntervalSince1970: 1_000)
        let mutations = try store.stageTrash([email], in: context, now: stagedAt)
        var remoteCalls = 0

        let earlyFlushes = await store.flushStagedTrash(
            mutations,
            now: stagedAt.addingTimeInterval(4)
        ) { _ in
            remoteCalls += 1
        }

        #expect(earlyFlushes == 0)
        #expect(remoteCalls == 0)

        let failedFlushes = await store.flushStagedTrash(
            mutations,
            now: stagedAt.addingTimeInterval(5)
        ) { _ in
            remoteCalls += 1
            throw MailboxMutationTestError.remote
        }

        #expect(failedFlushes == 0)
        #expect(remoteCalls == 1)
        #expect(!email.isInInbox)
        #expect(store.stagedTrashMutations == mutations)

        let successfulFlushes = await store.flushStagedTrash(
            mutations,
            now: stagedAt.addingTimeInterval(5)
        ) { _ in
            remoteCalls += 1
        }

        #expect(successfulFlushes == 1)
        #expect(remoteCalls == 2)
        #expect(!email.isInInbox)
        #expect(store.stagedTrashMutations.isEmpty)
    }

    @Test("cancelled remote read restores the unread state before any later save")
    func cancelledReadRollsBackOptimisticState() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let email = try insertEmail(provider: .gmail, into: context)
        let store = MailboxLocalStore(defaults: try makeDefaults(), saveContext: { try $0.save() })

        await #expect(throws: CancellationError.self) {
            try await store.markAsRead(email, in: context) { throw CancellationError() }
        }
        try context.save()
        let persisted = try #require(ModelContext(container).fetch(FetchDescriptor<EmailMessage>()).first)
        #expect(!persisted.isRead)
        #expect(persisted.labelIDs.contains("UNREAD"))
    }

    @Test("provider acknowledgement is persisted even if the caller is cancelled", arguments: [MailboxMutationAction.markAsRead, .trash])
    func acknowledgedMutationSurvivesLateCancellation(action: MailboxMutationAction) async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let email = try insertEmail(provider: .gmail, into: context)
        let store = MailboxLocalStore(defaults: try makeDefaults(), saveContext: { try $0.save() })

        let operation = Task { @MainActor in
            let acknowledge: () async throws -> Void = {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            switch action {
            case .markAsRead: try await store.markAsRead(email, in: context, remote: acknowledge)
            case .trash: try await store.trash(email, in: context, remote: acknowledge)
            }
        }
        try await operation.value
        let persisted = try #require(ModelContext(container).fetch(FetchDescriptor<EmailMessage>()).first)
        switch action {
        case .markAsRead:
            #expect(persisted.isRead)
            #expect(!persisted.labelIDs.contains("UNREAD"))
        case .trash:
            #expect(!persisted.isInInbox)
        }
    }

    @Test("a cancelled deferred batch stops and releases all leases for retry")
    func cancelledDeferredBatchRetainsRetryableMutations() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let first = try insertEmail(provider: .gmail, into: context)
        let second = try insertEmail(provider: .gmail, into: context)
        second.id = "gmail-imap:second-global-id"
        second.rawMessageID = "second-message-id"
        try context.save()
        let store = MailboxLocalStore(defaults: try makeDefaults(), saveContext: { try $0.save() })
        let mutations = try store.stageTrash([first, second], in: context, now: .distantPast)
        var attempts = 0
        let cancelled = await store.flushStagedTrash(mutations, now: .distantFuture) { _ in
            attempts += 1
            throw CancellationError()
        }
        #expect(cancelled == 0)
        #expect(attempts == 1)
        #expect(store.stagedTrashMutations == mutations)
        let retried = await store.flushStagedTrash(mutations, now: .distantFuture) { _ in }
        #expect(retried == 2)
        #expect(store.stagedTrashMutations.isEmpty)
    }
}
