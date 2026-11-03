import Foundation
import SwiftData

#if DEBUG
/// DEBUG-only, launch-argument-gated Mail inbox fixture for UI tests.
///
/// Inert unless launched with the exact argument `launchArgument`. When active it
/// seeds a few safe, synthetic Gmail rows into the on-device email store (never the
/// real mailbox) so `MailTabView` can render a populated inbox deterministically,
/// without any live IMAP authentication or network access. Excluded from Release
/// builds by `#if DEBUG`.
enum MailUITestFixture {
    /// Exact launch argument that activates the fixture. Absent by default in every
    /// other launch, including production and every other UI test.
    static let launchArgument = "-ui-test-mail-fixture"
    /// Optional attention/summary scenario; requires the base fixture argument too.
    static let attentionLaunchArgument = "-ui-test-mail-attention-fixture"
    /// Keep synthetic rows on relaunch to exercise durable app-viewed state.
    static let preserveLaunchArgument = "-ui-test-mail-fixture-preserve"

    /// Synthetic Gmail account the seeded rows are scoped to. Contains "@" and no
    /// whitespace so `IMAPCredentialStore.canonicalAccount` accepts it and
    /// `MailTabView.activeGmailNamespace` / `MailboxCachedProviderAccess` resolve it.
    static let gmailAccount = "ui-test-fixture@example.com"

    /// Distinctive subject of the first (topmost) seeded row — the accessibility
    /// anchor the focused UI test looks up directly under the mailbox header.
    static let firstRowSubject = "\(subjectPrefix) — Row 1"

    private static let subjectPrefix = "SIFT UI Test Fixture"
    private static let seededRowCount = 3

    /// True only when this exact launch argument was passed.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Replaces only synthetic fixture rows in `emailContainer` with a fresh,
    /// deterministic set. The fixture account is supplied through the launch
    /// argument domain, so this never persists test credentials.
    static func seedIfNeeded(into emailContainer: ModelContainer) {
        guard isEnabled else {
            if UserDefaults.standard.string(forKey: "pieroot.todo.imap.account") == gmailAccount {
                UserDefaults.standard.removeObject(forKey: "pieroot.todo.imap.account")
            }
            return
        }

        let namespace = IMAPCredentialStore.canonicalAccount(gmailAccount) ?? gmailAccount
        let stagedTrashStore = MailboxMutationStore(defaults: .standard, queue: .deferred)
        stagedTrashStore.remove(
            stagedTrashStore.mutations.filter {
                $0.sourceAccountNamespace == namespace
            }
        )
        let context = ModelContext(emailContainer)
        let existing = (try? context.fetch(
            FetchDescriptor<EmailMessage>(
                predicate: #Predicate { $0.sourceAccountNamespace == namespace }
            )
        )) ?? []
        if ProcessInfo.processInfo.arguments.contains(preserveLaunchArgument), !existing.isEmpty {
            return
        }
        for row in existing {
            context.delete(row)
        }

        let now = Date()
        let showsAttentionScenario = ProcessInfo.processInfo.arguments.contains(attentionLaunchArgument)
        for index in 1...seededRowCount {
            let subject = index == 1 ? firstRowSubject : "\(subjectPrefix) — Row \(index)"
            let email = EmailMessage(
                id: "gmail-imap:900\(index)",
                threadID: "ui-test-fixture-thread-\(index)",
                subject: subject,
                from: "Fixture Sender <fixture-sender@example.com>",
                snippet: "Deterministic UI-test fixture row \(index). Never live mail.",
                body: "Deterministic UI-test fixture row \(index). Never live mail.",
                receivedAt: now.addingTimeInterval(TimeInterval(-index * 60)),
                isRead: !showsAttentionScenario || index != 2,
                provider: .gmail,
                rawMessageID: "ui-test-fixture-mail-\(index)",
                labelIDs: showsAttentionScenario && index == 2 ? ["INBOX", "UNREAD"] : ["INBOX"],
                isInInbox: true,
                sourceAccountNamespace: namespace
            )
            email.bodyContentVersion = 1
            if index == 1 {
                email.body = "The synthetic fixture token expired. Review required settings. Renew the fixture token if it is still needed."
                email.htmlBody = """
                    <html><body style="margin:0;padding:24px;background:#151515;color:#ffffff">
                    <h2>Synthetic token notice</h2>
                    <p>The synthetic fixture token expired. Review required settings.</p>
                    <p>Renew the fixture token if it is still needed.</p>
                    </body></html>
                    """
                email.analysisSummary = "The synthetic fixture token expired. Review its settings and renew it if still needed."
                email.analysisActionItems = [
                    "SIFT UI Test Fixture — Review required settings",
                    "SIFT UI Test Fixture — Renew token if needed"
                ]
            } else if index == 3 {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                let due = formatter.string(from: now)
                email.body = "Please check the first fixture reservation and check the second fixture reservation. Both reviews are due by \(due)."
                email.analysisSummary = "Both synthetic fixture reservations need review by \(due)."
                email.analysisActionItems = [
                    "SIFT UI Test Fixture — First reservation check",
                    "SIFT UI Test Fixture — Second reservation check"
                ]
            } else {
                email.body = "The synthetic fixture deployment completed successfully. No recipient action is required."
                email.analysisSummary = "The synthetic fixture deployment completed successfully."
            }
            email.analysisState = .analyzed
            email.analyzedBodyFingerprint = EmailAnalysisContract.fingerprint(
                subject: email.subject, body: email.body
            )
            email.analysisVersion = EmailAnalysisContract.summaryContractVersion
            email.analyzedAt = now
            if showsAttentionScenario {
                // Row 1: provider-read but newly imported/unopened in SIFT.
                // Row 2: provider-unread but already viewed in SIFT. Row 3: legacy cache.
                email.hasBeenViewedInApp = index != 1
            }
            email.analysisTodoCandidate = !email.analysisActionItems.isEmpty
            email.analysisTodoCandidateFingerprint = email.analyzedBodyFingerprint
            context.insert(email)
        }
        try? context.save()
    }
}
#endif
