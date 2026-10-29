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
        folderID: String = "",
        globalID: String = "",
        namespace: String = ""
    ) -> MailboxMessageMetadata {
        MailboxMessageMetadata(
            provider: provider,
            providerMessageID: id,
            providerGlobalMessageID: globalID,
            sourceAccountNamespace: namespace,
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

    @Test("Only genuine inserts become app-unseen, independently of provider unread")
    func testInsertedKeysAndLocalAttentionState() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let cached = EmailMessage(id: "cached", isRead: false, labelIDs: ["INBOX", "UNREAD"], isInInbox: true)
        context.insert(cached)
        try context.save()
        let store = MailboxLocalStore(defaults: try makeDefaults(), saveContext: { try $0.save() })
        let page = MailboxPage(messages: [
            metadata(provider: .gmail, id: "cached"),
            metadata(provider: .gmail, id: "new", isRead: true),
            metadata(provider: .gmail, id: "new", isRead: true)
        ], nextCursor: nil)

        let inserted = try store.upsert(page, into: context)
        let rows = try context.fetch(FetchDescriptor<EmailMessage>())
        let newEmail = try #require(rows.first { $0.providerMessageID == "new" })
        #expect(inserted == Set([EmailMessageKey(newEmail)]))
        #expect(cached.hasBeenViewedInApp)
        #expect(!cached.isNewlyImportedUnseen)
        #expect(newEmail.isRead)
        #expect(newEmail.isNewlyImportedUnseen)
        #expect(try store.upsert(page, into: context).isEmpty)
        #expect(newEmail.isNewlyImportedUnseen)

        try store.markViewedInApp(newEmail, in: context)
        #expect(!newEmail.isNewlyImportedUnseen)
        #expect(try store.upsert(page, into: context).isEmpty)
        #expect(newEmail.hasBeenViewedInApp)
        let reloaded = try ModelContext(container).fetch(FetchDescriptor<EmailMessage>())
        #expect(reloaded.first { $0.providerMessageID == "new" }?.hasBeenViewedInApp == true)
    }

    @Test("Local app viewing never changes provider flags or queues remote mutations")
    func testMarkViewedDoesNotMutateProviderReadState() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let defaults = try makeDefaults()
        let email = EmailMessage(id: "unread", isRead: false, labelIDs: ["INBOX", "UNREAD"], isInInbox: true)
        email.hasBeenViewedInApp = false
        context.insert(email)
        try context.save()
        let store = MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() })
        try store.markViewedInApp(email, in: context)

        #expect(email.hasBeenViewedInApp)
        #expect(!email.isRead)
        #expect(email.labelIDs == ["INBOX", "UNREAD"])
        #expect(MailboxMutationStore(defaults: defaults, queue: .acknowledged).mutations.isEmpty)
        #expect(MailboxMutationStore(defaults: defaults, queue: .deferred).mutations.isEmpty)
    }

    @Test("Duplicate collapse retains viewed state and removed rows never show attention")
    func testDuplicateAndRemovalAttentionState() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let unseen = EmailMessage(id: "duplicate", body: "rich body", isInInbox: true)
        unseen.hasBeenViewedInApp = false
        let viewed = EmailMessage(id: "duplicate", isInInbox: true)
        context.insert(unseen)
        context.insert(viewed)
        try context.save()
        let store = MailboxLocalStore(defaults: try makeDefaults(), saveContext: { try $0.save() })
        let inserted = try store.upsert(MailboxPage(messages: [
            metadata(provider: .gmail, id: "duplicate"),
            metadata(provider: .gmail, id: "removed")
        ], nextCursor: nil), into: context)
        let rows = try context.fetch(FetchDescriptor<EmailMessage>())
        let survivor = try #require(rows.first { $0.providerMessageID == "duplicate" })
        let removed = try #require(rows.first { $0.providerMessageID == "removed" })
        #expect(survivor.hasBeenViewedInApp)
        #expect(inserted == Set([EmailMessageKey(removed)]))
        #expect(removed.isNewlyImportedUnseen)
        try store.upsert(MailboxPage(messages: [], nextCursor: nil, removedMessageKeys: [EmailMessageKey(removed)]), into: context)
        #expect(!removed.isNewlyImportedUnseen)
    }

    @Test("Content updates preserve local attention and equal provider IDs in another account are new")
    func testContentUpdateAndCrossAccountAttentionState() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = MailboxLocalStore(defaults: try makeDefaults(), saveContext: { try $0.save() })
        let firstMetadata = metadata(provider: .gmail, id: "same-id", namespace: "first@example.com")
        let firstKeys = try store.upsert(MailboxPage(messages: [firstMetadata], nextCursor: nil), into: context)
        let first = try #require(context.fetch(FetchDescriptor<EmailMessage>()).first { $0.providerMessageID == "same-id" })
        #expect(firstKeys == Set([EmailMessageKey(first)]))
        #expect(first.isNewlyImportedUnseen)

        try store.updateContent(MailboxMessageContent(metadata: firstMetadata, body: "First full body", htmlBody: ""), for: first, in: context)
        #expect(first.isNewlyImportedUnseen)
        try store.markViewedInApp(first, in: context)
        try store.updateContent(MailboxMessageContent(metadata: firstMetadata, body: "Updated body", htmlBody: ""), for: first, in: context)
        #expect(!first.isNewlyImportedUnseen)
        #expect(try store.upsert(MailboxPage(messages: [firstMetadata], nextCursor: nil), into: context).isEmpty)

        let secondMetadata = metadata(provider: .gmail, id: "same-id", namespace: "second@example.com")
        let secondKeys = try store.upsert(MailboxPage(messages: [secondMetadata], nextCursor: nil), into: context)
        let rows = try context.fetch(FetchDescriptor<EmailMessage>())
        let second = try #require(rows.first { $0.sourceAccountNamespace == "second@example.com" })
        #expect(rows.count == 2)
        #expect(secondKeys == Set([EmailMessageKey(second)]))
        #expect(second.isNewlyImportedUnseen)
        #expect(first.hasBeenViewedInApp)
        let laterKeys = try store.upsert(MailboxPage(messages: [
            metadata(provider: .gmail, id: "later", namespace: "second@example.com")
        ], nextCursor: nil), into: context)
        let later = try #require(context.fetch(FetchDescriptor<EmailMessage>()).first { $0.providerMessageID == "later" })
        #expect(laterKeys == Set([EmailMessageKey(later)]))
        #expect(later.isNewlyImportedUnseen)
    }

    @Test("Gmail UIDVALIDITY re-keys preserve app-viewed state by immutable identity within the account")
    func testGmailRekeyRetainsViewedState() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewed = EmailMessage(id: "gmail-imap:global", provider: .gmail, rawMessageID: "old-uid", providerGlobalMessageID: "global", isInInbox: true, sourceAccountNamespace: "first@example.com")
        context.insert(viewed)
        try context.save()
        let store = MailboxLocalStore(defaults: try makeDefaults(), saveContext: { try $0.save() })
        let keys = try store.upsert(MailboxPage(messages: [
            metadata(provider: .gmail, id: "new-uid", globalID: "global", namespace: "first@example.com"),
            metadata(provider: .gmail, id: "new-arrival", globalID: "new-global", namespace: "first@example.com"),
            metadata(provider: .gmail, id: "new-uid", globalID: "global", namespace: "second@example.com")
        ], nextCursor: nil, requiresInboxReconcile: true), into: context, resetNamespace: "first@example.com")
        let rows = try context.fetch(FetchDescriptor<EmailMessage>())
        let rekeyed = try #require(rows.first { $0.providerMessageID == "new-uid" && $0.sourceAccountNamespace == "first@example.com" })
        #expect(keys.contains(EmailMessageKey(rekeyed)))
        #expect(rekeyed.hasBeenViewedInApp)
        #expect(!rekeyed.isNewlyImportedUnseen)
        #expect(!viewed.isInInbox)
        #expect(rows.first { $0.providerMessageID == "new-arrival" }?.isNewlyImportedUnseen == true)
        #expect(rows.first { $0.providerMessageID == "new-uid" && $0.sourceAccountNamespace == "second@example.com" }?.isNewlyImportedUnseen == true)
    }

    @Test("Genuine first-import and older-page inserts are app-unseen without flagging existing cache")
    func testInitialAndHistoricalPageInsertsAreUnseen() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = MailboxLocalStore(defaults: try makeDefaults(), saveContext: { try $0.save() })
        let initialKeys = try store.upsert(MailboxPage(messages: [
            metadata(provider: .gmail, id: "baseline-1"),
            metadata(provider: .gmail, id: "baseline-2")
        ], nextCursor: "older"), into: context)
        #expect(initialKeys.count == 2)
        #expect(try context.fetch(FetchDescriptor<EmailMessage>()).allSatisfy { $0.isNewlyImportedUnseen })

        let olderKeys = try store.upsert(MailboxPage(messages: [
            metadata(provider: .gmail, id: "older")
        ], nextCursor: nil), into: context)
        let older = try #require(context.fetch(FetchDescriptor<EmailMessage>()).first { $0.providerMessageID == "older" })
        #expect(olderKeys == Set([EmailMessageKey(older)]))
        #expect(older.isNewlyImportedUnseen)

        try store.upsert(MailboxPage(messages: [metadata(provider: .gmail, id: "arrived")], nextCursor: nil), into: context)
        let arrived = try #require(context.fetch(FetchDescriptor<EmailMessage>()).first { $0.providerMessageID == "arrived" })
        #expect(arrived.isNewlyImportedUnseen)
    }

    @Test("App-viewed persistence failures retain the unseen state")
    func testMarkViewedFailurePreservesUnseenState() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = EmailMessage(id: "save-failure", isInInbox: true)
        email.hasBeenViewedInApp = false
        context.insert(email)
        try context.save()
        let store = MailboxLocalStore(defaults: try makeDefaults(), saveContext: { _ in throw CocoaError(.fileWriteUnknown) })
        #expect(throws: CocoaError.self) { try store.markViewedInApp(email, in: context) }
        #expect(email.isNewlyImportedUnseen)
    }

    @Test("duplicate upsert는 analyzed body survivor와 analysis를 보존한다")
    func testUpsertChoosesRichAnalyzedSurvivor() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let rich = EmailMessage(
            id: "gmail-imap:global-same",
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
        rich.analysisKeyPoints = ["retained key point"]
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
        let selection = MailDetailSelection(bodyOnly)
        let newestEmpty = EmailMessage(
            id: "same",
            subject: "newest-empty",
            receivedAt: Date(timeIntervalSince1970: 400),
            provider: .gmail,
            rawMessageID: "same",
            isInInbox: true
        )
        newestEmpty.analysisTodoCandidate = true
        newestEmpty.analysisTodoCandidateFingerprint = rich.analyzedBodyFingerprint
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
        #expect(survivor.id == "gmail-imap:global-same")
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
        #expect(survivor.analysisTodoCandidate == true)
        #expect(survivor.analysisTodoCandidateFingerprint == rich.analyzedBodyFingerprint)
        #expect(survivor.isRead)
        #expect(survivor.gmailInboxCategories == Set([.updates]))
        let resolvedDetailEmail = MailDetailSelection.resolve(rows, matching: selection.key)
        #expect(resolvedDetailEmail === survivor)
        #expect(resolvedDetailEmail?.analysisKeyPoints == ["retained key point"])
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
        email.analysisTodoCandidate = true
        email.analysisTodoCandidateFingerprint = "old fingerprint"
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
        #expect(email.analysisTodoCandidate == nil)
        #expect(email.analysisTodoCandidateFingerprint.isEmpty)
    }

    @Test("Gmail content rehydration never downgrades a local read state")
    func testGmailContentPreservesLocalReadState() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = EmailMessage(
            id: "gmail-imap:global-read",
            isRead: true,
            provider: .gmail,
            rawMessageID: "read-id",
            labelIDs: ["INBOX"],
            isInInbox: true
        )
        context.insert(email)
        try context.save()

        let store = MailboxLocalStore(
            defaults: try makeDefaults(),
            saveContext: { try $0.save() }
        )
        let content = MailboxMessageContent(
            metadata: metadata(
                provider: .gmail,
                id: "read-id",
                isRead: false,
                labels: ["INBOX", "UNREAD"]
            ),
            body: "body",
            htmlBody: ""
        )
        try store.updateContent(content, for: email, in: context)

        #expect(email.isRead)
        #expect(!email.labelIDs.contains("UNREAD"))
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

    @Test("Gmail label-less metadata preserves previously stored categories")
    func testCategoryPreservationWithEmptyLabels() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = EmailMessage(
            id: "cat-1",
            subject: "Promo Email",
            provider: MailProvider.gmail,
            rawMessageID: "cat-1",
            labelIDs: ["INBOX", "CATEGORY_PROMOTIONS"],
            isInInbox: true
        )
        context.insert(email)
        try context.save()

        let store = MailboxLocalStore(defaults: try makeDefaults(), saveContext: { try $0.save() })
        // Incoming metadata has empty gmailLabelIDs
        try store.upsert(
            MailboxPage(
                messages: [
                    metadata(
                        provider: MailProvider.gmail,
                        id: "cat-1",
                        labels: []
                    )
                ],
                nextCursor: nil
            ),
            into: context
        )

        #expect(email.labelIDs == ["INBOX", "CATEGORY_PROMOTIONS"])
    }

    @Test("Gmail metadata without a global ID never downgrades an existing stable local ID")
    func testGmailMissingGlobalIDPreservesStableLocalID() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let email = EmailMessage(
            id: "gmail-imap:900",
            provider: .gmail,
            rawMessageID: "7",
            isInInbox: true,
            sourceAccountNamespace: "imap@example.com"
        )
        context.insert(email)
        try context.save()

        let store = MailboxLocalStore(defaults: try makeDefaults(), saveContext: { try $0.save() })
        try store.upsert(
            MailboxPage(messages: [metadata(provider: .gmail, id: "7")], nextCursor: nil),
            into: context
        )

        #expect(email.id == "gmail-imap:900")
    }
}
