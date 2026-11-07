import Foundation
import SwiftData
import Testing
@testable import todo

final class ScriptedPagingProvider: MailboxPagingProvider {
    let provider: MailProvider
    var fetchInboxPageCalls: [String?] = []
    var fetchInboxUpdatesCalls: [String] = []
    var fetchInboxMessageIDsCalls: Int = 0
    var trashMessageIDs: [String] = []

    var pageResponses: [MailboxPage] = []
    var updateResponses: [MailboxPage] = []
    var updateError: Error?
    var suspendNextUpdate: Bool = false
    var suspendNextTrash: Bool = false
    var trashError: Error?
    private var trashContinuations: [CheckedContinuation<Void, Error>] = []
    private var updateContinuations: [CheckedContinuation<MailboxPage, Error>] = []
    var messageIDsResponse: Set<String> = []
    var messageIDsError: Error?
    var contentCalls: [String] = []
    var contentResponses: [String: MailboxMessageContent] = [:]
    var contentErrors: [String: Error] = [:]
    var suspendNextContent = false
    private var contentContinuation: CheckedContinuation<Void, Never>?

    init(provider: MailProvider) {
        self.provider = provider
    }

    func fetchInboxPage(after cursor: String?) async throws -> MailboxPage {
        fetchInboxPageCalls.append(cursor)
        if !pageResponses.isEmpty { return pageResponses.removeFirst() }
        return MailboxPage(messages: [], nextCursor: nil, newestCursor: "baseline:1")
    }

    func fetchInboxUpdates(newerThan cursor: String) async throws -> MailboxPage {
        fetchInboxUpdatesCalls.append(cursor)
        if let updateError { throw updateError }
        if suspendNextUpdate {
            suspendNextUpdate = false
            return try await withCheckedThrowingContinuation { continuation in
                updateContinuations.append(continuation)
            }
        }
        if !updateResponses.isEmpty { return updateResponses.removeFirst() }
        return MailboxPage(messages: [], nextCursor: nil, newestCursor: nil, hasMoreUpdates: false)
    }

    func waitUntilSuspended() async {
        while updateContinuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeUpdate(with page: MailboxPage) {
        guard !updateContinuations.isEmpty else { return }
        let c = updateContinuations.removeFirst()
        c.resume(returning: page)
    }

    func resumeUpdate(throwing error: Error) {
        guard !updateContinuations.isEmpty else { return }
        let c = updateContinuations.removeFirst()
        c.resume(throwing: error)
    }

    func fetchInboxMessageIDs() async throws -> Set<String> {
        fetchInboxMessageIDsCalls += 1
        if let messageIDsError { throw messageIDsError }
        return messageIDsResponse
    }

    func fetchMessageContent(messageID: String) async throws -> MailboxMessageContent {
        contentCalls.append(messageID)
        if suspendNextContent {
            suspendNextContent = false
            await withCheckedContinuation { contentContinuation = $0 }
        }
        try Task.checkCancellation()
        if let error = contentErrors[messageID] { throw error }
        if let content = contentResponses[messageID] { return content }
        let metadata = MailboxMessageMetadata(
            provider: provider, providerMessageID: messageID, sourceAccountNamespace: "user@gmail.com",
            threadID: "", subject: "", from: "", snippet: "", receivedAt: .distantPast,
            isRead: false, isInInbox: true, gmailLabelIDs: ["INBOX"],
            outlookInferenceClassificationRawValue: "", providerCategoryNames: [], providerFolderID: ""
        )
        return MailboxMessageContent(metadata: metadata, body: "Complete body \(messageID)", htmlBody: "")
    }

    func waitUntilContentSuspended() async {
        while contentContinuation == nil { await Task.yield() }
    }

    func resumeContent() {
        contentContinuation?.resume()
        contentContinuation = nil
    }

    func markAsRead(
        messageID _: String,
        expectedGlobalMessageID _: String?,
        expectedAccountNamespace _: String
    ) async throws {}

    func trashMessage(
        messageID: String,
        expectedGlobalMessageID _: String?,
        expectedAccountNamespace _: String
    ) async throws {
        trashMessageIDs.append(messageID)
        if let trashError { throw trashError }
        if suspendNextTrash {
            suspendNextTrash = false
            try await withCheckedThrowingContinuation { continuation in
                trashContinuations.append(continuation)
            }
        }
    }

    func waitUntilTrashSuspended() async {
        while trashContinuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeTrash() {
        guard !trashContinuations.isEmpty else { return }
        trashContinuations.removeFirst().resume()
    }
}

@Suite("MailboxIncrementalSyncCoordinator", .serialized)
@MainActor
struct MailboxIncrementalSyncCoordinatorTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([EmailMessage.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CoordinatorTests_\(UUID().uuidString)")!
    }


    @Test("cursor store isolates Gmail accounts and Outlook")
    func cursorStoreIsolation() {
        let defaults = makeDefaults()
        let store = MailboxUpdateCursorStore(defaults: defaults)

        store.setCursor("g1-cursor", for: .gmail, namespace: "user1@gmail.com")
        store.setCursor("g2-cursor", for: .gmail, namespace: "user2@gmail.com")
        store.setCursor("out-cursor", for: .outlook, namespace: "")

        #expect(store.cursor(for: .gmail, namespace: "user1@gmail.com") == "g1-cursor")
        #expect(store.cursor(for: .gmail, namespace: "user2@gmail.com") == "g2-cursor")
        #expect(store.cursor(for: .outlook, namespace: "") == "out-cursor")

        store.clearCursor(for: .gmail, namespace: "user1@gmail.com")
        #expect(store.cursor(for: .gmail, namespace: "user1@gmail.com") == nil)
        #expect(store.cursor(for: .gmail, namespace: "user2@gmail.com") == "g2-cursor")
        #expect(store.cursor(for: .outlook, namespace: "") == "out-cursor")
    }

    @Test("credential teardown clears a noncanonical raw Gmail cursor")
    func forgetCursorFallsBackToRawGmailAccount() throws {
        let defaults = makeDefaults()
        let cursorStore = MailboxUpdateCursorStore(defaults: defaults)
        let rawAccount = "not a canonical Gmail account"
        cursorStore.setCursor("42:100", for: .gmail, namespace: rawAccount)

        let container = try makeContainer()
        let context = ModelContext(container)
        let localStore = MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() })
        let provider = ScriptedPagingProvider(provider: .gmail)
        let coordinator = MailboxIncrementalSyncCoordinator(
            cursorStore: cursorStore,
            localStore: localStore,
            makeContext: { context },
            resolveProvider: { _ in provider },
            ensureReady: { _, _, _ in true },
            defaults: defaults
        )

        coordinator.forgetCursor(for: .gmail, rawAccount: rawAccount)

        #expect(cursorStore.cursor(for: .gmail, namespace: rawAccount) == nil)
    }

    @Test("first sync commits baseline head page and exactly one update round")
    func baselineAndOneUpdate() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let cursorStore = MailboxUpdateCursorStore(defaults: defaults)
        let container = try makeContainer()
        let context = ModelContext(container)
        let localStore = MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() })

        let gmailProvider = ScriptedPagingProvider(provider: .gmail)
        gmailProvider.pageResponses = [
            MailboxPage(messages: [], nextCursor: nil, newestCursor: "42:100")
        ]
        gmailProvider.updateResponses = [
            MailboxPage(messages: [], nextCursor: nil, newestCursor: "42:105", hasMoreUpdates: true)
        ]

        let coordinator = MailboxIncrementalSyncCoordinator(
            cursorStore: cursorStore,
            localStore: localStore,
            makeContext: { context },
            resolveProvider: { _ in gmailProvider },
            ensureReady: { _, _, _ in true },
            defaults: defaults
        )

        let result = await coordinator.sync(provider: .gmail)
        #expect(result == true)
        #expect(gmailProvider.fetchInboxPageCalls == [nil])
        // Baseline run executes exactly ONE update round, even though update returns hasMoreUpdates == true
        #expect(gmailProvider.fetchInboxUpdatesCalls.count == 1)
        #expect(gmailProvider.fetchInboxUpdatesCalls.first == "42:100")
        #expect(cursorStore.cursor(for: .gmail, namespace: "user@gmail.com") == "42:105")
    }

    @Test("background sync flushes an expired local-first trash request")
    func backgroundSyncFlushesExpiredStagedTrash() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let cursorStore = MailboxUpdateCursorStore(defaults: defaults)
        let container = try makeContainer()
        let context = ModelContext(container)
        let localStore = MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() })
        let email = EmailMessage(
            id: "gmail-imap:900",
            subject: "Deferred Trash",
            provider: .gmail,
            rawMessageID: "7",
            labelIDs: ["INBOX"],
            isInInbox: true,
            sourceAccountNamespace: "user@gmail.com"
        )
        context.insert(email)
        try context.save()
        _ = try localStore.stageTrash([email], in: context, now: .distantPast)

        let gmailProvider = ScriptedPagingProvider(provider: .gmail)
        gmailProvider.pageResponses = [
            MailboxPage(messages: [], nextCursor: nil, newestCursor: "42:100")
        ]
        let coordinator = MailboxIncrementalSyncCoordinator(
            cursorStore: cursorStore,
            localStore: localStore,
            makeContext: { context },
            resolveProvider: { _ in gmailProvider },
            ensureReady: { _, _, _ in true },
            defaults: defaults
        )

        let synced = await coordinator.sync(provider: .gmail)
        #expect(synced)
        #expect(gmailProvider.trashMessageIDs == ["7"])
        #expect(!email.isInInbox)
        #expect(localStore.stagedTrashMutations.isEmpty)
    }

    @Test("Gmail deferred trash keeps a mutation when remote identity verification fails")
    func gmailDeferredTrashRetainsMailboxReset() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let cursorStore = MailboxUpdateCursorStore(defaults: defaults)
        let container = try makeContainer()
        let context = ModelContext(container)
        let localStore = MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() })
        let email = EmailMessage(
            id: "gmail-imap:900",
            subject: "Identity Mismatch",
            provider: .gmail,
            rawMessageID: "7",
            labelIDs: ["INBOX"],
            isInInbox: true,
            sourceAccountNamespace: "user@gmail.com"
        )
        context.insert(email)
        try context.save()
        _ = try localStore.stageTrash([email], in: context, now: .distantPast)

        let gmailProvider = ScriptedPagingProvider(provider: .gmail)
        gmailProvider.trashError = GmailIMAPError.mailboxReset
        let coordinator = MailboxIncrementalSyncCoordinator(
            cursorStore: cursorStore,
            localStore: localStore,
            makeContext: { context },
            resolveProvider: { _ in gmailProvider },
            ensureReady: { _, _, _ in true },
            defaults: defaults
        )

        let synced = await coordinator.sync(provider: .gmail)

        #expect(synced)
        #expect(gmailProvider.trashMessageIDs == ["7"])
        #expect(localStore.stagedTrashMutations.count == 1)
    }

    @Test("sync claim prevents Undo from restoring a remotely deleting row")
    func syncClaimPreventsUndoInterleaving() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let cursorStore = MailboxUpdateCursorStore(defaults: defaults)
        let container = try makeContainer()
        let context = ModelContext(container)
        let localStore = MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() })
        let email = EmailMessage(
            id: "gmail-imap:900",
            subject: "Claimed Trash",
            provider: .gmail,
            rawMessageID: "7",
            labelIDs: ["INBOX"],
            isInInbox: true,
            sourceAccountNamespace: "user@gmail.com"
        )
        context.insert(email)
        try context.save()
        let stagedAt = Date(timeIntervalSince1970: 1_000)
        let mutations = try localStore.stageTrash([email], in: context, now: stagedAt)

        let gmailProvider = ScriptedPagingProvider(provider: .gmail)
        gmailProvider.suspendNextTrash = true
        gmailProvider.pageResponses = [
            MailboxPage(messages: [], nextCursor: nil, newestCursor: "42:100")
        ]
        let coordinator = MailboxIncrementalSyncCoordinator(
            cursorStore: cursorStore,
            localStore: localStore,
            makeContext: { context },
            resolveProvider: { _ in gmailProvider },
            ensureReady: { _, _, _ in true },
            defaults: defaults,
            now: { stagedAt.addingTimeInterval(5) }
        )

        let syncTask = Task { await coordinator.sync(provider: .gmail) }
        await gmailProvider.waitUntilTrashSuspended()

        let restored = try localStore.restoreStagedTrash(
            [email],
            mutations: mutations,
            in: context,
            now: stagedAt.addingTimeInterval(1)
        )
        #expect(!restored)
        #expect(!email.isInInbox)
        #expect(localStore.stagedTrashMutations == mutations)

        gmailProvider.resumeTrash()
        #expect(await syncTask.value)
        #expect(gmailProvider.trashMessageIDs == ["7"])
        #expect(!email.isInInbox)
        #expect(localStore.stagedTrashMutations.isEmpty)
    }

    @Test("drain loop stops at 10 page cap and second run resumes with 11th page")
    func tenPageCap() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let cursorStore = MailboxUpdateCursorStore(defaults: defaults)
        cursorStore.setCursor("42:100", for: .gmail, namespace: "user@gmail.com")

        let container = try makeContainer()
        let context = ModelContext(container)
        let localStore = MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() })

        let gmailProvider = ScriptedPagingProvider(provider: .gmail)
        // 11 synthetic update pages
        gmailProvider.updateResponses = (1...11).map { i in
            MailboxPage(messages: [], nextCursor: nil, newestCursor: "42:\(100 + i)", hasMoreUpdates: true)
        }

        let coordinator = MailboxIncrementalSyncCoordinator(
            cursorStore: cursorStore,
            localStore: localStore,
            makeContext: { context },
            resolveProvider: { _ in gmailProvider },
            ensureReady: { _, _, _ in true },
            defaults: defaults
        )

        // Run 1: should process 10 pages and stop
        let res1 = await coordinator.sync(provider: .gmail)
        #expect(res1 == true)
        #expect(gmailProvider.fetchInboxUpdatesCalls.count == 10)
        #expect(cursorStore.cursor(for: .gmail, namespace: "user@gmail.com") == "42:110")

        // Run 2: should process 11th page
        let res2 = await coordinator.sync(provider: .gmail)
        #expect(res2 == true)
        #expect(gmailProvider.fetchInboxUpdatesCalls.count == 12)
        #expect(cursorStore.cursor(for: .gmail, namespace: "user@gmail.com") == "42:111")
    }

    @Test("commit failure or provider error leaves prior durable cursor unchanged")
    func commitFailuresLeaveCursorIntact() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let cursorStore = MailboxUpdateCursorStore(defaults: defaults)
        cursorStore.setCursor("42:100", for: .gmail, namespace: "user@gmail.com")

        let container = try makeContainer()
        let context = ModelContext(container)

        // 1. Failing save context
        let failingLocalStore = MailboxLocalStore(
            defaults: defaults,
            saveContext: { _ in throw CocoaError(.fileWriteUnknown) }
        )

        let gmailProvider = ScriptedPagingProvider(provider: .gmail)
        gmailProvider.updateResponses = [
            MailboxPage(messages: [], nextCursor: nil, newestCursor: "42:105")
        ]

        let coordinator = MailboxIncrementalSyncCoordinator(
            cursorStore: cursorStore,
            localStore: failingLocalStore,
            makeContext: { context },
            resolveProvider: { _ in gmailProvider },
            ensureReady: { _, _, _ in true },
            defaults: defaults
        )

        let res = await coordinator.sync(provider: .gmail)
        #expect(res == false)
        #expect(cursorStore.cursor(for: .gmail, namespace: "user@gmail.com") == "42:100")

        // 2. Provider / decoder error throws during fetchInboxUpdates
        let localStore = MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() })
        let gmailProviderError = ScriptedPagingProvider(provider: .gmail)
        gmailProviderError.updateError = GmailIMAPError.invalidResponse

        let coordinatorError = MailboxIncrementalSyncCoordinator(
            cursorStore: cursorStore,
            localStore: localStore,
            makeContext: { context },
            resolveProvider: { _ in gmailProviderError },
            ensureReady: { _, _, _ in true },
            defaults: defaults
        )

        let resError = await coordinatorError.sync(provider: .gmail)
        #expect(resError == false)
        #expect(cursorStore.cursor(for: .gmail, namespace: "user@gmail.com") == "42:100")
    }

    @Test("requiresInboxReconcile invokes message ID fetch and gates cursor advancement")
    func reconcileGating() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let cursorStore = MailboxUpdateCursorStore(defaults: defaults)
        cursorStore.setCursor("42:100", for: .gmail, namespace: "user@gmail.com")

        let container = try makeContainer()
        let context = ModelContext(container)
        let localStore = MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() })

        // 1. Reconcile message ID fetch throws -> cursor MUST NOT advance
        let gmailProviderFail = ScriptedPagingProvider(provider: .gmail)
        gmailProviderFail.updateResponses = [
            MailboxPage(messages: [], nextCursor: nil, newestCursor: "42:200", requiresInboxReconcile: true)
        ]
        gmailProviderFail.messageIDsError = CocoaError(.fileReadUnknown)

        let coordinatorFail = MailboxIncrementalSyncCoordinator(
            cursorStore: cursorStore,
            localStore: localStore,
            makeContext: { context },
            resolveProvider: { _ in gmailProviderFail },
            ensureReady: { _, _, _ in true },
            defaults: defaults
        )

        let resFail = await coordinatorFail.sync(provider: .gmail)
        #expect(resFail == false)
        #expect(cursorStore.cursor(for: .gmail, namespace: "user@gmail.com") == "42:100")

        // 2. Reconcile succeeds -> hides stale rows and advances cursor
        let existingEmail = EmailMessage(
            id: "stale-1",
            subject: "Stale Email",
            provider: .gmail,
            rawMessageID: "stale-1",
            labelIDs: ["INBOX"],
            isInInbox: true,
            sourceAccountNamespace: "user@gmail.com"
        )
        context.insert(existingEmail)
        try context.save()

        let gmailProviderOK = ScriptedPagingProvider(provider: .gmail)
        gmailProviderOK.updateResponses = [
            MailboxPage(messages: [], nextCursor: nil, newestCursor: "42:200", requiresInboxReconcile: true)
        ]
        // active message IDs does not include "stale-1"
        gmailProviderOK.messageIDsResponse = ["active-1"]

        let coordinatorOK = MailboxIncrementalSyncCoordinator(
            cursorStore: cursorStore,
            localStore: localStore,
            makeContext: { context },
            resolveProvider: { _ in gmailProviderOK },
            ensureReady: { _, _, _ in true },
            defaults: defaults
        )

        let resOK = await coordinatorOK.sync(provider: .gmail)
        #expect(resOK == true)
        #expect(gmailProviderOK.fetchInboxMessageIDsCalls == 1)
        #expect(!existingEmail.isInInbox)
        #expect(cursorStore.cursor(for: .gmail, namespace: "user@gmail.com") == "42:200")
    }

    @Test("minimum interval throttling and in-flight guard deduplicate sync calls")
    func throttlingGuards() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let cursorStore = MailboxUpdateCursorStore(defaults: defaults)
        cursorStore.setCursor("42:100", for: .gmail, namespace: "user@gmail.com")

        let container = try makeContainer()
        let context = ModelContext(container)
        let localStore = MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() })

        var currentTime = Date(timeIntervalSince1970: 1_000_000)
        let gmailProvider = ScriptedPagingProvider(provider: .gmail)
        gmailProvider.updateResponses = [
            MailboxPage(messages: [], nextCursor: nil, newestCursor: "42:101"),
            MailboxPage(messages: [], nextCursor: nil, newestCursor: "42:102")
        ]

        let coordinator = MailboxIncrementalSyncCoordinator(
            cursorStore: cursorStore,
            localStore: localStore,
            makeContext: { context },
            resolveProvider: { _ in gmailProvider },
            ensureReady: { _, _, _ in true },
            defaults: defaults,
            now: { currentTime }
        )

        // Call 1 at time T=0
        let r1 = await coordinator.sync(provider: .gmail, minimumInterval: 30)
        #expect(r1 == true)
        #expect(gmailProvider.fetchInboxUpdatesCalls.count == 1)

        // Call 2 at time T=10s (< 30s) -> throttled
        currentTime = Date(timeIntervalSince1970: 1_000_010)
        let r2 = await coordinator.sync(provider: .gmail, minimumInterval: 30)
        #expect(r2 == true) // Healthy throttling is not a synchronization failure.
        #expect(gmailProvider.fetchInboxUpdatesCalls.count == 1)

        // Call 3 at time T=35s (>= 30s) -> allowed
        currentTime = Date(timeIntervalSince1970: 1_000_035)
        let r3 = await coordinator.sync(provider: .gmail, minimumInterval: 30)
        #expect(r3 == true)
        #expect(gmailProvider.fetchInboxUpdatesCalls.count == 2)

        // Call 4 suspended mid-flight, Call 5 invoked concurrently -> deduplicated by in-flight guard
        gmailProvider.suspendNextUpdate = true
        let task4 = Task {
            await coordinator.sync(provider: .gmail, minimumInterval: 0)
        }
        await gmailProvider.waitUntilSuspended()

        let task5 = Task { await coordinator.sync(provider: .gmail, minimumInterval: 0) }
        for _ in 0..<10 { await Task.yield() }
        #expect(gmailProvider.fetchInboxUpdatesCalls.count == 3)

        gmailProvider.resumeUpdate(with: MailboxPage(messages: [], nextCursor: nil, newestCursor: "42:103"))
        let r4 = await task4.value
        #expect(r4 == true)
        #expect(await task5.value)
        #expect(gmailProvider.fetchInboxUpdatesCalls.count == 3)
        #expect(cursorStore.cursor(for: .gmail, namespace: "user@gmail.com") == "42:103")
    }

}

@MainActor
extension MailboxIncrementalSyncCoordinatorTests {
    private func insertBodyBacklog(_ count: Int, in context: ModelContext) throws {
        for index in 1...count {
            let email = EmailMessage(
                id: "mail-\(index)", body: "Legacy cached prefix",
                receivedAt: Date(timeIntervalSince1970: Double(index)),
                provider: .gmail, rawMessageID: String(index), isInInbox: true,
                sourceAccountNamespace: "user@gmail.com"
            )
            context.insert(email)
        }
        try context.save()
    }

    @Test("prefetch is bounded, skips durable complete bodies and continues the latest backlog without AI")
    func boundedDurableBodyBacklog() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        defaults.set(false, forKey: "pieroot.todo.emailAutoAnalysisEnabled")
        defaults.set(false, forKey: "pieroot.todo.onDeviceLLMEnabled")
        let container = try makeContainer()
        let context = ModelContext(container)
        try insertBodyBacklog(20, in: context)
        let provider = ScriptedPagingProvider(provider: .gmail)
        let store = MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() })
        let coordinator = MailboxIncrementalSyncCoordinator(
            localStore: store, makeContext: { context }, resolveProvider: { _ in provider },
            ensureReady: { _, _, _ in true }, defaults: defaults
        )
        #expect(await coordinator.prefetchBodies(provider: .gmail))
        #expect(provider.contentCalls == (13...20).reversed().map(String.init))
        #expect(await coordinator.prefetchBodies(provider: .gmail))
        #expect(provider.contentCalls.count == MailboxPagingPolicy.bodyPrefetchBatchSize)
        let reloadedContext = ModelContext(container)
        let reloaded = try reloadedContext.fetch(FetchDescriptor<EmailMessage>())
        #expect(reloaded.filter(\.hasCompleteBody).count == MailboxPagingPolicy.bodyPrefetchBatchSize)
        #expect(reloaded.allSatisfy { $0.analysisState == .unanalyzed })
        let restarted = MailboxIncrementalSyncCoordinator(
            localStore: store, makeContext: { reloadedContext }, resolveProvider: { _ in provider },
            ensureReady: { _, _, _ in true }, defaults: defaults
        )
        #expect(await restarted.prefetchBodies(provider: .gmail))
        #expect(provider.contentCalls == (5...20).reversed().map(String.init))
        #expect(provider.contentCalls.count == Set(provider.contentCalls).count)
    }

    @Test("metadata sync also caches complete bodies while automatic analysis is disabled")
    func metadataSyncPrefetchesWithoutAI() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        defaults.set(false, forKey: "pieroot.todo.emailAutoAnalysisEnabled")
        let container = try makeContainer()
        let context = ModelContext(container)
        try insertBodyBacklog(2, in: context)
        let provider = ScriptedPagingProvider(provider: .gmail)
        let coordinator = MailboxIncrementalSyncCoordinator(
            localStore: MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() }),
            makeContext: { context }, resolveProvider: { _ in provider },
            ensureReady: { _, _, _ in true }, defaults: defaults
        )
        #expect(await coordinator.sync(provider: .gmail, backgroundOnly: true))
        #expect(provider.contentCalls == ["2", "1"])
        #expect(try context.fetch(FetchDescriptor<EmailMessage>()).allSatisfy(\.hasCompleteBody))
    }

    @Test("body batches coalesce while the same account's discovery continues independently")
    func bodyBatchCoalescesConcurrentRequests() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let container = try makeContainer()
        let context = ModelContext(container)
        try insertBodyBacklog(12, in: context)
        let provider = ScriptedPagingProvider(provider: .gmail)
        provider.suspendNextContent = true
        let coordinator = MailboxIncrementalSyncCoordinator(
            localStore: MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() }),
            makeContext: { context }, resolveProvider: { _ in provider },
            ensureReady: { _, _, _ in true }, defaults: defaults
        )
        let first = Task { await coordinator.prefetchBodies(provider: .gmail) }
        await provider.waitUntilContentSuspended()
        #expect(await coordinator.discover(provider: .gmail))
        #expect(provider.fetchInboxPageCalls.count == 1)
        let scheduled = Task { await coordinator.sync(provider: .gmail) }
        let duplicate = Task { await coordinator.prefetchBodies(provider: .gmail) }
        for _ in 0..<10 { await Task.yield() }
        #expect(provider.contentCalls == ["12"])
        provider.resumeContent()
        #expect(await first.value)
        #expect(await scheduled.value)
        #expect(await duplicate.value)
        #expect(provider.contentCalls.count == MailboxPagingPolicy.bodyPrefetchBatchSize)
    }

    @Test("account switch, session replacement, background revocation and cancellation cannot commit a suspended body",
          arguments: ["account", "generation", "background", "cancel"])
    func bodyCommitFences(reason: String) async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let container = try makeContainer()
        let context = ModelContext(container)
        try insertBodyBacklog(2, in: context)
        let provider = ScriptedPagingProvider(provider: .gmail)
        provider.suspendNextContent = true
        var ready = true
        var generation = 1
        let cursorStore = MailboxUpdateCursorStore(defaults: defaults)
        let coordinator = MailboxIncrementalSyncCoordinator(
            cursorStore: cursorStore,
            localStore: MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() }),
            makeContext: { context }, resolveProvider: { _ in provider },
            ensureReady: { _, _, _ in ready }, sessionGeneration: { _ in generation }, defaults: defaults
        )
        let task = Task { await coordinator.prefetchBodies(provider: .gmail, backgroundOnly: true) }
        await provider.waitUntilContentSuspended()
        switch reason {
        case "account": defaults.set("other@gmail.com", forKey: "pieroot.todo.imap.account")
        case "generation": generation += 1
        case "background": ready = false
        default: task.cancel()
        }
        provider.resumeContent()
        #expect(!(await task.value))
        #expect(provider.contentCalls == ["2"])
        let persisted = try ModelContext(container).fetch(FetchDescriptor<EmailMessage>())
        #expect(persisted.allSatisfy { !$0.hasCompleteBody && $0.body == "Legacy cached prefix" })
        #expect(cursorStore.cursor(for: .gmail, namespace: "user@gmail.com") == nil)
    }

    @Test("a successfully fetched empty body is durably complete and a denied background run fetches nothing")
    func emptyBodyAndReadinessGate() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let container = try makeContainer()
        let context = ModelContext(container)
        try insertBodyBacklog(1, in: context)
        let provider = ScriptedPagingProvider(provider: .gmail)
        let metadata = MailboxMessageMetadata(
            provider: .gmail, providerMessageID: "1", sourceAccountNamespace: "user@gmail.com",
            threadID: "", subject: "", from: "", snippet: "", receivedAt: .distantPast,
            isRead: false, isInInbox: true, gmailLabelIDs: ["INBOX"],
            outlookInferenceClassificationRawValue: "", providerCategoryNames: [], providerFolderID: ""
        )
        provider.contentResponses["1"] = MailboxMessageContent(metadata: metadata, body: "", htmlBody: "")
        var ready = false
        var time = Date()
        let coordinator = MailboxIncrementalSyncCoordinator(
            localStore: MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() }),
            makeContext: { context }, resolveProvider: { _ in provider },
            ensureReady: { _, _, _ in ready }, defaults: defaults, now: { time }
        )
        #expect(!(await coordinator.prefetchBodies(provider: .gmail, backgroundOnly: true)))
        #expect(provider.contentCalls.isEmpty)
        ready = true
        #expect(await coordinator.prefetchBodies(provider: .gmail))
        time = time.addingTimeInterval(MailboxPagingPolicy.pollInterval)
        #expect(await coordinator.prefetchBodies(provider: .gmail))
        #expect(provider.contentCalls == ["1"])
        #expect(try context.fetch(FetchDescriptor<EmailMessage>()).first?.hasCompleteBody == true)
    }

    @Test("a later body error preserves earlier committed cache visibility without advancing a body cursor")
    func bodyFailurePreservesCommittedCache() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let container = try makeContainer()
        let context = ModelContext(container)
        try insertBodyBacklog(3, in: context)
        let provider = ScriptedPagingProvider(provider: .gmail)
        provider.contentErrors["2"] = GmailIMAPError.transport("Synthetic body failure")
        let cursorStore = MailboxUpdateCursorStore(defaults: defaults)
        let coordinator = MailboxIncrementalSyncCoordinator(
            cursorStore: cursorStore,
            localStore: MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() }),
            makeContext: { context }, resolveProvider: { _ in provider },
            ensureReady: { _, _, _ in true }, defaults: defaults
        )
        #expect(!(await coordinator.prefetchBodies(provider: .gmail)))
        #expect(provider.contentCalls == ["3", "2"])
        let persisted = try ModelContext(container).fetch(FetchDescriptor<EmailMessage>())
        #expect(persisted.first { $0.providerMessageID == "3" }?.hasCompleteBody == true)
        #expect(persisted.first { $0.providerMessageID == "3" }?.body == "Complete body 3")
        #expect(persisted.filter { !$0.hasCompleteBody }.count == 2)
        #expect(cursorStore.cursor(for: .gmail, namespace: "user@gmail.com") == nil)
    }

    @Test("eight newest unreadable bodies rotate durably behind older readable mail",
          arguments: ["attachmentOnly", "oversized"])
    func failedBodyWindowCannotStarveOlderMail(failure: String) async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let container = try makeContainer()
        let seedContext = ModelContext(container)
        try insertBodyBacklog(17, in: seedContext)
        let provider = ScriptedPagingProvider(provider: .gmail)
        for index in 10...17 {
            // The service's explicit MIME-size guard throws invalidResponse;
            // it must still abort that batch, never be blanket-ignored.
            provider.contentErrors[String(index)] = failure == "attachmentOnly"
                ? GmailIMAPError.noSelectableTextPart : GmailIMAPError.invalidResponse
        }
        var time = Date(timeIntervalSince1970: 10_000)
        var reachedOlderReadableMail = false
        var rounds = 0
        while rounds < 10 && !reachedOlderReadableMail {
            // Recreate both context and coordinator to prove failed-row rotation
            // relies on durable row state rather than an in-memory cooldown.
            let context = ModelContext(container)
            let coordinator = MailboxIncrementalSyncCoordinator(
                localStore: MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() }),
                makeContext: { context }, resolveProvider: { _ in provider },
                ensureReady: { _, _, _ in true }, defaults: defaults, now: { time }
            )
            let before = provider.contentCalls.count
            let success = await coordinator.prefetchBodies(provider: .gmail)
            let attempted = provider.contentCalls.count - before
            #expect(attempted > 0 && attempted <= MailboxPagingPolicy.bodyPrefetchBatchSize)
            if failure == "oversized" && rounds < 8 {
                #expect(!success)
                #expect(attempted == 1)
            }
            let persisted = try ModelContext(container).fetch(FetchDescriptor<EmailMessage>())
            reachedOlderReadableMail = persisted.first { $0.providerMessageID == "9" }?.hasCompleteBody == true
            let failedRows = persisted.filter { (Int($0.providerMessageID) ?? 0) >= 10 }
            #expect(failedRows.allSatisfy { !$0.hasCompleteBody && $0.body == "Legacy cached prefix" })
            time = time.addingTimeInterval(MailboxPagingPolicy.pollInterval)
            rounds += 1
        }
        #expect(reachedOlderReadableMail)
        #expect(rounds == (failure == "attachmentOnly" ? 2 : 9))
        #expect(provider.contentCalls.count == Set(provider.contentCalls).count)
        let failedRows = try ModelContext(container).fetch(FetchDescriptor<EmailMessage>())
            .filter { (Int($0.providerMessageID) ?? 0) >= 10 }
        #expect(failedRows.allSatisfy { $0.lastBodyFetchAttemptAt > .distantPast && !$0.hasCompleteBody })
    }

    @Test("a suspended Gmail account does not delay Outlook discovery or complete-body hydration")
    func accountsProgressIndependently() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        defaults.set("user@outlook.com", forKey: "pieroot.todo.outlook.account")
        let container = try makeContainer()
        let context = ModelContext(container)
        let cursors = MailboxUpdateCursorStore(defaults: defaults)
        cursors.setCursor("g:1", for: .gmail, namespace: "user@gmail.com")
        cursors.setCursor("o:1", for: .outlook, namespace: "user@outlook.com")
        let gmail = ScriptedPagingProvider(provider: .gmail)
        gmail.suspendNextUpdate = true
        let outlook = ScriptedPagingProvider(provider: .outlook)
        outlook.suspendNextContent = true
        let metadata = MailboxMessageMetadata(
            provider: .outlook, providerMessageID: "2", sourceAccountNamespace: "user@outlook.com",
            threadID: "", subject: "Outlook", from: "", snippet: "Preview", receivedAt: Date(),
            isRead: false, isInInbox: true, gmailLabelIDs: [],
            outlookInferenceClassificationRawValue: "", providerCategoryNames: [], providerFolderID: "INBOX"
        )
        outlook.updateResponses = [MailboxPage(messages: [metadata], nextCursor: nil, newestCursor: "o:2")]
        outlook.contentResponses["2"] = MailboxMessageContent(metadata: metadata, body: "Complete Outlook body.", htmlBody: "")
        var analysisAccounts: [String] = []
        let coordinator = MailboxIncrementalSyncCoordinator(
            cursorStore: cursors, localStore: MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() }),
            makeContext: { context }, resolveProvider: { $0 == .gmail ? gmail : outlook },
            ensureReady: { _, _, _ in true }, defaults: defaults,
            enqueueAnalysis: { _, namespace in analysisAccounts.append(namespace) }
        )
        let task = Task { await coordinator.syncAvailableProviders() }
        await gmail.waitUntilSuspended()
        // Observe actual progress while Gmail remains suspended, then await
        // durable hydration, not merely the provider's fetch-start counter.
        await outlook.waitUntilContentSuspended()
        #expect(outlook.contentCalls == ["2"])
        outlook.resumeContent()
        #expect(await coordinator.prefetchBodies(provider: .outlook))
        #expect(cursors.cursor(for: .outlook, namespace: "user@outlook.com") == "o:2")
        #expect(try context.fetch(FetchDescriptor<EmailMessage>()).first?.body == "Complete Outlook body.")
        #expect(analysisAccounts.contains("user@outlook.com"))
        #expect(gmail.trashMessageIDs.isEmpty && outlook.trashMessageIDs.isEmpty)
        gmail.resumeUpdate(throwing: URLError(.notConnectedToInternet))
        #expect(await task.value)
        #expect(cursors.cursor(for: .gmail, namespace: "user@gmail.com") == "g:1")
    }

    @Test("complete-body hydration still progresses when metadata discovery fails")
    func discoveryFailureDoesNotStarveBodies() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let container = try makeContainer()
        let context = ModelContext(container)
        // This fixture represents an already-upgraded cache. A parser migration
        // legitimately invalidates pre-migration cursors before discovery.
        try GmailIMAPContentMigration.migrateIfNeeded(
            account: "user@gmail.com", context: context, defaults: defaults
        )
        try insertBodyBacklog(2, in: context)
        let cursors = MailboxUpdateCursorStore(defaults: defaults)
        cursors.setCursor("g:1", for: .gmail, namespace: "user@gmail.com")
        let gmail = ScriptedPagingProvider(provider: .gmail)
        gmail.updateError = URLError(.timedOut)
        let coordinator = MailboxIncrementalSyncCoordinator(
            cursorStore: cursors, localStore: MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() }),
            makeContext: { context }, resolveProvider: { _ in gmail },
            ensureReady: { _, _, _ in true }, defaults: defaults, enqueueAnalysis: { _, _ in }
        )
        #expect(!(await coordinator.sync(provider: .gmail)))
        #expect(gmail.contentCalls == ["2", "1"])
        #expect(try context.fetch(FetchDescriptor<EmailMessage>()).allSatisfy(\.hasCompleteBody))
        #expect(cursors.cursor(for: .gmail, namespace: "user@gmail.com") == "g:1")
        #expect(gmail.trashMessageIDs.isEmpty)
        #expect((30...60).contains(MailboxPagingPolicy.pollInterval))
        #expect(MailboxPagingPolicy.backgroundRefreshInterval >= 15 * 60)
    }
}

@MainActor
extension MailboxIncrementalSyncCoordinatorTests {
    @Test("both account lanes share one authentication attempt and a rejected account backs off independently")
    func sharedReadinessAndAccountBackoff() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        defaults.set("user@outlook.com", forKey: "pieroot.todo.outlook.account")
        let container = try makeContainer()
        let context = ModelContext(container)
        let gmail = ScriptedPagingProvider(provider: .gmail)
        let outlook = ScriptedPagingProvider(provider: .outlook)
        var attempts = 0
        var continuation: CheckedContinuation<Bool, Error>?
        var suspend = true
        var outlookReady = false
        var session = 1
        var time = Date(timeIntervalSince1970: 10_000)
        let coordinator = MailboxIncrementalSyncCoordinator(
            localStore: MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() }),
            makeContext: { context }, resolveProvider: { $0 == .gmail ? gmail : outlook },
            ensureReady: { provider, _, _ in
                if provider == .gmail { return true }
                attempts += 1
                if suspend {
                    suspend = false
                    return try await withCheckedThrowingContinuation { continuation = $0 }
                }
                guard outlookReady else { throw OutlookIMAPError.authenticationFailed }
                return true
            },
            sessionGeneration: { _ in session }, defaults: defaults,
            enqueueAnalysis: { _, _ in }, now: { time }
        )
        let discovery = Task { await coordinator.discover(provider: .outlook) }
        let bodies = Task { await coordinator.prefetchBodies(provider: .outlook) }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        #expect(continuation != nil)
        #expect(attempts == 1)
        continuation?.resume(throwing: OutlookIMAPError.authenticationFailed)
        #expect(!(await discovery.value))
        #expect(!(await bodies.value))
        for _ in 0..<40 {
            time = time.addingTimeInterval(MailboxPagingPolicy.pollInterval)
            #expect(await coordinator.syncAvailableProviders())
        }
        #expect(attempts <= 6)
        #expect(gmail.fetchInboxPageCalls.count == 1)
        #expect(gmail.fetchInboxUpdatesCalls.count == 40)
        #expect(outlook.fetchInboxPageCalls.isEmpty && outlook.contentCalls.isEmpty)
        // A successful explicit reconnect changes the session generation, so it
        // need not wait out a previous credential's account-local backoff.
        let rejectedAttempts = attempts
        outlookReady = true
        session += 1
        #expect(await coordinator.prefetchBodies(provider: .outlook))
        #expect(attempts == rejectedAttempts + 1)
    }
}

@MainActor
extension MailboxIncrementalSyncCoordinatorTests {
    @Test("omitted cursor stores use the coordinator's injected preference domain")
    func implicitCursorStoreRespectsInjectedDefaults() async throws {
        let firstDefaults = makeDefaults()
        let secondDefaults = makeDefaults()
        for defaults in [firstDefaults, secondDefaults] {
            defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        }
        let container = try makeContainer()
        let context = ModelContext(container)
        MailboxUpdateCursorStore(defaults: firstDefaults)
            .setCursor("first:1", for: .gmail, namespace: "user@gmail.com")
        let firstProvider = ScriptedPagingProvider(provider: .gmail)
        let secondProvider = ScriptedPagingProvider(provider: .gmail)
        let first = MailboxIncrementalSyncCoordinator(
            localStore: MailboxLocalStore(defaults: firstDefaults, saveContext: { try $0.save() }),
            makeContext: { context }, resolveProvider: { _ in firstProvider },
            ensureReady: { _, _, _ in true }, defaults: firstDefaults, enqueueAnalysis: { _, _ in }
        )
        let second = MailboxIncrementalSyncCoordinator(
            localStore: MailboxLocalStore(defaults: secondDefaults, saveContext: { try $0.save() }),
            makeContext: { context }, resolveProvider: { _ in secondProvider },
            ensureReady: { _, _, _ in true }, defaults: secondDefaults, enqueueAnalysis: { _, _ in }
        )
        #expect(await first.discover(provider: .gmail))
        #expect(firstProvider.fetchInboxPageCalls.isEmpty)
        #expect(firstProvider.fetchInboxUpdatesCalls == ["first:1"])
        #expect(await second.discover(provider: .gmail))
        #expect(secondProvider.fetchInboxPageCalls.count == 1)
        #expect(MailboxUpdateCursorStore(defaults: firstDefaults)
            .cursor(for: .gmail, namespace: "user@gmail.com") == "first:1")
        #expect(MailboxUpdateCursorStore(defaults: secondDefaults)
            .cursor(for: .gmail, namespace: "user@gmail.com") == "baseline:1")
    }
}

@MainActor
extension MailboxIncrementalSyncCoordinatorTests {
    @Test("transient offline or approval failures recover on the next foreground poll, not an exponential deadline",
          arguments: ["network", "approval"])
    func transientReadinessRecoversAtForegroundCadence(reason: String) async throws {
        let defaults = makeDefaults()
        defaults.set("user@outlook.com", forKey: "pieroot.todo.outlook.account")
        let container = try makeContainer()
        let context = ModelContext(container)
        let provider = ScriptedPagingProvider(provider: .outlook)
        var available = false
        var attempts = 0
        var time = Date(timeIntervalSince1970: 10_000)
        let coordinator = MailboxIncrementalSyncCoordinator(
            localStore: MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() }),
            makeContext: { context }, resolveProvider: { _ in provider },
            ensureReady: { _, _, _ in
                attempts += 1
                guard available else {
                    if reason == "approval" { throw KeychainStoreError.authenticationRequired }
                    throw URLError(.notConnectedToInternet)
                }
                return true
            },
            sessionGeneration: { _ in 1 }, defaults: defaults,
            enqueueAnalysis: { _, _ in }, now: { time }
        )
        for _ in 0..<40 {
            #expect(!(await coordinator.syncAvailableProviders()))
            time = time.addingTimeInterval(MailboxPagingPolicy.pollInterval)
        }
        #expect(attempts == 40) // One failed attempt shared across both lanes per tick.
        available = true
        #expect(await coordinator.syncAvailableProviders())
        #expect(provider.fetchInboxPageCalls.count == 1)
        #expect(provider.fetchInboxUpdatesCalls.count == 1)
        #expect(MailboxUpdateCursorStore(defaults: defaults)
            .cursor(for: .outlook, namespace: "user@outlook.com") == "baseline:1")
    }

    @Test("an explicit foreground refresh can retry corrected credentials during rejection backoff")
    func explicitRefreshBypassesRejectionBackoff() async throws {
        let defaults = makeDefaults()
        defaults.set("user@outlook.com", forKey: "pieroot.todo.outlook.account")
        let container = try makeContainer()
        let context = ModelContext(container)
        let provider = ScriptedPagingProvider(provider: .outlook)
        var corrected = false
        var attempts = 0
        var time = Date(timeIntervalSince1970: 10_000)
        let coordinator = MailboxIncrementalSyncCoordinator(
            localStore: MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() }),
            makeContext: { context }, resolveProvider: { _ in provider },
            ensureReady: { _, _, _ in
                attempts += 1
                guard corrected else { throw OutlookIMAPError.authenticationFailed }
                return true
            },
            sessionGeneration: { _ in 1 }, defaults: defaults,
            enqueueAnalysis: { _, _ in }, now: { time }
        )
        #expect(!(await coordinator.syncAvailableProviders()))
        #expect(attempts == 1)
        time = time.addingTimeInterval(MailboxPagingPolicy.pollInterval)
        #expect(!(await coordinator.syncAvailableProviders()))
        #expect(attempts == 1)
        corrected = true
        #expect(await coordinator.sync(provider: .outlook))
        #expect(attempts > 1)
        #expect(provider.fetchInboxPageCalls.count == 1)
    }
}
