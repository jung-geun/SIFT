import Foundation
import SwiftData


/// Owns durable, account-scoped "newer mail" sync cursors for Gmail and Outlook.
///
/// The durable discovery cursor is separate from the UI's older-page continuation
/// (`MailboxPagingState.nextCursor`, driven from `MailTabView`). Local action
/// analysis consumes durable complete bodies, never a second network cursor.
/// This coordinator keeps local mailbox metadata and a bounded
/// backlog of complete bodies current independently of AI analysis: on independent
/// 45-second foreground lanes and opportunistic, OS-bounded background refresh.
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
    private let ensureReady: (MailProvider, String, Bool) async throws -> Bool
    private let defaults: UserDefaults
    private let now: () -> Date

    private let sessionGeneration: (MailProvider) async -> Int
    private var lastBodyAttempt: [String: Date] = [:]
    private enum Lane: Hashable { case discovery, bodies, readiness }
    private struct LaneKey: Hashable {
        let provider: MailProvider
        let lane: Lane
    }
    private struct Turn {
        let id: UUID
        let namespace: String
        let backgroundOnly: Bool
        let task: Task<Bool, Never>
    }
    private var turns: [LaneKey: Turn] = [:]
    private struct ReadinessFailure {
        let count: Int
        let retryAt: Date
        let sessionGeneration: Int
    }
    private var readinessFailures: [String: ReadinessFailure] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var pollTasks: [Task<Void, Never>] = []
    private let enqueueAnalysis: (MailProvider, String) -> Void
    private let resetAnalysisRetries: (MailProvider, String) -> Void
    private var syncGeneration: [MailProvider: Int] = [:]

    init(
        cursorStore: MailboxUpdateCursorStore? = nil,
        localStore: MailboxLocalStore? = nil,
        makeContext: (() -> ModelContext)? = nil,
        resolveProvider: ((MailProvider) -> any MailboxPagingProvider)? = nil,
        ensureReady: ((MailProvider, String, Bool) async throws -> Bool)? = nil,
        sessionGeneration: ((MailProvider) async -> Int)? = nil,
        defaults: UserDefaults = .standard,
        enqueueAnalysis: ((MailProvider, String) -> Void)? = nil,
        resetAnalysisRetries: ((MailProvider, String) -> Void)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.cursorStore = cursorStore ?? MailboxUpdateCursorStore(defaults: defaults)
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
        self.enqueueAnalysis = enqueueAnalysis ?? { provider, namespace in
            EmailAutomationOrchestrator.shared.enqueue(provider: provider, namespace: namespace)
        }
        self.resetAnalysisRetries = resetAnalysisRetries ?? { provider, namespace in
            EmailAutomationOrchestrator.shared.resetAutomaticRetries(provider: provider, namespace: namespace)
        }
    }

    // MARK: - Polling lifecycle

    /// Idempotent: a second call while a poll task is already running is a no-op.
    func startPolling() {
        guard pollTasks.isEmpty else { return }
        for provider in [MailProvider.gmail, .outlook] {
            // A slow account or body download cannot delay another account's
            // discovery cadence. Each lane coalesces only its own work.
            for hydrateBodies in [false, true] {
                pollTasks.append(Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        if hydrateBodies {
                            _ = await self.prefetchBodies(provider: provider)
                        } else {
                            _ = await self.discover(
                                provider: provider,
                                minimumInterval: MailboxPagingPolicy.updatesMinimumInterval
                            )
                            if let namespace = self.namespace(for: provider) {
                                self.enqueueAnalysis(provider, namespace)
                            }
                        }
                        guard !Task.isCancelled else { return }
                        try? await Task.sleep(for: .seconds(MailboxPagingPolicy.pollInterval))
                    }
                })
            }
        }
    }

    func stopPolling() {
        for task in pollTasks { task.cancel() }
        pollTasks.removeAll()
        EmailAutomationOrchestrator.shared.stopForegroundProcessing()
    }

    // MARK: - Sync entry points

    @discardableResult
    func syncAvailableProviders(backgroundOnly: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            for provider in [MailProvider.gmail, .outlook] {
                group.addTask { @MainActor in
                    await self.sync(
                        provider: provider,
                        minimumInterval: MailboxPagingPolicy.updatesMinimumInterval,
                        backgroundOnly: backgroundOnly
                    )
                }
            }
            var succeeded = false
            for await result in group { succeeded = result || succeeded }
            return succeeded
        }
    }

    @discardableResult
    func sync(
        provider: MailProvider,
        minimumInterval: TimeInterval = 0,
        backgroundOnly: Bool = false
    ) async -> Bool {
        let discovered = await discover(
            provider: provider, minimumInterval: minimumInterval, backgroundOnly: backgroundOnly
        )
        // Already cached mail remains eligible even if discovery is offline.
        let hydrated = await prefetchBodies(provider: provider, backgroundOnly: backgroundOnly)
        return discovered && hydrated
    }

    @discardableResult
    func discover(
        provider: MailProvider,
        minimumInterval: TimeInterval = 0,
        backgroundOnly: Bool = false
    ) async -> Bool {
        if !backgroundOnly, minimumInterval <= 0, let namespace = namespace(for: provider) {
            // An explicit foreground refresh may retry a corrected credential
            // immediately, without changing scheduled-account backoff.
            readinessFailures.removeValue(forKey: "\(provider.rawValue):\(namespace)")
            resetAnalysisRetries(provider, namespace)
        }
        return await coalesce(provider: provider, lane: .discovery, backgroundOnly: backgroundOnly) {
            await self.discoverNow(
                provider: provider, minimumInterval: minimumInterval, backgroundOnly: backgroundOnly
            )
        }
    }

    private func discoverNow(
        provider: MailProvider,
        minimumInterval: TimeInterval,
        backgroundOnly: Bool
    ) async -> Bool {
        guard let namespace = namespace(for: provider) else { return false }
        let attemptKey = "\(provider.rawValue):\(namespace)"
        guard minimumInterval <= 0
            || lastAttempt[attemptKey] == nil
            || now().timeIntervalSince(lastAttempt[attemptKey]!) >= minimumInterval
        else { return true }
        let generation = syncGeneration[provider, default: 0]

        lastAttempt[attemptKey] = now()

        guard await ready(provider, namespace: namespace, backgroundOnly: backgroundOnly),
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
        guard await ready(provider, namespace: namespace, backgroundOnly: backgroundOnly),
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
            if !backgroundOnly { enqueueAnalysis(provider, namespace) }
            return isCurrent(provider: provider, namespace: namespace, generation: generation)
        } catch {
            return false
        }
    }

    /// A separate per-account hydration turn: metadata discovery never waits for
    /// a suspended body download, while duplicate body batches remain coalesced.
    @discardableResult
    func prefetchBodies(provider: MailProvider, backgroundOnly: Bool = false) async -> Bool {
        await coalesce(provider: provider, lane: .bodies, backgroundOnly: backgroundOnly) {
            await self.prefetchBodiesNow(provider: provider, backgroundOnly: backgroundOnly)
        }
    }

    private func prefetchBodiesNow(provider: MailProvider, backgroundOnly: Bool) async -> Bool {
        guard let namespace = namespace(for: provider) else { return false }
        let generation = syncGeneration[provider, default: 0]
        do {
            guard await ready(provider, namespace: namespace, backgroundOnly: backgroundOnly),
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

    /// Duplicate manual/scheduled callers await the same result instead of
    /// reporting a false failure merely because that lane is already working.
    private func coalesce(
        provider: MailProvider,
        lane: Lane,
        backgroundOnly: Bool,
        operation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        guard !Task.isCancelled, let namespace = namespace(for: provider) else { return false }
        let key = LaneKey(provider: provider, lane: lane)
        while let existing = turns[key] {
            if existing.namespace == namespace && existing.backgroundOnly == backgroundOnly {
                return await awaitTurn(existing.task)
            }
            // A background caller cannot borrow a foreground permission context.
            existing.task.cancel()
            _ = await awaitTurn(existing.task)
            if turns[key]?.id == existing.id { turns.removeValue(forKey: key) }
        }
        guard !Task.isCancelled, self.namespace(for: provider) == namespace else { return false }
        let id = UUID()
        let task = Task { @MainActor in await operation() }
        turns[key] = Turn(id: id, namespace: namespace, backgroundOnly: backgroundOnly, task: task)
        let result = await awaitTurn(task)
        if turns[key]?.id == id { turns.removeValue(forKey: key) }
        return result
    }

    private func awaitTurn(_ task: Task<Bool, Never>) async -> Bool {
        await withTaskCancellationHandler {
            await task.value && !Task.isCancelled
        } onCancel: {
            task.cancel()
        }
    }

    /// Authentication is shared by both account lanes. Only Outlook's existing
    /// authentication-rejection error receives exponential backoff. Transient
    /// failures coalesce for one short interval, then retry at the next poll.
    private func ready(_ provider: MailProvider, namespace: String, backgroundOnly: Bool) async -> Bool {
        await coalesce(provider: provider, lane: .readiness, backgroundOnly: backgroundOnly) {
            let key = "\(provider.rawValue):\(namespace)"
            let session = await self.sessionGeneration(provider)
            if let failure = self.readinessFailures[key] {
                if failure.sessionGeneration != session {
                    // An explicit successful reconnect establishes a new session.
                    self.readinessFailures.removeValue(forKey: key)
                } else if self.now() < failure.retryAt {
                    return false
                }
            }
            let ready: Bool
            var rejectedCredential = false
            do {
                ready = try await self.ensureReady(provider, namespace, backgroundOnly)
            } catch {
                ready = false
                rejectedCredential = provider == .outlook
                    && (error as? OutlookIMAPError) == .authenticationFailed
            }
            guard !Task.isCancelled, self.namespace(for: provider) == namespace else { return false }
            if ready {
                self.readinessFailures.removeValue(forKey: key)
            } else {
                let backgroundKey = provider == .gmail
                    ? "pieroot.todo.imap.backgroundEnabled" : "pieroot.todo.outlook.backgroundEnabled"
                // A missing background opt-in is not a failed credential.
                guard !backgroundOnly || self.defaults.bool(forKey: backgroundKey) else { return false }
                let count = rejectedCredential ? min(7, (self.readinessFailures[key]?.count ?? 0) + 1) : 0
                let delay = rejectedCredential
                    ? min(3600, 60 * Double(1 << (count - 1)))
                    : MailboxPagingPolicy.updatesMinimumInterval
                self.readinessFailures[key] = ReadinessFailure(
                    count: count, retryAt: self.now().addingTimeInterval(delay),
                    sessionGeneration: await self.sessionGeneration(provider)
                )
            }
            return ready
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
        let candidates = Array(
            try context.fetch(descriptor).lazy.filter {
                !(EmailAnalysisContract.isCurrentAnalysis($0) && $0.analysisFailureReasonRaw == nil)
            }.prefix(MailboxPagingPolicy.bodyPrefetchBatchSize)
        )
        let mailbox = resolveProvider(provider)
        let session = await sessionGeneration(provider)
        for email in candidates {
            guard isCurrent(provider: provider, namespace: namespace, generation: generation),
                  await sessionGeneration(provider) == session,
                  await ready(provider, namespace: namespace, backgroundOnly: backgroundOnly),
                  isCurrent(provider: provider, namespace: namespace, generation: generation),
                  await sessionGeneration(provider) == session
            else { throw CancellationError() }
            guard !email.hasCompleteBody,
                  !(EmailAnalysisContract.isCurrentAnalysis(email) && email.analysisFailureReasonRaw == nil),
                  email.isInInbox
            else { continue }
            let key = EmailMessageKey(email)
            try localStore.recordBodyFetchAttempt(for: email, at: now(), in: context)
            do {
                let content = try await mailbox.fetchMessageContent(messageID: key.providerMessageID)
                guard isCurrent(provider: provider, namespace: namespace, generation: generation),
                      await sessionGeneration(provider) == session,
                      await ready(provider, namespace: namespace, backgroundOnly: backgroundOnly),
                      isCurrent(provider: provider, namespace: namespace, generation: generation),
                      await sessionGeneration(provider) == session,
                      EmailMessageKey(email) == key, email.isInInbox
                else { throw CancellationError() }
                try localStore.updateContent(content, for: email, in: context)
                if !backgroundOnly { enqueueAnalysis(provider, namespace) }
            } catch GmailIMAPError.noSelectableTextPart {
                // An attachment-only message must not block readable backlog rows.
                continue
            } catch IMAPTextBodyError.tooLarge {
                continue
            } catch IMAPTextBodyError.noReadableText {
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
        readinessFailures.removeValue(forKey: attemptKey)
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
    nonisolated static let liveReadiness: (MailProvider, String, Bool) async throws -> Bool = { provider, namespace, backgroundOnly in
        try await KeychainStore.withoutAuthenticationUI {
            try await MailboxProviderRegistry.ensureReady(
                for: provider,
                namespace: namespace,
                backgroundOnly: backgroundOnly
            )
        }
        return true
    }
}
