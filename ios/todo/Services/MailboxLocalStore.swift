import Foundation
import SwiftData

nonisolated struct PendingMailboxMutation: Codable, Hashable {
    let providerRawValue: String
    let sourceAccountNamespace: String
    let providerMessageID: String
    let action: MailboxMutationAction
    /// Gmail's immutable X-GM-MSGID binds every deferred replay to the original message.
    let expectedGlobalMessageID: String?
    /// A local-first action must remain undoable until this time, including while the
    /// app is suspended and a background mailbox sync is granted.
    let deferredUntil: Date?

    init(
        providerRawValue: String,
        sourceAccountNamespace: String = "",
        providerMessageID: String,
        action: MailboxMutationAction,
        expectedGlobalMessageID: String? = nil,
        deferredUntil: Date? = nil
    ) {
        self.providerRawValue = providerRawValue
        self.sourceAccountNamespace = sourceAccountNamespace
        self.providerMessageID = providerMessageID
        self.action = action
        self.expectedGlobalMessageID = expectedGlobalMessageID
        self.deferredUntil = deferredUntil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.providerRawValue == rhs.providerRawValue
            && lhs.sourceAccountNamespace == rhs.sourceAccountNamespace
            && lhs.providerMessageID == rhs.providerMessageID
            && lhs.action == rhs.action
            && lhs.expectedGlobalMessageID == rhs.expectedGlobalMessageID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(providerRawValue)
        hasher.combine(sourceAccountNamespace)
        hasher.combine(providerMessageID)
        hasher.combine(action)
        hasher.combine(expectedGlobalMessageID)
    }

    private enum CodingKeys: String, CodingKey {
        case providerRawValue, sourceAccountNamespace, providerMessageID, action
        case expectedGlobalMessageID, deferredUntil
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        providerRawValue = try values.decode(String.self, forKey: .providerRawValue)
        sourceAccountNamespace = try values.decodeIfPresent(String.self, forKey: .sourceAccountNamespace) ?? ""
        providerMessageID = try values.decode(String.self, forKey: .providerMessageID)
        action = try values.decode(MailboxMutationAction.self, forKey: .action)
        expectedGlobalMessageID = try values.decodeIfPresent(String.self, forKey: .expectedGlobalMessageID)
        deferredUntil = try values.decodeIfPresent(Date.self, forKey: .deferredUntil)
    }
}

/// Shared persistence for acknowledged local-save retries and deferred remote actions.
nonisolated struct MailboxMutationStore {
    enum Queue {
        case acknowledged
        case deferred

        var key: String {
            switch self {
            case .acknowledged: "pieroot.todo.mailbox.pendingMutations.v1"
            case .deferred: "pieroot.todo.mailbox.pendingRemoteMutations.v1"
            }
        }
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, queue: Queue) {
        self.defaults = defaults
        key = queue.key
    }

    var mutations: Set<PendingMailboxMutation> {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Set<PendingMailboxMutation>.self, from: data)
        else { return [] }
        return decoded
    }

    func insert(_ mutations: Set<PendingMailboxMutation>) {
        guard !mutations.isEmpty else { return }
        persist(self.mutations.union(mutations))
    }

    func remove(_ mutations: Set<PendingMailboxMutation>) {
        guard !mutations.isEmpty else { return }
        persist(self.mutations.subtracting(mutations))
    }

    private func persist(_ mutations: Set<PendingMailboxMutation>) {
        guard !mutations.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(mutations) {
            defaults.set(data, forKey: key)
        }
    }
}

enum MailboxLocalStoreError: Error {
    case contentIdentityMismatch
}

@MainActor
final class MailboxLocalStore {
    static let live = MailboxLocalStore(
        defaults: .standard,
        saveContext: { try $0.save() }
    )

    private let pendingStore: MailboxMutationStore
    private let pendingRemoteStore: MailboxMutationStore
    /// Process-local leases prevent an Undo action from restoring a row once an
    /// IMAP trash command has begun. They intentionally are not persisted: after a
    /// termination the durable outbox remains eligible for a safe retry.
    private var claimedStagedTrashMutations: Set<PendingMailboxMutation> = []
    private let saveContext: (ModelContext) throws -> Void

    init(
        defaults: UserDefaults,
        saveContext: @escaping (ModelContext) throws -> Void
    ) {
        pendingStore = MailboxMutationStore(defaults: defaults, queue: .acknowledged)
        pendingRemoteStore = MailboxMutationStore(defaults: defaults, queue: .deferred)
        self.saveContext = saveContext
    }

    private struct EmailState {
        let id: String; let rawMessageID: String; let providerGlobalMessageID: String; let providerRawValue: String
        let sourceAccountNamespace: String; let threadID: String; let subject: String
        let from: String; let snippet: String; let body: String; let htmlBody: String?; let receivedAt: Date
        let isRead: Bool; let labelIDs: [String]; let isInInbox: Bool
        let outlookInferenceClassificationRawValue: String; let providerCategoryNames: [String]; let providerFolderID: String
        let analysisStateRaw: String; let analysisSummary: String; let analysisDetail: String
        let analysisKeyPoints: [String]; let analysisActionItems: [String]; let analysisError: String
        let analysisFailureReasonRaw: String?; let analyzedBodyFingerprint: String; let analyzedAt: Date?; let analysisVersion: Int
        let analysisTodoCandidate: Bool?; let analysisTodoCandidateFingerprint: String

        init(_ email: EmailMessage) {
            id = email.id; rawMessageID = email.rawMessageID; providerGlobalMessageID = email.providerGlobalMessageID
            providerRawValue = email.providerRawValue; sourceAccountNamespace = email.sourceAccountNamespace
            threadID = email.threadID; subject = email.subject
            from = email.from; snippet = email.snippet; body = email.body; htmlBody = email.htmlBody; receivedAt = email.receivedAt
            isRead = email.isRead; labelIDs = email.labelIDs; isInInbox = email.isInInbox
            outlookInferenceClassificationRawValue = email.outlookInferenceClassificationRawValue; providerCategoryNames = email.providerCategoryNames; providerFolderID = email.providerFolderID
            analysisStateRaw = email.analysisStateRaw; analysisSummary = email.analysisSummary; analysisDetail = email.analysisDetail
            analysisKeyPoints = email.analysisKeyPoints; analysisActionItems = email.analysisActionItems; analysisError = email.analysisError
            analysisFailureReasonRaw = email.analysisFailureReasonRaw
            analyzedBodyFingerprint = email.analyzedBodyFingerprint; analyzedAt = email.analyzedAt; analysisVersion = email.analysisVersion
            analysisTodoCandidate = email.analysisTodoCandidate; analysisTodoCandidateFingerprint = email.analysisTodoCandidateFingerprint
        }

        func restore(_ email: EmailMessage) {
            email.id = id; email.rawMessageID = rawMessageID; email.providerGlobalMessageID = providerGlobalMessageID
            email.providerRawValue = providerRawValue; email.sourceAccountNamespace = sourceAccountNamespace
            email.threadID = threadID; email.subject = subject
            email.from = from; email.snippet = snippet; email.body = body; email.htmlBody = htmlBody; email.receivedAt = receivedAt
            email.isRead = isRead; email.labelIDs = labelIDs; email.isInInbox = isInInbox
            email.outlookInferenceClassificationRawValue = outlookInferenceClassificationRawValue; email.providerCategoryNames = providerCategoryNames; email.providerFolderID = providerFolderID
            email.analysisStateRaw = analysisStateRaw; email.analysisSummary = analysisSummary; email.analysisDetail = analysisDetail
            email.analysisKeyPoints = analysisKeyPoints; email.analysisActionItems = analysisActionItems; email.analysisError = analysisError
            email.analysisFailureReasonRaw = analysisFailureReasonRaw
            email.analyzedBodyFingerprint = analyzedBodyFingerprint; email.analyzedAt = analyzedAt; email.analysisVersion = analysisVersion
            email.analysisTodoCandidate = analysisTodoCandidate; email.analysisTodoCandidateFingerprint = analysisTodoCandidateFingerprint
        }
    }

    func upsert(
        _ page: MailboxPage,
        into context: ModelContext,
        resetNamespace: String? = nil
    ) throws {
        let originalRows = try context.fetch(FetchDescriptor<EmailMessage>())
        let originalStates = Dictionary(uniqueKeysWithValues: originalRows.map { (ObjectIdentifier($0), EmailState($0)) })
        let gmailNamespace = resetNamespace ?? page.messages.first(where: { $0.provider == .gmail })?.sourceAccountNamespace
        if page.requiresInboxReconcile, let gmailNamespace {
            // A head-page reset means rows absent from this page are no longer in
            // Inbox. Their cached bodies and prior analysis remain available for
            // duplicate selection and later hydration, like reconcileInbox.
            for email in originalRows
            where email.provider == .gmail && email.sourceAccountNamespace == gmailNamespace {
                email.isInInbox = false
            }
        }
        let removedProviders = Set(
            page.removedMessageKeys.compactMap { MailProvider(rawValue: $0.providerRawValue) }
        )
        let providers = Set(page.messages.map(\.provider)).union(removedProviders)
        var survivorByKey = [EmailMessageKey: EmailMessage]()

        for provider in providers {
            let providerRawValue = provider.rawValue
            let descriptor = FetchDescriptor<EmailMessage>(
                predicate: #Predicate<EmailMessage> { email in
                    email.providerRawValue == providerRawValue
                },
                sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
            )
            let rows = try context.fetch(descriptor)
            let grouped = Dictionary(grouping: rows, by: EmailMessageKey.init)
            for (key, group) in grouped {
                guard let survivor = preferredSurvivor(in: group) else { continue }
                mergeRichContent(from: group, into: survivor)
                survivorByKey[key] = survivor
                for duplicate in group where duplicate !== survivor {
                    context.delete(duplicate)
                }
            }
        }

        var seenPageKeys = Set<EmailMessageKey>()
        for metadata in page.messages {
            let key = EmailMessageKey(
                providerRawValue: metadata.provider.rawValue,
                sourceAccountNamespace: metadata.sourceAccountNamespace,
                providerMessageID: metadata.providerMessageID
            )
            guard seenPageKeys.insert(key).inserted else { continue }

            let email: EmailMessage
            if let existing = survivorByKey[key] {
                email = existing
            } else {
                email = EmailMessage(
                    id: localID(for: metadata),
                    provider: metadata.provider,
                    rawMessageID: metadata.providerMessageID,
                    sourceAccountNamespace: metadata.sourceAccountNamespace
                )
                context.insert(email)
                survivorByKey[key] = email
            }
            apply(metadata, to: email)
            invalidateAnalysisIfStale(for: email)
        }

        // Delta-page deletions hide the row without deleting its retained
        // content/analysis, matching reconcileInbox's existing semantics.
        for key in page.removedMessageKeys {
            survivorByKey[key]?.isInInbox = false
        }

        do {
            try saveContext(context)
        } catch {
            context.rollback()
            for email in originalRows {
                originalStates[ObjectIdentifier(email)]?.restore(email)
            }
            throw error
        }
    }

    func reconcileInbox(
        provider: MailProvider,
        sourceAccountNamespace: String = "",
        activeMessageIDs: Set<String>,
        in context: ModelContext
    ) throws {
        let providerRawValue = provider.rawValue
        let descriptor = FetchDescriptor<EmailMessage>(
            predicate: #Predicate<EmailMessage> { email in
                email.providerRawValue == providerRawValue
            }
        )
        let rows = try context.fetch(descriptor).filter { $0.sourceAccountNamespace == sourceAccountNamespace }
        let originalStates = Dictionary(uniqueKeysWithValues: rows.map { (ObjectIdentifier($0), EmailState($0)) })
        var didChange = false
        for email in rows {
            let shouldHide = !activeMessageIDs.contains(email.providerMessageID)
                || (provider == .outlook && email.providerFolderID.isEmpty)
            if shouldHide && email.isInInbox {
                email.isInInbox = false
                didChange = true
            }
        }
        guard didChange else { return }
        do {
            try saveContext(context)
        } catch {
            context.rollback()
            for email in rows {
                originalStates[ObjectIdentifier(email)]?.restore(email)
            }
            throw error
        }
    }

    func replayPendingMutations(in context: ModelContext, currentNamespace: String? = nil) throws {
        try reapplyStagedTrashMasks(in: context, currentNamespace: currentNamespace)

        let pending = pendingStore.mutations
        guard !pending.isEmpty else { return }

        let gmailRaw = MailProvider.gmail.rawValue
        let gmailPending = pending.filter { $0.providerRawValue == gmailRaw }
        let nonGmailPending = pending.filter { $0.providerRawValue != gmailRaw }

        if !nonGmailPending.isEmpty {
            pendingStore.remove(nonGmailPending)
        }
        guard !gmailPending.isEmpty else { return }

        let descriptor = FetchDescriptor<EmailMessage>(
            predicate: #Predicate { $0.providerRawValue == "gmail" }
        )
        let rows = try context.fetch(descriptor)
        let rowsByKey = Dictionary(grouping: rows, by: EmailMessageKey.init)
            .compactMapValues(\.first)
        var requiresSave = false
        var applied = Set<PendingMailboxMutation>()
        for mutation in gmailPending {
            guard currentNamespace == nil || mutation.sourceAccountNamespace == currentNamespace else { continue }
            let key = EmailMessageKey(
                providerRawValue: mutation.providerRawValue,
                sourceAccountNamespace: mutation.sourceAccountNamespace,
                providerMessageID: mutation.providerMessageID
            )
            guard let email = rowsByKey[key] else { continue }
            guard let expectedGlobalMessageID = mutation.expectedGlobalMessageID,
                  GmailIMAPService.globalMessageID(from: email.id) == expectedGlobalMessageID
            else {
                applied.insert(mutation)
                continue
            }
            switch mutation.action {
            case .markAsRead:
                email.isRead = true
                email.labelIDs.removeAll { $0 == "UNREAD" }
            case .trash:
                // Preserve the local-only record after a remote move. Detail views and
                // search may still hold this model while SwiftUI dismisses the sheet;
                // deleting it can detach unresolved persisted properties mid-render.
                email.isInInbox = false
            }
            applied.insert(mutation)
            requiresSave = true
        }

        if requiresSave {
            do {
                try saveContext(context)
            } catch {
                context.rollback()
                throw error
            }
        }
        pendingStore.remove(applied)
    }

    func updateContent(
        _ content: MailboxMessageContent,
        for email: EmailMessage,
        in context: ModelContext
    ) throws {
        let emailKey = EmailMessageKey(email)
        let contentKey = EmailMessageKey(
            providerRawValue: content.metadata.provider.rawValue,
            sourceAccountNamespace: content.metadata.sourceAccountNamespace,
            providerMessageID: content.metadata.providerMessageID
        )
        guard emailKey == contentKey else {
            throw MailboxLocalStoreError.contentIdentityMismatch
        }
        if !email.providerGlobalMessageID.isEmpty,
           !content.metadata.providerGlobalMessageID.isEmpty,
           email.providerGlobalMessageID != content.metadata.providerGlobalMessageID {
            throw MailboxLocalStoreError.contentIdentityMismatch
        }

        let normalizedHTML = content.htmlBody.isEmpty ? nil : content.htmlBody
        let bodyChanged = email.body != content.body
            || email.htmlBody != normalizedHTML
        email.body = content.body
        email.htmlBody = normalizedHTML
        if content.metadata.provider == .gmail {
            // Gmail body fetches intentionally omit list headers; never erase
            // metadata already committed by the preceding page fetch.
            email.isRead = content.metadata.isRead || email.isRead
            email.isInInbox = content.metadata.isInInbox
            if !content.metadata.gmailLabelIDs.isEmpty {
                email.labelIDs = content.metadata.gmailLabelIDs
                if email.isRead {
                    email.labelIDs.removeAll { $0 == "UNREAD" }
                }
            }
        } else {
            apply(content.metadata, to: email)
        }
        if bodyChanged {
            invalidateAnalysis(for: email)
        } else {
            invalidateAnalysisIfStale(for: email)
        }

        do {
            try saveContext(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    func markAsRead(
        _ email: EmailMessage,
        in context: ModelContext,
        remote: () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let key = EmailMessageKey(email)
        let mutation = pendingMutation(for: email, action: .markAsRead)
        let previousIsRead = email.isRead
        let previousLabelIDs = email.labelIDs
        email.isRead = true
        if email.provider == .gmail {
            email.labelIDs.removeAll { $0 == "UNREAD" }
        }

        do {
            try await remote()
        } catch {
            guard let currentEmail = try? resolvedEmail(matching: key, in: context) else {
                throw error
            }
            currentEmail.isRead = previousIsRead
            currentEmail.labelIDs = previousLabelIDs
            throw error
        }

        guard let currentEmail = try resolvedEmail(matching: key, in: context) else {
            return
        }
        currentEmail.isRead = true
        if currentEmail.provider == .gmail {
            currentEmail.labelIDs.removeAll { $0 == "UNREAD" }
        }
        do {
            try saveContext(context)
            pendingStore.remove([mutation])
        } catch {
            pendingStore.insert([mutation])
            throw MailboxMutationError.remoteCommittedLocalSaveFailed(
                provider: currentEmail.provider,
                action: .markAsRead
            )
        }
    }

    func trash(
        _ email: EmailMessage,
        in context: ModelContext,
        remote: () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let key = EmailMessageKey(email)
        let provider = email.provider
        let mutation = pendingMutation(for: email, action: .trash)
        try await remote()

        guard let currentEmail = try resolvedEmail(matching: key, in: context) else {
            return
        }
        // Keep cached content and analysis locally; only inbox visibility changes.
        currentEmail.isInInbox = false
        do {
            try saveContext(context)
            pendingStore.remove([mutation])
        } catch {
            context.rollback()
            currentEmail.isInInbox = false
            pendingStore.insert([mutation])
            throw MailboxMutationError.remoteCommittedLocalSaveFailed(
                provider: provider,
                action: .trash
            )
        }
    }

    var stagedTrashMutations: Set<PendingMailboxMutation> {
        pendingRemoteStore.mutations
    }

    /// Hides the message locally and durably queues its IMAP move. The remote operation
    /// is intentionally deferred so the list responds immediately and undo can restore it.
    func stageTrash(
        _ emails: [EmailMessage],
        in context: ModelContext,
        now: Date = Date()
    ) throws -> Set<PendingMailboxMutation> {
        if let emailWithoutIdentity = emails.first(where: {
            mutationIdentity(for: $0) == nil
        }) {
            throw MailboxMutationError.mutationIdentityUnavailable(
                provider: emailWithoutIdentity.provider
            )
        }

        let mutations = Set(emails.map {
            pendingMutation(
                for: $0,
                action: .trash,
                deferredUntil: now.addingTimeInterval(5)
            )
        })

        pendingRemoteStore.insert(mutations)
        for email in emails {
            email.isInInbox = false
        }
        do {
            try saveContext(context)
            return mutations
        } catch {
            context.rollback()
            pendingRemoteStore.remove(mutations)
            throw error
        }
    }

    /// Returns false when the five-second window expired or an IMAP trash command
    /// already owns one of these mutations. In either case restoring the local row
    /// would diverge from the provider's eventual state.
    func restoreStagedTrash(
        _ emails: [EmailMessage],
        mutations: Set<PendingMailboxMutation>,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> Bool {
        guard !mutations.isEmpty else { return true }
        let queued = pendingRemoteStore.mutations.intersection(mutations)
        guard queued == mutations,
              claimedStagedTrashMutations.isDisjoint(with: mutations),
              queued.allSatisfy({ $0.deferredUntil.map { $0 > now } ?? true })
        else {
            return false
        }

        pendingRemoteStore.remove(mutations)
        for email in emails {
            email.isInInbox = true
        }
        do {
            try saveContext(context)
            return true
        } catch {
            context.rollback()
            pendingRemoteStore.insert(mutations)
            throw error
        }
    }

    /// Flushes local-first trash requests. Failures stay queued and locally hidden for a
    /// later foreground/background sync rather than reintroducing a row the user deleted.
    @discardableResult
    func flushStagedTrash(
        _ mutations: Set<PendingMailboxMutation>,
        now: Date = Date(),
        remote: (PendingMailboxMutation) async throws -> Void
    ) async -> Int {
        let eligible = pendingRemoteStore.mutations
            .intersection(mutations)
            .filter { $0.deferredUntil.map { $0 <= now } ?? true }
            .subtracting(claimedStagedTrashMutations)
        claimedStagedTrashMutations.formUnion(eligible)
        defer { claimedStagedTrashMutations.subtract(eligible) }

        var completed = 0
        for mutation in eligible {
            guard !Task.isCancelled else { break }
            do {
                try await remote(mutation)
                pendingRemoteStore.remove([mutation])
                completed += 1
            } catch is CancellationError {
                break
            } catch {
                DiagnosticRecorder.shared.record(
                    error: error,
                    component: "mail.mutation",
                    operation: "deferredTrash"
                )
            }
            claimedStagedTrashMutations.remove(mutation)
        }
        return completed
    }

    @discardableResult
    func flushStagedTrash(
        provider: MailProvider,
        sourceAccountNamespace: String,
        now: Date = Date(),
        remote: (PendingMailboxMutation) async throws -> Void
    ) async -> Int {
        let mutations = pendingRemoteStore.mutations.filter {
            $0.providerRawValue == provider.rawValue
                && $0.sourceAccountNamespace == sourceAccountNamespace
                && $0.action == .trash
        }
        return await flushStagedTrash(mutations, now: now, remote: remote)
    }

    private func reapplyStagedTrashMasks(
        in context: ModelContext,
        currentNamespace: String?
    ) throws {
        let staged = pendingRemoteStore.mutations.filter {
            currentNamespace == nil || $0.sourceAccountNamespace == currentNamespace
        }
        guard !staged.isEmpty else { return }

        let rows = try context.fetch(FetchDescriptor<EmailMessage>())
        let rowsByKey = Dictionary(grouping: rows, by: EmailMessageKey.init)
            .compactMapValues(\.first)
        var changed = false
        for mutation in staged {
            let key = EmailMessageKey(
                providerRawValue: mutation.providerRawValue,
                sourceAccountNamespace: mutation.sourceAccountNamespace,
                providerMessageID: mutation.providerMessageID
            )
            if let email = rowsByKey[key],
               mutationMatchesStoredIdentity(mutation, email: email),
               email.isInInbox {
                email.isInInbox = false
                changed = true
            }
        }
        guard changed else { return }
        do {
            try saveContext(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    private func resolvedEmail(
        matching key: EmailMessageKey,
        in context: ModelContext
    ) throws -> EmailMessage? {
        let providerRawValue = key.providerRawValue
        let sourceAccountNamespace = key.sourceAccountNamespace
        let descriptor = FetchDescriptor<EmailMessage>(
            predicate: #Predicate<EmailMessage> { email in
                email.providerRawValue == providerRawValue
                    && email.sourceAccountNamespace == sourceAccountNamespace
            },
            sortBy: [SortDescriptor(\EmailMessage.receivedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
            .first { EmailMessageKey($0) == key }
    }

    private func pendingMutation(
        for email: EmailMessage,
        action: MailboxMutationAction,
        deferredUntil: Date? = nil
    ) -> PendingMailboxMutation {
        let expectedGlobalMessageID = mutationIdentity(for: email)
        return PendingMailboxMutation(
            providerRawValue: email.providerRawValue,
            sourceAccountNamespace: email.sourceAccountNamespace,
            providerMessageID: email.providerMessageID,
            action: action,
            expectedGlobalMessageID: expectedGlobalMessageID,
            deferredUntil: deferredUntil
        )
    }

    private func mutationIdentity(for email: EmailMessage) -> String? {
        switch email.provider {
        case .gmail:
            return GmailIMAPService.globalMessageID(from: email.id)
        case .outlook:
            return email.providerGlobalMessageID.isEmpty
                ? nil
                : email.providerGlobalMessageID
        }
    }

    private func mutationMatchesStoredIdentity(
        _ mutation: PendingMailboxMutation,
        email: EmailMessage
    ) -> Bool {
        guard let expectedGlobalMessageID = mutation.expectedGlobalMessageID else {
            return false
        }
        return mutationIdentity(for: email) == expectedGlobalMessageID
    }

    private func preferredSurvivor(in rows: [EmailMessage]) -> EmailMessage? {
        rows.enumerated().sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element
            let leftHasContent = hasContent(left)
            let rightHasContent = hasContent(right)
            let leftHasAnalyzedContent = leftHasContent
                && EmailAnalysisContract.isCurrentAnalysis(left)
            let rightHasAnalyzedContent = rightHasContent
                && EmailAnalysisContract.isCurrentAnalysis(right)
            if leftHasAnalyzedContent != rightHasAnalyzedContent {
                return leftHasAnalyzedContent
            }
            if leftHasContent != rightHasContent {
                return leftHasContent
            }
            if left.receivedAt != right.receivedAt {
                return left.receivedAt > right.receivedAt
            }
            return lhs.offset < rhs.offset
        }.first?.element
    }

    private func mergeRichContent(
        from rows: [EmailMessage],
        into survivor: EmailMessage
    ) {
        if let bodySource = preferredSurvivor(in: rows.filter(hasContent)) {
            survivor.body = bodySource.body
            survivor.htmlBody = bodySource.htmlBody
        }
        if let analysisSource = rows
            .filter({
                EmailAnalysisContract.matchesAnalysis(
                    $0,
                    subject: survivor.subject,
                    body: survivor.body
                )
            })
            .max(by: { analysisSize($0) < analysisSize($1) }) {
            survivor.analysisStateRaw = analysisSource.analysisStateRaw
            survivor.analysisSummary = analysisSource.analysisSummary
            survivor.analysisDetail = analysisSource.analysisDetail
            survivor.analysisKeyPoints = analysisSource.analysisKeyPoints
            survivor.analysisActionItems = analysisSource.analysisActionItems
            survivor.analysisError = analysisSource.analysisError
            survivor.analysisFailureReasonRaw = analysisSource.analysisFailureReasonRaw
            survivor.analyzedBodyFingerprint = analysisSource.analyzedBodyFingerprint
            survivor.analyzedAt = analysisSource.analyzedAt
            survivor.analysisVersion = analysisSource.analysisVersion
        } else {
            invalidateAnalysisIfStale(for: survivor)
        }
        if rows.contains(where: { $0.analysisTodoCandidate != nil }) {
            let fingerprint = EmailAnalysisContract.fingerprint(subject: survivor.subject, body: survivor.body)
            if let source = rows.first(where: {
                $0.analysisTodoCandidate != nil && $0.analysisTodoCandidateFingerprint == fingerprint
            }) {
                survivor.analysisTodoCandidate = source.analysisTodoCandidate
                survivor.analysisTodoCandidateFingerprint = fingerprint
            } else {
                survivor.analysisTodoCandidate = nil
                survivor.analysisTodoCandidateFingerprint = ""
            }
        }
    }

    private func localID(for metadata: MailboxMessageMetadata) -> String {
        guard metadata.provider == .gmail,
              !metadata.providerGlobalMessageID.isEmpty
        else {
            return metadata.providerMessageID
        }
        return "gmail-imap:\(metadata.providerGlobalMessageID)"
    }

    private func apply(
        _ metadata: MailboxMessageMetadata,
        to email: EmailMessage
    ) {
        if isIdentityMismatch(email: email, metadata: metadata) {
            email.body = ""
            email.htmlBody = nil
            invalidateAnalysis(for: email)
        }
        if metadata.provider != .gmail
            || !metadata.providerGlobalMessageID.isEmpty
            || !email.id.hasPrefix("gmail-imap:")
        {
            email.id = localID(for: metadata)
        }
        email.rawMessageID = metadata.providerMessageID
        email.providerGlobalMessageID = metadata.providerGlobalMessageID
        email.providerRawValue = metadata.provider.rawValue
        email.sourceAccountNamespace = metadata.sourceAccountNamespace
        email.threadID = metadata.threadID
        email.subject = metadata.subject
        email.from = metadata.from
        email.snippet = metadata.snippet
        email.receivedAt = metadata.receivedAt
        email.isRead = metadata.provider == .gmail
            ? (metadata.isRead || email.isRead)
            : metadata.isRead
        email.isInInbox = metadata.isInInbox
        switch metadata.provider {
        case .gmail:
            if !metadata.gmailLabelIDs.isEmpty {
                email.labelIDs = metadata.gmailLabelIDs
                if email.isRead {
                    email.labelIDs.removeAll { $0 == "UNREAD" }
                }
            }
        case .outlook:
            email.labelIDs = []
            email.outlookInferenceClassificationRawValue = metadata.outlookInferenceClassificationRawValue
            email.providerCategoryNames = metadata.providerCategoryNames
            email.providerFolderID = metadata.providerFolderID
        }
    }

    private func isIdentityMismatch(
        email: EmailMessage,
        metadata: MailboxMessageMetadata
    ) -> Bool {
        if !email.providerGlobalMessageID.isEmpty && !metadata.providerGlobalMessageID.isEmpty {
            return email.providerGlobalMessageID != metadata.providerGlobalMessageID
        }

        // Gmail's provider message ID is immutable. Metadata refreshes may change
        // headers (or omit a global ID) without making its cached body stale.
        // The legacy Outlook path lacks that invariant and still uses headers to
        // detect a reused UID until its global ID is populated.
        guard email.provider == .outlook,
              !email.subject.isEmpty || !email.from.isEmpty || email.receivedAt != .distantPast
        else {
            return false
        }
        if !email.subject.isEmpty && email.subject != metadata.subject {
            return true
        }
        if !email.from.isEmpty && email.from != metadata.from {
            return true
        }
        return email.receivedAt != .distantPast && email.receivedAt != metadata.receivedAt
    }
    private func invalidateAnalysis(for email: EmailMessage) {
        EmailAnalysisContract.resetAnalysis(email)
    }

    private func invalidateAnalysisIfStale(for email: EmailMessage) {
        if !email.analysisTodoCandidateFingerprint.isEmpty,
           email.analysisTodoCandidateFingerprint != EmailAnalysisContract.fingerprint(
               subject: email.subject, body: email.body
           ) {
            email.analysisTodoCandidate = nil
            email.analysisTodoCandidateFingerprint = ""
        }
        guard email.analysisState == .analyzed,
              !EmailAnalysisContract.isCurrentAnalysis(email) else {
            return
        }
        invalidateAnalysis(for: email)
    }

    private func hasContent(_ email: EmailMessage) -> Bool {
        !email.body.isEmpty || !(email.htmlBody ?? "").isEmpty
    }



    private func analysisSize(_ email: EmailMessage) -> Int {
        email.analysisSummary.utf8.count
            + email.analysisDetail.utf8.count
            + email.analysisKeyPoints.reduce(0) { $0 + $1.utf8.count }
            + email.analysisActionItems.reduce(0) { $0 + $1.utf8.count }
    }
}
