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
        for row in existing {
            context.delete(row)
        }

        let now = Date()
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
                isRead: true,
                provider: .gmail,
                rawMessageID: "ui-test-fixture-mail-\(index)",
                labelIDs: ["INBOX"],
                isInInbox: true,
                sourceAccountNamespace: namespace
            )
            if index == 1 {
                email.analysisTodoCandidate = true
                email.analysisTodoCandidateFingerprint = EmailAnalysisContract.fingerprint(
                    subject: email.subject, body: email.body
                )
            }
            context.insert(email)
        }
        try? context.save()
    }
}
#endif
