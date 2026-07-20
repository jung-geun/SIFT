import Foundation
import SwiftData
import Testing
@testable import todo

@MainActor
@Suite("Mailbox paging local store", .serialized)
struct MailboxPagingTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([EmailMessage.self])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MailboxPagingTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suiteName))
    }

    private func metadata(
        provider: MailProvider,
        id: String,
        receivedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        isRead: Bool = false,
        isInInbox: Bool = true,
        labels: [String] = [],
        classification: String = "",
        categories: [String] = [],
        folderID: String = ""
    ) -> MailboxMessageMetadata {
        MailboxMessageMetadata(
            provider: provider,
            providerMessageID: id,
            threadID: "thread-\(id)",
            subject: "subject-\(id)",
            from: "sender-\(id)@example.com",
            snippet: "snippet-\(id)",
            receivedAt: receivedAt,
            isRead: isRead,
            isInInbox: isInInbox,
            gmailLabelIDs: labels,
            outlookInferenceClassificationRawValue: classification,
            providerCategoryNames: categories,
            providerFolderID: folderID
        )
    }

    @Test("duplicate upsert는 analyzed body survivor와 analysis를 보존한다")
    func testUpsertChoosesRichAnalyzedSurvivor() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let rich = EmailMessage(
            id: "same",
            subject: "subject-same",
            body: "analyzed body",
            htmlBody: "<p>analyzed HTML</p>",
            receivedAt: Date(timeIntervalSince1970: 100),
            provider: .gmail,
            rawMessageID: "same",
            labelIDs: ["INBOX"],
            isInInbox: true
        )
        rich.analysisState = .analyzed
        rich.analysisSummary = "preserved summary"
        rich.analysisDetail = "preserved detail"
        rich.analyzedBodyFingerprint = EmailAnalysisContract.fingerprint(
            subject: "subject-same",
            body: "analyzed body"
        )
        rich.analysisVersion = EmailAnalysisContract.summaryContractVersion
        let bodyOnly = EmailMessage(
            id: "same",
            subject: "newer-body",
            body: "a much longer but unanalyzed body",
            receivedAt: Date(timeIntervalSince1970: 300),
            provider: .gmail,
            rawMessageID: "same",
            isInInbox: true
        )
        let newestEmpty = EmailMessage(
            id: "same",
            subject: "newest-empty",
            receivedAt: Date(timeIntervalSince1970: 400),
            provider: .gmail,
            rawMessageID: "same",
            isInInbox: true
        )
        context.insert(rich)
        context.insert(bodyOnly)
        context.insert(newestEmpty)
        try context.save()

        var saveCount = 0
        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: {
                saveCount += 1
                try $0.save()
            }
        )
        let page = MailboxPage(
            messages: [
                metadata(
                    provider: .gmail,
                    id: "same",
                    receivedAt: Date(timeIntervalSince1970: 500),
                    isRead: true,
                    labels: ["INBOX", "CATEGORY_UPDATES"]
                )
            ],
            nextCursor: "next"
        )
        try store.upsert(page, into: context)

        let rows = try context.fetch(FetchDescriptor<EmailMessage>())
        let survivor = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(survivor === rich)
        #expect(survivor.subject == "subject-same")
        #expect(survivor.body == "analyzed body")
        #expect(survivor.htmlBody == "<p>analyzed HTML</p>")
        #expect(survivor.analysisState == .analyzed)
        #expect(survivor.analysisSummary == "preserved summary")
        #expect(survivor.analysisDetail == "preserved detail")
        #expect(
            survivor.analyzedBodyFingerprint
                == EmailAnalysisContract.fingerprint(
                    subject: "subject-same",
                    body: "analyzed body"
                )
        )
        #expect(
            survivor.analysisVersion
                == EmailAnalysisContract.summaryContractVersion
        )
        #expect(survivor.isRead)
        #expect(survivor.gmailInboxCategories == Set([.updates]))
        #expect(saveCount == 1)
    }

    @Test("duplicate upsert는 다른 본문의 analysis를 survivor에 붙이지 않는다")
    func testUpsertInvalidatesMismatchedDuplicateAnalysis() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let staleAnalysis = EmailMessage(
            id: "mismatch",
            subject: "subject-mismatch",
            receivedAt: Date(timeIntervalSince1970: 100),
            provider: .gmail,
            rawMessageID: "mismatch",
            isInInbox: true
        )
        staleAnalysis.analysisState = .analyzed
        staleAnalysis.analysisSummary = "must not survive"
        staleAnalysis.analysisDetail = "must not survive"
        staleAnalysis.analyzedBodyFingerprint = EmailAnalysisContract.fingerprint(
            subject: "subject-mismatch",
            body: "different duplicate body"
        )
        staleAnalysis.analysisVersion = EmailAnalysisContract.summaryContractVersion

        let bodySource = EmailMessage(
            id: "mismatch",
            subject: "subject-mismatch",
            body: "current duplicate body",
            htmlBody: "<p>current duplicate body</p>",
            receivedAt: Date(timeIntervalSince1970: 200),
            provider: .gmail,
            rawMessageID: "mismatch",
            isInInbox: true
        )
        context.insert(staleAnalysis)
        context.insert(bodySource)
        try context.save()

        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: { try $0.save() }
        )
        try store.upsert(
            MailboxPage(
                messages: [
                    metadata(
                        provider: .gmail,
                        id: "mismatch",
                        receivedAt: Date(timeIntervalSince1970: 300),
                        labels: ["INBOX"]
                    )
                ],
                nextCursor: nil
            ),
            into: context
        )

        let rows = try context.fetch(FetchDescriptor<EmailMessage>())
        let survivor = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(survivor === bodySource)
        #expect(survivor.body == "current duplicate body")
        #expect(survivor.htmlBody == "<p>current duplicate body</p>")
        #expect(survivor.analysisState == .unanalyzed)
        #expect(survivor.analysisSummary.isEmpty)
        #expect(survivor.analysisDetail.isEmpty)
        #expect(survivor.analyzedBodyFingerprint.isEmpty)
        #expect(survivor.analysisVersion == 0)
    }

    @Test("complete index는 cache를 숨기되 삭제하지 않고 legacy Outlook을 hydration으로 복원한다")
    func testReconcileAndHydrateLegacyOutlookRow() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let gmail = EmailMessage(
            id: "gmail-missing",
            body: "gmail body",
            provider: .gmail,
            rawMessageID: "gmail-missing",
            isInInbox: true
        )
        let legacy = EmailMessage(
            id: "outlook-legacy",
            subject: "subject-outlook-legacy",
            body: "legacy body",
            htmlBody: "<p>legacy HTML</p>",
            provider: .outlook,
            rawMessageID: "outlook-legacy",
            isInInbox: true
        )
        legacy.analysisState = .analyzed
        legacy.analysisSummary = "legacy summary"
        legacy.analyzedBodyFingerprint = EmailAnalysisContract.fingerprint(
            subject: "subject-outlook-legacy",
            body: "legacy body"
        )
        legacy.analysisVersion = EmailAnalysisContract.summaryContractVersion
        context.insert(gmail)
        context.insert(legacy)
        try context.save()

        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: { try $0.save() }
        )
        try store.reconcileInbox(
            provider: .gmail,
            activeMessageIDs: [],
            in: context
        )
        try store.reconcileInbox(
            provider: .outlook,
            activeMessageIDs: ["outlook-legacy"],
            in: context
        )
        #expect(!gmail.isInInbox)
        #expect(!legacy.isInInbox)
        #expect(try context.fetch(FetchDescriptor<EmailMessage>()).count == 2)

        try store.upsert(
            MailboxPage(
                messages: [
                    metadata(
                        provider: .outlook,
                        id: "outlook-legacy",
                        isRead: true,
                        classification: "focused",
                        categories: ["VIP"],
                        folderID: "inbox-folder"
                    )
                ],
                nextCursor: nil
            ),
            into: context
        )
        #expect(legacy.isInInbox)
        #expect(legacy.body == "legacy body")
        #expect(legacy.htmlBody == "<p>legacy HTML</p>")
        #expect(legacy.analysisState == .analyzed)
        #expect(legacy.analysisSummary == "legacy summary")
        #expect(legacy.outlookInboxClassification == .focused)
        #expect(legacy.providerCategoryNames == ["VIP"])
        #expect(legacy.providerFolderID == "inbox-folder")
    }

    @Test("content update는 provider key를 검증하고 body와 native metadata를 함께 저장한다")
    func testUpdateContentValidatesKeyAndInvalidatesChangedAnalysis() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = EmailMessage(
            id: "content-id",
            body: "old body",
            provider: .outlook,
            rawMessageID: "content-id",
            isInInbox: true
        )
        email.analysisState = .analyzed
        email.analysisSummary = "stale summary"
        email.analyzedBodyFingerprint = "old fingerprint"
        email.analysisVersion = 2
        context.insert(email)
        try context.save()

        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: { try $0.save() }
        )
        let mismatched = MailboxMessageContent(
            metadata: metadata(provider: .gmail, id: "content-id", labels: ["INBOX"]),
            body: "wrong",
            htmlBody: ""
        )
        #expect(throws: MailboxLocalStoreError.self) {
            try store.updateContent(mismatched, for: email, in: context)
        }

        let content = MailboxMessageContent(
            metadata: metadata(
                provider: .outlook,
                id: "content-id",
                isRead: true,
                classification: "OTHER",
                categories: ["고객"],
                folderID: "inbox-folder"
            ),
            body: "new body",
            htmlBody: "<p>new HTML</p>"
        )
        try store.updateContent(content, for: email, in: context)

        #expect(email.body == "new body")
        #expect(email.htmlBody == "<p>new HTML</p>")
        #expect(email.isRead)
        #expect(email.isInInbox)
        #expect(email.outlookInboxClassification == .other)
        #expect(email.providerCategoryNames == ["고객"])
        #expect(email.providerFolderID == "inbox-folder")
        #expect(email.analysisState == .unanalyzed)
        #expect(email.analysisSummary.isEmpty)
        #expect(email.analyzedBodyFingerprint.isEmpty)
        #expect(email.analysisVersion == 0)
    }
    @Test("upsert와 reconciliation save 실패는 기존 cache 상태로 rollback한다")
    func testSaveFailuresRollbackMailboxState() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = EmailMessage(
            id: "rollback-id",
            subject: "original",
            provider: .gmail,
            rawMessageID: "rollback-id",
            labelIDs: ["INBOX"],
            isInInbox: true
        )
        context.insert(email)
        try context.save()

        let failingStore = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: { _ in throw CocoaError(.fileWriteUnknown) }
        )
        #expect(throws: CocoaError.self) {
            try failingStore.upsert(
                MailboxPage(
                    messages: [
                        metadata(
                            provider: .gmail,
                            id: "rollback-id",
                            isRead: true,
                            labels: ["INBOX", "UNREAD"]
                        )
                    ],
                    nextCursor: nil
                ),
                into: context
            )
        }
        #expect(email.subject == "original")
        #expect(!email.isRead)
        #expect(email.isInInbox)

        #expect(throws: CocoaError.self) {
            try failingStore.reconcileInbox(
                provider: .gmail,
                activeMessageIDs: [],
                in: context
            )
        }
        #expect(email.isInInbox)
        #expect(try context.fetch(FetchDescriptor<EmailMessage>()).count == 1)
    }

}
