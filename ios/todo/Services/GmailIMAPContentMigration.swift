import Foundation
import SwiftData

/// Invalidates Gmail IMAP-derived content when parsing behavior changes.
///
/// Rewritten rows are saved, both dependent cursors are cleared, and only then is
/// the per-account version stamped. This ordering keeps the migration retryable if
/// the process terminates after saving but before the version marker is committed.
@MainActor
enum GmailIMAPContentMigration {
    static let currentVersion = 2

    private static let versionKeyPrefix = "pieroot.todo.gmailIMAP.contentVersion."

    @discardableResult
    static func migrateIfNeeded(
        account: String,
        context: ModelContext,
        defaults: UserDefaults = .standard
    ) throws -> Bool {
        let canonicalAccount = account.lowercased()
        let versionKey = versionKeyPrefix + canonicalAccount
        guard defaults.integer(forKey: versionKey) != currentVersion else { return false }

        let rows = try context.fetch(FetchDescriptor<EmailMessage>())
            .filter { $0.provider == .gmail && $0.sourceAccountNamespace == canonicalAccount }
        for row in rows {
            row.subject = MIMETextDecoder.decodeRFC2047(row.subject)
            row.from = MIMETextDecoder.decodeRFC2047(row.from)
            row.body = ""
            row.htmlBody = nil
            EmailAnalysisContract.resetAnalysis(row)

            if let globalMessageID = globalMessageID(from: row.id) {
                let fingerprint = MailAnalysisFingerprint.make(
                    provider: "gmail-imap",
                    canonicalAccount: canonicalAccount,
                    gmailMessageID: globalMessageID,
                    key: MailAnalysisLedgerKeyStore.key()
                )
                try MailAnalysisLedgerStore.shared.reset(fingerprint)
            }
        }

        // Save the rewritten rows before invalidating either cursor. Cursor
        // invalidation happens before the version stamp so a termination between
        // these operations retries the migration instead of stranding blank rows
        // behind a still-current cursor.
        if !rows.isEmpty {
            try context.save()
            MailboxUpdateCursorStore(defaults: defaults)
                .clearCursor(for: .gmail, namespace: canonicalAccount)
            GmailIMAPIngestionCursorStore(defaults: defaults)
                .clearCursor(for: canonicalAccount)
        }
        defaults.set(currentVersion, forKey: versionKey)
        return !rows.isEmpty
    }

    private static func globalMessageID(from localID: String) -> String? {
        let prefix = "gmail-imap:"
        guard localID.hasPrefix(prefix) else { return nil }
        let value = String(localID.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }
}
