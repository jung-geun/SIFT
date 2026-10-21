import Foundation
import Testing
@testable import todo

@MainActor
@Suite("EmailMessage provider helpers")
struct EmailMessageProviderTests {
    @Test("기존 Gmail 스타일 메시지는 Gmail 기본값을 유지한다")
    func testGmailDefaults() {
        let email = EmailMessage(
            id: "gmail-raw",
            threadID: "thread-1",
            subject: "Subject",
            from: "sender@example.com",
            snippet: "snippet",
            body: "body",
            htmlBody: nil,
            receivedAt: Date()
        )

        #expect(email.provider == .gmail)
        #expect(email.providerMessageID == "gmail-raw")
        #expect(email.todoSourceRef == "gmail-raw")
    }

    @Test("Outlook 메시지는 provider-safe 식별자를 만든다")
    func testOutlookProviderIdentifiers() {
        let email = EmailMessage(
            id: "outlook-raw",
            threadID: "thread-2",
            subject: "Subject",
            from: "sender@example.com",
            snippet: "snippet",
            body: "body",
            htmlBody: nil,
            receivedAt: Date(),
            provider: .outlook,
            rawMessageID: "outlook-raw"
        )

        #expect(email.provider == .outlook)
        #expect(email.localListID == "outlook:outlook-raw")
        #expect(email.todoSourceRef == "outlook:outlook-raw")
    }
    @Test("Gmail 시스템 라벨은 모든 카테고리 멤버십을 보존한다")
    func testGmailCategoryMappings() {
        let cases: [(String, GmailInboxCategory)] = [
            ("CATEGORY_PERSONAL", .primary),
            ("CATEGORY_PROMOTIONS", .promotions),
            ("CATEGORY_SOCIAL", .social),
            ("CATEGORY_UPDATES", .updates),
            ("CATEGORY_FORUMS", .forums)
        ]

        for (labelID, category) in cases {
            #expect(
                GmailInboxCategory.resolveAll(labelIDs: [labelID])
                    == Set([category])
            )
        }

        #expect(
            GmailInboxCategory.resolveAll(
                labelIDs: ["CATEGORY_PERSONAL", "CATEGORY_UPDATES"]
            ) == Set([.primary, .updates])
        )
    }

    @Test("인식되지 않은 Gmail 라벨은 기본 카테고리이다")
    func testMailCategoryFallbacks() {
        let gmail = EmailMessage(id: "gmail", labelIDs: ["INBOX", "UNREAD"])

        #expect(gmail.gmailInboxCategories == Set([.primary]))
    }

    @Test("Outlook classification은 case-insensitive이고 unknown은 Other로 귀속된다")
    func testOutlookClassificationAndProviderDictionaryKey() {
        let focused = EmailMessage(
            id: "focused",
            provider: .outlook,
            outlookInferenceClassificationRawValue: "FoCuSeD"
        )
        let unknown = EmailMessage(
            id: "unknown",
            provider: .outlook,
            outlookInferenceClassificationRawValue: "unexpected"
        )
        let missing = EmailMessage(id: "missing", provider: .outlook)

        #expect(focused.outlookInboxClassification == .focused)
        #expect(unknown.outlookInboxClassification == .other)
        #expect(missing.outlookInboxClassification == .other)

        let states: [MailProvider: MailboxPagingState] = [
            .gmail: MailboxPagingState(nextCursor: "gmail"),
            .outlook: MailboxPagingState(nextCursor: "outlook")
        ]
        #expect(states[.gmail]?.nextCursor == "gmail")
        #expect(states[.outlook]?.nextCursor == "outlook")
    }

    @Test("메일 분석 기간은 기존 key와 3일 기본값, 1일부터 30일 범위를 유지한다")
    func testEmailAnalysisLookbackPolicyNormalizationAndCutoff() {
        #expect(EmailAnalysisLookbackPolicy.lookbackSettingKey == "pieroot.todo.emailLookbackDays")
        #expect(EmailAnalysisLookbackPolicy.normalizedLookbackDays(-1) == 3)
        #expect(EmailAnalysisLookbackPolicy.normalizedLookbackDays(0) == 3)
        #expect(EmailAnalysisLookbackPolicy.normalizedLookbackDays(1) == 1)
        #expect(EmailAnalysisLookbackPolicy.normalizedLookbackDays(15) == 15)
        #expect(EmailAnalysisLookbackPolicy.normalizedLookbackDays(30) == 30)
        #expect(EmailAnalysisLookbackPolicy.normalizedLookbackDays(31) == 30)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(
            EmailAnalysisLookbackPolicy.cutoff(now: now, lookbackDays: 0)
                == now.addingTimeInterval(-3 * 24 * 60 * 60)
        )
    }

    @Test("분석 후보 filtering은 mailbox 표시 개수와 분리된다")
    func testEmailAnalysisLookbackCandidates() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let recent = EmailMessage(
                id: "recent",
                receivedAt: now.addingTimeInterval(-2 * 24 * 60 * 60),
                isInInbox: true
            )
            let old = EmailMessage(
                id: "old",
                receivedAt: now.addingTimeInterval(-10 * 24 * 60 * 60),
                isInInbox: true
            )
            let archived = EmailMessage(
                id: "archived",
                receivedAt: now,
                isInInbox: false
            )
            let emails = [recent, old, archived]
            let displayCount = emails.filter(\.isInInbox).count
            #expect(
                mailboxAnalysisCandidates(
                    from: emails,
                    lookbackDays: 1,
                    now: now
                ).isEmpty
            )
            #expect(
                mailboxAnalysisCandidates(
                    from: emails,
                    lookbackDays: 30,
                    now: now
                ).count == 2
            )
            #expect(emails.filter(\.isInInbox).count == displayCount)
    }

    @Test("Laya 설치 후 이미 요약된 메일도 한 번 분류하고 아니오 결과는 유지한다")
    func analyzedInboxMailWithoutVerdictGetsClassifiedOnce() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let email = EmailMessage(
            id: "classified-later",
            subject: "프로젝트 검토",
            body: "검토 후 답장해 주세요.",
            receivedAt: now,
            isInInbox: true
        )
        email.analysisState = .analyzed
        email.analysisVersion = EmailAnalysisContract.summaryContractVersion

        #expect(mailboxAnalysisCandidates(from: [email], lookbackDays: 7, now: now).isEmpty)
        #expect(mailboxAnalysisCandidates(
            from: [email], lookbackDays: 7, now: now, includeUnclassified: true
        ).count == 1)
        email.analysisTodoCandidate = false
        #expect(mailboxAnalysisCandidates(
            from: [email], lookbackDays: 7, now: now, includeUnclassified: true
        ).isEmpty)
        email.analysisVersion -= 1
        #expect(mailboxAnalysisCandidates(
            from: [email], lookbackDays: 7, now: now
        ).count == 1)
    }

}
