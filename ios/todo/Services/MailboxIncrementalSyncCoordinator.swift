import Foundation
import SwiftData


/// Owns durable, account-scoped "newer mail" sync cursors for Gmail.
///
/// This coordinator is deliberately separate from the UI's older-page continuation
/// (`MailboxPagingState.nextCursor`, driven from `MailTabView`) and from Gmail's
/// background-analysis ingestion cursor (`GmailIMAPIngestionCursorStore`, driven from
/// `GmailIMAPIngestionService`). It only keeps the local mailbox list metadata (not
/// bodies, not AI analysis) current: on a 5-minute foreground poll, on scroll-to-top,
/// and on an OS-granted background refresh.
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

    private var inFlight: Set<MailProvider> = []
    private var lastAttempt: [MailProvider: Date] = [:]
    private var pollTask: Task<Void, Never>?
    private var syncGeneration: [MailProvider: Int] = [:]

    init(
        cursorStore: MailboxUpdateCursorStore? = nil,
        localStore: MailboxLocalStore? = nil,
        makeContext: (() -> ModelContext)? = nil,
        resolveProvider: ((MailProvider) -> any MailboxPagingProvider)? = nil,
        ensureReady: ((MailProvider, String, Bool) async -> Bool)? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.cursorStore = cursorStore ?? .live
        self.localStore = localStore ?? .live
        self.makeContext = makeContext ?? { ModelContext(AppDataContainer.shared.emailContainer) }
        self.resolveProvider = resolveProvider ?? MailboxProviderRegistry.provider(for:)
        self.ensureReady = ensureReady ?? Self.liveReadiness
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
                try? await Task.sleep(for: .seconds(MailboxPagingPolicy.pollInterval))
                guard !Task.isCancelled else { break }
                await self.syncAvailableProviders()
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
        let gmailOK = await sync(provider: .gmail, backgroundOnly: backgroundOnly)
        let outlookOK = await sync(provider: .outlook, backgroundOnly: backgroundOnly)
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
        guard minimumInterval <= 0
            || lastAttempt[provider] == nil
            || now().timeIntervalSince(lastAttempt[provider]!) >= minimumInterval
        else { return false }
        let generation = syncGeneration[provider, default: 0]

        inFlight.insert(provider)
        lastAttempt[provider] = now()
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
                        expectedGlobalMessageID: mutation.expectedGlobalMessageID
                    )
                } catch GmailIMAPError.credentialRejected {
                    IMAPCredentialStore.markCredentialRejected(for: namespace)
                    throw GmailIMAPError.credentialRejected
            }
            }
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
            return isCurrent(provider: provider, namespace: namespace, generation: generation)
        } catch {
            return false
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
        switch provider {
        case .gmail:
            let backgroundEnabled = UserDefaults.standard.bool(forKey: "pieroot.todo.imap.backgroundEnabled")
            if backgroundOnly && !backgroundEnabled { return false }
            if IMAPCredentialStore.isCredentialRejected(for: namespace) { return false }
            if await GmailIMAPService.shared.isAuthenticated { return true }
            do {
                try await GmailIMAPService.shared.authenticate(
                    email: namespace,
                    backgroundEnabled: backgroundEnabled
                )
                return true
            } catch GmailIMAPError.credentialRejected {
                IMAPCredentialStore.markCredentialRejected(for: namespace)
                return false
            } catch {
                return false
            }
        case .outlook:
            let backgroundEnabled = UserDefaults.standard.bool(forKey: "pieroot.todo.outlook.backgroundEnabled")
            if backgroundOnly && !backgroundEnabled { return false }
            if await OutlookIMAPService.shared.isAuthenticated { return true }
            return (try? await OutlookIMAPService.shared.authenticate(
                email: namespace,
                backgroundEnabled: backgroundEnabled
            )) != nil
        }
    }
}
