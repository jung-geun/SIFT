import Foundation
import SwiftData
import Testing
@testable import todo

final class TestHydrationPagingProvider: MailboxPagingProvider {
    let provider: MailProvider
    var shouldFailContentFetch = false
    var contentFetchCallCount = 0
    let mockContent: MailboxMessageContent

    init(provider: MailProvider, mockContent: MailboxMessageContent) {
        self.provider = provider
        self.mockContent = mockContent
    }

    func fetchInboxPage(after cursor: String?) async throws -> MailboxPage {
        MailboxPage(messages: [], nextCursor: nil)
    }

    func fetchInboxUpdates(newerThan cursor: String) async throws -> MailboxPage {
        MailboxPage(messages: [], nextCursor: nil)
    }

    func fetchInboxMessageIDs() async throws -> Set<String> { [] }

    func fetchMessageContent(messageID: String) async throws -> MailboxMessageContent {
        contentFetchCallCount += 1
        if shouldFailContentFetch {
            throw GmailIMAPError.invalidResponse
        }
        return mockContent
    }

    func markAsRead(messageID: String, expectedGlobalMessageID: String?) async throws {}
    func trashMessage(messageID: String, expectedGlobalMessageID: String?) async throws {}
}

@MainActor
@Suite("EmbeddedTodoMailResolver Tests", .serialized)
struct EmbeddedTodoMailResolverTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([EmailMessage.self, Todo.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "EmbeddedResolverTests_\(UUID().uuidString)")!
    }

    @Test("parseSourceRef handles legacy outlook prefix and gmail defaults")
    func testParseSourceRef() {
        let outlookParsed = EmbeddedTodoMailResolver.parseSourceRef(sourceRef: "outlook:msg-123", sourceAccountNamespace: "user@outlook.com")
        #expect(outlookParsed?.provider == .outlook)
        #expect(outlookParsed?.providerMessageID == "msg-123")
        #expect(outlookParsed?.sourceAccountNamespace == "user@outlook.com")

        let gmailParsed = EmbeddedTodoMailResolver.parseSourceRef(sourceRef: "105", sourceAccountNamespace: "dev@gmail.com")
        #expect(gmailParsed?.provider == .gmail)
        #expect(gmailParsed?.providerMessageID == "105")
        #expect(gmailParsed?.sourceAccountNamespace == "dev@gmail.com")
    }

    @Test("IMAP local-id/sourceRef mismatch resolves via providerMessageID and rawMessageID")
    func testIMAPLocalIDMismatchResolution() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let cachedEmail = EmailMessage(
            id: "gmail-imap:1001",
            threadID: "thread-1",
            subject: "테스트 메일",
            from: "sender@example.com",
            snippet: "스니펫",
            body: "이미 로드된 본문",
            htmlBody: nil,
            receivedAt: Date(),
            provider: .gmail,
            rawMessageID: "105",
            sourceAccountNamespace: "user@gmail.com"
        )
        context.insert(cachedEmail)
        try context.save()

        let todo = Todo(title: "할일", notes: "", dueDate: nil, source: .email, sourceRef: "105")
        todo.sourceAccountNamespace = "user@gmail.com"

        let resolver = EmbeddedTodoMailResolver(
            resolveProvider: { _ in nil },
            ensureReady: { _, _ in true }
        )

        let result = await resolver.resolveAndHydrate(todo: todo, in: context)
        guard case .success(let resolved) = result else {
            Issue.record("Expected successful resolution from cache")
            return
        }

        #expect(resolved.id == "gmail-imap:1001")
        #expect(resolved.providerMessageID == "105")
    }

    @Test("Legacy empty namespace with multiple matching candidate accounts returns ambiguous error")
    func testAmbiguousNamespaceError() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let email1 = EmailMessage(id: "id1", provider: .gmail, rawMessageID: "105", sourceAccountNamespace: "account1@gmail.com")
        let email2 = EmailMessage(id: "id2", provider: .gmail, rawMessageID: "105", sourceAccountNamespace: "account2@gmail.com")
        context.insert(email1)
        context.insert(email2)
        try context.save()

        let todo = Todo(title: "할일", source: .email, sourceRef: "105")

        let defaults = makeDefaults()
        let resolver = EmbeddedTodoMailResolver(
            resolveProvider: { _ in nil },
            ensureReady: { _, _ in true },
            defaults: defaults
        )

        let result = await resolver.resolveAndHydrate(todo: todo, in: context)
        guard case .failure(let error) = result else {
            Issue.record("Expected ambiguous error")
            return
        }

        #expect(error == .ambiguousAccountNamespace)
    }

    @Test("Cache-miss hydration fetches from provider and updates local store atomically")
    func testCacheMissHydrationSuccess() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let metadata = MailboxMessageMetadata(
            provider: .gmail,
            providerMessageID: "105",
            providerGlobalMessageID: "global-105",
            sourceAccountNamespace: "user@gmail.com",
            threadID: "thread-105",
            subject: "원격 제목",
            from: "sender@example.com",
            snippet: "원격 요약",
            receivedAt: Date(),
            isRead: false,
            isInInbox: true,
            gmailLabelIDs: ["INBOX"],
            outlookInferenceClassificationRawValue: "",
            providerCategoryNames: [],
            providerFolderID: "INBOX"
        )
        let mockContent = MailboxMessageContent(
            metadata: metadata,
            body: "원격 로드된 평문 본문",
            htmlBody: "<p>원격 HTML</p>"
        )
        let fakeProvider = TestHydrationPagingProvider(provider: .gmail, mockContent: mockContent)

        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")

        let resolver = EmbeddedTodoMailResolver(
            resolveProvider: { _ in fakeProvider },
            ensureReady: { _, _ in true },
            defaults: defaults
        )

        let parsed = ParsedEmailSourceRef(provider: .gmail, providerMessageID: "105", sourceAccountNamespace: "user@gmail.com")
        let result = await resolver.resolveAndHydrate(parsed: parsed, in: context)

        guard case .success(let email) = result else {
            Issue.record("Expected successful hydration")
            return
        }

        #expect(email.body == "원격 로드된 평문 본문")
        #expect(email.htmlBody == "<p>원격 HTML</p>")
        #expect(email.sourceAccountNamespace == "user@gmail.com")
    }

    @Test("Failed hydration returns error and succeeds on subsequent retry")
    func testRetryableFailedHydration() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let metadata = MailboxMessageMetadata(
            provider: .gmail,
            providerMessageID: "202",
            providerGlobalMessageID: "global-202",
            sourceAccountNamespace: "user@gmail.com",
            threadID: "t-202",
            subject: "재시도 테스트",
            from: "a@b.com",
            snippet: "snippet",
            receivedAt: Date(),
            isRead: true,
            isInInbox: true,
            gmailLabelIDs: [],
            outlookInferenceClassificationRawValue: "",
            providerCategoryNames: [],
            providerFolderID: "INBOX"
        )
        let mockContent = MailboxMessageContent(metadata: metadata, body: "성공 본문", htmlBody: "")
        let fakeProvider = TestHydrationPagingProvider(provider: .gmail, mockContent: mockContent)
        fakeProvider.shouldFailContentFetch = true

        let defaults = makeDefaults()
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")

        let resolver = EmbeddedTodoMailResolver(
            resolveProvider: { _ in fakeProvider },
            ensureReady: { _, _ in true },
            defaults: defaults
        )

        let parsed = ParsedEmailSourceRef(provider: .gmail, providerMessageID: "202", sourceAccountNamespace: "user@gmail.com")

        // First attempt fails
        let result1 = await resolver.resolveAndHydrate(parsed: parsed, in: context)
        guard case .failure(let err1) = result1 else {
            Issue.record("Expected first attempt to fail")
            return
        }
        #expect(err1 == .hydrationFailed(GmailIMAPError.invalidResponse.localizedDescription))

        // Retry succeeds
        fakeProvider.shouldFailContentFetch = false
        let result2 = await resolver.resolveAndHydrate(parsed: parsed, in: context)
        guard case .success(let email2) = result2 else {
            Issue.record("Expected retry attempt to succeed")
            return
        }
        #expect(email2.body == "성공 본문")
    }

    @Test("Resolution failure produces typed in-app error without external URL fallback")
    func testAbsenceOfExternalDeepLinkFallback() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let defaults = makeDefaults()
        let resolver = EmbeddedTodoMailResolver(
            resolveProvider: { _ in nil },
            ensureReady: { _, _ in false },
            defaults: defaults
        )

        let todo = Todo(title: "할일", source: .email, sourceRef: "invalid-ref")
        let result = await resolver.resolveAndHydrate(todo: todo, in: context)

        guard case .failure(let err) = result else {
            Issue.record("Expected error failure")
            return
        }
        #expect(err == .ambiguousAccountNamespace)
    }
}
