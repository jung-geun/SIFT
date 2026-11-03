import Foundation
import SwiftData


/// Owns durable, account-scoped "newer mail" sync cursors for Gmail.
///
/// This coordinator is deliberately separate from the UI's older-page continuation
/// (`MailboxPagingState.nextCursor`, driven from `MailTabView`) and from Gmail's
/// background-analysis ingestion cursor (`GmailIMAPIngestionCursorStore`, driven from
/// `GmailIMAPIngestionService`). It keeps local mailbox metadata and a bounded
/// backlog of complete bodies current independently of AI analysis: on a 5-minute
/// foreground poll, on scroll-to-top, and on opportunistic OS background refresh.
///
/// A durable per-provider cursor is only advanced after every local commit for that
/// page succeeds, so a crash, save failure, or thrown provider error always leaves the
/// previous cursor intact — the same page is safely replayed on the next attempt.
@MainActor
final class MailboxIncrementalSyncCoordinator {
    static let shared = MailboxIncrementalSyncCoordinator()

    private let cursorStore: MailboxUpdateCursorStore
    private let localStore: MailboxLocalStore
    private let makeContext: () -> ModelContext
    private let resolveProvider: (MailProvider) -> any MailboxPagingProvider
    private let ensureReady: (MailProvider, String, Bool) async -> Bool
    private let defaults: UserDefaults
    private let now: () -> Date

    private let sessionGeneration: (MailProvider) async -> Int
    private var lastBodyAttempt: [String: Date] = [:]
    private var inFlight: Set<MailProvider> = []
    private var lastAttempt: [String: Date] = [:]
    private var pollTask: Task<Void, Never>?
    private var syncGeneration: [MailProvider: Int] = [:]

    init(
        cursorStore: MailboxUpdateCursorStore? = nil,
        localStore: MailboxLocalStore? = nil,
        makeContext: (() -> ModelContext)? = nil,
        resolveProvider: ((MailProvider) -> any MailboxPagingProvider)? = nil,
        ensureReady: ((MailProvider, String, Bool) async -> Bool)? = nil,
        sessionGeneration: ((MailProvider) async -> Int)? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.cursorStore = cursorStore ?? .live
        self.localStore = localStore ?? .live
        self.makeContext = makeContext ?? { ModelContext(AppDataContainer.shared.emailContainer) }
        self.resolveProvider = resolveProvider ?? MailboxProviderRegistry.provider(for:)
        self.ensureReady = ensureReady ?? Self.liveReadiness
        self.sessionGeneration = sessionGeneration ?? { provider in
            switch provider {
            case .gmail: return await GmailIMAPService.shared.sessionGeneration
            case .outlook: return await OutlookIMAPService.shared.sessionGeneration
            }
        }
        self.defaults = defaults
        self.now = now
    }

    // MARK: - Polling lifecycle

    /// Idempotent: a second call while a poll task is already running is a no-op.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.syncAvailableProviders()
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(MailboxPagingPolicy.pollInterval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Sync entry points

    @discardableResult
    func syncAvailableProviders(backgroundOnly: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        let gmailOK = await sync(provider: .gmail, minimumInterval: MailboxPagingPolicy.updatesMinimumInterval, backgroundOnly: backgroundOnly)
        let outlookOK = await sync(provider: .outlook, minimumInterval: MailboxPagingPolicy.updatesMinimumInterval, backgroundOnly: backgroundOnly)
        return gmailOK || outlookOK
    }

    @discardableResult
    func sync(
        provider: MailProvider,
        minimumInterval: TimeInterval = 0,
        backgroundOnly: Bool = false
    ) async -> Bool {
        guard let namespace = namespace(for: provider) else { return false }
        guard !inFlight.contains(provider) else { return false }
        let attemptKey = "\(provider.rawValue):\(namespace)"
        guard minimumInterval <= 0
            || lastAttempt[attemptKey] == nil
            || now().timeIntervalSince(lastAttempt[attemptKey]!) >= minimumInterval
        else { return false }
        let generation = syncGeneration[provider, default: 0]

        inFlight.insert(provider)
        lastAttempt[attemptKey] = now()
        defer { inFlight.remove(provider) }

        guard await ensureReady(provider, namespace, backgroundOnly),
              isCurrent(provider: provider, namespace: namespace, generation: generation)
        else { return false }

        let context = makeContext()
            let mailboxProvider = resolveProvider(provider)
            _ = await localStore.flushStagedTrash(
                provider: provider,
                sourceAccountNamespace: namespace
            ) { mutation in
                do {
                    guard self.isCurrent(provider: provider, namespace: namespace, generation: generation) else {
                        throw CancellationError()
                    }
                    try await mailboxProvider.trashMessage(
                        messageID: mutation.providerMessageID,
                        expectedGlobalMessageID: mutation.expectedGlobalMessageID,
                        expectedAccountNamespace: mutation.sourceAccountNamespace
                    )
                } catch GmailIMAPError.credentialRejected {
                    IMAPCredentialStore.markCredentialRejected(for: namespace)
                    throw GmailIMAPError.credentialRejected
            }
            }
        guard await ensureReady(provider, namespace, backgroundOnly),
              isCurrent(provider: provider, namespace: namespace, generation: generation)
        else { return false }
        do {
            if provider == .gmail {
                try GmailIMAPContentMigration.migrateIfNeeded(
                    account: namespace,
                    context: context,
                    defaults: defaults
                )
            }
            if cursorStore.cursor(for: provider, namespace: namespace) == nil {
                try await runBaseline(
                    provider: provider,
                    namespace: namespace,
                    generation: generation,
                    context: context
                )
            } else {
                try await runDrainLoop(
                    provider: provider,
                    namespace: namespace,
                    generation: generation,
                    context: context
                )
            }
            try await prefetchBodyBatch(
                provider: provider,
                namespace: namespace,
                generation: generation,
                context: context,
                backgroundOnly: backgroundOnly
            )
            return isCurrent(provider: provider, namespace: namespace, generation: generation)
        } catch {
            return false
        }
    }

    /// Also used after a UI head-page commit. Shares the provider's sync turn so
    /// manual refresh and scheduled prefetch cannot start duplicate body batches.
    @discardableResult
    func prefetchBodies(provider: MailProvider, backgroundOnly: Bool = false) async -> Bool {
        guard let namespace = namespace(for: provider), !inFlight.contains(provider) else { return false }
        let generation = syncGeneration[provider, default: 0]
        inFlight.insert(provider)
        defer { inFlight.remove(provider) }
        do {
            guard await ensureReady(provider, namespace, backgroundOnly),
                  isCurrent(provider: provider, namespace: namespace, generation: generation)
            else { return false }
            try await prefetchBodyBatch(
                provider: provider,
                namespace: namespace,
                generation: generation,
                context: makeContext(),
                backgroundOnly: backgroundOnly
            )
            return isCurrent(provider: provider, namespace: namespace, generation: generation)
        } catch {
            return false
        }
    }

    private func prefetchBodyBatch(
        provider: MailProvider,
        namespace: String,
        generation: Int,
        context: ModelContext,
        backgroundOnly: Bool
    ) async throws {
        let attemptKey = "\(provider.rawValue):\(namespace)"
        if let last = lastBodyAttempt[attemptKey],
           now().timeIntervalSince(last) < MailboxPagingPolicy.updatesMinimumInterval { return }
        lastBodyAttempt[attemptKey] = now()
        let providerRaw = provider.rawValue
        var descriptor = FetchDescriptor<EmailMessage>(
            predicate: #Predicate {
                $0.providerRawValue == providerRaw && $0.sourceAccountNamespace == namespace
                    && $0.isInInbox && $0.bodyContentVersion != 1
            },
            // Unattempted rows first, then least recently attempted failures.
            // The durable order progresses even when an entire batch is unreadable.
            sortBy: [
                SortDescriptor(\.lastBodyFetchAttemptAt),
                SortDescriptor(\.receivedAt, order: .reverse),
                SortDescriptor(\.rawMessageID)
            ]
        )
        descriptor.fetchLimit = MailboxPagingPolicy.bodyPrefetchBatchSize
        let candidates = try context.fetch(descriptor)
        let mailbox = resolveProvider(provider)
        let session = await sessionGeneration(provider)
        for email in candidates {
            guard isCurrent(provider: provider, namespace: namespace, generation: generation),
                  await sessionGeneration(provider) == session,
                  await ensureReady(provider, namespace, backgroundOnly),
                  isCurrent(provider: provider, namespace: namespace, generation: generation),
                  await sessionGeneration(provider) == session
            else { throw CancellationError() }
            guard !email.hasCompleteBody, email.isInInbox else { continue }
            let key = EmailMessageKey(email)
            try localStore.recordBodyFetchAttempt(for: email, at: now(), in: context)
            do {
                let content = try await mailbox.fetchMessageContent(messageID: key.providerMessageID)
                guard isCurrent(provider: provider, namespace: namespace, generation: generation),
                      await sessionGeneration(provider) == session,
                      await ensureReady(provider, namespace, backgroundOnly),
                      isCurrent(provider: provider, namespace: namespace, generation: generation),
                      await sessionGeneration(provider) == session,
                      EmailMessageKey(email) == key, email.isInInbox
                else { throw CancellationError() }
                try localStore.updateContent(content, for: email, in: context)
            } catch GmailIMAPError.noSelectableTextPart {
                // An attachment-only message must not block readable backlog rows.
                continue
            } catch GmailIMAPError.credentialRejected {
                IMAPCredentialStore.markCredentialRejected(for: namespace)
                throw GmailIMAPError.credentialRejected
            }
        }
    }

    // MARK: - Baseline + drain

    /// Commits a bounded head page, then runs exactly one newer-sync round from the
    /// freshly-minted cursor so the window between the head snapshot and the first
    /// poll never opens a gap. Never walks older mail.
    private func runBaseline(
        provider: MailProvider,
        namespace: String,
        generation: Int,
        context: ModelContext
    ) async throws {
        guard isCurrent(provider: provider, namespace: namespace, generation: generation) else {
            throw CancellationError()
        }
        let page = try await resolveProvider(provider).fetchInboxPage(after: nil)
        guard isCurrent(provider: provider, namespace: namespace, generation: generation) else {
            throw CancellationError()
        }
        try localStore.upsert(page, into: context)
        try localStore.replayPendingMutations(in: context)
        if let newestCursor = page.newestCursor {
            guard isCurrent(provider: provider, namespace: namespace, generation: generation) else {
                throw CancellationError()
            }
            cursorStore.setCursor(newestCursor, for: provider, namespace: namespace)
        }
        guard let seedCursor = cursorStore.cursor(for: provider, namespace: namespace) else { return }
        let updatePage = try await drainOnePage(
            provider: provider,
            namespace: namespace,
            generation: generation,
            cursor: seedCursor,
            context: context
        )
        if let newestCursor = updatePage.newestCursor, newestCursor != seedCursor {
            guard isCurrent(provider: provider, namespace: namespace, generation: generation) else {
                throw CancellationError()
            }
            cursorStore.setCursor(newestCursor, for: provider, namespace: namespace)
        }
    }

    /// Drains up to `MailboxPagingPolicy.maxUpdateDrainPages` newer-sync pages,
    /// persisting the durable cursor only after each page's local commit succeeds.
    private func runDrainLoop(
        provider: MailProvider,
        namespace: String,
        generation: Int,
        context: ModelContext
    ) async throws {
        guard var currentCursor = cursorStore.cursor(for: provider, namespace: namespace) else { return }
        var iterations = 0
        while iterations < MailboxPagingPolicy.maxUpdateDrainPages {
            guard isCurrent(provider: provider, namespace: namespace, generation: generation) else {
                throw CancellationError()
            }
            let page = try await drainOnePage(
                provider: provider,
                namespace: namespace,
                generation: generation,
                cursor: currentCursor,
                context: context
            )
            iterations += 1
            guard let newestCursor = page.newestCursor, newestCursor != currentCursor else { break }
            guard isCurrent(provider: provider, namespace: namespace, generation: generation) else {
                throw CancellationError()
            }
            cursorStore.setCursor(newestCursor, for: provider, namespace: namespace)
            currentCursor = newestCursor
            guard page.hasMoreUpdates else { break }
        }
    }

    private func drainOnePage(
        provider: MailProvider,
        namespace: String,
        generation: Int,
        cursor: String,
        context: ModelContext
    ) async throws -> MailboxPage {
        guard isCurrent(provider: provider, namespace: namespace, generation: generation) else {
            throw CancellationError()
        }
        let page = try await resolveProvider(provider).fetchInboxUpdates(newerThan: cursor)
        guard isCurrent(provider: provider, namespace: namespace, generation: generation) else {
            throw CancellationError()
        }
        try localStore.upsert(
            page,
            into: context,
            resetNamespace: page.requiresInboxReconcile && provider == .gmail ? namespace : nil
        )
        try localStore.replayPendingMutations(in: context)
        if page.requiresInboxReconcile {
            guard isCurrent(provider: provider, namespace: namespace, generation: generation) else {
                throw CancellationError()
            }
            let activeIDs = try await resolveProvider(provider).fetchInboxMessageIDs()
            guard isCurrent(provider: provider, namespace: namespace, generation: generation) else {
                throw CancellationError()
            }
            try localStore.reconcileInbox(
                provider: provider,
                sourceAccountNamespace: namespace,
                activeMessageIDs: activeIDs,
                in: context
            )
        }
        return page
    }

    // MARK: - Cursor lifecycle

    /// Called after a UI-driven head load commits successfully. Never overwrites a
    /// live delta/UID continuation already tracked by this coordinator.
    func seedBaselineIfNeeded(for provider: MailProvider, page: MailboxPage) {
        guard let namespace = namespace(for: provider) else { return }
        guard cursorStore.cursor(for: provider, namespace: namespace) == nil else { return }
        guard let newestCursor = page.newestCursor else { return }
        cursorStore.setCursor(newestCursor, for: provider, namespace: namespace)
    }

    /// Called on credential teardown so a reconnected mailbox always rebuilds a fresh
    /// baseline and can never consume another account's cursor.
    func forgetCursor(for provider: MailProvider, rawAccount: String) {
        syncGeneration[provider, default: 0] += 1
        let namespace: String
        switch provider {
        case .gmail:
            namespace = IMAPCredentialStore.canonicalAccount(rawAccount) ?? rawAccount
        case .outlook:
            namespace = OutlookIMAPCredentialStore.canonicalAccount(rawAccount) ?? rawAccount
        }
        cursorStore.clearCursor(for: provider, namespace: namespace)
        let attemptKey = "\(provider.rawValue):\(namespace)"
        lastAttempt.removeValue(forKey: attemptKey)
        lastBodyAttempt.removeValue(forKey: attemptKey)
    }


    private func isCurrent(
        provider: MailProvider,
        namespace: String,
        generation: Int
    ) -> Bool {
        !Task.isCancelled
            && syncGeneration[provider, default: 0] == generation
            && self.namespace(for: provider) == namespace
    }
    // MARK: - Namespace resolution

    /// Namespace resolution is centralized here so no caller can key a cursor
    /// differently than the coordinator that reads it back.
    private func namespace(for provider: MailProvider) -> String? {
        switch provider {
        case .gmail:
            let raw = defaults.string(forKey: "pieroot.todo.imap.account") ?? ""
            return IMAPCredentialStore.canonicalAccount(raw)
        case .outlook:
            let raw = defaults.string(forKey: "pieroot.todo.outlook.account") ?? ""
            return OutlookIMAPCredentialStore.canonicalAccount(raw)
        }
    }

    // MARK: - Live readiness

    /// Gmail: reject an out-of-app run unless the user opted into background access;
    /// otherwise authenticate if needed.
    nonisolated static let liveReadiness: (MailProvider, String, Bool) async -> Bool = { provider, namespace, backgroundOnly in
        do {
            try await KeychainStore.withoutAuthenticationUI {
                try await MailboxProviderRegistry.ensureReady(
                    for: provider,
                    namespace: namespace,
                    backgroundOnly: backgroundOnly
                )
            }
            return true
        } catch {
            return false
        }
    }
}
