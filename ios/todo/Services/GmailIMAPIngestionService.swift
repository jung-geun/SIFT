import Foundation
import SwiftData

/// Durable per-account cursor for Gmail *background analysis ingestion* only.
///
/// This is intentionally distinct from `MailboxUpdateCursorStore`, which tracks the
/// UI's list-metadata sync: loading mail into `MailTabView` must never be treated as
/// "already handled by the analysis pipeline", and vice versa.
struct GmailIMAPIngestionCursorStore {
    private let defaults: UserDefaults
    private let keyPrefix = "pieroot.todo.gmailIMAP.ingestionCursor."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var userDefaults: UserDefaults {
        defaults
    }

    func cursor(for account: String) -> String? {
        defaults.string(forKey: keyPrefix + account.lowercased())
    }

    func setCursor(_ cursor: String, for account: String) {
        defaults.set(cursor, forKey: keyPrefix + account.lowercased())
    }

    func clearCursor(for account: String) {
        defaults.removeObject(forKey: keyPrefix + account.lowercased())
    }
}

@MainActor
final class GmailIMAPIngestionService {
    struct Result: Sendable {
        let analyzedCount: Int
        let skippedCount: Int
    }

    // Parser/content migration revision. A higher revision reclaims an old
    // analyzed ledger record even when an older row lost its stable global ID.
    private static let analysisRevision = 2

    private let emailContext: ModelContext
    private let imapService: GmailIMAPService
    private let cursorStore: GmailIMAPIngestionCursorStore
    /// Separate from the email content container so a durable analysis claim
    /// cannot substitute for a missing local email row after that store resets.
    private let ledgerStore: MailAnalysisLedgerStore

    init(
        emailContext: ModelContext,
        imapService: GmailIMAPService? = nil,
        cursorStore: GmailIMAPIngestionCursorStore? = nil,
        ledgerStore: MailAnalysisLedgerStore? = nil
    ) {
        self.emailContext = emailContext
        self.imapService = imapService ?? .shared
        self.cursorStore = cursorStore ?? .init()
        self.ledgerStore = ledgerStore ?? .shared
    }

    /// Deterministic baseline/update policy:
    /// - No stored cursor: process exactly one bounded head page, then persist its
    ///   newest anchor as the ingestion baseline. This never backfills all history.
    /// - Stored cursor: drain up to `MailboxPagingPolicy.maxUpdateDrainPages` newer
    ///   pages, persisting the cursor only after each page's rows are saved. A burst
    ///   larger than that cap continues from the persisted cursor on the next run.
    /// A thrown error (network, save, analysis) leaves the previous cursor untouched,
    /// so the same page range is retried — not skipped — on the next sync.
    func sync(account rawAccount: String, backgroundEnabled: Bool) async throws -> Result {
        guard let account = IMAPCredentialStore.canonicalAccount(rawAccount) else {
            throw GmailIMAPError.missingCredential
        }
        try await imapService.authenticate(email: account, backgroundEnabled: backgroundEnabled)
        let sessionGeneration = await imapService.sessionGeneration
        try await ensureAccount(account, generation: sessionGeneration)
        try GmailIMAPContentMigration.migrateIfNeeded(
            account: account,
            context: emailContext,
            defaults: cursorStore.userDefaults
        )

        let canonicalAccount = account
        let descriptor = FetchDescriptor<EmailMessage>(
            predicate: #Predicate { $0.providerRawValue == "gmail" && $0.sourceAccountNamespace == canonicalAccount }
        )
        let cached = try emailContext.fetch(descriptor)
        // Metadata sync may have already inserted a body-less row for the same
        // message. Only hydrated rows are complete enough to suppress ingestion.
        var existingRowsByKey: [EmailMessageKey: EmailMessage] = [:]
        for row in cached {
            let key = EmailMessageKey(
                providerRawValue: row.providerRawValue,
                sourceAccountNamespace: row.sourceAccountNamespace,
                providerMessageID: row.providerMessageID
            )
            guard let current = existingRowsByKey[key] else {
                existingRowsByKey[key] = row
                continue
            }
            let currentScore = (EmailAnalysisContract.isCurrentAnalysis(current) ? 2 : 0)
                + (current.body.isEmpty ? 0 : 1)
            let candidateScore = (EmailAnalysisContract.isCurrentAnalysis(row) ? 2 : 0)
                + (row.body.isEmpty ? 0 : 1)
            if candidateScore > currentScore
                || (candidateScore == currentScore && row.receivedAt > current.receivedAt) {
                existingRowsByKey[key] = row
            }
        }
        var knownKeys = Set(
            existingRowsByKey.compactMap { key, row in
                EmailAnalysisContract.isCurrentAnalysis(row) ? key : nil
            }
        )

        var analyzed = 0
        var skipped = 0

        if let cursor = cursorStore.cursor(for: account) {
            var currentCursor = cursor
            var iterations = 0
            while iterations < MailboxPagingPolicy.maxUpdateDrainPages {
                let page = try await imapService.fetchInboxUpdates(newerThan: currentCursor)
                try await ensureAccount(account, generation: sessionGeneration)
                guard page.messages.allSatisfy({ $0.sourceAccountNamespace == account }) else {
                    throw GmailIMAPError.authenticationFailed
                }
                if page.requiresInboxReconcile {
                    try resetLocalNamespace(account: account)
                    existingRowsByKey = existingRowsByKey.filter { $0.key.sourceAccountNamespace != account }
                    knownKeys = knownKeys.filter { $0.sourceAccountNamespace != account }
                }
                let outcome = try await process(
                    page,
                    account: account,
                    generation: sessionGeneration,
                    knownKeys: &knownKeys,
                    existingRowsByKey: &existingRowsByKey
                )
                analyzed += outcome.analyzedCount
                skipped += outcome.skippedCount
                iterations += 1
                guard let newestCursor = page.newestCursor, newestCursor != currentCursor else { break }
                try await ensureAccount(account, generation: sessionGeneration)
                cursorStore.setCursor(newestCursor, for: account)
                currentCursor = newestCursor
                guard page.hasMoreUpdates else { break }
            }
        } else {
            let page = try await imapService.fetchInboxPage(after: nil)
            try await ensureAccount(account, generation: sessionGeneration)
            guard page.messages.allSatisfy({ $0.sourceAccountNamespace == account }) else {
                throw GmailIMAPError.authenticationFailed
            }
            if page.requiresInboxReconcile {
                try resetLocalNamespace(account: account)
                existingRowsByKey = existingRowsByKey.filter { $0.key.sourceAccountNamespace != account }
                knownKeys = knownKeys.filter { $0.sourceAccountNamespace != account }
            }
            let outcome = try await process(
                page,
                account: account,
                generation: sessionGeneration,
                knownKeys: &knownKeys,
                existingRowsByKey: &existingRowsByKey
            )
            analyzed += outcome.analyzedCount
            skipped += outcome.skippedCount
            if let newestCursor = page.newestCursor {
                try await ensureAccount(account, generation: sessionGeneration)
                cursorStore.setCursor(newestCursor, for: account)
            }
        }

        return Result(analyzedCount: analyzed, skippedCount: skipped)
    }

    /// Processes one page's messages against the existing ledger/fingerprint/body-fetch
    /// /analyze pipeline. `knownKeys` is threaded through (and grown) across pages so a
    /// multi-page drain never re-inserts a row a prior page in the same run just saved.
    private func process(
        _ page: MailboxPage,
        account: String,
        generation: Int,
        knownKeys: inout Set<EmailMessageKey>,
        existingRowsByKey: inout [EmailMessageKey: EmailMessage]
    ) async throws -> Result {
        var analyzed = 0
        var skipped = 0

        for metadata in page.messages {
            guard !metadata.providerGlobalMessageID.isEmpty else { continue }
            let fingerprint = MailAnalysisFingerprint.make(
                provider: "gmail-imap",
                canonicalAccount: account,
                gmailMessageID: metadata.providerGlobalMessageID,
                key: MailAnalysisLedgerKeyStore.key()
            )
            let key = EmailMessageKey(
                providerRawValue: MailProvider.gmail.rawValue,
                sourceAccountNamespace: account,
                providerMessageID: metadata.providerMessageID
            )
            guard !knownKeys.contains(key) else {
                skipped += 1
                continue
            }
            if page.requiresInboxReconcile {
                try ledgerStore.reset(fingerprint)
            }
            var claimOutcome = try ledgerStore.claimOutcome(
                fingerprint,
                revision: Self.analysisRevision
            )
            // The analysis ledger is durable separately from EmailMessage. If
            // the current email context has no analyzed row, an old ledger
            // result must be reclaimed rather than advancing the cursor and
            // leaving this message permanently absent from the local mailbox.
            if claimOutcome == .alreadyAnalyzed {
                try ledgerStore.reset(fingerprint)
                claimOutcome = try ledgerStore.claimOutcome(
                    fingerprint,
                    revision: Self.analysisRevision
                )
            }
            switch claimOutcome {
            case .acquired:
                break
            case .alreadyAnalyzed:
                skipped += 1
                continue
            case .leased:
                throw GmailIMAPError.analysisLeased
            }

            do {
                try await ensureAccount(account, generation: generation)
                let content = try await imapService.fetchMessageContent(messageID: metadata.providerMessageID)
                try await ensureAccount(account, generation: generation)
                guard content.metadata.sourceAccountNamespace == account,
                      content.metadata.providerMessageID == metadata.providerMessageID
                else {
                    throw GmailIMAPError.authenticationFailed
                }
            let email: EmailMessage
            if let existing = existingRowsByKey[key] {
                email = existing
                email.id = "gmail-imap:\(metadata.providerGlobalMessageID)"
                email.threadID = metadata.threadID
                email.subject = metadata.subject
                email.from = metadata.from
                email.snippet = metadata.snippet
                email.body = content.body
                email.htmlBody = content.htmlBody
                email.receivedAt = metadata.receivedAt
                email.isRead = metadata.isRead || email.isRead
                email.providerRawValue = MailProvider.gmail.rawValue
                email.rawMessageID = metadata.providerMessageID
                if !metadata.gmailLabelIDs.isEmpty {
                    email.labelIDs = metadata.gmailLabelIDs
                    if email.isRead {
                        email.labelIDs.removeAll { $0 == "UNREAD" }
                    }
                }
                email.isInInbox = true
                email.providerFolderID = metadata.providerFolderID
                email.sourceAccountNamespace = account
            } else {
                email = EmailMessage(
                    id: "gmail-imap:\(metadata.providerGlobalMessageID)",
                    threadID: metadata.threadID,
                    subject: metadata.subject,
                    from: metadata.from,
                    snippet: metadata.snippet,
                    body: content.body,
                    htmlBody: content.htmlBody,
                    receivedAt: metadata.receivedAt,
                    isRead: metadata.isRead,
                    rawMessageID: metadata.providerMessageID,
                    labelIDs: metadata.gmailLabelIDs,
                    isInInbox: true,
                    providerFolderID: metadata.providerFolderID,
                    sourceAccountNamespace: account
                )
                emailContext.insert(email)
                existingRowsByKey[key] = email
            }
            try emailContext.save()
            knownKeys.insert(key)
            try await EmailMessageAnalysisService.shared.analyze(email, context: emailContext)
            guard email.analysisState == .analyzed else {
                throw GmailIMAPError.analysisFailed
            }
            try ledgerStore.markAnalyzed(
                fingerprint,
                revision: Self.analysisRevision
            )
            analyzed += 1
            } catch {
                try? ledgerStore.release(fingerprint)
                throw error
            }
    }
        return Result(analyzedCount: analyzed, skippedCount: skipped)
    }

    private func ensureAccount(_ expected: String, generation: Int) async throws {
        guard await imapService.authenticatedAccount == expected,
              await imapService.sessionGeneration == generation
        else {
            throw GmailIMAPError.authenticationFailed
        }
    }

    private func resetLocalNamespace(account: String) throws {
        let rows = try emailContext.fetch(FetchDescriptor<EmailMessage>())
        for row in rows where row.provider == .gmail && row.sourceAccountNamespace == account {
            row.body = ""
            row.htmlBody = nil
            row.isInInbox = false
            EmailAnalysisContract.resetAnalysis(row)
        }
        try emailContext.save()
    }
}
