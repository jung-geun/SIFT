import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Gmail IMAP background ingestion service", .serialized)
@MainActor
struct GmailIMAPIngestionServiceTests {
    private let email = "ingest@example.com"

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([EmailMessage.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeLedgerContainer() throws -> ModelContainer {
        let schema = Schema([MailAnalysisLedgerRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "GmailIMAPIngestionServiceTests_\(UUID().uuidString)")!
    }

    private func setupCredentials() throws {
        try? IMAPCredentialStore.delete(for: email)
        try IMAPCredentialStore.save(appPassword: "app-password", for: email, backgroundEnabled: false)
    }

    private func cleanupCredentials() {
        try? IMAPCredentialStore.delete(for: email)
    }

    private func setupAuth(transport: ScriptedIMAPTransport) {
        transport.addRoute(matching: "CAPABILITY", response: [
            "* CAPABILITY IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID X-GM-EXT-1",
            "A0000 OK CAPABILITY"
        ])
        for _ in 0..<32 {
            transport.addRoute(matching: "SELECT INBOX", response: [
                "* OK [UIDVALIDITY 42] selected",
                "A0001 OK SELECT"
            ])
        }
    }

    @Test("parser migration decodes existing IMAP rows once")
    func parserMigration() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let defaults = makeDefaults()
        MailboxUpdateCursorStore(defaults: defaults)
            .setCursor("42:1", for: .gmail, namespace: email)
        GmailIMAPIngestionCursorStore(defaults: defaults)
            .setCursor("42:1", for: email)
        let row = EmailMessage(
            id: "uid-1",
            subject: "=?UTF-8?B?67O07JWIIA==?= =?UTF-8?B?7JWM66a8?=",
            from: "=?UTF-8?B?7ZWc7J2066y8?= <sender@example.com>",
            body: "old raw MIME",
            provider: .gmail,
            rawMessageID: "1",
            sourceAccountNamespace: email
        )
        row.analysisState = .analyzed
        row.analysisSummary = "old summary"
        context.insert(row)
        try context.save()

        #expect(
            try GmailIMAPContentMigration.migrateIfNeeded(
                account: email,
                context: context,
                defaults: defaults
            )
        )
        #expect(
            MailboxUpdateCursorStore(defaults: defaults)
                .cursor(for: .gmail, namespace: email) == nil
        )
        #expect(GmailIMAPIngestionCursorStore(defaults: defaults).cursor(for: email) == nil)
        #expect(row.subject == "보안 알림")
        #expect(row.from.contains("<sender@example.com>"))
        #expect(row.body.isEmpty)
        #expect(row.analysisState == .unanalyzed)
        #expect(
            try !GmailIMAPContentMigration.migrateIfNeeded(
                account: email,
                context: context,
                defaults: defaults
            )
        )
    }

    @Test("no stored cursor processes bounded head baseline and sets cursor")
    func boundedBaseline() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let container = try makeContainer()
            let context = ModelContext(container)
            let defaults = makeDefaults()
            let cursorStore = GmailIMAPIngestionCursorStore(defaults: defaults)

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            transport.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH 10 20",
                "A0002 OK SEARCH"
            ])
            transport.addRoute(matching: "UID FETCH 10,20", response: [
                "* 10 FETCH (UID 10 X-GM-MSGID 1010 X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Head 10\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "* 20 FETCH (UID 20 X-GM-MSGID 1020 X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Head 20\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "A0003 OK FETCH"
            ])
            transport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0004 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0005 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0006 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0007 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0008 OK SEARCH"])

            // Body fetches during ingestion
            transport.addRoute(matching: "UID FETCH 10 (BODYSTRUCTURE)", response: ["* 1 FETCH (UID 10 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\")))", "A0010 OK FETCH"])
            transport.addRoute(matching: "UID FETCH 10 (UID FLAGS INTERNALDATE", response: ["* 1 FETCH (UID 10 X-GM-MSGID 1010 BODY[TEXT] {11}Body text 10)", "A0011 OK FETCH"])
            transport.addRoute(matching: "UID FETCH 20 (BODYSTRUCTURE)", response: ["* 1 FETCH (UID 20 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\")))", "A0012 OK FETCH"])
            transport.addRoute(matching: "UID FETCH 20 (UID FLAGS INTERNALDATE", response: ["* 1 FETCH (UID 20 X-GM-MSGID 1020 BODY[TEXT] {11}Body text 20)", "A0013 OK FETCH"])

            let imapService = GmailIMAPService(transport: transport)
            let service = GmailIMAPIngestionService(emailContext: context, imapService: imapService, cursorStore: cursorStore)

            #expect(cursorStore.cursor(for: email) == nil)
            let result = try await service.sync(account: " Ingest@Example.COM ", backgroundEnabled: false)

            #expect(result.analyzedCount == 2)
            #expect(cursorStore.cursor(for: email) == "42:20")

            let saved = try context.fetch(FetchDescriptor<EmailMessage>())
            #expect(saved.count == 2)
        }
    }

    @Test("stale analyzed ledger claim rehydrates an empty email context before advancing baseline")
    func staleLedgerClaimRehydratesEmptyContext() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let emailContainer = try makeContainer()
            let context = ModelContext(emailContainer)
            let ledgerContainer = try makeLedgerContainer()
            let defaults = makeDefaults()
            let cursorStore = GmailIMAPIngestionCursorStore(defaults: defaults)
            let ledgerStore = MailAnalysisLedgerStore(container: ledgerContainer)
            let fingerprint = MailAnalysisFingerprint.make(
                provider: "gmail-imap",
                canonicalAccount: email,
                gmailMessageID: "9001",
                key: MailAnalysisLedgerKeyStore.key()
            )
            #expect(try ledgerStore.claim(fingerprint, revision: Int.max))
            try ledgerStore.markAnalyzed(fingerprint, revision: Int.max)

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)
            transport.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH 1",
                "A0002 OK SEARCH"
            ])
            transport.addRoute(matching: "UID FETCH 1 (UID FLAGS X-GM-MSGID", response: [
                "* 1 FETCH (UID 1 X-GM-MSGID 9001 X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Rehydrate\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "A0003 OK FETCH"
            ])
            transport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0004 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0005 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0006 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0007 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0008 OK SEARCH"])
            transport.addRoute(matching: "UID FETCH 1 (BODYSTRUCTURE)", response: [
                "* 1 FETCH (UID 1 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\")))",
                "A0010 OK FETCH"
            ])
            transport.addRoute(matching: "UID FETCH 1 (UID FLAGS INTERNALDATE", response: [
                "* 1 FETCH (UID 1 X-GM-MSGID 9001 BODY[TEXT] {15}Rehydrated body)",
                "A0011 OK FETCH"
            ])

            let service = GmailIMAPIngestionService(
                emailContext: context,
                imapService: GmailIMAPService(transport: transport),
                cursorStore: cursorStore,
                ledgerStore: ledgerStore
            )
            let result = try await service.sync(account: email, backgroundEnabled: false)

            #expect(result.analyzedCount == 1)
            #expect(cursorStore.cursor(for: email) == "42:1")
            #expect(try context.fetch(FetchDescriptor<EmailMessage>()).count == 1)
            #expect(
                try ledgerStore.claimOutcome(fingerprint, revision: 0)
                    == .alreadyAnalyzed
            )
        }
    }

    @Test("stored cursor with >100 updates processes batch in order and updates cursor per page")
    func moreThan100Updates() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let container = try makeContainer()
            let context = ModelContext(container)
            let defaults = makeDefaults()
            let cursorStore = GmailIMAPIngestionCursorStore(defaults: defaults)
            cursorStore.setCursor("42:100", for: email)

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            // Page 1: 100 items (101...200)
            let page1UIDs = (101...200).map(String.init).joined(separator: " ")
            transport.addRoute(matching: "UID SEARCH UID 101:*", response: [
                "* SEARCH \(page1UIDs) 201",
                "A0002 OK SEARCH"
            ])
            let page1FetchRange = (101...200).map(String.init).joined(separator: ",")
            let page1FetchLines = (101...200).map { uid in
                "* \(uid) FETCH (UID \(uid) X-GM-MSGID \(1000 + uid) X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test \(uid)\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)"
            } + ["A0003 OK FETCH"]
            transport.addRoute(matching: "UID FETCH \(page1FetchRange)", response: page1FetchLines)
            transport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0004 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0005 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0006 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0007 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0008 OK SEARCH"])

            // Add routes for body fetch of page 1 items
            for uid in 101...200 {
                transport.addRoute(matching: "UID FETCH \(uid) (BODYSTRUCTURE)", response: ["* 1 FETCH (UID \(uid) BODYSTRUCTURE ((\"TEXT\" \"PLAIN\")))", "A0100 OK FETCH"])
                transport.addRoute(matching: "UID FETCH \(uid) (UID FLAGS INTERNALDATE", response: ["* 1 FETCH (UID \(uid) X-GM-MSGID \(1000 + uid) BODY[TEXT] {9}Body \(uid))", "A0101 OK FETCH"])
            }

            // Page 2: 1 item (201)
            transport.addRoute(matching: "UID SEARCH UID 201:*", response: [
                "* SEARCH 201",
                "A0010 OK SEARCH"
            ])
            transport.addRoute(matching: "UID FETCH 201 (UID FLAGS X-GM-MSGID", response: [
                "* 201 FETCH (UID 201 X-GM-MSGID 1201 X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test 201\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "A0011 OK FETCH"
            ])
            transport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0012 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0013 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0014 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0015 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0016 OK SEARCH"])

            transport.addRoute(matching: "UID FETCH 201 (BODYSTRUCTURE)", response: ["* 1 FETCH (UID 201 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\")))", "A0200 OK FETCH"])
            transport.addRoute(matching: "UID FETCH 201 (UID FLAGS INTERNALDATE", response: ["* 1 FETCH (UID 201 X-GM-MSGID 1201 BODY[TEXT] {8}Body 201)", "A0201 OK FETCH"])

            let imapService = GmailIMAPService(transport: transport)
            let service = GmailIMAPIngestionService(emailContext: context, imapService: imapService, cursorStore: cursorStore)

            let result = try await service.sync(account: email, backgroundEnabled: false)
            #expect(result.analyzedCount == 101)
            #expect(cursorStore.cursor(for: email) == "42:201")
        }
    }

    @Test("failed page processing leaves cursor at previous committed state")
    func commitBeforeCursorAndRetryFailure() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let container = try makeContainer()
            let context = ModelContext(container)
            let defaults = makeDefaults()
            let cursorStore = GmailIMAPIngestionCursorStore(defaults: defaults)
            cursorStore.setCursor("42:998", for: email)

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            // Search succeeds but body fetch fails
            transport.addRoute(matching: "UID SEARCH UID 999:*", response: [
                "* SEARCH 999",
                "A0002 OK SEARCH"
            ])
            transport.addRoute(matching: "UID FETCH 999", response: [
                "* 999 FETCH (UID 999 X-GM-MSGID 1999 X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test 999\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "A0003 OK FETCH"
            ])
            transport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0004 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0005 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0006 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0007 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0008 OK SEARCH"])

            // Body fetch error
            transport.addRoute(matching: "UID FETCH 999 (BODYSTRUCTURE)", error: GmailIMAPError.transport("Body fetch network error"))

            let imapService = GmailIMAPService(transport: transport)
            let service = GmailIMAPIngestionService(emailContext: context, imapService: imapService, cursorStore: cursorStore)

            await #expect(throws: GmailIMAPError.self) {
                try await service.sync(account: email, backgroundEnabled: false)
            }

            // Cursor must remain unchanged at "42:998" so next run retries UID 999
            #expect(cursorStore.cursor(for: email) == "42:998")
        }
    }
    @Test("multi-page update commits first page cursor and preserves it when second page fails")
    func multiPageUpdateFailureAndRetry() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let container = try makeContainer()
            let context = ModelContext(container)
            let defaults = makeDefaults()
            let cursorStore = GmailIMAPIngestionCursorStore(defaults: defaults)
            cursorStore.setCursor("42:100", for: email)

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            // Page 1: 100 items (101...200)
            let page1UIDs = (101...200).map(String.init).joined(separator: " ")
            transport.addRoute(matching: "UID SEARCH UID 101:*", response: [
                "* SEARCH \(page1UIDs) 201",
                "A0002 OK SEARCH"
            ])
            let page1FetchRange = (101...200).map(String.init).joined(separator: ",")
            let page1FetchLines = (101...200).map { uid in
                "* \(uid) FETCH (UID \(uid) X-GM-MSGID \(5000 + uid) X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test \(uid)\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)"
            } + ["A0003 OK FETCH"]
            transport.addRoute(matching: "UID FETCH \(page1FetchRange)", response: page1FetchLines)
            transport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0004 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0005 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0006 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0007 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0008 OK SEARCH"])

            // Add routes for body fetch of page 1 items
            for uid in 101...200 {
                transport.addRoute(matching: "UID FETCH \(uid) (BODYSTRUCTURE)", response: ["* 1 FETCH (UID \(uid) BODYSTRUCTURE ((\"TEXT\" \"PLAIN\")))", "A0100 OK FETCH"])
                transport.addRoute(matching: "UID FETCH \(uid) (UID FLAGS INTERNALDATE", response: ["* 1 FETCH (UID \(uid) X-GM-MSGID \(5000 + uid) BODY[TEXT] {9}Body \(uid))", "A0101 OK FETCH"])
            }

            // Page 2: 1 item (201)
            transport.addRoute(matching: "UID SEARCH UID 201:*", response: [
                "* SEARCH 201",
                "A0010 OK SEARCH"
            ])
            transport.addRoute(matching: "UID FETCH 201 (UID FLAGS X-GM-MSGID", response: [
                "* 201 FETCH (UID 201 X-GM-MSGID 6201 X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test 201\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "A0011 OK FETCH"
            ])

            // Page 2 body fetch error on first try
            transport.addRoute(matching: "UID FETCH 201 (BODYSTRUCTURE)", error: GmailIMAPError.transport("Page 2 body fetch error"), once: true)

            // Page 2 body fetch success routes for retry
            transport.addRoute(matching: "UID FETCH 201 (BODYSTRUCTURE)", response: ["* 1 FETCH (UID 201 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\")))", "A0200 OK FETCH"])
            transport.addRoute(matching: "UID FETCH 201 (UID FLAGS INTERNALDATE", response: ["* 1 FETCH (UID 201 X-GM-MSGID 6201 BODY[TEXT] {8}Body 201)", "A0201 OK FETCH"])

            let imapService = GmailIMAPService(transport: transport)
            let service = GmailIMAPIngestionService(emailContext: context, imapService: imapService, cursorStore: cursorStore)

            // Initial sync fails on page 2 after page 1 committed
            await #expect(throws: GmailIMAPError.self) {
                try await service.sync(account: email, backgroundEnabled: false)
            }

            // Stored cursor must remain at page 1's committed anchor "42:200"
            #expect(cursorStore.cursor(for: email) == "42:200")

            // Retrying sync resumes from "42:200", processes page 2, and advances stored cursor to "42:201"
            let commandCountBeforeRetry = transport.commands.count
            let retryResult = try await service.sync(account: email, backgroundEnabled: false)
            #expect(retryResult.analyzedCount == 1)
            #expect(cursorStore.cursor(for: email) == "42:201")

            let retryCommands = Array(transport.commands[commandCountBeforeRetry...])
            #expect(retryCommands.contains(where: { $0.contains("UID SEARCH UID 201:*") }))
            #expect(!retryCommands.contains(where: { $0.contains("UID SEARCH UID 101:*") }))
        }
    }

    @Test("UIDVALIDITY reset replaces ingestion cursor with committed head anchor")
    func validityReset() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let container = try makeContainer()
            let context = ModelContext(container)
            let defaults = makeDefaults()
            let cursorStore = GmailIMAPIngestionCursorStore(defaults: defaults)

            // Stored cursor with OLD validity 99
            cursorStore.setCursor("99:100", for: email)

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            // Current SELECT INBOX has validity 42
            // Since cursor validity is 99 != 42, fetchInboxUpdates degrades to head load (fetchInboxPage(after: nil))
            transport.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH 50",
                "A0002 OK SEARCH"
            ])
            transport.addRoute(matching: "UID FETCH 50 (UID FLAGS X-GM-MSGID", response: [
                "* 50 FETCH (UID 50 X-GM-MSGID 1050 X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Reset Head 50\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "A0003 OK FETCH"
            ])
            transport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0004 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0005 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0006 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0007 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0008 OK SEARCH"])

            transport.addRoute(matching: "UID FETCH 50 (BODYSTRUCTURE)", response: ["* 1 FETCH (UID 50 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\")))", "A0010 OK FETCH"])
            transport.addRoute(matching: "UID FETCH 50 (UID FLAGS INTERNALDATE", response: ["* 1 FETCH (UID 50 X-GM-MSGID 1050 BODY[TEXT] {7}Body 50)", "A0011 OK FETCH"])

            let imapService = GmailIMAPService(transport: transport)
            let service = GmailIMAPIngestionService(emailContext: context, imapService: imapService, cursorStore: cursorStore)

            let result = try await service.sync(account: email, backgroundEnabled: false)
            #expect(result.analyzedCount == 1)
            #expect(cursorStore.cursor(for: email) == "42:50")
        }
    }
}
