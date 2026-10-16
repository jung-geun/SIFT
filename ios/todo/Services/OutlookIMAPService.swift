import Foundation
import Network

nonisolated enum OutlookIMAPError: LocalizedError, Equatable, Sendable {
    case missingCredential
    case invalidResponse
    case authenticationFailed
    case legacyAuthUnsupported
    case mailboxReset
    case mutationUnsupported
    case messageIdentityUnavailable
    case transport(String)

    var errorDescription: String? {
        errorDescription(language: .current)
    }

    func errorDescription(language: AppLanguage) -> String {
        switch self {
        case .missingCredential:
            return AppLanguage.localized("error.mail.outlookIMAP.missingCredential", defaultValue: "Outlook IMAP credentials are missing.", language: language)
        case .invalidResponse:
            return AppLanguage.localized("error.mail.outlookIMAP.invalidResponse", defaultValue: "Outlook IMAP returned an invalid response.", language: language)
        case .authenticationFailed:
            return AppLanguage.localized("error.mail.outlookIMAP.authenticationFailed", defaultValue: "Outlook IMAP authentication failed. Please check your email and app password.", language: language)
        case .legacyAuthUnsupported:
            return AppLanguage.localized("error.mail.outlookIMAP.legacyAuthUnsupported", defaultValue: "Basic/app-password authentication is disabled or unsupported for this Outlook account (LOGINDISABLED/OAuth required). Legacy login is best-effort only.", language: language)
        case .mailboxReset:
            return AppLanguage.localized("error.mail.outlookIMAP.mailboxReset", defaultValue: "The Outlook mailbox changed. Refresh the inbox and try again.", language: language)
        case .mutationUnsupported:
            return AppLanguage.localized("error.mail.outlookIMAP.mutationUnsupported", defaultValue: "This Outlook IMAP server does not support the requested mail action.", language: language)
        case .messageIdentityUnavailable:
            return AppLanguage.localized("error.mail.outlookIMAP.messageIdentityUnavailable", defaultValue: "This cached Outlook message needs a mailbox refresh before it can be changed.", language: language)
        case .transport(let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !detail.isEmpty else {
                return AppLanguage.localized("error.mail.outlookIMAP.transport", defaultValue: "The Outlook IMAP connection failed. Try again.", language: language)
            }
            return String(format: AppLanguage.localized("error.mail.outlookIMAP.transportDetail", defaultValue: "The Outlook IMAP connection failed. Try again. (%@)", language: language), locale: language.locale, String(detail))
        }
    }
}

nonisolated struct OutlookIMAPMessageRecord: Sendable, Equatable {
    let uid: UInt32
    let messageID: String
    let subject: String
    let from: String
    let receivedAt: Date
    let isRead: Bool
    let body: String
}

actor OutlookIMAPService: MailboxPagingProvider {
    static let shared = OutlookIMAPService()
    static let legacyAuthHelpURLString = "https://support.microsoft.com/en-us/office/pop-imap-and-smtp-settings-for-outlook-com-d088b986-211d-4baa-8c84-13d30b8108fb"

    let provider: MailProvider = .outlook

    private let transport: IMAPCommandTransport
    private static let metadataFetchAttributes = "(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (SUBJECT FROM MESSAGE-ID DATE)])"
    private var account: String?
    private var uidValidity: String?
    private var uidIndex: [UInt32] = []
    private var indexValidity: String?
    private var imapCapabilities = Set<String>()
    private var trashMailbox: String?
    private var generationToken = 0

    private var isCommandBusy = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []

    init(transport: IMAPCommandTransport = NetworkIMAPCommandTransport(host: "outlook.office365.com", port: 993)) {
        self.transport = transport
    }

    var authenticatedAccount: String? { account }
    var sessionGeneration: Int { generationToken }
    var isAuthenticated: Bool { account != nil }

    // MARK: - Command serialization

    private func acquireCommandTurn() async {
        guard isCommandBusy else {
            isCommandBusy = true
            return
        }
        await withCheckedContinuation { commandWaiters.append($0) }
    }

    private func releaseCommandTurn() {
        if commandWaiters.isEmpty {
            isCommandBusy = false
        } else {
            commandWaiters.removeFirst().resume()
        }
    }

    // MARK: - Public gated entry points

    func authenticate(email: String, backgroundEnabled: Bool) async throws {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        try Task.checkCancellation()
        try await performAuthenticate(email: email, backgroundEnabled: backgroundEnabled)
    }

    /// Validate message access before settings report this account as connected.
    func validateConnection(email: String, backgroundEnabled: Bool) async throws {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        try Task.checkCancellation()
        do {
            try await performAuthenticate(
                email: email,
                backgroundEnabled: backgroundEnabled,
                verifyingMessageRetrieval: true
            )
        } catch {
            await performDisconnect()
            if error is GmailIMAPError { throw mapTransportError(error) }
            throw error
        }
    }

    func authenticateAndSave(email: String, appPassword: String, backgroundEnabled: Bool) async throws {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        try Task.checkCancellation()
        do {
            try await performAuthenticateAndSave(email: email, appPassword: appPassword, backgroundEnabled: backgroundEnabled)
        } catch {
            await performDisconnect()
            if error is GmailIMAPError { throw mapTransportError(error) }
            throw error
        }
    }

    func disconnect() async {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        await performDisconnect()
    }

    func fetchInboxPage(after cursor: String?) async throws -> MailboxPage {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        try Task.checkCancellation()
        return try await performFetchInboxPage(after: cursor)
    }

    func fetchInboxUpdates(newerThan cursor: String) async throws -> MailboxPage {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        try Task.checkCancellation()
        return try await performFetchInboxUpdates(newerThan: cursor)
    }

    func fetchInboxMessageIDs() async throws -> Set<String> {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        try Task.checkCancellation()
        return try await performFetchInboxMessageIDs()
    }

    func fetchMessageContent(messageID: String) async throws -> MailboxMessageContent {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        try Task.checkCancellation()
        return try await performFetchMessageContent(messageID: messageID)
    }

    func markAsRead(
        messageID: String,
        expectedGlobalMessageID: String?
    ) async throws {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        try Task.checkCancellation()
        try await performMarkAsRead(
            messageID: messageID,
            expectedGlobalMessageID: expectedGlobalMessageID
        )
    }

    func trashMessage(
        messageID: String,
        expectedGlobalMessageID: String?
    ) async throws {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        try Task.checkCancellation()
        try await performTrashMessage(
            messageID: messageID,
            expectedGlobalMessageID: expectedGlobalMessageID
        )
    }

    // MARK: - Authentication

    private func performAuthenticate(
        email: String,
        backgroundEnabled _: Bool,
        verifyingMessageRetrieval: Bool = false
    ) async throws {
        generationToken += 1
        await transport.close()
        resetState()

        guard let password = try OutlookIMAPCredentialStore.credential(for: email) else {
            throw OutlookIMAPError.missingCredential
        }
        try await connectAndVerifyLegacyAuth(email: email, password: password)
        _ = try await selectInbox(verifyingMessageRetrieval: verifyingMessageRetrieval)
        account = OutlookIMAPCredentialStore.canonicalAccount(email)
    }

    private func performAuthenticateAndSave(email: String, appPassword: String, backgroundEnabled: Bool) async throws {
        generationToken += 1
        await transport.close()
        resetState()

        let normalizedPassword = appPassword.replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPassword.isEmpty else { throw IMAPCredentialError.emptyPassword }

        try await connectAndVerifyLegacyAuth(email: email, password: normalizedPassword)
        _ = try await selectInbox(verifyingMessageRetrieval: true)

        try OutlookIMAPCredentialStore.save(
            appPassword: normalizedPassword,
            for: email,
            backgroundEnabled: backgroundEnabled
        )
        account = OutlookIMAPCredentialStore.canonicalAccount(email)
    }

    private func performDisconnect() async {
        generationToken += 1
        await transport.close()
        resetState()
    }

    private func resetState() {
        account = nil
        uidValidity = nil
        uidIndex = []
        indexValidity = nil
        imapCapabilities = []
        trashMailbox = nil
    }

    private func connectAndVerifyLegacyAuth(email: String, password: String) async throws {
        var preAuthCapabilities: [String] = []

        if let probing = transport as? IMAPPreAuthCapabilityProbing {
            do {
                let greeting = try await probing.connectPreAuth()
                preAuthCapabilities.append(contentsOf: greeting)
            } catch {
                let mappedError = mapTransportError(error)
                DiagnosticRecorder.shared.record(
                    error: mappedError,
                    component: "mail.outlook",
                    operation: "connect"
                )
                throw mappedError
            }
        } else {
            do {
                try await transport.connect(username: email, password: password)
            } catch {
                let mappedError = mapAuthOrTransportError(error)
                DiagnosticRecorder.shared.record(
                    error: mappedError,
                    component: "mail.outlook",
                    operation: "connect"
                )
                throw mappedError
            }
        }

        // Issue CAPABILITY command to gather complete capability tokens
        do {
            let capLines = try await transport.execute("CAPABILITY")
            preAuthCapabilities.append(contentsOf: capLines)
        } catch {
            // Ignore capability command failure if connection is still intact
        }

        let parsedCaps = Self.parseCapabilities(preAuthCapabilities)
        imapCapabilities = parsedCaps

        // Capability check: reject if LOGINDISABLED or if AUTH mechs exist but none are PLAIN/LOGIN
        if parsedCaps.contains("LOGINDISABLED") {
            await transport.close()
            throw OutlookIMAPError.legacyAuthUnsupported
        }

        let authMechs = parsedCaps.filter { $0.hasPrefix("AUTH=") }
        if !authMechs.isEmpty {
            let supportsLegacy = authMechs.contains("AUTH=PLAIN") || authMechs.contains("AUTH=LOGIN")
            if !supportsLegacy {
                await transport.close()
                throw OutlookIMAPError.legacyAuthUnsupported
            }
        }

        // Perform actual login if using pre-auth probing transport
        if let probing = transport as? IMAPPreAuthCapabilityProbing {
            do {
                try await probing.login(username: email, password: password)
            } catch {
                await transport.close()
                let mappedError = mapAuthOrTransportError(error)
                DiagnosticRecorder.shared.record(
                    error: mappedError,
                    component: "mail.outlook",
                    operation: "login"
                )
                throw mappedError
            }
        }

        // Post-login capability refresh to discover post-auth mechs (e.g. MOVE)
        do {
            let postCapLines = try await transport.execute("CAPABILITY")
            imapCapabilities.formUnion(Self.parseCapabilities(postCapLines))
        } catch {
            // Non-fatal if post-login capability fails
        }
    }

    private func mapAuthOrTransportError(_ error: Error) -> OutlookIMAPError {
        if let gmailErr = error as? GmailIMAPError {
            switch gmailErr {
            case .authenticationFailed, .credentialRejected:
                return .authenticationFailed
            case .transport(let msg):
                return .transport(msg)
            default:
                return .authenticationFailed
            }
        }
        if let outlookErr = error as? OutlookIMAPError {
            return outlookErr
        }
        return .transport(error.localizedDescription)
    }

    private func mapTransportError(_ error: Error) -> OutlookIMAPError {
        if let gmailErr = error as? GmailIMAPError {
            switch gmailErr {
            case .transport(let msg):
                return .transport(msg)
            case .invalidResponse:
                return .invalidResponse
            default:
                return .transport(gmailErr.localizedDescription)
            }
        }
        if let outlookErr = error as? OutlookIMAPError {
            return outlookErr
        }
        return .transport(error.localizedDescription)
    }

    // MARK: - UID index + cursor helpers

    private func refreshUIDIndex() async throws -> String {
        let validity = try await selectInbox()
        let search = try await transport.execute("UID SEARCH ALL")
        uidIndex = Self.parseUIDs(search).sorted()
        indexValidity = validity
        return validity
    }

    private func selectInbox(verifyingMessageRetrieval: Bool = false) async throws -> String {
        let selected = try await transport.execute("SELECT INBOX")
        guard let validity = IMAPWireSyntax.uidValidity(selected) else {
            throw OutlookIMAPError.invalidResponse
        }
        if verifyingMessageRetrieval {
            guard let count = IMAPWireSyntax.messageCount(selected) else {
                throw OutlookIMAPError.invalidResponse
            }
            if count > 0 {
                let lines = try await transport.execute("FETCH * \(Self.metadataFetchAttributes)")
                guard let header = lines.first(where: {
                    IMAPWireSyntax.isFetch(IMAPWireSyntax.protocolText($0))
                        && IMAPWireSyntax.literal($0) != nil
                }), Self.parseRecord([header]) != nil else {
                    throw OutlookIMAPError.invalidResponse
                }
            }
            try Task.checkCancellation()
        }
        uidValidity = validity
        return validity
    }

    // MARK: - Outlook mailbox mutations

    private func performMarkAsRead(
        messageID: String,
        expectedGlobalMessageID: String?
    ) async throws {
        let uid = try Self.uid(from: messageID)
        try await verifyMessageForMutation(uid: uid, expectedGlobalMessageID: expectedGlobalMessageID)
        _ = try await transport.execute("UID STORE \(uid) +FLAGS.SILENT (\\Seen)")
    }

    private func performTrashMessage(
        messageID: String,
        expectedGlobalMessageID: String?
    ) async throws {
        let uid = try Self.uid(from: messageID)
        try await verifyMessageForMutation(uid: uid, expectedGlobalMessageID: expectedGlobalMessageID)
        guard imapCapabilities.contains("MOVE") || imapCapabilities.contains("UIDPLUS") else {
            throw OutlookIMAPError.mutationUnsupported
        }
        let mailbox = try await resolvedTrashMailbox()

        if imapCapabilities.contains("MOVE") {
            _ = try await transport.execute("UID MOVE \(uid) \(Self.quoteMailbox(mailbox))")
        } else {
            _ = try await transport.execute("UID COPY \(uid) \(Self.quoteMailbox(mailbox))")
            _ = try await transport.execute("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
            _ = try await transport.execute("UID EXPUNGE \(uid)")
        }

        uidIndex.removeAll { $0 == uid }
    }

    private func verifyMessageForMutation(
        uid: UInt32,
        expectedGlobalMessageID: String?
    ) async throws {
        guard let expectedValidity = uidValidity else {
            throw OutlookIMAPError.invalidResponse
        }
        guard let expectedGlobalMessageID, !Self.sanitizeMessageID(expectedGlobalMessageID).isEmpty else {
            throw OutlookIMAPError.messageIdentityUnavailable
        }
        let actualValidity = try await selectInbox()
        guard expectedValidity == actualValidity else {
            uidIndex = []
            indexValidity = nil
            throw OutlookIMAPError.mailboxReset
        }

        let lines = try await transport.execute("UID FETCH \(uid) (UID BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
        guard let record = Self.parseRecord(lines),
              record.uid == uid,
              !record.messageID.isEmpty,
              Self.sanitizeMessageID(record.messageID) == Self.sanitizeMessageID(expectedGlobalMessageID)
        else {
            throw OutlookIMAPError.mailboxReset
        }
    }

    private func resolvedTrashMailbox() async throws -> String {
        if let trashMailbox {
            return trashMailbox
        }

        let lines = try await transport.execute("LIST \"\" \"*\"")

        // First look for standard \Trash attribute
        if let mailbox = lines
            .first(where: { $0.hasPrefix("* LIST") && $0.uppercased().contains("\\TRASH") })
            .flatMap(Self.lastQuotedString) {
            trashMailbox = mailbox
            return mailbox
        }

        // Fallback for Outlook standard folder names
        let listMailboxNames = lines
            .filter { $0.hasPrefix("* LIST") }
            .compactMap(Self.lastQuotedString)

        if let deletedItems = listMailboxNames.first(where: { $0.caseInsensitiveCompare("Deleted Items") == .orderedSame || $0.caseInsensitiveCompare("Deleted Messages") == .orderedSame }) {
            trashMailbox = deletedItems
            return deletedItems
        }

        if let defaultFallback = listMailboxNames.first(where: { $0.lowercased().contains("deleted") || $0.lowercased().contains("trash") }) {
            trashMailbox = defaultFallback
            return defaultFallback
        }

        throw OutlookIMAPError.mutationUnsupported
    }

    private nonisolated static func uid(from messageID: String) throws -> UInt32 {
        guard let uid = IMAPWireSyntax.positiveDecimal(messageID, as: UInt32.self) else {
            throw OutlookIMAPError.invalidResponse
        }
        return uid
    }

    private nonisolated static func cursorUID(_ cursor: String, validity: String) -> UInt32? {
        let parts = cursor.split(separator: ":")
        guard parts.count == 2, String(parts[0]) == validity else { return nil }
        return UInt32(parts[1])
    }

    // MARK: - Paging

    private func performFetchInboxPage(after cursor: String?) async throws -> MailboxPage {
        guard account != nil else { throw OutlookIMAPError.missingCredential }
        let validity = try await refreshUIDIndex()
        let boundary = cursor.flatMap { Self.cursorUID($0, validity: validity) }
        let isHeadLoad = boundary == nil
        let window = boundary
            .map { limit in Array(uidIndex.filter { $0 < limit }.suffix(MailboxPagingPolicy.pageSize)) }
            ?? Array(uidIndex.suffix(MailboxPagingPolicy.pageSize))

        guard let lowest = window.first, let highest = window.last else {
            return MailboxPage(
                messages: [],
                nextCursor: nil,
                newestCursor: isHeadLoad ? "\(validity):\(uidIndex.last ?? 0)" : nil
            )
        }
        let messages = try await fetchMetadata(for: window)
        let hasOlder = (uidIndex.first ?? lowest) < lowest
        return MailboxPage(
            messages: messages,
            nextCursor: hasOlder ? "\(validity):\(lowest)" : nil,
            newestCursor: isHeadLoad ? "\(validity):\(highest)" : nil
        )
    }

    private func performFetchInboxUpdates(newerThan cursor: String) async throws -> MailboxPage {
        guard account != nil else { throw OutlookIMAPError.missingCredential }
        let validity = try await selectInbox()
        guard let boundary = Self.cursorUID(cursor, validity: validity) else {
            let head = try await performFetchInboxPage(after: nil)
            return MailboxPage(
                messages: head.messages,
                nextCursor: head.nextCursor,
                newestCursor: head.newestCursor,
                hasMoreUpdates: head.hasMoreUpdates,
                removedMessageKeys: head.removedMessageKeys,
                requiresInboxReconcile: true
            )
        }
        guard boundary < UInt32.max else {
            return MailboxPage(messages: [], nextCursor: nil, newestCursor: nil)
        }
        let search = try await transport.execute("UID SEARCH UID \(boundary + 1):*")
        let fresh = Self.parseUIDs(search).sorted().filter { $0 > boundary }
        let window = Array(fresh.prefix(MailboxPagingPolicy.pageSize))
        guard let newest = window.last else {
            return MailboxPage(messages: [], nextCursor: nil, newestCursor: nil)
        }
        if indexValidity == validity {
            uidIndex = Array(Set(uidIndex).union(window)).sorted()
        }
        let messages = try await fetchMetadata(for: window)
        return MailboxPage(
            messages: messages,
            nextCursor: nil,
            newestCursor: "\(validity):\(newest)",
            hasMoreUpdates: fresh.count > window.count
        )
    }

    private func performFetchInboxMessageIDs() async throws -> Set<String> {
        guard account != nil else { throw OutlookIMAPError.missingCredential }
        _ = try await refreshUIDIndex()
        return Set(uidIndex.map(String.init))
    }

    private func performFetchMessageContent(messageID: String) async throws -> MailboxMessageContent {
        guard account != nil else { throw OutlookIMAPError.missingCredential }
        let uid = try Self.uid(from: messageID)
        let structure = try await transport.execute("UID FETCH \(uid) (BODYSTRUCTURE)")
        guard Self.supportsTextBody(structure) else { throw OutlookIMAPError.invalidResponse }

        let lines = try await transport.execute(
            "UID FETCH \(uid) (UID FLAGS INTERNALDATE BODY.PEEK[HEADER] BODY.PEEK[TEXT]<0.500000>)"
        )
        let bodyLine = lines.first(where: { $0.uppercased().contains("BODY[TEXT") })
        guard let body = bodyLine.flatMap({ Self.captureLiteral(in: $0) }) else {
            throw OutlookIMAPError.invalidResponse
        }
        let header = lines
            .first(where: { $0.uppercased().contains("BODY[HEADER]") })
            .flatMap { Self.captureLiteral(in: $0) }
        let rawMessage: String
        if let header {
            let separator = header.hasSuffix("\r\n\r\n") || header.hasSuffix("\n\n") ? "" : "\r\n\r\n"
            rawMessage = header + separator + body
        } else {
            rawMessage = body
        }

        let records = Self.parseRecords(lines)
        guard let fallbackRecord = records.first(where: { $0.uid == uid }) else {
            throw OutlookIMAPError.invalidResponse
        }
        let headerFields = header.map { Self.parseHeadersAndBody($0).headers } ?? [:]
        let record = OutlookIMAPMessageRecord(
            uid: fallbackRecord.uid,
            messageID: Self.sanitizeMessageID(headerFields["message-id"] ?? fallbackRecord.messageID),
            subject: MIMETextDecoder.decodeRFC2047(
                headerFields["subject"] ?? fallbackRecord.subject
            ),
            from: MIMETextDecoder.decodeRFC2047(
                headerFields["from"] ?? fallbackRecord.from
            ),
            receivedAt: headerFields["date"].flatMap(Self.parseDate)
                ?? fallbackRecord.receivedAt,
            isRead: fallbackRecord.isRead,
            body: rawMessage
        )
        let decoded = MIMETextDecoder.decode(rawMessage)
        let metadata = metadata(record, snippet: String(decoded.text.prefix(200)))
        return MailboxMessageContent(metadata: metadata, body: decoded.text, htmlBody: decoded.html)
    }

    // MARK: - Metadata construction

    private func fetchMetadata(for uids: [UInt32]) async throws -> [MailboxMessageMetadata] {
        guard !uids.isEmpty else { return [] }
        let range = uids.map(String.init).joined(separator: ",")
        let lines = try await transport.execute(
            "UID FETCH \(range) \(Self.metadataFetchAttributes)"
        )
        return Self.parseRecords(lines).map { metadata($0) }
    }

    private func metadata(
        _ record: OutlookIMAPMessageRecord,
        snippet: String? = nil
    ) -> MailboxMessageMetadata {
        MailboxMessageMetadata(
            provider: .outlook,
            providerMessageID: String(record.uid),
            providerGlobalMessageID: record.messageID,
            sourceAccountNamespace: account ?? "",
            threadID: "",
            subject: record.subject,
            from: record.from,
            snippet: snippet ?? String(record.body.prefix(200)),
            receivedAt: record.receivedAt,
            isRead: record.isRead,
            isInInbox: true,
            gmailLabelIDs: [],
            outlookInferenceClassificationRawValue: "",
            providerCategoryNames: [],
            providerFolderID: "INBOX"
        )
    }

    // MARK: - Wire parsing

    private nonisolated static func parseCapabilities(_ lines: [String]) -> Set<String> {
        Set(
            lines.flatMap { line -> [String] in
                let upper = line.uppercased()
                if upper.contains("CAPABILITY") {
                    return upper.split(whereSeparator: \.isWhitespace).map(String.init)
                }
                return []
            }
        )
    }

    private nonisolated static func supportsTextBody(_ lines: [String]) -> Bool {
        lines.contains { line in
            let upper = line.uppercased()
            return upper.contains("TEXT") && (upper.contains("PLAIN") || upper.contains("HTML"))
        }
    }

    private nonisolated static func parseUIDs(_ lines: [String]) -> [UInt32] {
        IMAPWireSyntax.searchUIDs(lines)
    }

    private nonisolated static func parseRecords(_ lines: [String]) -> [OutlookIMAPMessageRecord] {
        lines.compactMap { line -> OutlookIMAPMessageRecord? in
            let syntax = IMAPWireSyntax.protocolText(line)
            guard IMAPWireSyntax.isFetch(syntax),
                  let uid = captureToken("UID", in: syntax).flatMap({ IMAPWireSyntax.positiveDecimal($0, as: UInt32.self) }) else { return nil }
            let literal = captureLiteral(in: line) ?? ""
            let parsed = parseHeadersAndBody(literal)
            let body = line.uppercased().contains("BODY[TEXT") ? literal : parsed.body
            let isRead = IMAPWireSyntax.hasSeenFlag(syntax)
            let rawMsgID = parsed.headers["message-id"] ?? ""
            return OutlookIMAPMessageRecord(
                uid: uid,
                messageID: sanitizeMessageID(rawMsgID),
                subject: MIMETextDecoder.decodeRFC2047(parsed.headers["subject"] ?? ""),
                from: MIMETextDecoder.decodeRFC2047(parsed.headers["from"] ?? ""),
                receivedAt: parsed.headers["date"].flatMap { Self.parseDate($0) }
                    ?? Self.parseIMAPInternalDate(in: line)
                    ?? Date(),
                isRead: isRead,
                body: body
            )
        }
    }

    private nonisolated static func parseHeadersAndBody(_ literal: String) -> (headers: [String: String], body: String) {
        let normalized = literal.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.split(separator: "\n\n", maxSplits: 1, omittingEmptySubsequences: false)
        let headerBlock = String(parts.first ?? "")
        let body = parts.count == 2 ? String(parts[1]) : ""
        var headers: [String: String] = [:]
        var current: String?
        for rawLine in headerBlock.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.first == " " || rawLine.first == "\t", let current {
                headers[current, default: ""] += " " + rawLine.trimmingCharacters(in: .whitespaces)
            } else if let separator = rawLine.firstIndex(of: ":"), MIMETextDecoder.isFieldName(rawLine[..<separator]) {
                let key = rawLine[..<separator].lowercased()
                headers[key] = rawLine[rawLine.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                current = key
            }
        }
        return (headers, body)
    }

    private nonisolated static func parseDate(_ value: String) -> Date? {
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "d-MMM-yyyy HH:mm:ss Z",
            "dd-MMM-yyyy HH:mm:ss Z"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return date
            }
        }
        return nil
    }

    private nonisolated static func parseIMAPInternalDate(in line: String) -> Date? {
        guard let marker = line.range(of: #"INTERNALDATE\s+""#, options: .regularExpression),
              let end = line[marker.upperBound...].firstIndex(of: "\"")
        else {
            return nil
        }
        return parseDate(String(line[marker.upperBound..<end]))
    }

    private nonisolated static func captureLiteral(in line: String) -> String? {
        guard let marker = line.range(of: #"\{\d+\}"#, options: .regularExpression) else { return nil }
        let lengthText = line[line.index(after: marker.lowerBound)..<line.index(before: marker.upperBound)]
        guard let length = Int(lengthText) else { return nil }
        var literal = String(line[marker.upperBound...])
        if literal.hasPrefix("\r\n") {
            // Swift treats CRLF as one extended grapheme cluster.
            literal.removeFirst()
        } else if literal.hasPrefix("\n") {
            literal.removeFirst()
        }
        return String(decoding: literal.utf8.prefix(length), as: UTF8.self)
    }

    private nonisolated static func parseRecord(_ lines: [String]) -> OutlookIMAPMessageRecord? {
        parseRecords(lines).first
    }

    private nonisolated static func captureToken(_ token: String, in line: String) -> String? {
        IMAPWireSyntax.token(token, in: line)
    }

    private nonisolated static func quoteMailbox(_ mailbox: String) -> String {
        let sanitized = mailbox
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(sanitized)\""
    }

    private nonisolated static func lastQuotedString(in line: String) -> String? {
        var values: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false

        for character in line {
            if isEscaped {
                current.append(character)
                isEscaped = false
            } else if character == "\\" && isQuoted {
                isEscaped = true
            } else if character == "\"" {
                if isQuoted {
                    values.append(current)
                    current = ""
                }
                isQuoted.toggle()
            } else if isQuoted {
                current.append(character)
            }
        }
        return values.last
    }

    private nonisolated static func sanitizeMessageID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") {
            return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}
