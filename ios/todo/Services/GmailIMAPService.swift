import Foundation
import Network

nonisolated protocol IMAPCommandTransport: Sendable {
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
            return AppLanguage.localized("error.mail.gmailIMAP.missingCredential", defaultValue: "Gmail IMAP credentials are missing.", language: language)
        case .invalidResponse:
            return AppLanguage.localized("error.mail.gmailIMAP.invalidResponse", defaultValue: "Gmail IMAP returned an invalid response.", language: language)
        case .authenticationFailed:
            return AppLanguage.localized("error.mail.gmailIMAP.authenticationFailed", defaultValue: "Gmail IMAP authentication failed.", language: language)
        case .credentialRejected:
            return AppLanguage.localized("error.mail.gmailIMAP.credentialRejected", defaultValue: "Gmail rejected the saved App Password. Replace it in Email Settings.", language: language)
        case .mailboxReset:
            return AppLanguage.localized("error.mail.gmailIMAP.mailboxReset", defaultValue: "The Gmail mailbox changed. Refresh the inbox and try again.", language: language)
        case .mutationUnsupported:
            return AppLanguage.localized("error.mail.gmailIMAP.mutationUnsupported", defaultValue: "This Gmail IMAP server does not support the requested mail action.", language: language)
        case .messageIdentityUnavailable:
            return AppLanguage.localized("error.mail.gmailIMAP.messageIdentityUnavailable", defaultValue: "This cached Gmail message needs a mailbox refresh before it can be changed.", language: language)
        case .unsupportedExtension:
            return AppLanguage.localized("error.mail.gmailIMAP.unsupportedExtension", defaultValue: "Gmail IMAP does not advertise X-GM-EXT-1.", language: language)
        case .analysisFailed:
            return AppLanguage.localized("error.mail.gmailIMAP.analysisFailed", defaultValue: "Gmail message analysis did not complete.", language: language)
        case .analysisLeased:
            return AppLanguage.localized("error.mail.gmailIMAP.analysisLeased", defaultValue: "Gmail message analysis is already in progress.", language: language)
        case .noSelectableTextPart:
            return AppLanguage.localized("error.mail.gmailIMAP.noSelectableTextPart", defaultValue: "No readable text content found in this message.", language: language)
        case .transport(let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !detail.isEmpty else {
                return AppLanguage.localized("error.mail.gmailIMAP.transport", defaultValue: "The Gmail IMAP connection failed. Try again.", language: language)
            }
            return String(format: AppLanguage.localized("error.mail.gmailIMAP.transportDetail", defaultValue: "The Gmail IMAP connection failed. Try again. (%@)", language: language), locale: language.locale, String(detail))
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

/// Callback state is shared only through the lock; the transport itself is actor-isolated.
nonisolated private final class IMAPTransportCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}

/// One absolute deadline covers queueing, TLS, greeting, send and the entire response.
nonisolated private final class IMAPTransportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    private var resumeFailure: (@Sendable (Error) -> Void)?
    private var cancelConnection: (@Sendable () -> Void)?
    private var timer: DispatchWorkItem?

    init(timeout: TimeInterval) {
        let timer = DispatchWorkItem { [weak self] in
            self?.abort(GmailIMAPError.transport("IMAP operation timed out"))
        }
        self.timer = timer
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
    }

    func attach(_ connection: any IMAPWireConnection) {
        let alreadyFailed = lock.withLock {
            cancelConnection = { connection.cancel() }
            return failure != nil
        }
        if alreadyFailed { connection.cancel() }
    }

    func abort(_ error: Error) {
        let handlers = lock.withLock { () -> ((@Sendable (Error) -> Void)?, (@Sendable () -> Void)?) in
            guard failure == nil else { return (nil, nil) }
            failure = error
            return (resumeFailure, cancelConnection)
        }
        handlers.1?()
        handlers.0?(error)
    }

    func finish() {
        lock.withLock {
            timer?.cancel()
            timer = nil
            resumeFailure = nil
            cancelConnection = nil
        }
    }

    func wait<Value: Sendable>(
        _ start: (@escaping @Sendable (Result<Value, Error>) -> Bool) -> Void
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let completion = IMAPTransportCompletion(continuation)
                let error = lock.withLock {
                    resumeFailure = { completion.resolve(.failure($0)) }
                    return failure
                }
                if let error {
                    completion.resolve(.failure(error))
                } else {
                    start { completion.resolve($0) }
                }
            }
        } onCancel: {
            self.abort(CancellationError())
        }
    }
}

/// Internal wire seam exercises the production deadline and framing paths without live credentials.
nonisolated struct IMAPWireChunk: Sendable {
    let data: Data
    let isComplete: Bool
}

nonisolated protocol IMAPWireConnection: Sendable {
    func start(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void)
    func send(_ data: Data, completion: @escaping @Sendable (Result<Void, Error>) -> Void)
    func receive(_ completion: @escaping @Sendable (Result<IMAPWireChunk, Error>) -> Void)
    func cancel()
}

nonisolated private final class NetworkIMAPWireConnection: Sendable, IMAPWireConnection {
    private let connection: NWConnection

    init(host: String, port: UInt16) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw GmailIMAPError.invalidResponse }
        connection = NWConnection(host: NWEndpoint.Host(host), port: port,
                                  using: NWParameters(tls: NWProtocolTLS.Options()))
    }

    func start(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: completion(.success(()))
            case .failed: completion(.failure(GmailIMAPError.transport("IMAP TLS connection failed")))
            case .cancelled: completion(.failure(GmailIMAPError.transport("IMAP connection closed")))
            default: break
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    func send(_ data: Data, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error == nil ? .success(()) : .failure(GmailIMAPError.transport("IMAP send failed")))
        })
    }

    func receive(_ completion: @escaping @Sendable (Result<IMAPWireChunk, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, complete, error in
            if error != nil {
                completion(.failure(GmailIMAPError.transport("IMAP receive failed")))
            } else {
                completion(.success(IMAPWireChunk(data: data ?? Data(), isComplete: complete)))
            }
        }
    }

    func cancel() { connection.cancel() }
}

/// Refines `IMAPCommandTransport` to expose a pre-authentication greeting probe.
/// Callers that must inspect legacy-auth support (e.g. `LOGINDISABLED`) before
/// sending credentials use `connectPreAuth()` + `login(username:password:)`
/// instead of the combined `connect(username:password:)`.
nonisolated protocol IMAPPreAuthCapabilityProbing: IMAPCommandTransport {
    /// Opens the TLS connection and returns the greeting lines, without sending `LOGIN`.
    func connectPreAuth() async throws -> [String]
    /// Sends `LOGIN` on a connection already opened by `connect`/`connectPreAuth`.
    func login(username: String, password: String) async throws
}

/// TLS IMAP transport. FIFO turns prevent actor reentrancy from overlapping wire reads.
actor NetworkIMAPCommandTransport: IMAPPreAuthCapabilityProbing {
    private let makeConnection: @Sendable () throws -> any IMAPWireConnection
    private let timeout: TimeInterval
    private var connection: (any IMAPWireConnection)?
    private var tag: UInt64 = 0
    private var decoder = IMAPResponseDecoder()
    private var pendingLines: [String] = []
    private var reachedEOF = false
    private var activeOperation: IMAPTransportOperation?
    private var busy = false
    private var waiters: [(IMAPTransportOperation, @Sendable (Result<Void, Error>) -> Bool)] = []

    init(host: String = "imap.gmail.com", port: UInt16 = 993) {
        makeConnection = { try NetworkIMAPWireConnection(host: host, port: port) }
        timeout = 30
    }

    init(timeout: TimeInterval, makeConnection: @escaping @Sendable () throws -> any IMAPWireConnection) {
        precondition(timeout.isFinite && timeout > 0)
        self.timeout = timeout
        self.makeConnection = makeConnection
    }

    func connect(username: String, password: String) async throws {
        let command = try Self.loginCommand(username: username, password: password)
        try await withTurn { transport, operation in
            _ = try await transport.open(operation)
            try await transport.authenticate(command, operation: operation)
        }
    }

    func connectPreAuth() async throws -> [String] {
        try await withTurn { transport, operation in try await transport.open(operation) }
    }

    func login(username: String, password: String) async throws {
        let command = try Self.loginCommand(username: username, password: password)
        try await withTurn { transport, operation in
            try await transport.authenticate(command, operation: operation)
        }
    }

    func execute(_ command: String) async throws -> [String] {
        try Self.validateCommand(command)
        return try await withTurn { transport, operation in
            let response = try await transport.send(command, operation: operation)
            guard Self.status(in: response.last ?? "") == "OK" else { throw GmailIMAPError.invalidResponse }
            return response
        }
    }

    /// Closing interrupts active and queued work, rather than waiting for a silent peer.
    func close() async {
        activeOperation?.abort(GmailIMAPError.transport("IMAP connection closed"))
        for (operation, _) in waiters { operation.abort(GmailIMAPError.transport("IMAP connection closed")) }
        waiters.removeAll()
        disposeConnection()
    }

    private func withTurn<Value: Sendable>(
        _ body: (isolated NetworkIMAPCommandTransport, IMAPTransportOperation) async throws -> Value
    ) async throws -> Value {
        let operation = IMAPTransportOperation(timeout: timeout)
        defer { operation.finish() }
        let _: Void = try await operation.wait { completion in
            if busy {
                waiters.append((operation, completion))
            } else {
                busy = true
                _ = completion(.success(()))
            }
        }
        activeOperation = operation
        if let connection { operation.attach(connection) }
        defer {
            activeOperation = nil
            busy = false
            while !waiters.isEmpty {
                let (_, completion) = waiters.removeFirst()
                if completion(.success(())) {
                    busy = true
                    break
                }
            }
        }
        do {
            try Task.checkCancellation()
            let result = try await body(self, operation)
            if reachedEOF { disposeConnection() }
            return result
        } catch {
            // A partially transmitted/consumed command must never be reused by another turn.
            disposeConnection()
            throw error
        }
    }

    private func disposeConnection() {
        connection?.cancel()
        connection = nil
        decoder = IMAPResponseDecoder()
        pendingLines.removeAll()
        reachedEOF = false
    }

    private func open(_ operation: IMAPTransportOperation) async throws -> [String] {
        disposeConnection()
        let wire = try makeConnection()
        connection = wire
        operation.attach(wire)
        tag = 0
        let _: Void = try await operation.wait { completion in
            wire.start { _ = completion($0) }
        }
        return try await readResponse(until: nil, operation: operation)
    }

    private func authenticate(_ command: String, operation: IMAPTransportOperation) async throws {
        let response = try await send(command, operation: operation)
        guard let terminal = response.last else { throw GmailIMAPError.invalidResponse }
        if Self.status(in: terminal) != "OK" {
            if GmailIMAPError.isPermanentCredentialRejection(in: [terminal]) {
                throw GmailIMAPError.credentialRejected
            }
            throw GmailIMAPError.invalidResponse
        }
    }

    private func send(_ command: String, operation: IMAPTransportOperation) async throws -> [String] {
        guard let wire = connection else { throw GmailIMAPError.transport("IMAP is not connected") }
        guard tag < UInt64.max else { throw GmailIMAPError.invalidResponse }
        tag += 1
        let commandTag = "A" + String(repeating: "0", count: max(0, 4 - String(tag).count)) + String(tag)
        let data = Data("\(commandTag) \(command)\r\n".utf8)
        let _: Void = try await operation.wait { completion in
            wire.send(data) { _ = completion($0) }
        }
        return try await readResponse(until: commandTag, operation: operation)
    }

    private func readResponse(until commandTag: String?, operation: IMAPTransportOperation) async throws -> [String] {
        guard let wire = connection else { throw GmailIMAPError.transport("IMAP is not connected") }
        var lines: [String] = []
        var byteCount = pendingLines.reduce(0) { $0 + $1.utf8.count }
        while true {
            while !pendingLines.isEmpty {
                let line = pendingLines.removeFirst()
                let tokens = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard tokens.count >= 2 else { throw GmailIMAPError.invalidResponse }
                let status = tokens[1].uppercased()
                lines.append(line)
                if let commandTag {
                    if tokens[0] == commandTag {
                        guard ["OK", "NO", "BAD"].contains(status) else { throw GmailIMAPError.invalidResponse }
                        return lines
                    }
                    guard tokens[0] == "*", status != "BYE" else { throw GmailIMAPError.invalidResponse }
                } else {
                    guard tokens[0] == "*", ["OK", "PREAUTH"].contains(status) else {
                        throw GmailIMAPError.invalidResponse
                    }
                    return lines
                }
            }
            guard !reachedEOF else { throw GmailIMAPError.transport("IMAP connection closed") }
            let chunk: IMAPWireChunk = try await operation.wait { completion in
                wire.receive { _ = completion($0) }
            }
            reachedEOF = chunk.isComplete
            guard chunk.data.count <= 8_388_608 - byteCount else { throw GmailIMAPError.invalidResponse }
            byteCount += chunk.data.count
            pendingLines = try decoder.append(chunk.data)
        }
    }

    nonisolated private static func status(in line: String) -> String? {
        let tokens = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        return tokens.count >= 2 ? tokens[1].uppercased() : nil
    }

    nonisolated private static func validateCommand(_ command: String) throws {
        guard !command.isEmpty, command.utf8.count <= 65_536,
              command.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }),
              command.first != " " else { throw GmailIMAPError.invalidResponse }
    }

    nonisolated private static func loginCommand(username: String, password: String) throws -> String {
        let command = "LOGIN \(try quote(username)) \(try quote(password))"
        try validateCommand(command)
        return command
    }

    nonisolated private static func quote(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
            throw GmailIMAPError.invalidResponse
        }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

actor GmailIMAPService: MailboxPagingProvider {
    static let shared = GmailIMAPService()
    let provider: MailProvider = .gmail

    private let transport: IMAPCommandTransport
    private static let metadataFetchAttributes = "(UID FLAGS X-GM-MSGID X-GM-THRID INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (SUBJECT FROM MESSAGE-ID DATE)])"
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
    // Cancelled waiters release their turn without issuing any commands.

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
        try Task.checkCancellation()
        try await performAuthenticate(email: email, backgroundEnabled: backgroundEnabled)
    }

    /// Connection settings require proof of message access, not only a successful LOGIN.
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
        _ = try await selectInbox(verifyingMessageRetrieval: verifyingMessageRetrieval)
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
        _ = try await selectInbox(verifyingMessageRetrieval: true)
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

    private func selectInbox(verifyingMessageRetrieval: Bool = false) async throws -> String {
        let selected = try await transport.execute("SELECT INBOX")
        guard let validity = IMAPWireSyntax.uidValidity(selected) else {
            throw GmailIMAPError.invalidResponse
        }
        if verifyingMessageRetrieval {
            guard let count = IMAPWireSyntax.messageCount(selected) else {
                throw GmailIMAPError.invalidResponse
            }
            if count > 0 {
                // Sequence '*' reads only the newest message, without listing the entire mailbox.
                // PEEK leaves its read flag unchanged. An empty mailbox needs no FETCH.
                let lines = try await transport.execute("FETCH * \(Self.metadataFetchAttributes)")
                guard let header = lines.first(where: {
                    IMAPWireSyntax.isFetch(IMAPWireSyntax.protocolText($0))
                        && IMAPWireSyntax.literal($0) != nil
                }), Self.parseRecord([header]) != nil else {
                    throw GmailIMAPError.invalidResponse
                }
            }
            try Task.checkCancellation()
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
              IMAPWireSyntax.positiveDecimal(expectedGlobalMessageID, as: UInt64.self) != nil
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
        guard let uid = IMAPWireSyntax.positiveDecimal(messageID, as: UInt32.self) else {
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
        let uid = try Self.uid(from: messageID)
        let structureLines = try await transport.execute("UID FETCH \(uid) (BODYSTRUCTURE)")

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
        let fetchCmd = "UID FETCH \(uid) (UID FLAGS INTERNALDATE X-GM-MSGID X-GM-THRID BODY.PEEK[HEADER] BODY.PEEK[\(section).MIME] BODY.PEEK[\(section)]<0.500000>)"
        let responseLines = try await transport.execute(fetchCmd)
        let lines = responseLines.filter { Self.captureToken("UID", in: $0).flatMap(UInt32.init) == uid }

        let preferredBodyAttribute = "BODY[\(section)]"
        let bodyAttribute: String
        let bodyLine: String
        if let preferredLine = lines.first(where: {
            Self.captureLiteral(in: $0, afterAttribute: preferredBodyAttribute) != nil
        }) {
            bodyAttribute = preferredBodyAttribute
            bodyLine = preferredLine
        } else if let textLine = lines.first(where: { Self.captureLiteral(in: $0, afterAttribute: "BODY[TEXT]") != nil }) {
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
            Self.captureLiteral(in: $0, afterAttribute: mimeAttribute) != nil
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
        let topHeader = lines.compactMap { Self.captureLiteral(in: $0, afterAttribute: "BODY[HEADER]") }.first

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
        guard let fallbackRecord = records.first(where: { $0.uid == uid }) else {
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
        return parseExpr(text, index: &index, depth: 0)
    }

    private nonisolated static func parseExpr(_ text: String, index: inout String.Index, depth: Int) -> SExpr? {
        guard depth < 64 else { return nil }
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
                guard let element = parseExpr(text, index: &index, depth: depth + 1) else { return nil }
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
        IMAPWireSyntax.literal(line)?.length
    }
    // MARK: - Metadata + category resolution

    private func fetchMetadata(for uids: [UInt32]) async throws -> [MailboxMessageMetadata] {
        guard let lowest = uids.first, let highest = uids.last else { return [] }
        let range = uids.map(String.init).joined(separator: ",")
        let lines = try await transport.execute(
            "UID FETCH \(range) \(Self.metadataFetchAttributes)"
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
        IMAPWireSyntax.searchUIDs(lines)
    }

    private nonisolated static func parseRecords(_ lines: [String]) -> [IMAPMessageRecord] {
        lines.compactMap { line -> IMAPMessageRecord? in
            let syntax = IMAPWireSyntax.protocolText(line)
            guard IMAPWireSyntax.isFetch(syntax),
                  let uid = captureToken("UID", in: syntax).flatMap({ IMAPWireSyntax.positiveDecimal($0, as: UInt32.self) }),
                  let gmailID = captureToken("X-GM-MSGID", in: syntax),
                  IMAPWireSyntax.positiveDecimal(gmailID, as: UInt64.self) != nil else { return nil }
            let thread = captureToken("X-GM-THRID", in: syntax) ?? ""
            let literal = captureLiteral(in: line) ?? ""
            let parsed = parseHeadersAndBody(literal)
            let body = line.contains("BODY[TEXT]") ? literal : parsed.body
            let isRead = IMAPWireSyntax.hasSeenFlag(syntax)
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
        IMAPWireSyntax.literal(line)?.text
    }

    private nonisolated static func captureLiteral(in line: String, afterAttribute attribute: String) -> String? {
        IMAPWireSyntax.literal(line, attribute: attribute)?.text
    }

    private nonisolated static func captureLiteralLength(in line: String, afterAttribute attribute: String) -> Int? {
        IMAPWireSyntax.literal(line, attribute: attribute)?.length
    }

    private nonisolated static func parseRecord(_ lines: [String]) -> IMAPMessageRecord? {
        parseRecords(lines).first
    }

    private nonisolated static func captureToken(_ token: String, in line: String) -> String? {
        IMAPWireSyntax.token(token, in: line)
    }
}

/// Protocol metadata must never be read from quoted strings or message literals.
/// Shared by both providers so UID identity checks use the same wire boundary.
nonisolated enum IMAPWireSyntax {
    static func positiveDecimal<T: FixedWidthInteger & UnsignedInteger>(_ value: String, as: T.Type) -> T? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = T(value), number > 0 else { return nil }
        return number
    }

    static func protocolText(_ line: String) -> String {
        scan(line).syntax
    }

    static func literal(_ line: String, attribute: String? = nil) -> (text: String, length: Int)? {
        let result = scan(line, attribute: attribute, captureLiteral: true)
        guard let text = result.literal else { return nil }
        return (text, result.length)
    }

    private static func scan(_ line: String, attribute: String? = nil, captureLiteral: Bool = false)
        -> (syntax: String, literal: String?, length: Int) {
        let bytes = line.utf8
        var index = bytes.startIndex
        var syntax = ""
        var literal: String?
        var literalLength = 0
        var quoted = false
        var escaped = false
        while index < bytes.endIndex {
            let byte = bytes[index]
            let next = bytes.index(after: index)
            if !quoted && byte == 123 {
                var markerEnd = next
                while markerEnd < bytes.endIndex, (48...57).contains(bytes[markerEnd]) {
                    bytes.formIndex(after: &markerEnd)
                }
                guard markerEnd > next, markerEnd < bytes.endIndex, bytes[markerEnd] == 125,
                      let length = Int(String(decoding: bytes[next..<markerEnd], as: UTF8.self)),
                      length <= 500_000 else { break }
                let start = bytes.index(after: markerEnd)
                let end = bytes.index(start, offsetBy: length, limitedBy: bytes.endIndex) ?? bytes.endIndex
                let matchesAttribute = attribute.map {
                    syntax.range(of: NSRegularExpression.escapedPattern(for: $0) + #"(?:<[0-9]+>)?\s*$"#,
                                 options: [.regularExpression, .caseInsensitive]) != nil
                } ?? true
                if captureLiteral && literal == nil && matchesAttribute {
                    literal = String(decoding: bytes[start..<end], as: UTF8.self)
                    literalLength = length
                }
                syntax.append(" ")
                index = end
                continue
            }
            if escaped {
                escaped = false
                syntax.append(" ")
            } else if quoted && byte == 92 {
                escaped = true
                syntax.append(" ")
            } else if byte == 34 {
                quoted.toggle()
                syntax.append(" ")
            } else {
                syntax.unicodeScalars.append(UnicodeScalar(quoted || byte > 127 ? 32 : byte))
            }
            index = next
        }
        return (syntax, literal, literalLength)
    }

    static func token(_ name: String, in line: String) -> String? {
        let text = protocolText(line)
        let pattern = "(?i)(?:^|[ (])" + NSRegularExpression.escapedPattern(for: name)
            + #" +([0-9]+)(?=[ )\]]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func isFetch(_ text: String) -> Bool {
        text.range(of: #"^\* [1-9][0-9]* FETCH \("#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func hasSeenFlag(_ text: String) -> Bool {
        guard let range = text.range(of: #"(?i)(?:^|[ (])FLAGS +\([^)]*\)"#, options: .regularExpression) else { return false }
        return text[range].split(whereSeparator: { $0 == " " || $0 == "(" || $0 == ")" })
            .contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }
    }

    static func uidValidity(_ lines: [String]) -> String? {
        for line in lines {
            guard line.range(of: #"^\* OK \[UIDVALIDITY [0-9]+\](?: |$)"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  let value = token("UIDVALIDITY", in: line.replacingOccurrences(of: "[", with: " ")),
                  let validity = positiveDecimal(value, as: UInt32.self) else { continue }
            return String(validity)
        }
        return nil
    }

    /// SELECT must explicitly report EXISTS; a missing count is not an empty mailbox.
    static func messageCount(_ lines: [String]) -> UInt32? {
        for line in lines.reversed() {
            let tokens = line.split(separator: " ")
            guard tokens.count == 3, tokens[0] == "*", tokens[2].uppercased() == "EXISTS" else { continue }
            guard !tokens[1].isEmpty, tokens[1].utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return UInt32(tokens[1])
        }
        return nil
    }

    static func searchUIDs(_ lines: [String]) -> [UInt32] {
        var result = Set<UInt32>()
        for line in lines {
            let tokens = line.split(separator: " ")
            guard tokens.count >= 2, tokens[0] == "*", tokens[1].uppercased() == "SEARCH" else { continue }
            for token in tokens.dropFirst(2) {
                guard let uid = positiveDecimal(String(token), as: UInt32.self) else { continue }
                result.insert(uid)
            }
        }
        return result.sorted()
    }
}
