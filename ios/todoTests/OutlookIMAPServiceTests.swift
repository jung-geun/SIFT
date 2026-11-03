import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Outlook IMAP mailbox", .serialized)
@MainActor
struct OutlookIMAPServiceTests {
    private let email = "user@outlook.com"

    private func setupCredentials() throws {
        try? OutlookIMAPCredentialStore.delete(for: email)
        try OutlookIMAPCredentialStore.save(appPassword: "app-password", for: email, backgroundEnabled: false)
    }

    private func cleanupCredentials() {
        try? OutlookIMAPCredentialStore.delete(for: email)
    }

    private func setupAuth(transport: ScriptedIMAPTransport, messageCount: UInt32? = nil) {
        transport.addRoute(matching: "CONNECT_PREAUTH", response: [
            "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN AUTH=LOGIN MOVE] outlook.office365.com IMAP4Server ready"
        ])
        transport.addRoute(matching: "CAPABILITY", response: [
            "* CAPABILITY IMAP4rev1 AUTH=PLAIN AUTH=LOGIN MOVE",
            "A0000 OK CAPABILITY completed"
        ])
        transport.addRoute(matching: "SELECT INBOX", response: (messageCount.map { ["* \($0) EXISTS"] } ?? []) + [
            "* OK [UIDVALIDITY 100] selected",
            "A0001 OK SELECT completed"
        ])
    }

    @Test("connection verification fails closed and preserves the saved password", arguments: ["denied", "disconnected", "missingHeaders", "missingIdentity"], [false, true])
    func connectionVerificationFailsClosed(failure: String, replacingPassword: Bool) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }
            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport, messageCount: 1)
            let expected: OutlookIMAPError = failure == "disconnected" ? .transport("IMAP is not connected") : .invalidResponse
            switch failure {
            case "denied", "disconnected":
                transport.addRoute(matching: "FETCH *", error: expected, once: true)
            case "missingHeaders":
                transport.addRoute(matching: "FETCH *", response: ["* 1 FETCH (UID 7)", "A0002 OK FETCH"], once: true)
            default:
                let header = "Subject: Mail\r\n\r\n"
                transport.addRoute(matching: "FETCH *", response: ["* 1 FETCH (BODY[HEADER.FIELDS] {\(header.utf8.count)}\(header))", "A0002 OK FETCH"], once: true)
            }
            let service = OutlookIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            await #expect(throws: expected) {
                if replacingPassword {
                    try await service.authenticateAndSave(email: email, appPassword: "replacement-password", backgroundEnabled: false)
                } else {
                    try await service.validateConnection(email: email, backgroundEnabled: false)
                }
            }
            #expect(await service.authenticatedAccount == nil)
            #expect(!(await service.isAuthenticated))
            #expect(try OutlookIMAPCredentialStore.credential(for: email) == "app-password")

            let header = "Subject: Mail\r\n\r\n"
            transport.addRoute(matching: "FETCH *", response: [
                "* 1 FETCH (UID 7 BODY[HEADER.FIELDS] {\(header.utf8.count)}\(header))",
                "A0003 OK FETCH"
            ])
            try await service.validateConnection(email: email, backgroundEnabled: false)
            #expect(await service.authenticatedAccount == email)
        }
    }

    @Test("verifies readable and explicitly empty inboxes before saving", arguments: [UInt32(0), UInt32(1)])
    func verifiesInboxBeforeSaving(messageCount: UInt32) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }
            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport, messageCount: messageCount)
            let header = "Subject: Mail\r\nFrom: sender@outlook.com\r\n\r\n"
            transport.addRoute(matching: "FETCH *", response: [
                "* 1 FETCH (UID 7 BODY[HEADER.FIELDS] {\(header.utf8.count)}\(header))",
                "A0002 OK FETCH"
            ])
            let service = OutlookIMAPService(transport: transport)
            try await service.validateConnection(email: email, backgroundEnabled: false)
            #expect(await service.authenticatedAccount == email)
            try await service.authenticateAndSave(email: email, appPassword: "replacement-password", backgroundEnabled: false)
            #expect(try OutlookIMAPCredentialStore.credential(for: email) == "replacement-password")
            #expect(await service.authenticatedAccount == email)
            #expect(transport.commands.contains { $0.hasPrefix("FETCH *") } == (messageCount > 0))
            #expect(transport.commands.allSatisfy { !$0.contains("STORE") && !$0.contains("EXPUNGE") && !$0.contains("UID SEARCH ALL") && !$0.contains("X-GM-") })
            #expect(transport.commands.filter { $0.hasPrefix("FETCH *") }.allSatisfy { $0.contains("BODY.PEEK[") })
        }
    }

    @Test("a missing EXISTS response is not an empty inbox")
    func verificationRequiresExplicitMailboxCount() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }
            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)
            let service = OutlookIMAPService(transport: transport)
            await #expect(throws: OutlookIMAPError.invalidResponse) {
                try await service.validateConnection(email: email, backgroundEnabled: false)
            }
            #expect(!(await service.isAuthenticated))
            #expect(try OutlookIMAPCredentialStore.credential(for: email) == "app-password")
        }
    }

    @Test("failed reconnect keeps the stored App Password")
    func failedReconnectKeepsStoredCredential() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)
            transport.addRoute(matching: "LOGIN", response: ["A0000 NO LOGIN failed"])

            let service = OutlookIMAPService(transport: transport)
            await #expect(throws: OutlookIMAPError.authenticationFailed) {
                try await service.authenticate(email: email, backgroundEnabled: false)
            }

            #expect(try OutlookIMAPCredentialStore.credential(for: email) == "app-password")
        }
    }

    @Test("rejects legacy auth when server advertises LOGINDISABLED or only modern OAuth mechs")
    func legacyAuthDiagnostics() async {
        await AIProviderTestIsolation.shared.withLock {
            // Case 1: LOGINDISABLED
            let transport1 = ScriptedIMAPTransport()
            transport1.addRoute(matching: "CONNECT_PREAUTH", response: [
                "* OK [CAPABILITY IMAP4rev1 LOGINDISABLED] outlook.office365.com IMAP4Server ready"
            ])
            transport1.addRoute(matching: "CAPABILITY", response: [
                "* CAPABILITY IMAP4rev1 LOGINDISABLED",
                "A0000 OK CAPABILITY"
            ])

            let service1 = OutlookIMAPService(transport: transport1)
            await #expect(throws: OutlookIMAPError.legacyAuthUnsupported) {
                try await service1.authenticateAndSave(email: email, appPassword: "password", backgroundEnabled: false)
            }

            // Case 2: Only XOAUTH2 (no PLAIN or LOGIN)
            let transport2 = ScriptedIMAPTransport()
            transport2.addRoute(matching: "CONNECT_PREAUTH", response: [
                "* OK [CAPABILITY IMAP4rev1 AUTH=XOAUTH2] outlook.office365.com IMAP4Server ready"
            ])
            transport2.addRoute(matching: "CAPABILITY", response: [
                "* CAPABILITY IMAP4rev1 AUTH=XOAUTH2",
                "A0000 OK CAPABILITY"
            ])

            let service2 = OutlookIMAPService(transport: transport2)
            await #expect(throws: OutlookIMAPError.legacyAuthUnsupported) {
                try await service2.authenticateAndSave(email: email, appPassword: "password", backgroundEnabled: false)
            }

        }
    }

    @Test("fetches Outlook metadata with provider separation and NO Gmail-only commands")
    func providerSeparationAndNoGmailCommands() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            transport.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH 1 2",
                "A0002 OK SEARCH completed"
            ])
            transport.addRoute(matching: "UID FETCH 1,2", response: [
                "* 1 FETCH (UID 1 BODY[HEADER.FIELDS] {120}Subject: Outlook Test\r\nFrom: sender@outlook.com\r\nMessage-ID: <msg123@outlook.com>\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "* 2 FETCH (UID 2 BODY[HEADER.FIELDS] {122}Subject: Outlook Test 2\r\nFrom: sender2@outlook.com\r\nMessage-ID: <msg456@outlook.com>\r\nDate: Tue, 1 Jul 2025 11:00:00 +0000\r\n\r\n)",
                "A0003 OK FETCH completed"
            ])

            let service = OutlookIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            let page = try await service.fetchInboxPage(after: nil)

            #expect(page.messages.count == 2)
            let first = try #require(page.messages.first)
            #expect(first.provider == .outlook)
            #expect(first.providerMessageID == "1")
            #expect(first.providerGlobalMessageID == "msg123@outlook.com")
            #expect(first.sourceAccountNamespace == email)
            #expect(first.outlookInferenceClassificationRawValue == "")
            #expect(first.providerCategoryNames.isEmpty)
            #expect(first.providerFolderID == "INBOX")
            #expect(first.gmailLabelIDs.isEmpty)

            // Assert NO Gmail-specific commands emitted
            #expect(transport.commands.allSatisfy { cmd in
                !cmd.contains("X-GM-MSGID") &&
                !cmd.contains("X-GM-THRID") &&
                !cmd.contains("X-GM-RAW") &&
                !cmd.contains("category:")
            })
        }
    }

    @Test("pages older and newer Outlook mail using UIDVALIDITY-safe cursors")
    func pagingAndCursorBehavior() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            // Head page search
            transport.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH 10 20 30",
                "A0002 OK SEARCH"
            ])
            transport.addRoute(matching: "UID FETCH 10,20,30", response: [
                "* 10 FETCH (UID 10 BODY[HEADER.FIELDS] {60}Subject: Ten\r\nMessage-ID: <m10>\r\n\r\n)",
                "* 20 FETCH (UID 20 BODY[HEADER.FIELDS] {60}Subject: Twenty\r\nMessage-ID: <m20>\r\n\r\n)",
                "* 30 FETCH (UID 30 BODY[HEADER.FIELDS] {60}Subject: Thirty\r\nMessage-ID: <m30>\r\n\r\n)",
                "A0003 OK FETCH"
            ])

            let service = OutlookIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)

            let headPage = try await service.fetchInboxPage(after: nil)
            #expect(headPage.newestCursor == "100:30")
            #expect(headPage.nextCursor == nil) // less than 100 items

            // Updates search after boundary
            transport.addRoute(matching: "UID SEARCH UID 31:*", response: [
                "* SEARCH 31 32",
                "A0004 OK SEARCH"
            ])
            transport.addRoute(matching: "UID FETCH 31,32", response: [
                "* 31 FETCH (UID 31 BODY[HEADER.FIELDS] {60}Subject: 31\r\nMessage-ID: <m31>\r\n\r\n)",
                "* 32 FETCH (UID 32 BODY[HEADER.FIELDS] {60}Subject: 32\r\nMessage-ID: <m32>\r\n\r\n)",
                "A0005 OK FETCH"
            ])

            let updatePage = try await service.fetchInboxUpdates(newerThan: "100:30")
            #expect(updatePage.messages.count == 2)
            #expect(updatePage.newestCursor == "100:32")
        }
    }

    @Test("verifies RFC822 Message-ID header before performing mutations")
    func messageIDVerificationBeforeMutation() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            // Message identity fetch matching expected Message-ID
            transport.addRoute(matching: "UID FETCH 15 (UID BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])", response: [
                "* 15 FETCH (UID 15 BODY[HEADER.FIELDS] {35}Message-ID: <target-msg-id>\r\n\r\n)",
                "A0002 OK FETCH"
            ])
            transport.addRoute(matching: "LIST \"\" \"*\"", response: [
                "* LIST (\\HasNoChildren \\Trash) \"/\" \"Deleted Items\"",
                "A0003 OK LIST"
            ])

            let service = OutlookIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)

            // Successful markAsRead & trashMessage
            try await service.markAsRead(messageID: "15", expectedGlobalMessageID: "target-msg-id", expectedAccountNamespace: email)
            try await service.trashMessage(messageID: "15", expectedGlobalMessageID: "target-msg-id", expectedAccountNamespace: email)

            #expect(transport.commands.contains("UID STORE 15 +FLAGS.SILENT (\\Seen)"))
            #expect(transport.commands.contains("UID MOVE 15 \"Deleted Items\""))

            // Mismatched Message-ID throws mailboxReset
            transport.addRoute(matching: "UID FETCH 20 (UID BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])", response: [
                "* 20 FETCH (UID 20 BODY[HEADER.FIELDS] {35}Message-ID: <different-msg-id>\r\n\r\n)",
                "A0004 OK FETCH"
            ])

            await #expect(throws: OutlookIMAPError.mailboxReset) {
                try await service.trashMessage(messageID: "20", expectedGlobalMessageID: "expected-msg-id", expectedAccountNamespace: email)
            }
        }
    }

    @Test("staged Outlook trash carries the persisted RFC Message-ID to IMAP")
    func stagedTrashUsesPersistedMessageID() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)
            transport.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH 15",
                "A0002 OK SEARCH completed"
            ])
            transport.addRoute(matching: "UID FETCH 15 (UID FLAGS", response: [
                "* 15 FETCH (UID 15 FLAGS () INTERNALDATE \"1-Jul-2025 10:00:00 +0000\" BODY[HEADER.FIELDS] {110}Subject: Deferred\r\nFrom: sender@outlook.com\r\nMessage-ID: <target-msg-id>\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "A0003 OK FETCH completed"
            ])
            transport.addRoute(matching: "UID FETCH 15 (UID BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])", response: [
                "* 15 FETCH (UID 15 BODY[HEADER.FIELDS] {35}Message-ID: <target-msg-id>\r\n\r\n)",
                "A0004 OK FETCH completed"
            ])
            transport.addRoute(matching: "LIST \"\" \"*\"", response: [
                "* LIST (\\HasNoChildren \\Trash) \"/\" \"Deleted Items\"",
                "A0005 OK LIST"
            ])

            let service = OutlookIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            let page = try await service.fetchInboxPage(after: nil)
            let metadata = try #require(page.messages.first)

            let schema = Schema([EmailMessage.self])
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let defaults = UserDefaults(suiteName: "OutlookStagedTrash_\(UUID().uuidString)")!
            let localStore = MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() })
            try localStore.upsert(
                MailboxPage(messages: [metadata], nextCursor: nil),
                into: context
            )
            let stored = try #require(context.fetch(FetchDescriptor<EmailMessage>()).first)
            #expect(stored.providerGlobalMessageID == "target-msg-id")

            let mutations = try localStore.stageTrash([stored], in: context, now: .distantPast)
            #expect(mutations.first?.expectedGlobalMessageID == "target-msg-id")

            let flushed = await localStore.flushStagedTrash(
                mutations,
                now: Date()
            ) { mutation in
                try await service.trashMessage(messageID: mutation.providerMessageID, expectedGlobalMessageID: mutation.expectedGlobalMessageID, expectedAccountNamespace: mutation.sourceAccountNamespace)
            }

            #expect(flushed == 1)
            #expect(transport.commands.contains("UID MOVE 15 \"Deleted Items\""))
            #expect(localStore.stagedTrashMutations.isEmpty)
        }
    }

    @Test("hydrates a complete selected text literal without MIME framing bytes")
    func fetchMessageContentParsesCompleteTextLiteral() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)
            transport.addRoute(matching: "UID FETCH 42 (BODYSTRUCTURE)", response: [
                "* 42 FETCH (UID 42 BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" \("Agenda: review at 3pm".utf8.count) 1 NIL NIL NIL NIL))",
                "A0002 OK FETCH"
            ])
            let header = "Subject: Outlook note\r\nFrom: sender@example.com\r\nMessage-ID: <outlook-42>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"
            let body = "Agenda: review at 3pm"
            let mime = "Content-Type: text/plain; charset=utf-8\r\n\r\n"
            let unrelatedHeader = "Subject: Wrong message\r\nMessage-ID: <outlook-99>\r\n\r\n"
            let unrelatedBody = "Do not cache this other UID."
            let wire = "* 99 FETCH (UID 99 BODY[HEADER] {\(unrelatedHeader.utf8.count)}\r\n\(unrelatedHeader) BODY[1.MIME] {\(mime.utf8.count)}\r\n\(mime) BODY[1] {\(unrelatedBody.utf8.count)}\r\n\(unrelatedBody))\r\n"
                + "* 42 FETCH (UID 42 FLAGS (\\Seen) INTERNALDATE \"1-Jan-2026 12:00:00 +0000\" BODY[HEADER] {\(header.utf8.count)}\r\n\(header) BODY[1.MIME] {\(mime.utf8.count)}\r\n\(mime) BODY[1] {\(body.utf8.count)}\r\n\(body))\r\nA0003 OK FETCH\r\n"
            var decoder = IMAPResponseDecoder()
            let framedLines = try decoder.append(Data(wire.utf8))
            try decoder.finish()
            transport.addRoute(matching: "BODY.PEEK[1.MIME]", response: framedLines)

            let service = OutlookIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            let content = try await service.fetchMessageContent(messageID: "42")

            #expect(content.metadata.provider == .outlook)
            #expect(content.metadata.providerMessageID == "42")
            #expect(content.metadata.providerGlobalMessageID == "outlook-42")
            #expect(content.body == "Agenda: review at 3pm")
            #expect(!content.body.hasPrefix("\r\n"))
            #expect(!content.body.hasSuffix(")"))
            #expect(content.metadata.subject == "Outlook note")
            #expect(content.metadata.isRead)
            #expect(transport.commands.allSatisfy { !$0.contains("<0.") })
        }
    }
    @Test("small Outlook text opens without fetching large binary or text attachments")
    func readableBodyExcludesLargeAttachments() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }
            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)
            let body = "Please review the small agenda. The earlier upload request is withdrawn."
            let mime = "Content-Type: text/plain; charset=utf-8\r\n\r\n"
            let header = "Subject: Small readable body\r\nMessage-ID: <outlook-43>\r\n\r\n"
            transport.addRoute(matching: "UID FETCH 43 (BODYSTRUCTURE)", response: [
                "* 43 FETCH (UID 43 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" \(body.utf8.count) 1 NIL NIL) (\"APPLICATION\" \"PDF\" (\"NAME\" \"large.pdf\") NIL NIL \"BASE64\" 24000000 NIL (\"ATTACHMENT\" (\"FILENAME\" \"large.pdf\"))) (\"TEXT\" \"PLAIN\" (\"NAME\" \"large.txt\") NIL NIL \"7BIT\" 9000000 1 NIL (\"ATTACHMENT\" (\"FILENAME\" \"large.txt\"))) \"MIXED\"))",
                "A0002 OK FETCH"
            ])
            let wire = "* 43 FETCH (UID 43 BODY[HEADER] {\(header.utf8.count)}\r\n\(header) BODY[1.MIME] {\(mime.utf8.count)}\r\n\(mime) BODY[1] {\(body.utf8.count)}\r\n\(body))\r\nA0003 OK FETCH\r\n"
            var decoder = IMAPResponseDecoder()
            let frames = try decoder.append(Data(wire.utf8))
            try decoder.finish()
            transport.addRoute(matching: "BODY.PEEK[1.MIME]", response: frames)
            let service = OutlookIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            let content = try await service.fetchMessageContent(messageID: "43")
            #expect(content.body == body)
            #expect(content.metadata.providerGlobalMessageID == "outlook-43")
            #expect(transport.commands.allSatisfy {
                !$0.contains("BODY.PEEK[TEXT]") && !$0.contains("BODY.PEEK[2") && !$0.contains("BODY.PEEK[3")
            })
        }
    }

}

@MainActor
extension OutlookIMAPServiceTests {
    @Test("disposed command session reconnects with the saved credential before the next inbox request")
    func disposedSessionReadinessRecovery() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }
            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)
            let service = OutlookIMAPService(transport: transport)
            try await service.ensureAuthenticated(email: email, backgroundEnabled: false)
            transport.addRoute(matching: "UID SEARCH ALL", error: OutlookIMAPError.transport("Synthetic failure"), once: true)
            await #expect(throws: OutlookIMAPError.transport("Synthetic failure")) {
                _ = try await service.fetchInboxPage(after: nil)
            }
            #expect(!(await service.isAuthenticated))
            #expect(await service.authenticatedAccount == nil)
            try await service.ensureAuthenticated(email: email, backgroundEnabled: false)
            #expect(try await service.fetchInboxPage(after: nil).messages.isEmpty)
            #expect(transport.commands.filter { $0 == "CONNECT_PREAUTH" }.count == 2)
        }
    }
}
