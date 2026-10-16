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
        fatalError("Not used in coordinator tests")
    }

    func markAsRead(
        messageID _: String,
        expectedGlobalMessageID _: String?
    ) async throws {}

    func trashMessage(
        messageID: String,
        expectedGlobalMessageID _: String?
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
        #expect(r2 == false)
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

        let r5 = await coordinator.sync(provider: .gmail, minimumInterval: 0)
        #expect(r5 == false)
        #expect(gmailProvider.fetchInboxUpdatesCalls.count == 3)

        gmailProvider.resumeUpdate(with: MailboxPage(messages: [], nextCursor: nil, newestCursor: "42:103"))
        let r4 = await task4.value
        #expect(r4 == true)
        #expect(gmailProvider.fetchInboxUpdatesCalls.count == 3)
        #expect(cursorStore.cursor(for: .gmail, namespace: "user@gmail.com") == "42:103")
    }

    @Test("startPolling delays the first sync until after the poll interval sleep")
    func testStartPollingDelaysFirstSync() async throws {
        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        let cursorStore = MailboxUpdateCursorStore(defaults: defaults)
        cursorStore.setCursor("42:100", for: .gmail, namespace: "user@gmail.com")

        let container = try makeContainer()
        let context = ModelContext(container)
        let localStore = MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() })
        let gmailProvider = ScriptedPagingProvider(provider: .gmail)

        var ensureReadyCallCount = 0
        let coordinator = MailboxIncrementalSyncCoordinator(
            cursorStore: cursorStore,
            localStore: localStore,
            makeContext: { context },
            resolveProvider: { _ in gmailProvider },
            ensureReady: { _, _, _ in
                ensureReadyCallCount += 1
                return true
            },
            defaults: defaults
        )

        coordinator.startPolling()
        await Task.yield()

        #expect(ensureReadyCallCount == 0)
        #expect(gmailProvider.fetchInboxUpdatesCalls.count == 0)

        coordinator.stopPolling()
    }
}
