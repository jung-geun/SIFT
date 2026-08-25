import Foundation
import Network

protocol IMAPCommandTransport: Sendable {
    func connect(username: String, password: String) async throws
    func execute(_ command: String) async throws -> [String]
    func close() async
}

nonisolated enum GmailIMAPError: LocalizedError, Equatable, Sendable {
    case missingCredential
    case invalidResponse
    case authenticationFailed
    /// The IMAP LOGIN command rejected the saved App Password.
    case credentialRejected
    case mailboxReset
    case mutationUnsupported
    case messageIdentityUnavailable
    case unsupportedExtension
    case analysisFailed
    case analysisLeased
    case noSelectableTextPart
    case transport(String)
    var errorDescription: String? {
        errorDescription(language: .current)
    }

    func errorDescription(language: AppLanguage) -> String {
        switch self {
        case .missingCredential:
            return language == .english
                ? "Gmail IMAP credentials are missing."
                : "Gmail IMAP 인증 정보가 없습니다."
        case .invalidResponse:
            return language == .english
                ? "Gmail IMAP returned an invalid response."
                : "Gmail IMAP에서 올바르지 않은 응답을 받았습니다."
        case .authenticationFailed:
            return language == .english
                ? "Gmail IMAP authentication failed."
                : "Gmail IMAP 인증에 실패했습니다."
        case .credentialRejected:
            return language == .english
                ? "Gmail rejected the saved App Password. Replace it in Email Settings."
                : "Gmail이 저장된 App Password를 거부했습니다. 이메일 설정에서 교체해주세요."
        case .mailboxReset:
            return language == .english
                ? "The Gmail mailbox changed. Refresh the inbox and try again."
                : "Gmail 메일함이 변경되었습니다. 받은편지함을 새로고침한 뒤 다시 시도해주세요."
        case .mutationUnsupported:
            return language == .english
                ? "This Gmail IMAP server does not support the requested mail action."
                : "이 Gmail IMAP 서버는 요청한 메일 작업을 지원하지 않습니다."
        case .messageIdentityUnavailable:
            return language == .english
                ? "This cached Gmail message needs a mailbox refresh before it can be changed."
                : "이 Gmail 메일은 변경하기 전에 받은편지함을 새로고침해야 합니다."
        case .unsupportedExtension:
            return language == .english
                ? "Gmail IMAP does not advertise X-GM-EXT-1."
                : "Gmail IMAP에서 필요한 Gmail 확장을 지원하지 않습니다."
        case .analysisFailed:
            return language == .english
                ? "Gmail message analysis did not complete."
                : "Gmail 메일 분석을 완료하지 못했습니다."
        case .analysisLeased:
            return language == .english
                ? "Gmail message analysis is already in progress."
                : "Gmail 메일 분석이 이미 진행 중입니다."
        case .noSelectableTextPart:
            return language == .english
                ? "No readable text content found in this message."
                : "이 메일에서 읽을 수 있는 텍스트 본문을 찾을 수 없습니다."
        case .transport(let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !detail.isEmpty else {
                return language == .english
                    ? "The Gmail IMAP connection failed. Try again."
                    : "Gmail IMAP 연결에 실패했습니다. 다시 시도해주세요."
            }
            return language == .english
                ? "The Gmail IMAP connection failed. Try again. (\(detail))"
                : "Gmail IMAP 연결에 실패했습니다. 다시 시도해주세요. (\(detail))"
        }
    }

    /// Only permanent SASL/IMAP credential failures pause automatic retries.
    /// Generic `NO` responses can be transient server limits or maintenance.
    static func isPermanentCredentialRejection(in responseLines: [String]) -> Bool {
        responseLines.contains { line in
            let upper = line.uppercased()
            guard upper.contains(" NO ") || upper.contains(" BAD ") else { return false }
            return upper.contains("[AUTHENTICATIONFAILED]")
                || upper.contains("[AUTHORIZATIONFAILED]")
                || upper.contains("[EXPIRED]")
        }
    }
}

nonisolated struct IMAPMessageRecord: Sendable, Equatable {
    let uid: UInt32
    let gmailMessageID: String
    let threadID: String
    let subject: String
    let from: String
    let messageID: String
    let receivedAt: Date
    let isRead: Bool
    let body: String
}

private final class IMAPConnectionCompletion: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var completed = false

    nonisolated func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

/// Refines `IMAPCommandTransport` to expose a pre-authentication greeting probe.
/// Callers that must inspect legacy-auth support (e.g. `LOGINDISABLED`) before
/// sending credentials use `connectPreAuth()` + `login(username:password:)`
/// instead of the combined `connect(username:password:)`.
protocol IMAPPreAuthCapabilityProbing: IMAPCommandTransport {
    /// Opens the TLS connection and returns the greeting lines, without sending `LOGIN`.
    func connectPreAuth() async throws -> [String]
    /// Sends `LOGIN` on a connection already opened by `connect`/`connectPreAuth`.
    func login(username: String, password: String) async throws
}

/// Minimal TLS IMAP transport. It exposes tagged command execution for the
/// selected mailbox; the service owns safe UID-based mutations.
nonisolated final class NetworkIMAPCommandTransport: IMAPPreAuthCapabilityProbing, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private var tag = 0

    init(host: String = "imap.gmail.com", port: UInt16 = 993) {
        self.host = host
        self.port = port
    }

    func connect(username: String, password: String) async throws {
        _ = try await connectPreAuth()
        try await login(username: username, password: password)
    }

    func connectPreAuth() async throws -> [String] {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: NWProtocolTLS.Options())
        )
        self.connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = IMAPConnectionCompletion()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard completion.claim() else { return }
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    guard completion.claim() else { return }
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: GmailIMAPError.transport(error.localizedDescription))
                case .cancelled:
                    guard completion.claim() else { return }
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: GmailIMAPError.transport("IMAP connection cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
        return try await readResponse(until: nil)
    }

    func login(username: String, password: String) async throws {
        let user = Self.quote(username)
        let secret = Self.quote(password)
        let response = try await send("LOGIN \(user) \(secret)", allowingTaggedFailure: true)
        if GmailIMAPError.isPermanentCredentialRejection(in: response) {
            throw GmailIMAPError.credentialRejected
        }
        guard response.contains(where: { $0.contains(" OK") }) else {
            throw GmailIMAPError.invalidResponse
        }
    }

    func execute(_ command: String) async throws -> [String] {
        try await send(command)
    }

    func close() async {
        connection?.cancel()
        connection = nil
    }

    private func send(_ command: String, allowingTaggedFailure: Bool = false) async throws -> [String] {
        guard let connection else { throw GmailIMAPError.transport("IMAP is not connected") }
        tag += 1
        let commandTag = String(format: "A%04d", tag)
        let payload = Data("\(commandTag) \(command)\r\n".utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: GmailIMAPError.transport(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
        let lines = try await readResponse(until: commandTag)
        guard lines.contains(where: { $0.hasPrefix("\(commandTag) OK") }) else {
            if allowingTaggedFailure,
               lines.contains(where: { $0.hasPrefix("\(commandTag) NO") || $0.hasPrefix("\(commandTag) BAD") }) {
                return lines
            }
            throw GmailIMAPError.invalidResponse
        }
        return lines
    }

    private func readResponse(until commandTag: String?) async throws -> [String] {
        guard let connection else { throw GmailIMAPError.transport("IMAP is not connected") }
        var decoder = IMAPResponseDecoder()
        var lines: [String] = []
        while true {
            let chunk = try await receive(from: connection)
            for line in try decoder.append(chunk) {
                lines.append(line)
                if let commandTag {
                    if line.hasPrefix(commandTag + " ") { return lines }
                } else if line.hasPrefix("* OK") || line.hasPrefix("* PREAUTH") {
                    return lines
                }
            }
        }
    }

    private func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: GmailIMAPError.transport(error.localizedDescription))
                } else if isComplete && (data == nil || data!.isEmpty) {
                    continuation.resume(throwing: GmailIMAPError.transport("IMAP connection closed"))
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private static func quote(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return "\"" + sanitized
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

actor GmailIMAPService: MailboxPagingProvider {
    static let shared = GmailIMAPService()
    let provider: MailProvider = .gmail

    private let transport: IMAPCommandTransport
    private var account: String?
    private var uidValidity: String?
    /// Ascending INBOX UIDs from the last `UID SEARCH ALL`, valid only for `indexValidity`.
    private var uidIndex: [UInt32] = []
    private var indexValidity: String?
    /// Category labels resolved per UID by the last page fetches. A missing key means
    /// "not resolved", which `metadata(_:)` reports as an empty label array.
    private var categoryLabelsByUID: [UInt32: [String]] = [:]
    private var imapCapabilities = Set<String>()
    private var trashMailbox: String?
    private var allMailMailbox: String?
    private var generationToken = 0
    /// One TCP connection cannot interleave two command sequences. Actor reentrancy at
    /// every `await transport.execute` allows exactly that, so whole sequences take turns.
    private var isCommandBusy = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []

    init(transport: IMAPCommandTransport = NetworkIMAPCommandTransport()) {
        self.transport = transport
    }
    var authenticatedAccount: String? { account }
    var sessionGeneration: Int { generationToken }

    var isAuthenticated: Bool { account != nil }

    // MARK: - Command serialization
    //
    // Ownership transfers on `resume`, so `isCommandBusy` stays true across handoffs.
    // `withCheckedContinuation` is not cancellable: a cancelled waiter still takes its
    // turn and runs its body, which is acceptable (a wasted sequence).

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
    //
    // Every method that touches `transport` is gated so a whole command sequence takes
    // its turn atomically. Internal `perform…` bodies must call other `perform…` helpers
    // directly, never these gated wrappers — a nested `acquireCommandTurn()` deadlocks.

    func authenticate(email: String, backgroundEnabled: Bool) async throws {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        try await performAuthenticate(email: email, backgroundEnabled: backgroundEnabled)
    }

    func authenticateAndSave(email: String, appPassword: String, backgroundEnabled: Bool) async throws {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        try await performAuthenticateAndSave(email: email, appPassword: appPassword, backgroundEnabled: backgroundEnabled)
    }

    func disconnect() async {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        await performDisconnect()
    }

    func fetchInboxPage(after cursor: String?) async throws -> MailboxPage {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        return try await performFetchInboxPage(after: cursor)
    }

    func fetchInboxUpdates(newerThan cursor: String) async throws -> MailboxPage {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        return try await performFetchInboxUpdates(newerThan: cursor)
    }

    func fetchInboxMessageIDs() async throws -> Set<String> {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        return try await performFetchInboxMessageIDs()
    }

    func fetchMessageContent(messageID: String) async throws -> MailboxMessageContent {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
        return try await performFetchMessageContent(messageID: messageID)
    }

    func markAsRead(
        messageID: String,
        expectedGlobalMessageID: String?
    ) async throws {
        await acquireCommandTurn()
        defer { releaseCommandTurn() }
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
        try await performTrashMessage(
            messageID: messageID,
            expectedGlobalMessageID: expectedGlobalMessageID
        )
    }

    // MARK: - Authentication

    private func performAuthenticate(email: String, backgroundEnabled _: Bool) async throws {
        generationToken += 1
        await transport.close()
        account = nil
        uidValidity = nil
        uidIndex = []
        indexValidity = nil
        categoryLabelsByUID = [:]
        imapCapabilities = []
        trashMailbox = nil
        allMailMailbox = nil
        guard let password = try IMAPCredentialStore.credential(for: email) else {
            throw GmailIMAPError.missingCredential
        }
        try await transport.connect(username: email, password: password)
        try await requireGmailExtensions()
        _ = try await selectInbox()
        account = IMAPCredentialStore.canonicalAccount(email)
    }

    private func performAuthenticateAndSave(email: String, appPassword: String, backgroundEnabled: Bool) async throws {
        generationToken += 1
        await transport.close()
        account = nil
        uidValidity = nil
        uidIndex = []
        indexValidity = nil
        categoryLabelsByUID = [:]
        imapCapabilities = []
        trashMailbox = nil
        allMailMailbox = nil
        let normalizedPassword = appPassword.replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPassword.isEmpty else { throw IMAPCredentialError.emptyPassword }
        try await transport.connect(username: email, password: normalizedPassword)
        try await requireGmailExtensions()
        _ = try await selectInbox()
        try IMAPCredentialStore.save(
            appPassword: normalizedPassword,
            for: email,
            backgroundEnabled: backgroundEnabled,
            clearsRejectionLatch: true
        )
        account = IMAPCredentialStore.canonicalAccount(email)
    }

    private func performDisconnect() async {
        generationToken += 1
        await transport.close()
        account = nil
        uidValidity = nil
        uidIndex = []
        indexValidity = nil
        categoryLabelsByUID = [:]
        imapCapabilities = []
        trashMailbox = nil
        allMailMailbox = nil
    }

    /// `X-GM-MSGID`, `X-GM-THRID`, and `X-GM-RAW` all depend on this capability. Failing
    /// the connection is safer than silently assigning Primary when provider-native
    /// classification is unavailable.
    private func requireGmailExtensions() async throws {
        let lines = try await transport.execute("CAPABILITY")
        imapCapabilities = Set(
            lines
                .flatMap { $0.uppercased().split(whereSeparator: \.isWhitespace).map(String.init) }
        )
        guard imapCapabilities.contains("X-GM-EXT-1") else {
            throw GmailIMAPError.unsupportedExtension
        }
    }

    // MARK: - UID index + cursor helpers

    /// Re-selects INBOX, re-reads UIDVALIDITY and rebuilds the ascending UID index.
    /// Returns the current UIDVALIDITY token.
    private func refreshUIDIndex() async throws -> String {
        let validity = try await selectInbox()
        let search = try await transport.execute("UID SEARCH ALL")
        uidIndex = Self.parseUIDs(search).sorted()
        indexValidity = validity
        return validity
    }

    private func selectInbox() async throws -> String {
        let selected = try await transport.execute("SELECT INBOX")
        guard let validity = selected.first(where: { $0.contains("UIDVALIDITY") })
            .flatMap({ Self.captureToken("UIDVALIDITY", in: $0) }) else {
            throw GmailIMAPError.invalidResponse
        }
        uidValidity = validity
        return validity
    }

    // MARK: - Gmail mailbox mutations

    private enum MutationUIDResolution {
        case resolved(UInt32)
        case noLongerInInbox
    }
    private enum TrashMutationResolution {
        case move(UInt32)
        case complete
    }


    private func performMarkAsRead(
        messageID: String,
        expectedGlobalMessageID: String?
    ) async throws {
        let uid = try Self.uid(from: messageID)
        let resolution = try await resolveMutationUID(
            staleUID: uid,
            expectedGlobalMessageID: expectedGlobalMessageID
        )
        guard case .resolved(let mutationUID) = resolution else {
            throw GmailIMAPError.mailboxReset
        }
        _ = try await transport.execute("UID STORE \(mutationUID) +FLAGS.SILENT (\\Seen)")
    }

    private func performTrashMessage(
        messageID: String,
        expectedGlobalMessageID: String?
    ) async throws {
        guard let expectedGlobalMessageID else {
            throw GmailIMAPError.messageIdentityUnavailable
        }
        let uid = try Self.uid(from: messageID)
        let resolution = try await resolveMutationUID(
            staleUID: uid,
            expectedGlobalMessageID: expectedGlobalMessageID
        )
        let mutationUID: UInt32
        switch resolution {
        case .resolved(let uid):
            mutationUID = uid
        case .noLongerInInbox:
            switch try await resolveTrashMutationAfterLeavingInbox(
                expectedGlobalMessageID: expectedGlobalMessageID
            ) {
            case .move(let uid):
                mutationUID = uid
            case .complete:
                return
            }
        }
        let mailbox = try await resolvedTrashMailbox()
        guard imapCapabilities.contains("MOVE") else {
            throw GmailIMAPError.mutationUnsupported
        }
        _ = try await transport.execute("UID MOVE \(mutationUID) \(Self.quoteMailbox(mailbox))")

        uidIndex.removeAll { $0 == mutationUID }
        categoryLabelsByUID.removeValue(forKey: mutationUID)
    }

    /// Resolves a cached UID against Gmail's immutable `X-GM-MSGID` immediately before
    /// a mutation. Gmail can rebuild a mailbox UID namespace while a row is awaiting
    /// its undo window; finding the immutable ID keeps that deferred action safe.
    ///
    /// An empty successful INBOX search establishes only that the message is no longer
    /// in INBOX; trash mutations must still distinguish All Mail from Trash.
    private func resolveMutationUID(
        staleUID: UInt32,
        expectedGlobalMessageID: String?
    ) async throws -> MutationUIDResolution {
        guard let expectedValidity = uidValidity else {
            throw GmailIMAPError.invalidResponse
        }
        guard let expectedGlobalMessageID,
              !expectedGlobalMessageID.isEmpty,
              UInt64(expectedGlobalMessageID) != nil
        else {
            throw GmailIMAPError.messageIdentityUnavailable
        }

        let actualValidity = try await selectInbox()
        if expectedValidity == actualValidity,
           try await matchesGlobalMessageID(
               uid: staleUID,
               expectedGlobalMessageID: expectedGlobalMessageID
           ) {
            return .resolved(staleUID)
        }

        uidIndex = []
        indexValidity = nil
        categoryLabelsByUID = [:]

        let search = try await transport.execute(
            "UID SEARCH X-GM-MSGID \(expectedGlobalMessageID)"
        )
        guard let currentUID = Self.parseUIDs(search).last else {
            return .noLongerInInbox
        }
        guard try await matchesGlobalMessageID(
            uid: currentUID,
            expectedGlobalMessageID: expectedGlobalMessageID
        ) else {
            throw GmailIMAPError.mailboxReset
        }
        return .resolved(currentUID)
    }

    private func resolveTrashMutationAfterLeavingInbox(
        expectedGlobalMessageID: String
    ) async throws -> TrashMutationResolution {
        let allMail = try await resolvedAllMailMailbox()
        _ = try await transport.execute("SELECT \(Self.quoteMailbox(allMail))")
        let allMailSearch = try await transport.execute(
            "UID SEARCH X-GM-MSGID \(expectedGlobalMessageID)"
        )
        if let allMailUID = Self.parseUIDs(allMailSearch).last {
            guard try await matchesGlobalMessageID(
                uid: allMailUID,
                expectedGlobalMessageID: expectedGlobalMessageID
            ) else {
                throw GmailIMAPError.mailboxReset
            }
            return .move(allMailUID)
        }

        let trash = try await resolvedTrashMailbox()
        _ = try await transport.execute("SELECT \(Self.quoteMailbox(trash))")
        let trashSearch = try await transport.execute(
            "UID SEARCH X-GM-MSGID \(expectedGlobalMessageID)"
        )
        guard let trashUID = Self.parseUIDs(trashSearch).last else {
            return .complete
        }
        guard try await matchesGlobalMessageID(
            uid: trashUID,
            expectedGlobalMessageID: expectedGlobalMessageID
        ) else {
            throw GmailIMAPError.mailboxReset
        }
        return .complete
    }

    private func matchesGlobalMessageID(
        uid: UInt32,
        expectedGlobalMessageID: String
    ) async throws -> Bool {
        let lines = try await transport.execute("UID FETCH \(uid) (UID X-GM-MSGID)")
        guard let record = Self.parseRecord(lines) else { return false }
        return record.uid == uid && record.gmailMessageID == expectedGlobalMessageID
    }

    private func resolvedTrashMailbox() async throws -> String {
        if let trashMailbox {
            return trashMailbox
        }

        let lines = try await transport.execute("LIST \"\" \"*\"")
        guard let mailbox = lines
            .first(where: { $0.hasPrefix("* LIST") && $0.uppercased().contains("\\TRASH") })
            .flatMap(Self.lastQuotedString)
        else {
            throw GmailIMAPError.mutationUnsupported
        }
        trashMailbox = mailbox
        return mailbox
    }

    private func resolvedAllMailMailbox() async throws -> String {
        if let allMailMailbox {
            return allMailMailbox
        }

        let lines = try await transport.execute("LIST \"\" \"*\"")
        guard let mailbox = lines
            .first(where: { $0.hasPrefix("* LIST") && $0.uppercased().contains("\\ALL") })
            .flatMap(Self.lastQuotedString)
        else {
            throw GmailIMAPError.mutationUnsupported
        }
        allMailMailbox = mailbox
        return mailbox
    }

    private nonisolated static func uid(from messageID: String) throws -> UInt32 {
        guard let uid = UInt32(messageID), uid > 0 else {
            throw GmailIMAPError.invalidResponse
        }
        return uid
    }

    nonisolated static func globalMessageID(from localID: String) -> String? {
        let prefix = "gmail-imap:"
        guard localID.hasPrefix(prefix) else { return nil }
        let globalID = String(localID.dropFirst(prefix.count))
        return globalID.isEmpty ? nil : globalID
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

    /// nil when the cursor was minted under a different UIDVALIDITY (mailbox reset).
    private nonisolated static func cursorUID(_ cursor: String, validity: String) -> UInt32? {
        let parts = cursor.split(separator: ":")
        guard parts.count == 2, String(parts[0]) == validity else { return nil }
        return UInt32(parts[1])
    }

    // MARK: - Paging

    private func performFetchInboxPage(after cursor: String?) async throws -> MailboxPage {
        guard account != nil else { throw GmailIMAPError.missingCredential }
        let validity = try await refreshUIDIndex()
        let boundary = cursor.flatMap { Self.cursorUID($0, validity: validity) }
        // A cursor from a dead UIDVALIDITY degrades to a head load, and must therefore
        // also publish a fresh newest anchor.
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
        guard account != nil else { throw GmailIMAPError.missingCredential }
        let validity = try await selectInbox()
        guard let boundary = Self.cursorUID(cursor, validity: validity) else {
            // UIDVALIDITY changed. A bounded head page is the new baseline; its
            // fresh cursor is committed after the local page upsert. The old UID
            // namespace must also be reconciled out of the local inbox cache.
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
        // RFC 3501 `m:*` still returns the last message when m exceeds the highest UID,
        // so the boundary is re-applied here.
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
        guard account != nil else { throw GmailIMAPError.missingCredential }
        _ = try await refreshUIDIndex()
        return Set(uidIndex.map(String.init))
    }

    private func performFetchMessageContent(messageID: String) async throws -> MailboxMessageContent {
        guard account != nil else { throw GmailIMAPError.missingCredential }
        let structureLines = try await transport.execute("UID FETCH \(messageID) (BODYSTRUCTURE)")

        var sectionToFetch: String?
        if let bstructString = Self.extractBodyStructureString(from: structureLines),
           let sexpr = Self.parseSExpr(bstructString) {
            var leaves: [BodyPartLeaf] = []
            Self.collectLeaves(expr: sexpr, prefix: "", into: &leaves)
            if let preferred = Self.selectPreferredTextLeaf(from: leaves) {
                sectionToFetch = preferred.sectionNumber
            }
        }

        if sectionToFetch == nil {
            if Self.isSafeSinglePartFallback(structureLines) {
                sectionToFetch = "1"
            } else {
                throw GmailIMAPError.noSelectableTextPart
            }
        }

        let section = sectionToFetch ?? "1"
        let fetchCmd = "UID FETCH \(messageID) (UID FLAGS INTERNALDATE X-GM-MSGID X-GM-THRID BODY.PEEK[HEADER] BODY.PEEK[\(section).MIME] BODY.PEEK[\(section)]<0.500000>)"
        let lines = try await transport.execute(fetchCmd)

        let preferredBodyAttribute = "BODY[\(section)]"
        let bodyAttribute: String
        let bodyLine: String
        if let preferredLine = lines.first(where: {
            $0.range(of: preferredBodyAttribute, options: .caseInsensitive) != nil
        }) {
            bodyAttribute = preferredBodyAttribute
            bodyLine = preferredLine
        } else if let textLine = lines.first(where: { $0.uppercased().contains("BODY[TEXT]") }) {
            // Some IMAP servers expose a safe single-part text section as BODY[TEXT].
            bodyAttribute = "BODY[TEXT]"
            bodyLine = textLine
        } else {
            throw GmailIMAPError.invalidResponse
        }
        guard let sectionBody = Self.captureLiteral(in: bodyLine, afterAttribute: bodyAttribute) else {
            throw GmailIMAPError.invalidResponse
        }

        let mimeAttribute = "BODY[\(section).MIME]"
        let mimeHeaderLine = lines.first(where: {
            $0.range(of: mimeAttribute, options: .caseInsensitive) != nil
        })
        let mimeHeader = mimeHeaderLine.flatMap {
            Self.captureLiteral(in: $0, afterAttribute: mimeAttribute)
        }
        if let mimeHeader {
            let lowerMime = mimeHeader.lowercased()
            if lowerMime.contains("content-disposition:") && lowerMime.contains("attachment") {
                throw GmailIMAPError.noSelectableTextPart
            }
        }
        let topHeaderLine = lines.first(where: { $0.uppercased().contains("BODY[HEADER]") })
        let topHeader = topHeaderLine.flatMap { Self.captureLiteral(in: $0) }

        let declaredLiteralLength = Self.captureLiteralLength(in: bodyLine, afterAttribute: bodyAttribute) ?? sectionBody.utf8.count
        let isTruncated = declaredLiteralLength >= 500_000 || sectionBody.utf8.count >= 500_000

        let mimeHeaderBlock = mimeHeader ?? ""
        let hasHeaderTerminator = mimeHeaderBlock.hasSuffix("\r\n\r\n")
            || mimeHeaderBlock.hasSuffix("\n\n")
        let headerSeparator = hasHeaderTerminator ? "" : "\r\n\r\n"
        let partContentToDecode: String
        if isTruncated && mimeHeaderBlock.lowercased().contains("base64") {
            let cleanBase64 = sectionBody.filter { !$0.isWhitespace }
            let validLen = (cleanBase64.count / 4) * 4
            let truncatedBase64 = String(cleanBase64.prefix(validLen))
            partContentToDecode = mimeHeaderBlock + headerSeparator + truncatedBase64
        } else {
            partContentToDecode = mimeHeaderBlock + headerSeparator + sectionBody
        }

        let decoded = MIMETextDecoder.decode(partContentToDecode)

        let finalHtml: String
        let finalText: String

        if isTruncated {
            finalHtml = ""
            let notice = AppLanguage.localized(
                "mail.bodyTruncated",
                defaultValue: AppLanguage.current == .english
                    ? "\n\n[Message truncated due to size limit]"
                    : "\n\n[크기 제한으로 인해 메일 일부가 생략되었습니다]",
                language: .current
            )
            let baseText = decoded.text.isEmpty ? String(decoded.html.prefix(1000)) : decoded.text
            finalText = baseText + notice
        } else {
            finalHtml = decoded.html
            finalText = decoded.text
        }

        let records = Self.parseRecords(lines)
        guard let fallbackRecord = records.first else {
            throw GmailIMAPError.invalidResponse
        }
        let topHeaderFields = topHeader.map { Self.parseHeadersAndBody($0).headers } ?? [:]
        let record = IMAPMessageRecord(
            uid: fallbackRecord.uid,
            gmailMessageID: fallbackRecord.gmailMessageID,
            threadID: fallbackRecord.threadID,
            subject: MIMETextDecoder.decodeRFC2047(
                topHeaderFields["subject"] ?? fallbackRecord.subject
            ),
            from: MIMETextDecoder.decodeRFC2047(
                topHeaderFields["from"] ?? fallbackRecord.from
            ),
            messageID: topHeaderFields["message-id"] ?? fallbackRecord.messageID,
            receivedAt: topHeaderFields["date"].flatMap(Self.parseDate)
                ?? fallbackRecord.receivedAt,
            isRead: fallbackRecord.isRead,
            body: partContentToDecode
        )

        let metadata = metadata(record, snippet: String(finalText.prefix(200)))
        return MailboxMessageContent(metadata: metadata, body: finalText, htmlBody: finalHtml)
    }

    // MARK: - BODYSTRUCTURE S-expression parser & part selector

    struct BodyPartLeaf: Sendable, Equatable {
        let sectionNumber: String
        let mediaType: String
        let subtype: String
        let charset: String?
        let isAttachment: Bool
    }

    enum SExpr: Sendable, Equatable {
        case atom(String)
        case list([SExpr])
    }

    private nonisolated static func parseSExpr(_ text: String) -> SExpr? {
        var index = text.startIndex
        return parseExpr(text, index: &index)
    }

    private nonisolated static func parseExpr(_ text: String, index: inout String.Index) -> SExpr? {
        skipWhitespace(text, index: &index)
        guard index < text.endIndex else { return nil }

        if text[index] == "(" {
            text.formIndex(after: &index)
            var elements: [SExpr] = []
            while index < text.endIndex {
                skipWhitespace(text, index: &index)
                if index < text.endIndex, text[index] == ")" {
                    text.formIndex(after: &index)
                    return .list(elements)
                }
                guard let element = parseExpr(text, index: &index) else { return nil }
                elements.append(element)
            }
            return nil
        } else if text[index] == "\"" {
            text.formIndex(after: &index)
            var str = ""
            var escaped = false
            while index < text.endIndex {
                let char = text[index]
                text.formIndex(after: &index)
                if escaped {
                    str.append(char)
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    return .atom(str)
                } else {
                    str.append(char)
                }
            }
            return nil
        } else {
            let start = index
            while index < text.endIndex {
                let char = text[index]
                if char.isWhitespace || char == "(" || char == ")" || char == "\"" {
                    break
                }
                text.formIndex(after: &index)
            }
            guard start < index else { return nil }
            return .atom(String(text[start..<index]))
        }
    }

    private nonisolated static func skipWhitespace(_ text: String, index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace {
            text.formIndex(after: &index)
        }
    }

    private nonisolated static func collectLeaves(
        expr: SExpr,
        prefix: String,
        into leaves: inout [BodyPartLeaf]
    ) {
        guard case .list(let elements) = expr, !elements.isEmpty else { return }

        if let first = elements.first, case .list = first {
            var childIndex = 1
            for element in elements {
                if case .list = element {
                    let childPrefix = prefix.isEmpty ? "\(childIndex)" : "\(prefix).\(childIndex)"
                    collectLeaves(expr: element, prefix: childPrefix, into: &leaves)
                    childIndex += 1
                } else {
                    break
                }
            }
        } else if let typeAtom = elements.first, case .atom(let typeStr) = typeAtom {
            let mediaType = typeStr.uppercased()
            let subtype = elements.count > 1 ? (extractAtomString(elements[1])?.uppercased() ?? "") : ""
            let charset = extractCharset(from: elements.count > 2 ? elements[2] : nil)
            let isAttach = isAttachmentDisposition(elements: elements, mediaType: mediaType)
            let section = prefix.isEmpty ? "1" : prefix
            leaves.append(BodyPartLeaf(
                sectionNumber: section,
                mediaType: mediaType,
                subtype: subtype,
                charset: charset,
                isAttachment: isAttach
            ))
        }
    }

    private nonisolated static func extractAtomString(_ expr: SExpr) -> String? {
        if case .atom(let str) = expr { return str }
        return nil
    }

    private nonisolated static func extractCharset(from expr: SExpr?) -> String? {
        guard let expr, case .list(let params) = expr else { return nil }
        var i = 0
        while i + 1 < params.count {
            if let name = extractAtomString(params[i]), name.uppercased() == "CHARSET" {
                return extractAtomString(params[i + 1])
            }
            i += 2
        }
        return nil
    }

    private nonisolated static func isAttachmentDisposition(elements: [SExpr], mediaType: String) -> Bool {
        let dispIndex = (mediaType == "TEXT") ? 9 : 8
        if elements.count > dispIndex {
            let dispExpr = elements[dispIndex]
            if case .list(let dispList) = dispExpr, let first = dispList.first, case .atom(let dispStr) = first {
                if dispStr.uppercased() == "ATTACHMENT" {
                    return true
                }
            }
        }
        if mediaType != "TEXT" && mediaType != "MULTIPART" {
            return true
        }
        return false
    }

    private nonisolated static func selectPreferredTextLeaf(from leaves: [BodyPartLeaf]) -> BodyPartLeaf? {
        let nonAttachments = leaves.filter { !$0.isAttachment }
        if let html = nonAttachments.first(where: { $0.mediaType == "TEXT" && $0.subtype == "HTML" }) {
            return html
        }
        if let plain = nonAttachments.first(where: { $0.mediaType == "TEXT" && $0.subtype == "PLAIN" }) {
            return plain
        }
        return nonAttachments.first(where: { $0.mediaType == "TEXT" })
    }

    private nonisolated static func extractBodyStructureString(from lines: [String]) -> String? {
        for line in lines {
            guard let range = line.range(of: "BODYSTRUCTURE", options: .caseInsensitive) else { continue }
            let tail = line[range.upperBound...]
            guard let openParen = tail.firstIndex(of: "(") else { continue }
            var depth = 0
            var inQuote = false
            var isEscaped = false
            var endIdx = openParen
            for idx in line.indices[openParen...] {
                let char = line[idx]
                if isEscaped {
                    isEscaped = false
                    continue
                }
                if char == "\\" && inQuote {
                    isEscaped = true
                    continue
                }
                if char == "\"" {
                    inQuote.toggle()
                    continue
                }
                if !inQuote {
                    if char == "(" {
                        depth += 1
                    } else if char == ")" {
                        depth -= 1
                        if depth == 0 {
                            endIdx = idx
                            return String(line[openParen...endIdx])
                        }
                    }
                }
            }
        }
        return nil
    }

    private nonisolated static func isSafeSinglePartFallback(_ lines: [String]) -> Bool {
        guard let bstruct = extractBodyStructureString(from: lines),
              let sexpr = parseSExpr(bstruct),
              case .list(let outer) = sexpr
        else {
            return false
        }
        let elements: [SExpr]
        if outer.count == 1, case .list(let nested) = outer[0] {
            elements = nested
        } else {
            elements = outer
        }
        guard elements.count >= 2,
              case .atom(let type) = elements[0],
              type.uppercased() == "TEXT",
              case .atom(let subtype) = elements[1],
              ["PLAIN", "HTML"].contains(subtype.uppercased()),
              !bstruct.localizedCaseInsensitiveContains("attachment")
        else {
            return false
        }
        return true
    }

    private nonisolated static func captureLiteralLength(in line: String) -> Int? {
        guard let marker = line.range(of: #"\{\d+\}"#, options: .regularExpression) else { return nil }
        let numStr = line[line.index(after: marker.lowerBound)..<line.index(before: marker.upperBound)]
        return Int(numStr)
    }
    // MARK: - Metadata + category resolution

    private func fetchMetadata(for uids: [UInt32]) async throws -> [MailboxMessageMetadata] {
        guard let lowest = uids.first, let highest = uids.last else { return [] }
        let range = uids.map(String.init).joined(separator: ",")
        let lines = try await transport.execute(
            "UID FETCH \(range) (UID FLAGS X-GM-MSGID X-GM-THRID INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (SUBJECT FROM MESSAGE-ID DATE)])"
        )
        try await resolveCategoryLabels(lowest: lowest, highest: highest, window: Set(uids))
        return Self.parseRecords(lines).map { metadata($0) }
    }

    /// Gmail's inbox tabs are not IMAP flags. `X-GM-RAW` is the documented path for
    /// Gmail search syntax, including `category:`. Each query is scoped to the UID
    /// window just fetched so it never scans the whole mailbox.
    private func resolveCategoryLabels(
        lowest: UInt32,
        highest: UInt32,
        window: Set<UInt32>
    ) async throws {
        var resolved = Dictionary(uniqueKeysWithValues: window.map { ($0, [String]()) })
        for entry in Self.categoryQueries {
            let lines = try await transport.execute(
                "UID SEARCH UID \(lowest):\(highest) X-GM-RAW \"\(entry.query)\""
            )
            for uid in Self.parseUIDs(lines) where window.contains(uid) {
                if !resolved[uid, default: []].contains(entry.label) {
                    resolved[uid, default: []].append(entry.label)
                }
            }
        }
        for uid in window {
            categoryLabelsByUID[uid] = resolved[uid] ?? []
        }
    }

    private struct CategoryQuery: Sendable {
        let query: String
        let label: String
    }

    /// `nonisolated` because the app target defaults to MainActor isolation and this
    /// table is read from inside the actor.
    private nonisolated static let categoryQueries: [CategoryQuery] = [
        CategoryQuery(query: "category:primary", label: "CATEGORY_PERSONAL"),
        CategoryQuery(query: "category:promotions", label: "CATEGORY_PROMOTIONS"),
        CategoryQuery(query: "category:social", label: "CATEGORY_SOCIAL"),
        CategoryQuery(query: "category:updates", label: "CATEGORY_UPDATES"),
        CategoryQuery(query: "category:forums", label: "CATEGORY_FORUMS")
    ]

    private func metadata(
        _ record: IMAPMessageRecord,
        snippet: String? = nil
    ) -> MailboxMessageMetadata {
        // A resolved UID yields the full Gmail-API-shaped label set; an unresolved one
        // yields [] so MailboxLocalStore keeps whatever labels are already stored.
        var labels: [String] = []
        if let categories = categoryLabelsByUID[record.uid] {
            labels = ["INBOX"] + (record.isRead ? [] : ["UNREAD"]) + categories
        }
        return MailboxMessageMetadata(
            provider: .gmail,
            providerMessageID: String(record.uid),
            providerGlobalMessageID: record.gmailMessageID,
            sourceAccountNamespace: account ?? "",
            threadID: record.threadID,
            subject: record.subject,
            from: record.from,
            snippet: snippet ?? String(record.body.prefix(200)),
            receivedAt: record.receivedAt,
            isRead: record.isRead,
            isInInbox: true,
            gmailLabelIDs: labels,
            outlookInferenceClassificationRawValue: "",
            providerCategoryNames: [],
            providerFolderID: "INBOX"
        )
    }

    // MARK: - Wire parsing

    private nonisolated static func supportsTextBody(_ lines: [String]) -> Bool {
        lines.contains { line in
            let upper = line.uppercased()
            return upper.contains("TEXT") && (upper.contains("PLAIN") || upper.contains("HTML"))
        }
    }

    private nonisolated static func parseUIDs(_ lines: [String]) -> [UInt32] {
        guard let line = lines.first(where: { $0.hasPrefix("* SEARCH") }) else { return [] }
        return line.split(separator: " ").dropFirst(2).compactMap { UInt32($0) }
    }

    private nonisolated static func parseRecords(_ lines: [String]) -> [IMAPMessageRecord] {
        lines.compactMap { line -> IMAPMessageRecord? in
            guard line.hasPrefix("* "), line.contains("FETCH") else { return nil }
            let uid = captureToken("UID", in: line).flatMap(UInt32.init) ?? 0
            let gmailID = captureToken("X-GM-MSGID", in: line) ?? "uid-\(uid)"
            let thread = captureToken("X-GM-THRID", in: line) ?? ""
            let literal = captureLiteral(in: line) ?? ""
            let parsed = parseHeadersAndBody(literal)
            let body = line.contains("BODY[TEXT]") ? literal : parsed.body
            let isRead = line.contains("\\Seen")
            return IMAPMessageRecord(
                uid: uid,
                gmailMessageID: gmailID,
                threadID: thread,
                subject: MIMETextDecoder.decodeRFC2047(parsed.headers["subject"] ?? ""),
                from: MIMETextDecoder.decodeRFC2047(parsed.headers["from"] ?? ""),
                messageID: parsed.headers["message-id"] ?? "",
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
            } else if let separator = rawLine.firstIndex(of: ":") {
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
        let bytes = line[marker.upperBound...].utf8.prefix(length)
        return String(decoding: bytes, as: UTF8.self)
    }

    private nonisolated static func captureLiteral(in line: String, afterAttribute attribute: String) -> String? {
        guard let range = line.range(of: attribute, options: .caseInsensitive) else { return nil }
        return captureLiteral(in: String(line[range.lowerBound...]))
    }

    private nonisolated static func captureLiteralLength(in line: String, afterAttribute attribute: String) -> Int? {
        guard let range = line.range(of: attribute, options: .caseInsensitive) else { return nil }
        return captureLiteralLength(in: String(line[range.lowerBound...]))
    }

    private nonisolated static func parseRecord(_ lines: [String]) -> IMAPMessageRecord? {
        parseRecords(lines).first
    }

    private nonisolated static func captureToken(_ token: String, in line: String) -> String? {
        guard let range = line.range(of: token, options: .caseInsensitive) else { return nil }
        let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return tail.split(whereSeparator: { $0 == " " || $0 == ")" || $0 == "]" }).first.map(String.init)
    }
}
