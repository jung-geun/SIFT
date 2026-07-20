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
            id: "message-id",
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
            MailboxPendingMutationStore(defaults: defaults).mutations == [
                PendingMailboxMutation(
                    providerRawValue: MailProvider.gmail.rawValue,
                    providerMessageID: "message-id",
                    action: .markAsRead
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
        #expect(!MailboxPendingMutationStore(defaults: defaults).mutations.isEmpty)

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
        #expect(MailboxPendingMutationStore(defaults: defaults).mutations.isEmpty)
        #expect(remoteCallCount == 1)
    }

    @Test("trash remote 실패는 row를 유지하고 성공은 remote 뒤 local delete한다")
    func testTrashOrderingAndRemoteFailure() async throws {
        let failedContainer = try makeContainer()
        let failedContext = ModelContext(failedContainer)
        let failedEmail = try insertEmail(provider: .outlook, into: failedContext)
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
        let successEmail = try insertEmail(provider: .outlook, into: successContext)
        var observedBeforeLocalDelete = false
        var remoteCallCount = 0
        try await store.trash(successEmail, in: successContext) {
            remoteCallCount += 1
            observedBeforeLocalDelete = successEmail.isInInbox
                && !successEmail.isDeleted
        }
        #expect(observedBeforeLocalDelete)
        #expect(remoteCallCount == 1)
        #expect(try successContext.fetch(FetchDescriptor<EmailMessage>()).isEmpty)
    }

    @Test("trash local save 실패는 pending을 남기고 replay가 row를 삭제한다")
    func testTrashLocalSaveFailureReplaysWithoutRemoteRetry() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = try insertEmail(provider: .outlook, into: context)
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
            #expect(provider == .outlook)
            #expect(action == .trash)
        }
        #expect(remoteCallCount == 1)
        #expect(!email.isInInbox)
        #expect(
            MailboxPendingMutationStore(defaults: defaults).mutations.contains(
                PendingMailboxMutation(
                    providerRawValue: MailProvider.outlook.rawValue,
                    providerMessageID: "message-id",
                    action: .trash
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
        #expect(try replayContext.fetch(FetchDescriptor<EmailMessage>()).isEmpty)
        #expect(MailboxPendingMutationStore(defaults: defaults).mutations.isEmpty)
        #expect(remoteCallCount == 1)
    }
}
