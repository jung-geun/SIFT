import Foundation
import SwiftData

struct PendingMailboxMutation: Codable, Hashable {
    let providerRawValue: String
    let sourceAccountNamespace: String
    let providerMessageID: String
    let action: MailboxMutationAction

    init(providerRawValue: String, sourceAccountNamespace: String = "", providerMessageID: String, action: MailboxMutationAction) {
        self.providerRawValue = providerRawValue
        self.sourceAccountNamespace = sourceAccountNamespace
        self.providerMessageID = providerMessageID
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case providerRawValue, sourceAccountNamespace, providerMessageID, action
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        providerRawValue = try values.decode(String.self, forKey: .providerRawValue)
        sourceAccountNamespace = try values.decodeIfPresent(String.self, forKey: .sourceAccountNamespace) ?? ""
        providerMessageID = try values.decode(String.self, forKey: .providerMessageID)
        action = try values.decode(MailboxMutationAction.self, forKey: .action)
    }
}

struct MailboxPendingMutationStore {
    private let defaults: UserDefaults
    private let key = "pieroot.todo.mailbox.pendingMutations.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var mutations: Set<PendingMailboxMutation> {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(
                Set<PendingMailboxMutation>.self,
                from: data
              ) else {
            return []
        }
        return decoded
    }

    func insert(_ mutation: PendingMailboxMutation) {
        var updated = mutations
        updated.insert(mutation)
        persist(updated)
    }

    func remove(_ mutations: Set<PendingMailboxMutation>) {
        guard !mutations.isEmpty else { return }
        var updated = self.mutations
        updated.subtract(mutations)
        persist(updated)
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

    private let pendingStore: MailboxPendingMutationStore
    private let saveContext: (ModelContext) throws -> Void

    init(
        defaults: UserDefaults,
        saveContext: @escaping (ModelContext) throws -> Void
    ) {
        pendingStore = MailboxPendingMutationStore(defaults: defaults)
        self.saveContext = saveContext
    }

    private struct EmailState {
        let id: String; let rawMessageID: String; let providerRawValue: String
        let sourceAccountNamespace: String; let threadID: String; let subject: String
        let from: String; let snippet: String; let body: String; let htmlBody: String?; let receivedAt: Date
        let isRead: Bool; let labelIDs: [String]; let isInInbox: Bool
        let outlookInferenceClassificationRawValue: String; let providerCategoryNames: [String]; let providerFolderID: String
        let analysisStateRaw: String; let analysisSummary: String; let analysisDetail: String
        let analysisKeyPoints: [String]; let analysisActionItems: [String]; let analysisError: String
        let analyzedBodyFingerprint: String; let analyzedAt: Date?; let analysisVersion: Int

        init(_ email: EmailMessage) {
            id = email.id; rawMessageID = email.rawMessageID; providerRawValue = email.providerRawValue
            sourceAccountNamespace = email.sourceAccountNamespace; threadID = email.threadID; subject = email.subject
            from = email.from; snippet = email.snippet; body = email.body; htmlBody = email.htmlBody; receivedAt = email.receivedAt
            isRead = email.isRead; labelIDs = email.labelIDs; isInInbox = email.isInInbox
            outlookInferenceClassificationRawValue = email.outlookInferenceClassificationRawValue; providerCategoryNames = email.providerCategoryNames; providerFolderID = email.providerFolderID
            analysisStateRaw = email.analysisStateRaw; analysisSummary = email.analysisSummary; analysisDetail = email.analysisDetail
            analysisKeyPoints = email.analysisKeyPoints; analysisActionItems = email.analysisActionItems; analysisError = email.analysisError
            analyzedBodyFingerprint = email.analyzedBodyFingerprint; analyzedAt = email.analyzedAt; analysisVersion = email.analysisVersion
        }

        func restore(_ email: EmailMessage) {
            email.id = id; email.rawMessageID = rawMessageID; email.providerRawValue = providerRawValue
            email.sourceAccountNamespace = sourceAccountNamespace; email.threadID = threadID; email.subject = subject
            email.from = from; email.snippet = snippet; email.body = body; email.htmlBody = htmlBody; email.receivedAt = receivedAt
            email.isRead = isRead; email.labelIDs = labelIDs; email.isInInbox = isInInbox
            email.outlookInferenceClassificationRawValue = outlookInferenceClassificationRawValue; email.providerCategoryNames = providerCategoryNames; email.providerFolderID = providerFolderID
            email.analysisStateRaw = analysisStateRaw; email.analysisSummary = analysisSummary; email.analysisDetail = analysisDetail
            email.analysisKeyPoints = analysisKeyPoints; email.analysisActionItems = analysisActionItems; email.analysisError = analysisError
            email.analyzedBodyFingerprint = analyzedBodyFingerprint; email.analyzedAt = analyzedAt; email.analysisVersion = analysisVersion
        }
    }

    func upsert(_ page: MailboxPage, into context: ModelContext) throws {
        let originalRows = try context.fetch(FetchDescriptor<EmailMessage>())
        let originalStates = Dictionary(uniqueKeysWithValues: originalRows.map { (ObjectIdentifier($0), EmailState($0)) })
        let providers = Set(page.messages.map(\.provider))
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
                    id: metadata.providerMessageID,
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
        let pending = pendingStore.mutations
        guard !pending.isEmpty else { return }

        let rows = try context.fetch(FetchDescriptor<EmailMessage>())
        let rowsByKey = Dictionary(grouping: rows, by: EmailMessageKey.init)
            .compactMapValues(\.first)
        var requiresSave = false
        var applied = Set<PendingMailboxMutation>()
        for mutation in pending {
            guard currentNamespace == nil || mutation.sourceAccountNamespace == currentNamespace else { continue }
            let key = EmailMessageKey(
                providerRawValue: mutation.providerRawValue,
                sourceAccountNamespace: mutation.sourceAccountNamespace,
                providerMessageID: mutation.providerMessageID
            )
            guard let email = rowsByKey[key] else { continue }
            switch mutation.action {
            case .markAsRead:
                email.isRead = true
                if email.provider == .gmail {
                    email.labelIDs.removeAll { $0 == "UNREAD" }
                }
            case .trash:
                email.isInInbox = false
                context.delete(email)
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

        let normalizedHTML = content.htmlBody.isEmpty ? nil : content.htmlBody
        let bodyChanged = email.body != content.body
            || email.htmlBody != normalizedHTML
        email.body = content.body
        email.htmlBody = normalizedHTML
        apply(content.metadata, to: email)
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
        let previousIsRead = email.isRead
        let previousLabelIDs = email.labelIDs
        email.isRead = true
        if email.provider == .gmail {
            email.labelIDs.removeAll { $0 == "UNREAD" }
        }

        do {
            try await remote()
        } catch {
            email.isRead = previousIsRead
            email.labelIDs = previousLabelIDs
            throw error
        }

        let mutation = pendingMutation(for: email, action: .markAsRead)
        do {
            try saveContext(context)
            pendingStore.remove([mutation])
        } catch {
            pendingStore.insert(mutation)
            throw MailboxMutationError.remoteCommittedLocalSaveFailed(
                provider: email.provider,
                action: .markAsRead
            )
        }
    }

    func trash(
        _ email: EmailMessage,
        in context: ModelContext,
        remote: () async throws -> Void
    ) async throws {
        try await remote()

        let provider = email.provider
        let mutation = pendingMutation(for: email, action: .trash)
        email.isInInbox = false
        context.delete(email)
        do {
            try saveContext(context)
            pendingStore.remove([mutation])
        } catch {
            context.rollback()
            email.isInInbox = false
            pendingStore.insert(mutation)
            throw MailboxMutationError.remoteCommittedLocalSaveFailed(
                provider: provider,
                action: .trash
            )
        }
    }

    private func pendingMutation(
        for email: EmailMessage,
        action: MailboxMutationAction
    ) -> PendingMailboxMutation {
        PendingMailboxMutation(
            providerRawValue: email.providerRawValue,
            sourceAccountNamespace: email.sourceAccountNamespace,
            providerMessageID: email.providerMessageID,
            action: action
        )
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
            survivor.analyzedBodyFingerprint = analysisSource.analyzedBodyFingerprint
            survivor.analyzedAt = analysisSource.analyzedAt
            survivor.analysisVersion = analysisSource.analysisVersion
        } else {
            invalidateAnalysisIfStale(for: survivor)
        }
    }

    private func apply(
        _ metadata: MailboxMessageMetadata,
        to email: EmailMessage
    ) {
        email.id = metadata.providerMessageID
        email.rawMessageID = metadata.providerMessageID
        email.providerRawValue = metadata.provider.rawValue
        email.sourceAccountNamespace = metadata.sourceAccountNamespace
        email.threadID = metadata.threadID
        email.subject = metadata.subject
        email.from = metadata.from
        email.snippet = metadata.snippet
        email.receivedAt = metadata.receivedAt
        email.isRead = metadata.isRead
        email.isInInbox = metadata.isInInbox
        switch metadata.provider {
        case .gmail:
            email.labelIDs = metadata.gmailLabelIDs
        case .outlook:
            email.labelIDs = []
            email.outlookInferenceClassificationRawValue = metadata.outlookInferenceClassificationRawValue
            email.providerCategoryNames = metadata.providerCategoryNames
            email.providerFolderID = metadata.providerFolderID
        }
    }

    private func invalidateAnalysis(for email: EmailMessage) {
        EmailAnalysisContract.resetAnalysis(email)
    }

    private func invalidateAnalysisIfStale(for email: EmailMessage) {
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
