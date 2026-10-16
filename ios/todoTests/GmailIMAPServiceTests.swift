import Foundation
import Testing
@testable import todo

@Suite("Gmail IMAP mailbox", .serialized)
@MainActor
struct GmailIMAPServiceTests {
    private let email = "imap@example.com"

    private func literal(_ value: String) -> String {
        "{\(value.utf8.count)}\(value)"
    }

    private func setupCredentials() throws {
        try? IMAPCredentialStore.delete(for: email)
        try IMAPCredentialStore.save(appPassword: "app-password", for: email, backgroundEnabled: false)
    }

    private func cleanupCredentials() {
        try? IMAPCredentialStore.delete(for: email)
    }

    private func setupAuth(transport: ScriptedIMAPTransport, messageCount: UInt32? = nil) {
        transport.addRoute(matching: "CAPABILITY", response: [
            "* CAPABILITY IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID UIDPLUS MOVE X-GM-EXT-1",
            "A0000 OK CAPABILITY"
        ])
        transport.addRoute(matching: "SELECT INBOX", response: (messageCount.map { ["* \($0) EXISTS"] } ?? []) + [
            "* OK [UIDVALIDITY 42] selected",
            "A0001 OK SELECT"
        ])
    }

    @Test("connection verification fails closed and preserves the saved password", arguments: ["denied", "disconnected", "missingHeaders", "missingIdentity"], [false, true])
    func connectionVerificationFailsClosed(failure: String, replacingPassword: Bool) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }
            IMAPCredentialStore.markCredentialRejected(for: email)
            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport, messageCount: 1)
            let expected: GmailIMAPError = failure == "disconnected" ? .transport("IMAP is not connected") : .invalidResponse
            switch failure {
            case "denied", "disconnected":
                transport.addRoute(matching: "FETCH *", error: expected, once: true)
            case "missingHeaders":
                transport.addRoute(matching: "FETCH *", response: ["* 1 FETCH (UID 7 X-GM-MSGID 900)", "A0002 OK FETCH"], once: true)
            default:
                transport.addRoute(matching: "FETCH *", response: ["* 1 FETCH (UID 7 BODY[HEADER.FIELDS] \(literal("Subject: Mail\r\n\r\n")))", "A0002 OK FETCH"], once: true)
            }
            let service = GmailIMAPService(transport: transport)
            // Start from an authenticated session to catch stale connected state on failure.
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
            #expect(try IMAPCredentialStore.credential(for: email) == "app-password")
            #expect(IMAPCredentialStore.isCredentialRejected(for: email))

            transport.addRoute(matching: "FETCH *", response: [
                "* 1 FETCH (UID 7 X-GM-MSGID 900 BODY[HEADER.FIELDS] \(literal("Subject: Mail\r\n\r\n")))",
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
            transport.addRoute(matching: "FETCH *", response: [
                "* 1 FETCH (UID 7 X-GM-MSGID 900 BODY[HEADER.FIELDS] \(literal("Subject: Mail\r\nFrom: sender@example.com\r\n\r\n")))",
                "A0002 OK FETCH"
            ])
            let service = GmailIMAPService(transport: transport)
            try await service.validateConnection(email: email, backgroundEnabled: false)
            #expect(await service.authenticatedAccount == email)
            try await service.authenticateAndSave(email: email, appPassword: "replacement-password", backgroundEnabled: false)
            #expect(try IMAPCredentialStore.credential(for: email) == "replacement-password")
            #expect(await service.authenticatedAccount == email)
            #expect(transport.commands.contains { $0.hasPrefix("FETCH *") } == (messageCount > 0))
            #expect(transport.commands.allSatisfy { !$0.contains("STORE") && !$0.contains("EXPUNGE") && !$0.contains("UID SEARCH ALL") })
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
            let service = GmailIMAPService(transport: transport)
            await #expect(throws: GmailIMAPError.invalidResponse) {
                try await service.validateConnection(email: email, backgroundEnabled: false)
            }
            #expect(!(await service.isAuthenticated))
            #expect(try IMAPCredentialStore.credential(for: email) == "app-password")
        }
    }

    @Test("failed reconnect keeps the stored App Password")
    func failedReconnectKeepsStoredCredential() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            transport.addRoute(matching: "LOGIN", response: ["A0000 NO [AUTHENTICATIONFAILED] LOGIN failed"])

            let service = GmailIMAPService(transport: transport)
            await #expect(throws: GmailIMAPError.credentialRejected) {
                try await service.authenticate(email: email, backgroundEnabled: false)
            }

            #expect(try IMAPCredentialStore.credential(for: email) == "app-password")
        }
    }

    @Test("transient IMAP LOGIN refusal remains retryable")
    func transientLoginRefusalIsNotCredentialRejection() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            transport.addRoute(matching: "LOGIN", response: ["A0000 NO [ALERT] Too many simultaneous connections"])

            let service = GmailIMAPService(transport: transport)
            await #expect(throws: GmailIMAPError.invalidResponse) {
                try await service.authenticate(email: email, backgroundEnabled: false)
            }
        }
    }

    @Test("metadata fetches before body without mutating the server")
    func readOnlyMailboxFlow() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            let searchUIDs = (1...5).map(String.init).joined(separator: " ")
            transport.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH \(searchUIDs)",
                "A0002 OK SEARCH"
            ])
            transport.addRoute(matching: "UID FETCH 1,2,3,4,5", response: [
                "* 1 FETCH (UID 1 X-GM-MSGID 900 X-GM-THRID 901 BODY[HEADER.FIELDS] {76}Subject: Hello\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "A0003 OK FETCH"
            ])
            // 5 category search routes
            transport.addRoute(matching: "category:primary", response: ["* SEARCH 1", "A0004 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0005 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0006 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0007 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0008 OK SEARCH"])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            let page = try await service.fetchInboxPage(after: nil)
            let metadata = try #require(page.messages.first)
            #expect(metadata.providerMessageID == "1")
            #expect(metadata.providerGlobalMessageID == "900")
            #expect(metadata.subject == "Hello")
            #expect(metadata.from == "sender@example.com")
            #expect(transport.commands.contains { $0.contains("BODY.PEEK") })
            #expect(transport.commands.allSatisfy { !$0.contains("STORE") && !$0.contains("EXPUNGE") && !$0.contains("DELETE") })
        }
    }

    @Test("Gmail mutations validate identity, mark read, and move to localized Trash")
    func gmailMutationCommandsReachServer() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)
            transport.addRoute(matching: "UID FETCH 7 (UID X-GM-MSGID)", response: [
                "* 7 FETCH (UID 7 X-GM-MSGID 900)",
                "A0002 OK FETCH"
            ])
            transport.addRoute(matching: "LIST \"\" \"*\"", response: [
                "* LIST (\\HasNoChildren \\Trash) \"/\" \"[Gmail]/휴지통\"",
                "A0003 OK LIST"
            ])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            try await service.markAsRead(messageID: "7", expectedGlobalMessageID: "900")
            try await service.trashMessage(messageID: "7", expectedGlobalMessageID: "900")

            #expect(transport.commands.contains("UID STORE 7 +FLAGS.SILENT (\\Seen)"))
            #expect(transport.commands.contains("LIST \"\" \"*\""))
            #expect(transport.commands.contains("UID MOVE 7 \"[Gmail]/휴지통\""))
            #expect(transport.commands.allSatisfy { !$0.uppercased().contains("EXPUNGE") })
        }
    }

    @Test("Gmail trash rejects a reset UID whose searched identity does not match")
    func gmailTrashRejectsMismatchedSearchResult() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            transport.addRoute(matching: "CAPABILITY", response: [
                "* CAPABILITY IMAP4rev1 MOVE X-GM-EXT-1",
                "A0000 OK CAPABILITY"
            ])
            transport.addRoute(matching: "SELECT INBOX", response: [
                "* OK [UIDVALIDITY 42] selected",
                "A0001 OK SELECT"
            ], once: true)
            transport.addRoute(matching: "SELECT INBOX", response: [
                "* OK [UIDVALIDITY 43] selected",
                "A0002 OK SELECT"
            ])
            transport.addRoute(matching: "UID SEARCH X-GM-MSGID 900", response: [
                "* SEARCH 12",
                "A0003 OK SEARCH"
            ])
            transport.addRoute(matching: "UID FETCH 12 (UID X-GM-MSGID)", response: [
                "* 12 FETCH (UID 12 X-GM-MSGID 901)",
                "A0004 OK FETCH"
            ])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            await #expect(throws: GmailIMAPError.mailboxReset) {
                try await service.trashMessage(messageID: "7", expectedGlobalMessageID: "900")
            }
            #expect(transport.commands.contains("UID SEARCH X-GM-MSGID 900"))
            #expect(transport.commands.contains("UID FETCH 12 (UID X-GM-MSGID)"))
            #expect(!transport.commands.contains("UID MOVE 12 \"[Gmail]/Trash\""))
        }
    }

    @Test("Gmail trash moves an archived message from All Mail")
    func gmailTrashMovesArchivedMessageFromAllMail() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            transport.addRoute(matching: "CAPABILITY", response: [
                "* CAPABILITY IMAP4rev1 MOVE X-GM-EXT-1",
                "A0000 OK CAPABILITY"
            ])
            transport.addRoute(matching: "SELECT INBOX", response: [
                "* OK [UIDVALIDITY 42] selected",
                "A0001 OK SELECT"
            ], once: true)
            transport.addRoute(matching: "SELECT INBOX", response: [
                "* OK [UIDVALIDITY 43] selected",
                "A0002 OK SELECT"
            ])
            transport.addRoute(matching: "UID SEARCH X-GM-MSGID 900", response: [
                "* SEARCH",
                "A0003 OK SEARCH"
            ], once: true)
            transport.addRoute(matching: "LIST \"\" \"*\"", response: [
                "* LIST (\\HasNoChildren \\All) \"/\" \"[Gmail]/All Mail\"",
                "* LIST (\\HasNoChildren \\Trash) \"/\" \"[Gmail]/Trash\"",
                "A0004 OK LIST"
            ])
            transport.addRoute(matching: "SELECT \"[Gmail]/All Mail\"", response: [
                "* OK [UIDVALIDITY 44] selected",
                "A0005 OK SELECT"
            ])
            transport.addRoute(matching: "UID SEARCH X-GM-MSGID 900", response: [
                "* SEARCH 12",
                "A0006 OK SEARCH"
            ])
            transport.addRoute(matching: "UID FETCH 12 (UID X-GM-MSGID)", response: [
                "* 12 FETCH (UID 12 X-GM-MSGID 900)",
                "A0007 OK FETCH"
            ])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            try await service.trashMessage(messageID: "7", expectedGlobalMessageID: "900")

            #expect(transport.commands.contains("SELECT \"[Gmail]/All Mail\""))
            #expect(transport.commands.contains("UID MOVE 12 \"[Gmail]/Trash\""))
        }
    }

    @Test("Gmail trash completes when the message is already in Trash")
    func gmailTrashTreatsMessageInTrashAsComplete() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            transport.addRoute(matching: "CAPABILITY", response: [
                "* CAPABILITY IMAP4rev1 MOVE X-GM-EXT-1",
                "A0000 OK CAPABILITY"
            ])
            transport.addRoute(matching: "SELECT INBOX", response: [
                "* OK [UIDVALIDITY 42] selected",
                "A0001 OK SELECT"
            ], once: true)
            transport.addRoute(matching: "SELECT INBOX", response: [
                "* OK [UIDVALIDITY 43] selected",
                "A0002 OK SELECT"
            ])
            transport.addRoute(matching: "UID SEARCH X-GM-MSGID 900", response: [
                "* SEARCH",
                "A0003 OK SEARCH"
            ], once: true)
            transport.addRoute(matching: "LIST \"\" \"*\"", response: [
                "* LIST (\\HasNoChildren \\All) \"/\" \"[Gmail]/All Mail\"",
                "* LIST (\\HasNoChildren \\Trash) \"/\" \"[Gmail]/Trash\"",
                "A0004 OK LIST"
            ])
            transport.addRoute(matching: "SELECT \"[Gmail]/All Mail\"", response: [
                "* OK [UIDVALIDITY 44] selected",
                "A0005 OK SELECT"
            ])
            transport.addRoute(matching: "UID SEARCH X-GM-MSGID 900", response: [
                "* SEARCH",
                "A0006 OK SEARCH"
            ], once: true)
            transport.addRoute(matching: "SELECT \"[Gmail]/Trash\"", response: [
                "* OK [UIDVALIDITY 45] selected",
                "A0007 OK SELECT"
            ])
            transport.addRoute(matching: "UID SEARCH X-GM-MSGID 900", response: [
                "* SEARCH 13",
                "A0008 OK SEARCH"
            ])
            transport.addRoute(matching: "UID FETCH 13 (UID X-GM-MSGID)", response: [
                "* 13 FETCH (UID 13 X-GM-MSGID 900)",
                "A0009 OK FETCH"
            ])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            try await service.trashMessage(messageID: "7", expectedGlobalMessageID: "900")

            #expect(transport.commands.contains("SELECT \"[Gmail]/Trash\""))
            #expect(!transport.commands.contains { $0.contains("UID MOVE") })
        }
    }

    @Test("Gmail trash completes only after All Mail and Trash both lack the message")
    func gmailTrashTreatsMessageMissingEverywhereAsComplete() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            transport.addRoute(matching: "CAPABILITY", response: [
                "* CAPABILITY IMAP4rev1 MOVE X-GM-EXT-1",
                "A0000 OK CAPABILITY"
            ])
            transport.addRoute(matching: "SELECT INBOX", response: [
                "* OK [UIDVALIDITY 42] selected",
                "A0001 OK SELECT"
            ], once: true)
            transport.addRoute(matching: "SELECT INBOX", response: [
                "* OK [UIDVALIDITY 43] selected",
                "A0002 OK SELECT"
            ])
            transport.addRoute(matching: "UID SEARCH X-GM-MSGID 900", response: [
                "* SEARCH",
                "A0003 OK SEARCH"
            ], once: true)
            transport.addRoute(matching: "LIST \"\" \"*\"", response: [
                "* LIST (\\HasNoChildren \\All) \"/\" \"[Gmail]/All Mail\"",
                "* LIST (\\HasNoChildren \\Trash) \"/\" \"[Gmail]/Trash\"",
                "A0004 OK LIST"
            ])
            transport.addRoute(matching: "SELECT \"[Gmail]/All Mail\"", response: [
                "* OK [UIDVALIDITY 44] selected",
                "A0005 OK SELECT"
            ])
            transport.addRoute(matching: "UID SEARCH X-GM-MSGID 900", response: [
                "* SEARCH",
                "A0006 OK SEARCH"
            ], once: true)
            transport.addRoute(matching: "SELECT \"[Gmail]/Trash\"", response: [
                "* OK [UIDVALIDITY 45] selected",
                "A0007 OK SELECT"
            ])
            transport.addRoute(matching: "UID SEARCH X-GM-MSGID 900", response: [
                "* SEARCH",
                "A0008 OK SEARCH"
            ])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            try await service.trashMessage(messageID: "7", expectedGlobalMessageID: "900")

            #expect(transport.commands.contains("SELECT \"[Gmail]/All Mail\""))
            #expect(transport.commands.contains("SELECT \"[Gmail]/Trash\""))
            #expect(!transport.commands.contains { $0.contains("UID MOVE") })
        }
    }

    @Test("Gmail trash resolves a stale UID by immutable message identity")
    func gmailTrashRecoversAfterMailboxUIDReset() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            transport.addRoute(matching: "CAPABILITY", response: [
                "* CAPABILITY IMAP4rev1 MOVE X-GM-EXT-1",
                "A0000 OK CAPABILITY"
            ])
            transport.addRoute(matching: "SELECT INBOX", response: [
                "* OK [UIDVALIDITY 42] selected",
                "A0001 OK SELECT"
            ], once: true)
            transport.addRoute(matching: "SELECT INBOX", response: [
                "* OK [UIDVALIDITY 43] selected",
                "A0002 OK SELECT"
            ])
            transport.addRoute(matching: "UID SEARCH X-GM-MSGID 900", response: [
                "* SEARCH 12",
                "A0003 OK SEARCH"
            ])
            transport.addRoute(matching: "UID FETCH 12 (UID X-GM-MSGID)", response: [
                "* 12 FETCH (UID 12 X-GM-MSGID 900)",
                "A0004 OK FETCH"
            ])
            transport.addRoute(matching: "LIST \"\" \"*\"", response: [
                "* LIST (\\HasNoChildren \\Trash) \"/\" \"[Gmail]/Trash\"",
                "A0005 OK LIST"
            ])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            try await service.trashMessage(messageID: "7", expectedGlobalMessageID: "900")

            #expect(transport.commands.contains("UID SEARCH X-GM-MSGID 900"))
            #expect(transport.commands.contains("UID MOVE 12 \"[Gmail]/Trash\""))
            #expect(!transport.commands.contains("UID MOVE 7 \"[Gmail]/Trash\""))
        }
    }

    @Test("Gmail mutations refuse a reused UID with a different Gmail message identity")
    func gmailMutationRejectsReusedUID() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)
            transport.addRoute(matching: "UID FETCH 7 (UID X-GM-MSGID)", response: [
                "* 7 FETCH (UID 7 X-GM-MSGID 901)",
                "A0002 OK FETCH"
            ])
            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)

            await #expect(throws: GmailIMAPError.mailboxReset) {
                try await service.markAsRead(messageID: "7", expectedGlobalMessageID: "900")
            }
            #expect(!transport.commands.contains("UID STORE 7 +FLAGS.SILENT (\\Seen)"))
        }
    }

    @Test("body fetch uses UID, parses BODYSTRUCTURE, selects text section and decodes content")
    func bodyFetchUsesUID() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            transport.addRoute(matching: "UID FETCH 7 (BODYSTRUCTURE)", response: [
                "* 1 FETCH (UID 7 BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"QUOTED-PRINTABLE\" 100 5 NIL NIL NIL NIL))",
                "A0002 OK FETCH"
            ])
            transport.addRoute(matching: "BODY.PEEK[1.MIME]", response: [
                "* 1 FETCH (UID 7 X-GM-MSGID 900 X-GM-THRID 901 BODY[HEADER] "
                    + literal("Subject: =?UTF-8?B?67O07JWIIA==?= =?UTF-8?B?7JWM66a8?=\r\nFrom: sender@example.com\r\n\r\n")
                    + " BODY[1.MIME] " + literal("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n")
                    + " BODY[1]<0> " + literal("Hello=20world=21") + ")",
                "A0003 OK FETCH"
            ])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            let content = try await service.fetchMessageContent(messageID: "7")
            #expect(content.metadata.providerMessageID == "7")
            #expect(content.metadata.subject == "보안 알림")
            #expect(content.metadata.snippet == "Hello world!")
            #expect(content.body == "Hello world!")
            #expect(transport.commands.contains { $0.contains("BODY.PEEK[1.MIME]") && $0.contains("BODY.PEEK[1]<0.500000>)") })
            #expect(transport.commands.allSatisfy { !$0.contains("STORE") && !$0.contains("EXPUNGE") && !$0.contains("DELETE") })
        }
    }

    @Test("body fetch prefers HTML over plain text in multipart alternative")
    func bodyFetchPrefersHTML() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            transport.addRoute(matching: "UID FETCH 8 (BODYSTRUCTURE)", response: [
                "* 1 FETCH (UID 8 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 20 2 NIL NIL NIL NIL) (\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 40 4 NIL NIL NIL NIL) \"ALTERNATIVE\"))",
                "A0002 OK FETCH"
            ])
            transport.addRoute(matching: "BODY.PEEK[2.MIME]", response: [
                "* 1 FETCH (UID 8 X-GM-MSGID 901 X-GM-THRID 901 BODY[HEADER] "
                    + literal("Subject: HTML Test\r\nFrom: sender@example.com\r\n\r\n")
                    + " BODY[2.MIME] " + literal("Content-Type: text/html; charset=utf-8\r\n\r\n")
                    + " BODY[2]<0> " + literal("<p>Hello <b>HTML</b></p>") + ")",
                "A0003 OK FETCH"
            ])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            let content = try await service.fetchMessageContent(messageID: "8")
            #expect(content.htmlBody == "<p>Hello <b>HTML</b></p>")
            #expect(content.body == "Hello HTML")
            #expect(!transport.commands.contains { $0.contains("BODY.PEEK[1]") })
            #expect(transport.commands.contains { $0.contains("BODY.PEEK[2.MIME]") })
        }
    }

    @Test("body fetch skips attachment section coming before text body")
    func bodyFetchSkipsAttachmentBeforeBody() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            transport.addRoute(matching: "UID FETCH 9 (BODYSTRUCTURE)", response: [
                "* 1 FETCH (UID 9 BODYSTRUCTURE ((\"APPLICATION\" \"PDF\" (\"NAME\" \"file.pdf\") NIL NIL \"BASE64\" 1000 NIL (\"ATTACHMENT\" (\"FILENAME\" \"file.pdf\")) NIL NIL) (\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 40 4 NIL NIL NIL NIL) \"MIXED\"))",
                "A0002 OK FETCH"
            ])
            transport.addRoute(matching: "BODY.PEEK[2.MIME]", response: [
                "* 1 FETCH (UID 9 X-GM-MSGID 902 X-GM-THRID 901 BODY[HEADER] "
                    + literal("Subject: Attach test\r\nFrom: sender@example.com\r\n\r\n")
                    + " BODY[2.MIME] " + literal("Content-Type: text/html; charset=utf-8\r\n\r\n")
                    + " BODY[2]<0> " + literal("<h1>Main Body</h1>") + ")",
                "A0003 OK FETCH"
            ])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            let content = try await service.fetchMessageContent(messageID: "9")
            #expect(content.htmlBody == "<h1>Main Body</h1>")
            #expect(!transport.commands.contains { $0.contains("BODY.PEEK[1]") })
            #expect(transport.commands.contains { $0.contains("BODY.PEEK[2.MIME]") })
        }
    }

    @Test("body fetch decodes non-UTF8 base64 charset parts")
    func bodyFetchNonUTF8Charset() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            transport.addRoute(matching: "UID FETCH 10 (BODYSTRUCTURE)", response: [
                "* 1 FETCH (UID 10 BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"EUC-KR\") NIL NIL \"BASE64\" 20 2 NIL NIL NIL NIL))",
                "A0002 OK FETCH"
            ])
            transport.addRoute(matching: "BODY.PEEK[1.MIME]", response: [
                "* 1 FETCH (UID 10 X-GM-MSGID 903 X-GM-THRID 901 BODY[HEADER] "
                    + literal("Subject: Non UTF8\r\nFrom: sender@example.com\r\n\r\n")
                    + " BODY[1.MIME] " + literal("Content-Type: text/plain; charset=euc-kr\r\nContent-Transfer-Encoding: base64\r\n\r\n")
                    + " BODY[1]<0> " + literal("vsiz58fPvLy/5A==") + ")",
                "A0003 OK FETCH"
            ])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            let content = try await service.fetchMessageContent(messageID: "10")
            #expect(content.body.contains("안녕하세요"))
        }
    }

    @Test("exact boundary truncation discards partial HTML and throws on unselectable attachment")
    func bodyFetchTruncationAndUnselectablePart() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            // 1. Truncated HTML payload discards partial HTML and attaches notice
            let transportTruncated = ScriptedIMAPTransport()
            setupAuth(transport: transportTruncated)
            transportTruncated.addRoute(matching: "UID FETCH 11 (BODYSTRUCTURE)", response: [
                "* 1 FETCH (UID 11 BODYSTRUCTURE (\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 600000 1000 NIL NIL NIL NIL))",
                "A0002 OK FETCH"
            ])
            let hugePayload = String(repeating: "A", count: 500000)
            transportTruncated.addRoute(matching: "BODY.PEEK[1.MIME]", response: [
                "* 1 FETCH (UID 11 X-GM-MSGID 904 X-GM-THRID 901 BODY[HEADER] "
                    + literal("Subject: Big Mail\r\nFrom: sender@example.com\r\n\r\n")
                    + " BODY[1.MIME] " + literal("Content-Type: text/html; charset=utf-8\r\n\r\n")
                    + " BODY[1]<0> " + literal(hugePayload) + ")",
                "A0003 OK FETCH"
            ])
            let serviceTruncated = GmailIMAPService(transport: transportTruncated)
            try await serviceTruncated.authenticate(email: email, backgroundEnabled: false)
            let truncatedContent = try await serviceTruncated.fetchMessageContent(messageID: "11")
            #expect(truncatedContent.htmlBody.isEmpty)
            #expect(truncatedContent.body.contains("["))

            // 2. Only attachment part throws noSelectableTextPart
            let transportAttachmentOnly = ScriptedIMAPTransport()
            setupAuth(transport: transportAttachmentOnly)
            transportAttachmentOnly.addRoute(matching: "UID FETCH 12 (BODYSTRUCTURE)", response: [
                "* 1 FETCH (UID 12 BODYSTRUCTURE (\"APPLICATION\" \"PDF\" (\"NAME\" \"file.pdf\") NIL NIL \"BASE64\" 1000 NIL (\"ATTACHMENT\" (\"FILENAME\" \"file.pdf\")) NIL NIL))",
                "A0002 OK FETCH"
            ])
            let serviceAttachmentOnly = GmailIMAPService(transport: transportAttachmentOnly)
            try await serviceAttachmentOnly.authenticate(email: email, backgroundEnabled: false)
            await #expect(throws: GmailIMAPError.noSelectableTextPart) {
                try await serviceAttachmentOnly.fetchMessageContent(messageID: "12")
            }
        }
    }

    @Test("head index 1...205 fetches 106...205 and pages older mail to completion")
    func headAndOlderUIDPaging() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            let allUIDs = (1...205).map(String.init).joined(separator: " ")
            transport.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH \(allUIDs)",
                "A0002 OK SEARCH"
            ])

            // Head page fetch: window 106...205
            let headRange = (106...205).map(String.init).joined(separator: ",")
            let fetchResponseLines = (106...205).map { uid in
                "* \(uid) FETCH (UID \(uid) X-GM-MSGID \(1000 + uid) X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test \(uid)\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)"
            } + ["A0003 OK FETCH"]
            transport.addRoute(matching: "UID FETCH \(headRange)", response: fetchResponseLines)

            // 5 category routes for 106...205
            transport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0004 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0005 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0006 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0007 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0008 OK SEARCH"])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)

            // 1. Head page load
            let headPage = try await service.fetchInboxPage(after: nil)
            #expect(headPage.messages.count == 100)
            #expect(headPage.nextCursor == "42:106")
            #expect(headPage.newestCursor == "42:205")

            // 2. Second page load (after 42:106): window 6...105
            transport.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH \(allUIDs)",
                "A0010 OK SEARCH"
            ])
            let page2Range = (6...105).map(String.init).joined(separator: ",")
            let page2ResponseLines = (6...105).map { uid in
                "* \(uid) FETCH (UID \(uid) X-GM-MSGID \(1000 + uid) X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test \(uid)\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)"
            } + ["A0011 OK FETCH"]
            transport.addRoute(matching: "UID FETCH \(page2Range)", response: page2ResponseLines)
            transport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0012 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0013 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0014 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0015 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0016 OK SEARCH"])

            let page2 = try await service.fetchInboxPage(after: "42:106")
            #expect(page2.messages.count == 100)
            #expect(page2.nextCursor == "42:6")
            #expect(page2.newestCursor == nil)

            // 3. Third page load (after 42:6): window 1...5
            transport.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH \(allUIDs)",
                "A0020 OK SEARCH"
            ])
            let page3Range = (1...5).map(String.init).joined(separator: ",")
            let page3ResponseLines = (1...5).map { uid in
                "* \(uid) FETCH (UID \(uid) X-GM-MSGID \(1000 + uid) X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test \(uid)\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)"
            } + ["A0021 OK FETCH"]
            transport.addRoute(matching: "UID FETCH \(page3Range)", response: page3ResponseLines)
            transport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0022 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0023 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0024 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0025 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0026 OK SEARCH"])

            let page3 = try await service.fetchInboxPage(after: "42:6")
            #expect(page3.messages.count == 5)
            #expect(page3.nextCursor == nil)
            #expect(page3.newestCursor == nil)
        }
    }

    @Test("empty inbox returns newest anchor 42:0 and parses UIDVALIDITY correctly")
    func emptyInboxAndUIDValidityParsing() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            transport.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH",
                "A0002 OK SEARCH"
            ])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)

            let page = try await service.fetchInboxPage(after: nil)
            #expect(page.messages.isEmpty)
            #expect(page.nextCursor == nil)
            #expect(page.newestCursor == "42:0")
        }
    }

    @Test("missing X-GM-EXT-1 extension throws and stale validity cursor resets to baseline")
    func missingExtensionAndValidityReset() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            // 1. Missing extension check
            let transportNoExt = ScriptedIMAPTransport()
            transportNoExt.addRoute(matching: "CAPABILITY", response: [
                "* CAPABILITY IMAP4rev1 UNSELECT IDLE",
                "A0000 OK CAPABILITY"
            ])
            let serviceNoExt = GmailIMAPService(transport: transportNoExt)
            await #expect(throws: GmailIMAPError.unsupportedExtension) {
                try await serviceNoExt.authenticate(email: email, backgroundEnabled: false)
            }
            #expect(
                GmailIMAPError.unsupportedExtension.errorDescription(language: .english)
                    == "Gmail IMAP does not advertise X-GM-EXT-1."
            )

            // 2. Stale validity cursor reset
            let transportReset = ScriptedIMAPTransport()
            setupAuth(transport: transportReset)
            transportReset.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH 10 20",
                "A0002 OK SEARCH"
            ])
            transportReset.addRoute(matching: "UID FETCH 10,20", response: [
                "* 10 FETCH (UID 10 X-GM-MSGID 1010 X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: M10\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "* 20 FETCH (UID 20 X-GM-MSGID 1020 X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: M20\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "A0003 OK FETCH"
            ])
            transportReset.addRoute(matching: "category:primary", response: ["* SEARCH", "A0004 OK SEARCH"])
            transportReset.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0005 OK SEARCH"])
            transportReset.addRoute(matching: "category:social", response: ["* SEARCH", "A0006 OK SEARCH"])
            transportReset.addRoute(matching: "category:updates", response: ["* SEARCH", "A0007 OK SEARCH"])
            transportReset.addRoute(matching: "category:forums", response: ["* SEARCH", "A0008 OK SEARCH"])

            let serviceReset = GmailIMAPService(transport: transportReset)
            try await serviceReset.authenticate(email: email, backgroundEnabled: false)

            // Pass stale validity "99:10" -> should degrade to head load under current validity "42"
            let page = try await serviceReset.fetchInboxPage(after: "99:10")
            #expect(page.messages.count == 2)
            #expect(page.newestCursor == "42:20")
        }
    }

    @Test("five scoped X-GM-RAW searches map to categories and failure throws")
    func fiveScopedCategorySearchesAndFailure() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            transport.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH 1 2 3 4 5",
                "A0002 OK SEARCH"
            ])
            let fetchLines = (1...5).map { uid in
                "* \(uid) FETCH (UID \(uid) X-GM-MSGID \(1000 + uid) X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test \(uid)\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)"
            } + ["A0003 OK FETCH"]
            transport.addRoute(matching: "UID FETCH 1,2,3,4,5", response: fetchLines)

            // Category mappings
            transport.addRoute(matching: "category:primary", response: ["* SEARCH 1", "A0004 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH 2", "A0005 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH 3", "A0006 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH 4", "A0007 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH 5", "A0008 OK SEARCH"])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)

            let page = try await service.fetchInboxPage(after: nil)
            #expect(page.messages.count == 5)

            #expect(page.messages[0].gmailLabelIDs.contains("CATEGORY_PERSONAL"))
            #expect(page.messages[1].gmailLabelIDs.contains("CATEGORY_PROMOTIONS"))
            #expect(page.messages[2].gmailLabelIDs.contains("CATEGORY_SOCIAL"))
            #expect(page.messages[3].gmailLabelIDs.contains("CATEGORY_UPDATES"))
            #expect(page.messages[4].gmailLabelIDs.contains("CATEGORY_FORUMS"))

            // Category search failure test
            let transportFail = ScriptedIMAPTransport()
            setupAuth(transport: transportFail)
            transportFail.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH 1",
                "A0002 OK SEARCH"
            ])
            transportFail.addRoute(matching: "UID FETCH 1", response: [
                "* 1 FETCH (UID 1 X-GM-MSGID 1001 X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test 1\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "A0003 OK FETCH"
            ])
            transportFail.addRoute(matching: "category:primary", error: GmailIMAPError.transport("Category search failed"))

            let serviceFail = GmailIMAPService(transport: transportFail)
            try await serviceFail.authenticate(email: email, backgroundEnabled: false)
            await #expect(throws: GmailIMAPError.self) {
                try await serviceFail.fetchInboxPage(after: nil)
            }
        }
    }

    @Test("body fetch retains category labels cached by page fetch")
    func bodyCategoryRetention() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            transport.addRoute(matching: "UID SEARCH ALL", response: [
                "* SEARCH 10",
                "A0002 OK SEARCH"
            ])
            transport.addRoute(matching: "RFC822.SIZE", response: [
                "* 10 FETCH (UID 10 X-GM-MSGID 1010 X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "A0003 OK FETCH"
            ])
            transport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0004 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH 10", "A0005 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0006 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0007 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0008 OK SEARCH"])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)

            let page = try await service.fetchInboxPage(after: nil)
            #expect(page.messages.first?.gmailLabelIDs.contains("CATEGORY_PROMOTIONS") == true)

            // Now fetch body for UID 10
            transport.addRoute(matching: "UID FETCH 10 (BODYSTRUCTURE)", response: [
                "* 1 FETCH (UID 10 BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 11 1 NIL NIL NIL NIL))",
                "A0010 OK FETCH"
            ])
            transport.addRoute(matching: "BODY.PEEK[1.MIME]", response: [
                "* 1 FETCH (UID 10 X-GM-MSGID 1010 X-GM-THRID 2000 BODY[HEADER] "
                    + literal("Subject: Test\r\nFrom: sender@example.com\r\n\r\n")
                    + " BODY[1.MIME] " + literal("Content-Type: text/plain; charset=utf-8\r\n\r\n")
                    + " BODY[1]<0> " + literal("Hello world") + ")",
                "A0011 OK FETCH"
            ])

            let content = try await service.fetchMessageContent(messageID: "10")
            #expect(content.metadata.gmailLabelIDs.contains("CATEGORY_PROMOTIONS") == true)
        }
    }

    @Test("150 UID newer update drains 100 first then remaining 50, filters RFC m:* and respects UInt32.max")
    func newerDrain150UIDsBoundaryAndMax() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)

            // 1. First update call from 42:100 -> 150 new UIDs (101...250)
            let newUIDs = (101...250).map(String.init).joined(separator: " ")
            transport.addRoute(matching: "UID SEARCH UID 101:*", response: [
                "* SEARCH \(newUIDs)",
                "A0002 OK SEARCH"
            ])
            let fetchRange1 = (101...200).map(String.init).joined(separator: ",")
            let fetchLines1 = (101...200).map { uid in
                "* \(uid) FETCH (UID \(uid) X-GM-MSGID \(1000 + uid) X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test \(uid)\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)"
            } + ["A0003 OK FETCH"]
            transport.addRoute(matching: "UID FETCH \(fetchRange1)", response: fetchLines1)
            transport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0004 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0005 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0006 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0007 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0008 OK SEARCH"])

            let update1 = try await service.fetchInboxUpdates(newerThan: "42:100")
            #expect(update1.messages.count == 100)
            #expect(update1.newestCursor == "42:200")
            #expect(update1.hasMoreUpdates == true)

            // 2. Second update call from 42:200 -> remaining 50 UIDs (201...250)
            transport.addRoute(matching: "UID SEARCH UID 201:*", response: [
                "* SEARCH \((201...250).map(String.init).joined(separator: " "))",
                "A0010 OK SEARCH"
            ])
            let fetchRange2 = (201...250).map(String.init).joined(separator: ",")
            let fetchLines2 = (201...250).map { uid in
                "* \(uid) FETCH (UID \(uid) X-GM-MSGID \(1000 + uid) X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test \(uid)\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)"
            } + ["A0011 OK FETCH"]
            transport.addRoute(matching: "UID FETCH \(fetchRange2)", response: fetchLines2)
            transport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0012 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0013 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0014 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0015 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0016 OK SEARCH"])

            let update2 = try await service.fetchInboxUpdates(newerThan: "42:200")
            #expect(update2.messages.count == 50)
            #expect(update2.newestCursor == "42:250")
            #expect(update2.hasMoreUpdates == false)

            // 3. RFC m:* boundary filtering (search returning UID 250 when boundary is 250)
            transport.addRoute(matching: "UID SEARCH UID 251:*", response: [
                "* SEARCH 250",
                "A0020 OK SEARCH"
            ])
            let update3 = try await service.fetchInboxUpdates(newerThan: "42:250")
            #expect(update3.messages.isEmpty)
            #expect(update3.newestCursor == nil)

            // 4. UInt32.max boundary
            let updateMax = try await service.fetchInboxUpdates(newerThan: "42:\(UInt32.max)")
            #expect(updateMax.messages.isEmpty)
            #expect(updateMax.newestCursor == nil)
        }
    }

    @Test("concurrent Gmail trash transactions do not interleave on one IMAP connection")
    func concurrentTrashTransactionsAreSerialized() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let rawTransport = ScriptedIMAPTransport()
            setupAuth(transport: rawTransport)
            rawTransport.addRoute(matching: "UID FETCH 7 (UID X-GM-MSGID)", response: [
                "* 7 FETCH (UID 7 X-GM-MSGID 900)",
                "A0002 OK FETCH"
            ])
            rawTransport.addRoute(matching: "UID FETCH 8 (UID X-GM-MSGID)", response: [
                "* 8 FETCH (UID 8 X-GM-MSGID 901)",
                "A0003 OK FETCH"
            ])
            rawTransport.addRoute(matching: "LIST \"\" \"*\"", response: [
                "* LIST (\\HasNoChildren \\Trash) \"/\" \"[Gmail]/Trash\"",
                "A0004 OK LIST"
            ])

            let probe = ProbeIMAPTransport(underlying: rawTransport)
            let service = GmailIMAPService(transport: probe)
            try await service.authenticate(email: email, backgroundEnabled: false)

            probe.armGate()
            let firstTrash = Task {
                try await service.trashMessage(messageID: "7", expectedGlobalMessageID: "900")
            }
            await probe.waitForStarted()
            let secondTrash = Task {
                try await service.trashMessage(messageID: "8", expectedGlobalMessageID: "901")
            }
            probe.releaseGate()

            try await firstTrash.value
            try await secondTrash.value

            let commands = rawTransport.commands
            let fetchIndices = commands.enumerated().compactMap {
                $0.element.contains("UID FETCH 7") || $0.element.contains("UID FETCH 8") ? $0.offset : nil
            }
            let moveIndices = commands.enumerated().compactMap {
                $0.element.contains("UID MOVE 7") || $0.element.contains("UID MOVE 8") ? $0.offset : nil
            }

            #expect(fetchIndices.count == 2)
            #expect(moveIndices.count == 2)
            if fetchIndices.count == 2 && moveIndices.count == 2 {
                #expect(fetchIndices[0] < moveIndices[0])
                #expect(moveIndices[0] < fetchIndices[1])
                #expect(fetchIndices[1] < moveIndices[1])
            }
        }
    }

    @Test("concurrent command turns are serialized and disconnect waits for completion")
    func concurrentCommandTurnSerializationAndDisconnect() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let rawTransport = ScriptedIMAPTransport()
            setupAuth(transport: rawTransport)

            // Prepare routes for two concurrent calls
            rawTransport.addRoute(matching: "UID SEARCH ALL", response: ["* SEARCH 1", "A0002 OK SEARCH"])
            rawTransport.addRoute(matching: "UID FETCH 1", response: [
                "* 1 FETCH (UID 1 X-GM-MSGID 1001 X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "A0003 OK FETCH"
            ])
            rawTransport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0004 OK SEARCH"])
            rawTransport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0005 OK SEARCH"])
            rawTransport.addRoute(matching: "category:social", response: ["* SEARCH", "A0006 OK SEARCH"])
            rawTransport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0007 OK SEARCH"])
            rawTransport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0008 OK SEARCH"])

            rawTransport.addRoute(matching: "UID SEARCH ALL", response: ["* SEARCH 1", "A0010 OK SEARCH"])
            rawTransport.addRoute(matching: "UID FETCH 1", response: [
                "* 1 FETCH (UID 1 X-GM-MSGID 1001 X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "A0011 OK FETCH"
            ])
            rawTransport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0012 OK SEARCH"])
            rawTransport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0013 OK SEARCH"])
            rawTransport.addRoute(matching: "category:social", response: ["* SEARCH", "A0014 OK SEARCH"])
            rawTransport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0015 OK SEARCH"])
            rawTransport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0016 OK SEARCH"])

            let probe = ProbeIMAPTransport(underlying: rawTransport)
            let service = GmailIMAPService(transport: probe)
            try await service.authenticate(email: email, backgroundEnabled: false)

            let postAuthCount = rawTransport.commands.count
            probe.armGate()

            let fetchTask1 = Task {
                try await service.fetchInboxPage(after: nil)
            }
            let fetchTask2 = Task {
                try await service.fetchInboxPage(after: nil)
            }

            await probe.waitForStarted()

            let disconnectTask = Task {
                await service.disconnect()
            }

            probe.releaseGate()

            let res1 = try await fetchTask1.value
            let res2 = try await fetchTask2.value
            await disconnectTask.value

            #expect(res1.messages.count == 1)
            #expect(res2.messages.count == 1)

            let postAuthCommands = Array(rawTransport.commands[postAuthCount...])
            let selectIndices = postAuthCommands.enumerated().compactMap { $0.element == "SELECT INBOX" ? $0.offset : nil }
            let forumsIndices = postAuthCommands.enumerated().compactMap { $0.element.contains("category:forums") ? $0.offset : nil }
            let closeIndex = postAuthCommands.lastIndex(of: "CLOSE")

            #expect(selectIndices.count == 2)
            #expect(forumsIndices.count == 2)
            #expect(closeIndex == postAuthCommands.count - 1)

            if selectIndices.count == 2 && forumsIndices.count == 2, let closeIndex {
                #expect(selectIndices[0] < forumsIndices[0])
                #expect(forumsIndices[0] < selectIndices[1])
                #expect(selectIndices[1] < forumsIndices[1])
                #expect(forumsIndices[1] < closeIndex)
            }
        }
    }

    @Test("all executed IMAP commands strictly exclude mutating keywords")
    func readOnlyWireAssertions() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            try setupCredentials()
            defer { cleanupCredentials() }

            let transport = ScriptedIMAPTransport()
            setupAuth(transport: transport)
            transport.addRoute(matching: "UID SEARCH ALL", response: ["* SEARCH 1", "A0002 OK SEARCH"])
            transport.addRoute(matching: "UID FETCH 1", response: [
                "* 1 FETCH (UID 1 X-GM-MSGID 1001 X-GM-THRID 2000 BODY[HEADER.FIELDS] {76}Subject: Test\r\nFrom: sender@example.com\r\nDate: Tue, 1 Jul 2025 10:00:00 +0000\r\n\r\n)",
                "A0003 OK FETCH"
            ])
            transport.addRoute(matching: "category:primary", response: ["* SEARCH", "A0004 OK SEARCH"])
            transport.addRoute(matching: "category:promotions", response: ["* SEARCH", "A0005 OK SEARCH"])
            transport.addRoute(matching: "category:social", response: ["* SEARCH", "A0006 OK SEARCH"])
            transport.addRoute(matching: "category:updates", response: ["* SEARCH", "A0007 OK SEARCH"])
            transport.addRoute(matching: "category:forums", response: ["* SEARCH", "A0008 OK SEARCH"])

            let service = GmailIMAPService(transport: transport)
            try await service.authenticate(email: email, backgroundEnabled: false)
            _ = try await service.fetchInboxPage(after: nil)

            for command in transport.commands {
                let upper = command.uppercased()
                #expect(!upper.contains("STORE"))
                #expect(!upper.contains("EXPUNGE"))
                #expect(!upper.contains("DELETE"))
            }
        }
    }
}

private final class ProbeIMAPTransport: IMAPCommandTransport, @unchecked Sendable {
    private let underlying: ScriptedIMAPTransport
    private let lock = NSLock()
    private var isArmed = false
    private var hasStarted = false
    private var isReleased = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(underlying: ScriptedIMAPTransport) {
        self.underlying = underlying
    }

    func armGate() {
        lock.withLock {
            isArmed = true
            hasStarted = false
            isReleased = false
        }
    }

    func waitForStarted() async {
        await withCheckedContinuation { continuation in
            let shouldResumeImmediately = lock.withLock {
                if hasStarted {
                    return true
                } else {
                    startedContinuation = continuation
                    return false
                }
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }

    func releaseGate() {
        let continuationToResume = lock.withLock {
            isReleased = true
            let cont = releaseContinuation
            releaseContinuation = nil
            return cont
        }
        continuationToResume?.resume()
    }

    func connect(username: String, password: String) async throws {
        try await underlying.connect(username: username, password: password)
    }

    func execute(_ command: String) async throws -> [String] {
        let shouldGate = lock.withLock {
            guard isArmed else { return false }
            isArmed = false
            hasStarted = true
            return true
        }

        if shouldGate {
            await withCheckedContinuation { continuation in
                var shouldResumeGate = false
                let startedToResume = lock.withLock {
                    let started = startedContinuation
                    startedContinuation = nil
                    if isReleased {
                        shouldResumeGate = true
                    } else {
                        releaseContinuation = continuation
                    }
                    return started
                }
                startedToResume?.resume()
                if shouldResumeGate {
                    continuation.resume()
                }
            }
        }

        return try await underlying.execute(command)
    }

    func close() async {
        await underlying.close()
    }
}
