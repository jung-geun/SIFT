import Foundation
import AuthenticationServices
import Security
import OSLog
import CryptoKit
import SwiftData
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Email Extraction Models (Codable — @Generable 제거, iOS 27 호환)

struct ExtractedTodoList: Codable {
    var todos: [ExtractedEmailTodo]
}

struct ExtractedEmailTodo: Codable {
    var title: String
    var notes: String
    var dueDateISO: String
    var priorityHint: String
}

struct ExtractedEventList: Codable {
    var events: [ExtractedEmailEvent]
}

struct ExtractedEmailEvent: Codable {
    var title: String
    var startISO: String
    var endISO: String
    var location: String
    var notes: String
    var isAllDay: Bool
}

struct EmailIngestionResult: Sendable {
    let todoCount: Int
    let eventCount: Int
}

struct EmailCacheSyncResult: Sendable {
    let upsertedMessageCount: Int
    let prunedMessageCount: Int
    let prunedTodoCount: Int
    let insertedMessageIDs: Set<String>
}

private struct RecentMessageSyncSnapshot: Sendable {
    let messages: [GmailMessage]
    /// Broad mailbox IDs remain the authority for destructive stale checks.
    let activeMailboxMessageIDs: Set<String>
    /// The display snapshot is explicitly Gmail INBOX-only.
    let recentInboxMessageIDs: Set<String>
    let lookbackCutoff: Date
}

/// 수동 등록 전용 이메일 할 일 초안 모델.
/// - Sendable: 백그라운드 전달 시 값 전송 안정성 확보.
struct EmailTodoDraft: Sendable {
    let title: String
    let notes: String
    let dueDate: Date?
    let isAllDay: Bool
    let sender: String
    let senderEmail: String
}

// MARK: - Gmail Message Model

struct GmailMessage: Sendable {
    let id: String
    let threadID: String
    let messageID: String   // RFC822 Message-ID (원본 메일 permalink 생성용)
    let subject: String
    let from: String
    let snippet: String     // Gmail 제공 ~200자 미리보기 (메모용)
    let body: String        // MIME 디코딩 전체 평문 (날짜 감지용)
    let htmlBody: String?   // 원본 HTML 본문 (WKWebView 렌더링용)
    let receivedAt: Date
    /// Gmail 카테고리 라벨 (예: CATEGORY_SOCIAL, CATEGORY_PROMOTIONS, CATEGORY_FORUMS)
    let labelIds: [String]
    /// List-Unsubscribe 또는 Precedence: bulk 헤더 존재 여부 (뉴스레터·대량발송 신호)
    let isBulk: Bool
    /// Provider-native identity is retained separately from legacy `id`.
    let provider: MailProvider
    let providerMessageID: String
    let sourceAccountNamespace: String

    init(
        id: String,
        threadID: String,
        messageID: String,
        subject: String,
        from: String,
        snippet: String,
        body: String,
        htmlBody: String?,
        receivedAt: Date,
        labelIds: [String],
        isBulk: Bool,
        provider: MailProvider = .gmail,
        providerMessageID: String = "",
        sourceAccountNamespace: String = ""
    ) {
        self.id = id
        self.threadID = threadID
        self.messageID = messageID
        self.subject = subject
        self.from = from
        self.snippet = snippet
        self.body = body
        self.htmlBody = htmlBody
        self.receivedAt = receivedAt
        self.labelIds = labelIds
        self.isBulk = isBulk
        self.provider = provider
        self.providerMessageID = providerMessageID
        self.sourceAccountNamespace = sourceAccountNamespace
    }
}

// MARK: - Mailbox Provider Contract

protocol MailboxPagingProvider: AnyObject {
    var provider: MailProvider { get }
    func fetchInboxPage(after cursor: String?) async throws -> MailboxPage
    func fetchInboxUpdates(newerThan cursor: String) async throws -> MailboxPage
    func fetchInboxMessageIDs() async throws -> Set<String>
    func fetchMessageContent(messageID: String) async throws -> MailboxMessageContent
    func markAsRead(
        messageID: String,
        expectedGlobalMessageID: String?
    ) async throws
    func trashMessage(
        messageID: String,
        expectedGlobalMessageID: String?
    ) async throws
}

enum MailboxMutationAction: String, Codable, Hashable, Sendable {
    case markAsRead
    case trash
}

enum MailboxMutationError: LocalizedError {
    case remoteCommittedLocalSaveFailed(
        provider: MailProvider,
        action: MailboxMutationAction
    )
    case mutationIdentityUnavailable(provider: MailProvider)

    var errorDescription: String? {
        errorDescription(language: .current)
    }

    func errorDescription(language: AppLanguage) -> String {
        switch self {
        case .remoteCommittedLocalSaveFailed:
            return AppLanguage.localized("error.mail.service.remoteCommittedLocalSaveFailed", defaultValue: "The change was applied by the provider, but the local state could not be saved. Sync the mailbox again.", language: language)
        case .mutationIdentityUnavailable(let provider):
            let providerName = provider == .outlook ? "Outlook" : "Gmail"
            return String(format: AppLanguage.localized("error.mail.service.mutationIdentityUnavailable", defaultValue: "%@ could not verify this message. Refresh the mailbox and try again.", language: language), locale: language.locale, String(providerName))
        }
    }
}

@MainActor
protocol GmailOAuthSession: AnyObject {
    func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: GmailOAuthSession {}

// MARK: - Email Service

/// Gmail OAuth + 메시지 fetch + 온디바이스 FM 할 일 추출 (v2)
///
/// 사전 준비:
/// 1. Google Cloud Console에서 OAuth 클라이언트 ID 발급 (iOS 앱 유형)
/// 2. 리디렉트 URI 스킴을 Info.plist CFBundleURLSchemes에 등록
/// 3. Native public-client OAuth uses PKCE; no client secret belongs in this app.
@MainActor
final class EmailService: NSObject, MailboxPagingProvider {
    static let shared = EmailService()
    let provider: MailProvider = .gmail
    override init() {}

    // MARK: - Configuration
    //
    // Native OAuth clients are public clients. Authorization-code binding is
    // provided by PKCE; do not embed a client secret in the application.
    private let clientID     = "746219534143-ij6p50gff6as4hn2bbhdc9a1u6os3jmp.apps.googleusercontent.com"
    private let redirectURI  = "com.googleusercontent.apps.746219534143-ij6p50gff6as4hn2bbhdc9a1u6os3jmp:/oauth2callback"
    private let scope        = "openid email profile https://www.googleapis.com/auth/gmail.modify"
    private let requiredTokenScopeVersion = "gmail.modify.openid.v2"
    private let accessTokenRefreshSkew: TimeInterval = 300

    private let keychainService = "pieroot.todo.gmail"
    static var firebaseIDToken: String? {
        // Legacy ID tokens are read only until the first successful bundle migration.
        guard !shared.signedOut else { return nil }
        guard let tokens = try? readPersistedTokens() else { return nil }
        return tokens.idToken
    }

    /// Reads only the locally-held ID-token subject; callers must never persist it.
    static var authenticatedAccountSubject: String? {
        guard let token = firebaseIDToken,
              let payloadPart = token.split(separator: ".").dropFirst().first
        else { return nil }
        let base64 = String(payloadPart).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64 + padding),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = payload["sub"] as? String,
              !subject.isEmpty
        else { return nil }
        return subject
    }
    private let logger = Logger(subsystem: "pieroot.todo", category: "GmailOAuth")
    private var credentialGeneration = UUID()
    private var signedOut = false
    private var activeTokenRefreshTask: (id: UUID, task: Task<Void, Error>)?
    var session: URLSession = .shared

    // The factory lets unit tests exercise start failure/cancellation without UI.
    var makeAuthenticationSession: (URL, String, @escaping (URL?, Error?) -> Void) -> any GmailOAuthSession = { url, scheme, completion in
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme, completionHandler: completion)
        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = WindowProvider.shared
        return session
    }
    private var authorization: (id: UUID, session: any GmailOAuthSession, continuation: CheckedContinuation<String, Error>)?

    // MARK: - Authorization State

    var isAuthenticated: Bool {
        guard !signedOut else { return false }
        guard let tokens = try? loadTokens() else { return false }
        guard tokens.accessToken != nil || tokens.refreshToken != nil else { return false }
        guard tokens.scopeVersion == requiredTokenScopeVersion else {
            try? clearTokensIfScopeIsStale(loadedTokens: tokens)
            return false
        }
        return tokens.accessToken?.isEmpty == false
    }

    private func clearTokensIfScopeIsStale(loadedTokens: StoredTokens) throws {
        guard loadedTokens.accessToken != nil || loadedTokens.refreshToken != nil,
              loadedTokens.scopeVersion != requiredTokenScopeVersion else { return }
        try deleteTokens()
        NotificationCenter.default.post(name: .gmailAuthChanged, object: false)
    }
    // MARK: - OAuth 2.0 (ASWebAuthenticationSession)

    // ASWebAuthenticationSession은 반드시 메인 스레드에서 실행해야 합니다.
    @MainActor
    func authenticate() async throws {
        #if SIFT_QA
        // A second installed app must not claim the App Store app's OAuth callback.
        // Enable Gmail here only after registering a separate iOS OAuth client for the QA bundle ID.
        throw EmailError.qaOAuthNotConfigured
        #else
        try Task.checkCancellation()
        invalidatePendingCredentials()
        let generation = credentialGeneration
        let binding = try makeOAuthBinding()
        guard let authURL = buildAuthURL(state: binding.state, codeChallenge: binding.challenge),
              let callbackScheme = URL(string: redirectURI)?.scheme else {
            throw EmailError.invalidConfiguration
        }
        let attemptID = UUID()
        let code: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let webSession = makeAuthenticationSession(authURL, callbackScheme) { [weak self] callbackURL, error in
                    Task { @MainActor in
                        guard let self else { return }
                        let result: Result<String, Error>
                        if let error {
                            result = .failure(error)
                        } else {
                            result = Result { try self.authorizationCode(from: callbackURL, expectedState: binding.state) }
                        }
                        self.finishAuthorization(id: attemptID, result: result)
                    }
                }
                authorization = (attemptID, webSession, continuation)
                if !webSession.start() {
                    finishAuthorization(id: attemptID, result: .failure(EmailError.authorizationFailed))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelAuthorization(id: attemptID)
            }
        }
        try Task.checkCancellation()
        guard credentialGeneration == generation else { throw CancellationError() }
        try await exchangeCodeForTokens(code: code, codeVerifier: binding.verifier, generation: generation)
        NotificationCenter.default.post(name: .gmailAuthChanged, object: true)
        #endif
    }

    func signOut() {
        signedOut = true
        invalidatePendingCredentials()
        do { try deleteTokens() }
        catch {
            DiagnosticRecorder.shared.record(error: error, component: "mail.gmail", operation: "signOut")
        }
        NotificationCenter.default.post(name: .gmailAuthChanged, object: false)
    }

    private func invalidatePendingCredentials() {
        credentialGeneration = UUID()
        activeTokenRefreshTask?.task.cancel()
        activeTokenRefreshTask = nil
        if let id = authorization?.id { cancelAuthorization(id: id) }
    }

    private func finishAuthorization(id: UUID, result: Result<String, Error>) {
        guard let pending = authorization, pending.id == id else { return }
        authorization = nil
        pending.continuation.resume(with: result)
    }

    private func cancelAuthorization(id: UUID) {
        guard let pending = authorization, pending.id == id else { return }
        finishAuthorization(id: id, result: .failure(CancellationError()))
        pending.session.cancel()
    }

    func authorizationCode(from url: URL?, expectedState: String) throws -> String {
        guard let url,
              let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(string: redirectURI),
              actual.scheme == expected.scheme, actual.host == expected.host,
              actual.path == expected.path, actual.port == expected.port,
              actual.user == nil, actual.password == nil, actual.fragment == nil else {
            throw EmailError.authorizationFailed
        }
        let items = actual.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        let codes = items.filter { $0.name == "code" }
        guard !expectedState.isEmpty, states.count == 1, states[0].value == expectedState,
              codes.count == 1, let code = codes[0].value, !code.isEmpty,
              !items.contains(where: { $0.name == "error" }) else {
            throw EmailError.authorizationFailed
        }
        return code
    }

    /// MailProvider 프로토콜 구현 — 최근 메시지 목록 반환.
    /// 내부적으로 `listRecentMessagesForExtraction(after:)`를 호출하며 Gmail 동작은 의도적으로 유지.
    func fetchRecentMessages() async throws -> [GmailMessage] {
        let token = try await refreshTokenIfNeeded()
        return try await listRecentMessagesForExtraction(after: nil, token: token)
    }

    // MARK: - Fetch & Extract

    /// 새 메일을 가져와 온디바이스 분석 후 Todo/Calendar에 반영한다.
    @MainActor
    func fetchAndStoreExtractedItems(
        context: ModelContext,
        allowFoundationModels: Bool = true,
        updateLastFetchTimestamp: Bool = true
    ) async throws -> EmailIngestionResult {
        let existing = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        let existingRefs = Set(existing.map(\.sourceRef))
        let (todos, events) = try await fetchAndExtractAll(
            allowFoundationModels: allowFoundationModels,
            excludingAlreadyHandledMessageIDs: existingRefs
        )
        let result = applyExtractedItems(
            todos: todos,
            events: events,
            to: context,
            existingRefs: existingRefs
        )
        if updateLastFetchTimestamp {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pieroot.todo.lastEmailFetchDate")
        }
        return result
    }

    @MainActor
    @discardableResult
    func syncRecentMessageCache(
        emailContext: ModelContext,
        todoContext _: ModelContext? = nil
    ) async throws -> EmailCacheSyncResult {
        let snapshot = try await fetchRecentMessageSyncSnapshot()
        let existing = ((try? emailContext.fetch(FetchDescriptor<EmailMessage>())) ?? [])
            .filter { $0.provider == .gmail }
        var existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        var upsertedMessageCount = 0
        var insertedMessageIDs = Set<String>()
        for msg in snapshot.messages {
            let serverIsRead = !msg.labelIds.contains("UNREAD")
            if let email = existingByID[msg.id] {
                var didChange = false
                if email.threadID != msg.threadID {
                    email.threadID = msg.threadID
                    didChange = true
                }
                if email.subject != msg.subject {
                    email.subject = msg.subject
                    didChange = true
                }
                if email.from != msg.from {
                    email.from = msg.from
                    didChange = true
                }
                if email.snippet != msg.snippet {
                    email.snippet = msg.snippet
                    didChange = true
                }
                if email.receivedAt != msg.receivedAt {
                    email.receivedAt = msg.receivedAt
                    didChange = true
                }
                if email.isRead != serverIsRead {
                    email.isRead = serverIsRead
                    didChange = true
                }
                if email.labelIDs != msg.labelIds {
                    email.labelIDs = msg.labelIds
                    didChange = true
                }
                if !email.isInInbox {
                    email.isInInbox = true
                    didChange = true
                }
                if didChange {
                    upsertedMessageCount += 1
                }
            } else {
                let email = EmailMessage(
                    id: msg.id,
                    threadID: msg.threadID,
                    subject: msg.subject,
                    from: msg.from,
                    snippet: msg.snippet,
                    body: msg.body,
                    htmlBody: msg.htmlBody,
                    receivedAt: msg.receivedAt,
                    labelIDs: msg.labelIds,
                    isInInbox: true
                )
                email.isRead = serverIsRead
                email.hasBeenViewedInApp = false
                emailContext.insert(email)
                existingByID[msg.id] = email
                insertedMessageIDs.insert(msg.id)
                upsertedMessageCount += 1
            }
        }


        let activeMailboxMessageIDs = snapshot.activeMailboxMessageIDs
        let deletionSafeActiveMessageIDs = activeMailboxMessageIDs
            .union(snapshot.recentInboxMessageIDs)
        let inWindowMissingEmailIDs = Set(
            existing.lazy
                .filter {
                    $0.receivedAt >= snapshot.lookbackCutoff
                        && !deletionSafeActiveMessageIDs.contains($0.id)
                }
                .map(\.id)
        )

        let staleEmails = existing.filter {
            inWindowMissingEmailIDs.contains($0.id)
        }
        for email in staleEmails {
            emailContext.delete(email)
        }

        let prunedTodoCount = 0

        if upsertedMessageCount > 0 || !staleEmails.isEmpty {
            try emailContext.save()
        }

        return EmailCacheSyncResult(
            upsertedMessageCount: upsertedMessageCount,
            prunedMessageCount: staleEmails.count,
            prunedTodoCount: prunedTodoCount,
            insertedMessageIDs: insertedMessageIDs
        )
    }

    @MainActor
    func applyExtractedItems(
        todos newTodos: [Todo],
        events extractedEvents: [(event: ExtractedEmailEvent, sourceRef: String)],
        to context: ModelContext,
        existingRefs: Set<String>
    ) -> EmailIngestionResult {
        var handledRefs = existingRefs
        var insertedTodosByRef: [String: Todo] = [:]
        var todoCount = 0
        for todo in newTodos where !handledRefs.contains(todo.sourceRef) {
            context.insert(todo)
            TaskBehaviorRecorder.recordCreation(of: todo, actor: .emailIngestion, in: context)
            handledRefs.insert(todo.sourceRef)
            insertedTodosByRef[todo.sourceRef] = todo
            todoCount += 1
        }
        Task { @MainActor in
            await TodoEligibilityReconciler.shared.reconcileAll(Array(insertedTodosByRef.values))
        }

        var eventCount = 0
        if CalendarService.shared.isAuthorized && CalendarAutoPolicy.isAuto {
            let iso = ISO8601DateFormatter()
            var processedEventRefs = Set<String>()
            for (event, sourceRef) in extractedEvents {
                guard let todo = insertedTodosByRef[sourceRef],
                      CalendarService.isAutomaticRegistrationCandidate(todo),
                      !processedEventRefs.contains(sourceRef),
                      todo.calendarEventID == nil,
                      let start = iso.date(from: event.startISO) else { continue }
                let end = event.endISO.isEmpty ? nil : iso.date(from: event.endISO)
                let alreadyLinked = CalendarService.shared.hasEvent(forEmailRef: sourceRef)
                if let eventID = try? CalendarService.shared.createEventFromEmail(
                    title: event.title,
                    start: start,
                    end: end,
                    isAllDay: event.isAllDay,
                    location: event.location,
                    notes: event.notes,
                    sourceRef: sourceRef
                ) {
                    todo.calendarEventID = eventID
                    processedEventRefs.insert(sourceRef)
                    if !alreadyLinked {
                        eventCount += 1
                    }
                }
            }

            for todo in insertedTodosByRef.values
                where CalendarService.isAutomaticRegistrationCandidate(todo)
                    && todo.calendarEventID == nil
                    && !CalendarService.shared.hasEvent(forEmailRef: todo.sourceRef) {
                if CalendarService.shared.applyAutoRegistration(for: todo) {
                    eventCount += 1
                }
            }
        }

        return EmailIngestionResult(todoCount: todoCount, eventCount: eventCount)
    }

    /// 할 일과 캘린더 일정을 한 번의 Gmail fetch로 함께 추출합니다.
    ///
    /// - Parameters:
    ///   - after: 마지막 확인 이후 히스토리 ID (없으면 최근 50건)
    ///   - allowFoundationModels: 포그라운드(true, 기본) → AFM 분석.
    ///     백그라운드 BGTask(false) → NSDataDetector (ANE 백그라운드 미사용).
    ///   - excludingAlreadyHandledMessageIDs: 이미 처리한 messageId 집합(외부 caller 전달).
    func fetchAndExtractAll(
        after historyID: String? = nil,
        allowFoundationModels: Bool = true,
        excludingAlreadyHandledMessageIDs: Set<String> = []
    ) async throws -> (todos: [Todo], events: [(event: ExtractedEmailEvent, sourceRef: String)]) {
        let token = try await refreshTokenIfNeeded()

        let store = EmailLearningStore.shared
        let excluded = store.analyzedMessageIDs()
            .union(excludingAlreadyHandledMessageIDs)
            .union(store.dismissedMessageIDs())

        let messages = try await listRecentMessagesForExtraction(
            after: historyID,
            excludingMessageIDs: excluded,
            token: token
        )

        let ingestionEngine = EmailIngestionEngine()
        var todos: [Todo] = []
        var successfullyAnalyzedIDs: [String] = []
        for message in messages {
            do {
                todos += try await ingestionEngine.extractTodos(
                    from: message, allowFoundationModels: allowFoundationModels
                )
                successfullyAnalyzedIDs.append(message.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                logger.error("Email candidate analysis failed: \(error.localizedDescription)")
            }
        }

        // 학습 필터: 억제된 발신자 또는 이미 처리한(dismissed) messageID 제거
        // → AppDelegate·설정화면 두 ingestion 경로 모두 혜택
        let filteredTodos = todos.filter {
            !store.isSuppressed($0.sourceSenderEmail) && !store.isDismissed($0.sourceRef)
        }

        // Only eligible, unsuppressed to-dos can yield calendar events. Review,
        // rejected, dismissed, and failed-to-classify messages stay out of EventKit.
        let todoSourceRefs = Set(filteredTodos.filter { $0.triage == .todo }.map(\.sourceRef))
        let eligibleMessages = messages.filter { todoSourceRefs.contains($0.id) }
        let events: [(event: ExtractedEmailEvent, sourceRef: String)]
        do {
            events = try await ingestionEngine.extractCalendarEvents(from: eligibleMessages)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            events = []
        }
        try Task.checkCancellation()
        store.recordAnalyzed(messageIDs: successfullyAnalyzedIDs)
        return (filteredTodos, events)
    }

    /// 수동 등록용 메시지 요약 기반 할 일 초안을 생성합니다.
    /// allowFoundationModels=false 이면 규칙 기반 폴백을 사용합니다.
    func makeManualTodo(
        from message: GmailMessage,
        allowFoundationModels: Bool = true,
        language: AppLanguage = .current
    ) async -> Todo {
        await EmailIngestionEngine().makeManualTodo(
            from: message,
            allowFoundationModels: allowFoundationModels,
            language: language
        )
    }

    // MARK: - Gmail API
    func fetchInboxPage(after cursor: String?) async throws -> MailboxPage {
        let token = try await refreshTokenIfNeeded()

        let list = try await fetchMessageListPage(
            token: token,
            maxResults: MailboxPagingPolicy.pageSize,
            requiredLabelID: "INBOX",
            pageToken: cursor
        )
        let messageIDs = (list.messages ?? []).map(\.id)
        var originalIndexByID = [String: Int]()
        for (index, messageID) in messageIDs.enumerated()
            where originalIndexByID[messageID] == nil {
            originalIndexByID[messageID] = index
        }

        let outcomes = try await fetchMetadataOutcomes(ids: messageIDs, token: token)
        let messages = outcomes.compactMap { outcome -> GmailMessage? in
            switch outcome {
            case .message(let message):
                return message
            case .notFound:
                return nil
            }
        }
        .sorted { lhs, rhs in
            if lhs.receivedAt != rhs.receivedAt {
                return lhs.receivedAt > rhs.receivedAt
            }
            return originalIndexByID[lhs.id, default: .max]
                < originalIndexByID[rhs.id, default: .max]
        }

        logger.info(
            "Gmail inbox page: hydrated \(messages.count)/\(messageIDs.count) IDs; hasMore=\(list.nextPageToken != nil)"
        )
        return MailboxPage(
            messages: messages.map(mailboxMetadata),
            nextCursor: list.nextPageToken,
            newestCursor: cursor == nil ? "head" : nil
        )
    }

    /// Dormant OAuth conformance to `MailboxPagingProvider.fetchInboxUpdates(newerThan:)`.
    /// Production `.gmail` routing stays on `GmailIMAPService`'s durable UID cursor; this
    /// bounded reissue of the head page only keeps the OAuth path compiling and usable.
    func fetchInboxUpdates(newerThan cursor: String) async throws -> MailboxPage {
        let head = try await fetchInboxPage(after: nil)
        return MailboxPage(
            messages: head.messages,
            nextCursor: nil,
            newestCursor: "head",
            hasMoreUpdates: false
        )
    }

    func fetchInboxMessageIDs() async throws -> Set<String> {
        let token = try await refreshTokenIfNeeded()
        return Set(
            try await listMessageIDs(
                token: token,
                maxResults: 500,
                requiredLabelID: "INBOX"
            )
        )
    }

    func fetchMessageContent(messageID: String) async throws -> MailboxMessageContent {
        let token = try await refreshTokenIfNeeded()
        guard let message = try await fetchMessage(id: messageID, token: token) else {
            throw EmailError.apiFailed
        }
        return MailboxMessageContent(
            metadata: mailboxMetadata(from: message),
            body: message.body,
            htmlBody: message.htmlBody ?? ""
        )
    }

    private func mailboxMetadata(from message: GmailMessage) -> MailboxMessageMetadata {
        MailboxMessageMetadata(
            provider: .gmail,
            providerMessageID: message.id,
            threadID: message.threadID,
            subject: message.subject,
            from: message.from,
            snippet: message.snippet,
            receivedAt: message.receivedAt,
            isRead: !message.labelIds.contains("UNREAD"),
            isInInbox: message.labelIds.contains("INBOX"),
            gmailLabelIDs: message.labelIds,
            outlookInferenceClassificationRawValue: "",
            providerCategoryNames: [],
            providerFolderID: ""
        )
    }


    private func listRecentMessagesForExtraction(
        after historyID: String?,
        excludingMessageIDs: Set<String> = [],
        token: String
    ) async throws -> [GmailMessage] {
        // 최근 수신 메일 ID 목록 조회
        let lookbackDays = EmailAnalysisLookbackPolicy.storedLookbackDays()

        logger.debug("Listing new messages for extraction, lookbackDays: \(lookbackDays)")
        if historyID != nil {
            logger.debug("History cursor ignored by bounded extraction scan")
        }

        let cap = min(50, max(10, lookbackDays * 3))
        var targetIDs: [String] = []
        var seenIDs = excludingMessageIDs
        var seenCursors = Set<String>()
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            let page = try await fetchMessageListPage(
                token: token, maxResults: 100, requiredLabelID: "INBOX",
                lookbackDays: lookbackDays, pageToken: cursor
            )
            for message in page.messages ?? [] where seenIDs.insert(message.id).inserted {
                targetIDs.append(message.id)
                if targetIDs.count == cap { break }
            }
            cursor = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            if let cursor, !seenCursors.insert(cursor).inserted { throw EmailError.apiFailed }
        } while targetIDs.count < cap && cursor != nil
        return try await fetchMessagesInBatches(ids: targetIDs, token: token)
    }

    private func fetchMessage(id: String, token: String) async throws -> GmailMessage? {
        logger.debug("Fetching message: \(id)")
        // format=full: 모든 헤더 + MIME 트리 + snippet 포함 (format=metadata보다 크지만 본문 파싱 가능)
        let url = try messageURL(id: id, queryItems: [URLQueryItem(name: "format", value: "full")])
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw EmailError.apiFailed }
        if status == 404 { return nil }
        guard status == 200 else {
            logger.error("Gmail message fetch rejected: status \(status)")
            throw EmailError.apiFailed
        }

        let raw: RawGmailMessage
        do {
            raw = try JSONDecoder().decode(RawGmailMessage.self, from: data)
        } catch {
            logger.error("Gmail full-message decoding failed")
            throw EmailError.apiFailed
        }
        guard raw.id == id else { throw EmailError.apiFailed }
        return decodedMessage(raw, includeBody: true)
    }

    private func decodedMessage(_ raw: RawGmailMessage, includeBody: Bool) -> GmailMessage {

        let headers   = raw.payload.headers ?? []
        // RFC2047 encoded-word 디코딩 적용 (예: =?UTF-8?B?7L+g7Yyh?= → 쿠팡)

        let subject   = decodeRFC2047(headers.first { $0.name.lowercased() == "subject" }?.value ?? "(제목 없음)")
        let from      = decodeRFC2047(headers.first { $0.name.lowercased() == "from" }?.value ?? "")
        let dateStr   = headers.first { $0.name.lowercased() == "date" }?.value ?? ""
        let messageID = headers.first { $0.name.lowercased() == "message-id" }?.value ?? ""

        // 대량발송 신호 — List-Unsubscribe(RFC 2369) 또는 Precedence: bulk
        let hasUnsubscribe = headers.contains { $0.name.lowercased() == "list-unsubscribe" }
        let precedence     = headers.first { $0.name.lowercased() == "precedence" }?.value.lowercased() ?? ""
        let isBulk         = hasUnsubscribe || precedence.contains("bulk") || precedence.contains("list")

        // internalDate(epoch-ms 문자열)를 1순위 수신 시각으로 사용 — Date 헤더는 발신자 주장이라 신뢰도 낮음
        let date     = raw.internalDate.flatMap { Double($0).map { Date(timeIntervalSince1970: $0 / 1000) } }
                     ?? parseRFC2822Date(dateStr) ?? Date()
        let snippet  = raw.snippet ?? ""
        let extractedBody = includeBody ? extractPlainText(from: raw.payload) : ""
        let body = includeBody ? (extractedBody.isEmpty ? snippet : extractedBody) : ""
        let htmlBody = includeBody ? extractHTML(from: raw.payload) : nil
        let labelIds = raw.labelIds ?? []

        return GmailMessage(
            id: raw.id,
            threadID: raw.threadId ?? "",
            messageID: messageID,
            subject: subject,
            from: from,
            snippet: snippet,
            body: body,
            htmlBody: htmlBody,
            receivedAt: date,
            labelIds: labelIds,
            isBulk: isBulk,
            provider: .gmail,
            providerMessageID: raw.id
        )
    }

    /// 헤더+스니펫만 가져오는 경량 fetch (format=metadata) — 목록 표시용.
    /// 응답 크기: ~500B (format=full 대비 100× 감소). 본문은 상세 화면에서 lazy-load.
    private func fetchMessageMetadata(id: String, token: String) async throws -> GmailMessage? {
        let url = try messageURL(id: id, queryItems: [URLQueryItem(name: "format", value: "metadata")]
            + ["Subject", "From", "Date", "Message-ID", "List-Unsubscribe", "Precedence"].map {
                URLQueryItem(name: "metadataHeaders", value: $0)
            })
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EmailError.apiFailed }
        if http.statusCode == 404 {
            logger.debug("fetchMessageMetadata tombstone for \(id)")
            return nil
        }
        guard http.statusCode == 200 else {
            logger.error("fetchMessageMetadata failed for \(id): status \(http.statusCode)")
            throw EmailError.apiFailed
        }
        do {
            let raw = try JSONDecoder().decode(RawGmailMessage.self, from: data)

            guard raw.id == id else { throw EmailError.apiFailed }
            return decodedMessage(raw, includeBody: false)
        } catch {
            logger.error("fetchMessageMetadata decode failed for \(id)")
            throw EmailError.apiFailed
        }

    }


    /// 특정 메시지의 전체 본문(format=full)을 가져옴. 상세 화면 lazy-load용.
    func fetchFullMessage(id: String) async throws -> GmailMessage? {
        let token = try await refreshTokenIfNeeded()
        return try await fetchMessage(id: id, token: token)
    }

    /// 메시지 목록을 배치로 나누어 조회하여 429(Too Many Requests) 방지.
    /// isMetadata=true 이면 format=metadata(경량), false 이면 format=full(전체 본문).
    private func fetchMessagesInBatches(
        ids: [String], token: String, batchSize: Int = 10, isMetadata: Bool = false
    ) async throws -> [GmailMessage] {
        var results: [GmailMessage] = []
        let chunks = ids.chunked(into: batchSize)
        for (index, chunk) in chunks.enumerated() {
            logger.info("Fetching batch \(index + 1)/\(chunks.count) (\(chunk.count) messages)\(isMetadata ? " [metadata]" : "")")
            let chunkMessages = try await withThrowingTaskGroup(of: GmailMessage?.self) { group in
                for id in chunk {
                    group.addTask { [weak self] in
                        guard let self else { return nil }
                        return isMetadata
                            ? try await self.fetchMessageMetadata(id: id, token: token)
                            : try await self.fetchMessage(id: id, token: token)
                    }
                }
                var batchResults: [GmailMessage] = []
                for try await msg in group { if let m = msg { batchResults.append(m) } }
                return batchResults
            }
            results.append(contentsOf: chunkMessages)
            if index < chunks.count - 1 {
                // 메타데이터 요청은 응답이 작아 딜레이 단축 (50ms), 전체 본문은 100ms 유지
                try await Task.sleep(nanoseconds: isMetadata ? 50_000_000 : 100_000_000)
            }
        }
        return results
    }

    /// Metadata sync preserves one outcome per requested ID. Full-body callers
    /// intentionally keep using `fetchMessagesInBatches`.
    private func fetchMetadataOutcomes(ids: [String], token: String) async throws -> [GmailMetadataOutcome] {
        var outcomes = [GmailMetadataOutcome]()
        let chunks = ids.chunked(into: 10)
        for (index, chunk) in chunks.enumerated() {
            let chunkOutcomes = try await withThrowingTaskGroup(of: GmailMetadataOutcome.self) { group in
                for id in chunk {
                    group.addTask { [weak self] in
                        guard let self else { throw EmailError.apiFailed }
                        guard let message = try await self.fetchMessageMetadata(id: id, token: token) else {
                            return .notFound(id: id)
                        }
                        return .message(message)
                    }
                }
                var results = [GmailMetadataOutcome]()
                for try await outcome in group { results.append(outcome) }
                return results
            }
            outcomes.append(contentsOf: chunkOutcomes)
            if index < chunks.count - 1 {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return outcomes
    }

    // MARK: - 이메일 뷰어: 최근 메일 전체 fetch

    /// 읽음/안읽음 관계없이 최근 메일 전체를 가져옴.
    /// 내부적으로 lookback 범위 전체 message id를 페이지네이션으로 수집해
    /// 로컬 stale 메일 prune 기준도 함께 만든다.
    func fetchAllRecentMessages() async throws -> [GmailMessage] {
        try await fetchRecentMessageSyncSnapshot().messages
    }


    private func fetchMessageListPage(
        token: String,
        maxResults: Int,
        requiredLabelID: String? = nil,
        lookbackDays: Int? = nil,
        pageToken: String? = nil
    ) async throws -> MessageListResponse {
        var urlComponents = URLComponents(
            string: "https://gmail.googleapis.com/gmail/v1/users/me/messages"
        )!
        var queryItems = [
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]
        if let lookbackDays {
            queryItems.append(URLQueryItem(name: "q", value: "newer_than:\(lookbackDays)d"))
        }
        if let requiredLabelID {
            queryItems.append(URLQueryItem(name: "labelIds", value: requiredLabelID))
        }
        if let pageToken, !pageToken.isEmpty {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        urlComponents.queryItems = queryItems

        var request = URLRequest(url: urlComponents.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw EmailError.apiFailed
        }
        do {
            return try JSONDecoder().decode(MessageListResponse.self, from: data)
        } catch {
            throw EmailError.apiFailed
        }
    }


    private func listMessageIDs(
        token: String,
        maxResults: Int = 100,
        requiredLabelID: String? = nil,
        lookbackDays: Int? = nil
    ) async throws -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        var seenCursors = Set<String>()
        var pageToken: String?
        repeat {
            try Task.checkCancellation()
            let list = try await fetchMessageListPage(
                token: token,
                maxResults: maxResults,
                requiredLabelID: requiredLabelID,
                lookbackDays: lookbackDays,
                pageToken: pageToken
            )
            for message in list.messages ?? [] where seen.insert(message.id).inserted {
                ids.append(message.id)
            }
            pageToken = list.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            if let pageToken, !seenCursors.insert(pageToken).inserted { throw EmailError.apiFailed }
        } while pageToken != nil
        return ids
    }

    private func fetchRecentMessageSyncSnapshot() async throws -> RecentMessageSyncSnapshot {
        let token = try await refreshTokenIfNeeded()

        let lookbackDays = EmailAnalysisLookbackPolicy.storedLookbackDays()
        let now = Date()
        let activeMailboxMessageIDs = try await listMessageIDs(
            token: token
        )
        let recentInboxMessageIDs = try await listMessageIDs(
            token: token,
            requiredLabelID: "INBOX",
            lookbackDays: lookbackDays
        )
        let messages = try await fetchMessagesInBatches(
            ids: recentInboxMessageIDs,
            token: token,
            isMetadata: true
        )

        return RecentMessageSyncSnapshot(
            messages: messages.sorted { $0.receivedAt > $1.receivedAt },
            activeMailboxMessageIDs: Set(activeMailboxMessageIDs),
            recentInboxMessageIDs: Set(recentInboxMessageIDs),
            lookbackCutoff: EmailAnalysisLookbackPolicy.cutoff(now: now, lookbackDays: lookbackDays)
        )
    }


    // MARK: - MIME Body Extraction

    /// MIME 트리에서 text/html 파트를 우선 추출 (WKWebView 렌더링용).
    /// multipart/alternative → text/html 우선, mixed/related → 재귀 탐색.
    private func extractHTML(from payload: RawGmailMessage.Payload) -> String? {
        guard !isAttachment(payload) else { return nil }
        let mime = payload.mimeType ?? ""

        if mime.hasPrefix("text/html"),
           let data = payload.body?.data, !data.isEmpty {
            return decodeBase64URL(data)
        }

        guard let parts = payload.parts, !parts.isEmpty else { return nil }

        if mime.hasPrefix("multipart/alternative") {
            // alternative: text/html 우선
            if let html = parts.first(where: { !isAttachment($0) && $0.mimeType?.hasPrefix("text/html") == true }),
               let data = html.body?.data, !data.isEmpty {
                return decodeBase64URL(data)
            }
        }

        for part in parts {
            if let html = extractHTML(from: part) { return html }
        }
        return nil
    }

    /// MIME 페이로드 트리를 재귀 탐색해 text/plain 우선, 없으면 text/html 태그 제거 반환.
    private func extractPlainText(from payload: RawGmailMessage.Payload) -> String {
        guard !isAttachment(payload) else { return "" }
        let mime = payload.mimeType ?? ""

        // text/plain 직접 포함
        if mime.hasPrefix("text/plain"),
           let data = payload.body?.data, !data.isEmpty {
            return decodeBase64URL(data) ?? ""
        }

        // text/html 직접 포함
        if mime.hasPrefix("text/html"),
           let data = payload.body?.data, !data.isEmpty {
            return stripHTML(decodeBase64URL(data) ?? "")
        }

        guard let parts = payload.parts, !parts.isEmpty else { return "" }

        // multipart/alternative: text/plain 먼저, 없으면 text/html
        if mime.hasPrefix("multipart/alternative") {
            if let plain = parts.first(where: { !isAttachment($0) && $0.mimeType?.hasPrefix("text/plain") == true }),
               let data = plain.body?.data, !data.isEmpty {
                return decodeBase64URL(data) ?? ""
            }
            if let html = parts.first(where: { !isAttachment($0) && $0.mimeType?.hasPrefix("text/html") == true }),
               let data = html.body?.data, !data.isEmpty {
                return stripHTML(decodeBase64URL(data) ?? "")
            }
        }

        // multipart/mixed, multipart/related 등 — 재귀 탐색
        for part in parts {
            let text = extractPlainText(from: part)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private func isAttachment(_ payload: RawGmailMessage.Payload) -> Bool {
        if let filename = payload.filename, !filename.isEmpty { return true }
        return payload.headers?.contains {
            $0.name.lowercased() == "content-disposition"
                && $0.value.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
        } == true
    }

    // MARK: - Base64URL Decoder

    private func decodeBase64URL(_ string: String) -> String? {
        var b64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem != 0 { b64 += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - HTML Stripper

    private func stripHTML(_ html: String) -> String {
        var text = html
        // ① style/script/주석 블록 전체 제거 — [\s\S] 는 개행 포함 (.은 개행 미처리)
        let blockPatterns = [
            "<style[^>]*>[\\s\\S]*?</style>",
            "<script[^>]*>[\\s\\S]*?</script>",
            "<!--[\\s\\S]*?-->",
        ]
        for pat in blockPatterns {
            if let re = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) {
                text = re.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
                )
            }
        }
        // ② 블록 태그 → 줄바꿈
        let blockTags = ["</p>", "</div>", "<br>", "<br/>", "<br />", "</li>",
                         "</h1>", "</h2>", "</h3>", "</h4>", "</tr>"]
        for tag in blockTags {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        // ③ 나머지 태그 제거
        if let re = try? NSRegularExpression(pattern: "<[^>]+>") {
            text = re.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
            )
        }
        // 기본 HTML 엔티티 복원
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
            ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")
        ]
        for (ent, ch) in entities { text = text.replacingOccurrences(of: ent, with: ch) }
        // 연속 빈 줄 정리
        if let re = try? NSRegularExpression(pattern: "\\n{3,}") {
            text = re.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n\n"
            )
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, codeVerifier: String, generation: UUID) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "code": code, "client_id": clientID, "redirect_uri": redirectURI,
            "grant_type": "authorization_code", "code_verifier": codeVerifier
        ])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard credentialGeneration == generation else { throw CancellationError() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw EmailError.authorizationFailed
        }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        try saveTokens(accessToken: tokens.access_token, refreshToken: tokens.refresh_token,
                       idToken: tokens.id_token, expiresIn: tokens.expires_in, explicitSignIn: true)
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        // Form values must escape '+' as well as '&' and '='.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
    }

    private func refreshTokenIfNeeded() async throws -> String {
        try Task.checkCancellation()
        guard !signedOut else { throw EmailError.notAuthenticated }
        let tokens = try loadTokens()
        guard tokens.scopeVersion == requiredTokenScopeVersion else {
            try clearTokensIfScopeIsStale(loadedTokens: tokens)
            throw EmailError.notAuthenticated
        }
        if let accessToken = tokens.accessToken, !accessToken.isEmpty,
           accessTokenIsFresh(tokens.accessTokenExpiry) { return accessToken }
        guard let refresh = tokens.refreshToken, !refresh.isEmpty else {
            throw EmailError.notAuthenticated
        }
        let generation = credentialGeneration
        let pending: (id: UUID, task: Task<Void, Error>)
        if let activeTokenRefreshTask {
            pending = activeTokenRefreshTask
        } else {
            pending = (UUID(), Task { [self] in
                try await performTokenRefresh(refreshToken: refresh, priorIDToken: tokens.idToken, generation: generation)
            })
            activeTokenRefreshTask = pending
        }
        defer {
            // An old waiter must not clear a newer account's refresh task.
            if activeTokenRefreshTask?.id == pending.id { activeTokenRefreshTask = nil }
        }
        try await pending.task.value
        try Task.checkCancellation()
        guard credentialGeneration == generation, !signedOut,
              let token = try loadTokens().accessToken, !token.isEmpty else {
            throw EmailError.notAuthenticated
        }
        return token
    }

    private func performTokenRefresh(refreshToken: String, priorIDToken: String?, generation: UUID) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID
        ])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard credentialGeneration == generation else { throw CancellationError() }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw EmailError.apiFailed }
        guard status == 200 else {
            // Only an explicit revocation invalidates stored credentials. Transport,
            // quota, and provider outages must not sign the user out.
            let rejection = try? JSONDecoder().decode(OAuthRejection.self, from: data)
            if status == 400, rejection?.error == "invalid_grant" {
                signedOut = true
                try deleteTokens()
                NotificationCenter.default.post(name: .gmailAuthChanged, object: false)
                throw EmailError.notAuthenticated
            }
            logger.error("Gmail token refresh rejected: status \(status)")
            throw EmailError.apiFailed
        }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        try saveTokens(accessToken: tokens.access_token, refreshToken: tokens.refresh_token ?? refreshToken,
                       idToken: tokens.id_token ?? priorIDToken, expiresIn: tokens.expires_in)
    }
    private func buildAuthURL(state: String, codeChallenge: String) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url
    }

    private func makeOAuthBinding() throws -> (state: String, verifier: String, challenge: String) {
        let verifier = try randomOAuthValue(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return (state: try randomOAuthValue(byteCount: 32), verifier: verifier, challenge: challenge)
    }

    private func randomOAuthValue(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw EmailError.authorizationFailed
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain (KeychainStore 위임)

    private struct StoredTokens: Codable {
        var accessToken: String?
        var refreshToken: String?
        var idToken: String?
        var accessTokenExpiry: Date?
        var scopeVersion: String?
    }

    private static let legacyTokenAccounts = [
        "access_token", "refresh_token", "id_token", "access_token_expires_at", "scope_version"
    ]

    private static func readPersistedTokens() throws -> StoredTokens {
        let service = "pieroot.todo.gmail"
        if let value = try KeychainStore.getChecked(service: service, account: "oauth_tokens") {
            return try JSONDecoder().decode(StoredTokens.self, from: Data(value.utf8))
        }
        // Migrate existing installations only. Never combine legacy fields with
        // a current bundle; a new authorization cannot inherit an old account's ID.
        return try StoredTokens(
            accessToken: KeychainStore.getChecked(service: service, account: "access_token"),
            refreshToken: KeychainStore.getChecked(service: service, account: "refresh_token"),
            idToken: KeychainStore.getChecked(service: service, account: "id_token"),
            accessTokenExpiry: KeychainStore.getChecked(service: service, account: "access_token_expires_at")
                .flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)),
            scopeVersion: KeychainStore.getChecked(service: service, account: "scope_version")
        )
    }

    private func loadTokens() throws -> StoredTokens {
        let tokens = try Self.readPersistedTokens()
        if try KeychainStore.getChecked(service: keychainService, account: "oauth_tokens") == nil,
           tokens.accessToken != nil || tokens.refreshToken != nil {
            try persist(tokens)
        }
        return tokens
    }

    private func saveTokens(accessToken: String, refreshToken: String?, idToken: String?, expiresIn: Int?, explicitSignIn: Bool = false) throws {
        guard !accessToken.isEmpty else { throw EmailError.authorizationFailed }
        try persist(StoredTokens(
            accessToken: accessToken, refreshToken: refreshToken, idToken: idToken,
            accessTokenExpiry: Date().addingTimeInterval(TimeInterval(expiresIn ?? 3600)),
            scopeVersion: requiredTokenScopeVersion
        ), explicitSignIn: explicitSignIn)
        signedOut = false
    }

    private func persist(_ tokens: StoredTokens, explicitSignIn: Bool = false) throws {
        let value = String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self)
        // One Keychain update commits every account-bound field together.
        if explicitSignIn { try KeychainStore.setGmailAfterExplicitSignIn(value: value) }
        else { try KeychainStore.setChecked(service: keychainService, account: "oauth_tokens", value: value) }
        for account in Self.legacyTokenAccounts {
            KeychainStore.deleteAny(service: keychainService, account: account)
        }
    }

    private func accessTokenIsFresh(_ expiry: Date?, now: Date = Date()) -> Bool {
        guard let expiry else { return false }
        return expiry.timeIntervalSince(now) > accessTokenRefreshSkew
    }

    private func deleteTokens() throws {
        // A single service deletion removes both the bundle and migration leftovers.
        try KeychainStore.deleteChecked(service: keychainService)
    }

    // MARK: - Read State Sync

    /// REST uses an immutable provider-native message ID, never a thread ID or UID.
    private func messageURL(id: String, action: String? = nil, queryItems: [URLQueryItem] = []) throws -> URL {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw EmailError.apiFailed
        }
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.path += "/" + id
        if let action { components.path += "/" + action }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw EmailError.apiFailed }
        return url
    }

    private func validateMutationIdentity(messageID: String, expectedGlobalMessageID: String?) throws {
        guard let expectedGlobalMessageID else { return }
        // Gmail REST IDs are the hexadecimal representation of X-GM-MSGID.
        guard let expected = UInt64(expectedGlobalMessageID), expected > 0,
              UInt64(messageID, radix: 16) == expected else {
            throw MailboxMutationError.mutationIdentityUnavailable(provider: .gmail)
        }
    }

    /// Gmail 서버에서 UNREAD 라벨을 제거하여 읽음 처리.
    /// `gmail.modify` 스코프 필요 — 이전 `gmail.readonly` 토큰이면 403으로 무음 실패.
    func markAsRead(
        messageID: String,
        expectedGlobalMessageID: String? = nil
    ) async throws {
        try validateMutationIdentity(messageID: messageID, expectedGlobalMessageID: expectedGlobalMessageID)
        logger.info("Marking message as read: \(messageID)")
        let token = try await refreshTokenIfNeeded()
        let url = try messageURL(id: messageID, action: "modify")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["removeLabelIds": ["UNREAD"]])
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            logger.error("markAsRead failed: No HTTP response")
            throw EmailError.apiFailed
        }

        logger.info("markAsRead response status: \(http.statusCode)")

        if !(200...299).contains(http.statusCode) {
            logger.error("Gmail mark-as-read rejected: status \(http.statusCode)")
            throw EmailError.apiFailed
        }
        logger.info("Message \(messageID) marked as read successfully")
    }

    func trashMessage(
        messageID: String,
        expectedGlobalMessageID: String? = nil
    ) async throws {
        try validateMutationIdentity(messageID: messageID, expectedGlobalMessageID: expectedGlobalMessageID)
        logger.info("Trashing message: \(messageID)")
        let token = try await refreshTokenIfNeeded()

        let url = try messageURL(id: messageID, action: "trash")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            logger.error("trashMessage failed: No HTTP response")
            throw EmailError.apiFailed
        }

        logger.info("trashMessage response status: \(http.statusCode)")

        if !(200...299).contains(http.statusCode) {
            logger.error("Gmail trash rejected: status \(http.statusCode)")
            throw EmailError.apiFailed
        }
        logger.info("Message \(messageID) moved to trash successfully")
    }
    // MARK: - Date Parsing

    private func parseRFC2822Date(_ string: String) -> Date? {
        // Gmail Date 헤더는 여러 RFC2822 변형을 사용 — 포맷 순서대로 시도
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",   // 표준: Mon, 01 Jan 2024 12:00:00 +0900
            "EEE, d MMM yyyy HH:mm:ss Z",    // 날짜 단자리: Mon, 1 Jan 2024 ...
            "dd MMM yyyy HH:mm:ss Z",         // 요일 생략: 01 Jan 2024 12:00:00 +0900
            "d MMM yyyy HH:mm:ss Z",          // 요일+날짜 단자리 생략
            "EEE, dd MMM yyyy HH:mm Z",       // 초 생략: Mon, 01 Jan 2024 12:00 +0900
            "EEE, d MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm Z",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // 타임존 약어(GMT, UTC 등)까지 처리하려면 zone 파서가 필요
        let cleaned = string.trimmingCharacters(in: .whitespaces)
                            .components(separatedBy: " (").first ?? string  // "(KST)" 등 제거
        for fmt in formats {
            formatter.dateFormat = fmt
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    // MARK: - RFC2047 Header Decoder

    /// Gmail format=full 응답의 헤더 값은 RFC2047 encoded-word 형식일 수 있음.
    /// 예: =?UTF-8?B?7L+g7Yyh?= <noreply@coupang.com>  →  쿠팡 <noreply@coupang.com>
    /// B(Base64) 및 Q(Quoted-Printable) 인코딩, 임의 charset 지원.
    private func decodeRFC2047(_ header: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: "=\\?([^?\\s]+)\\?([BbQq])\\?([^?]*)\\?="
        ) else { return header }

        let nsRange = NSRange(header.startIndex..., in: header)
        var result  = ""
        var cursor  = header.startIndex

        for match in re.matches(in: header, range: nsRange) {
            guard let fullRange    = Range(match.range(at: 0), in: header),
                  let charsetRange = Range(match.range(at: 1), in: header),
                  let encRange     = Range(match.range(at: 2), in: header),
                  let textRange    = Range(match.range(at: 3), in: header)
            else { continue }

            // encoded-word 앞 텍스트 보존
            result += header[cursor..<fullRange.lowerBound]
            cursor  = fullRange.upperBound

            let charset  = String(header[charsetRange])
            let encoding = String(header[encRange]).uppercased()
            let encoded  = String(header[textRange])

            // IANA charset → String.Encoding
            let cfEnc = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            let strEnc: String.Encoding
            if cfEnc == kCFStringEncodingInvalidId {
                strEnc = .utf8
            } else {
                strEnc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
            }

            var decoded: String?
            if encoding == "B" {
                // Base64 디코딩
                var b64 = encoded
                let pad = b64.count % 4
                if pad != 0 { b64 += String(repeating: "=", count: 4 - pad) }
                if let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                    decoded = String(data: data, encoding: strEnc) ?? String(data: data, encoding: .utf8)
                }
            } else {
                // Quoted-Printable 디코딩
                decoded = decodeRFC2047QP(encoded, encoding: strEnc)
            }

            result += decoded ?? String(header[fullRange])
        }

        result += header[cursor...]

        // RFC2047: 인접 encoded-word 사이 공백(WSP)은 무시 규칙이나
        // 간단히 앞뒤 공백만 정리 (실무상 충분)
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Quoted-Printable 디코딩 (RFC2047 Q 인코딩 전용: _ = 0x20, =XX = hex byte)
    private func decodeRFC2047QP(_ text: String, encoding: String.Encoding) -> String? {
        var bytes: [UInt8] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "_" {
                bytes.append(0x20)   // RFC2047: _ → SP
                idx = text.index(after: idx)
            } else if ch == "=" {
                let hi = text.index(after: idx)
                guard hi < text.endIndex else { bytes.append(0x3D); idx = hi; continue }
                let lo = text.index(after: hi)
                guard lo < text.endIndex else { bytes.append(0x3D); idx = hi; continue }
                let hexStr = String([text[hi], text[lo]])
                if let byte = UInt8(hexStr, radix: 16) {
                    bytes.append(byte)
                    idx = text.index(after: lo)
                } else {
                    bytes.append(0x3D)
                    idx = hi
                }
            } else {
                bytes += ch.utf8
                idx = text.index(after: idx)
            }
        }
        return String(bytes: bytes, encoding: encoding) ?? String(bytes: bytes, encoding: .utf8)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Gmail 인증 상태 변경(연결/해제)시 발송 — `object: Bool` (true=연결, false=해제)
    static let gmailAuthChanged = Notification.Name("pieroot.todo.gmailAuthChanged")
}

// MARK: - Error

enum EmailError: LocalizedError {
    case invalidConfiguration
    case qaOAuthNotConfigured
    case authorizationFailed
    case notAuthenticated
    case apiFailed

    var errorDescription: String? {
        errorDescription(language: .current)
    }

    func errorDescription(language: AppLanguage) -> String {
        switch self {
        case .invalidConfiguration:
            return AppLanguage.localized("error.mail.service.invalidConfiguration", defaultValue: "Gmail OAuth configuration is invalid.", language: language)
        case .qaOAuthNotConfigured:
            return AppLanguage.localized("error.mail.service.qaOAuthNotConfigured", defaultValue: "Gmail sign-in for SIFT QA requires its own registered Google iOS OAuth client.", language: language)
        case .authorizationFailed:
            return AppLanguage.localized("error.mail.service.authorizationFailed", defaultValue: "Gmail authorization failed.", language: language)
        case .notAuthenticated:
            return AppLanguage.localized("error.mail.service.notAuthenticated", defaultValue: "You are not signed in to Gmail.", language: language)
        case .apiFailed:
            return AppLanguage.localized("error.mail.service.apiFailed", defaultValue: "The Gmail API request failed.", language: language)
        }
    }
}

// MARK: - API Response Models

private struct MessageListResponse: Decodable {
    struct MessageRef: Decodable { let id: String }
    let messages: [MessageRef]?
    let nextPageToken: String?
}

private struct RawGmailMessage: Decodable {
    struct Payload: Decodable {
        struct Header: Decodable { let name: String; let value: String }
        struct Body: Decodable { let data: String? }
        let mimeType: String?
        let filename: String?
        let headers: [Header]?
        let body: Body?
        /// 재귀 파트 — Array는 힙 참조이므로 구조체 재귀가 성립
        let parts: [Payload]?
    }
    let id: String
    let threadId: String?
    let snippet: String?
    let payload: Payload
    /// Gmail 카테고리 라벨 (예: ["INBOX", "CATEGORY_PROMOTIONS", "UNREAD"])
    let labelIds: [String]?
    /// epoch-ms 문자열 — Date 헤더(발신자 주장)보다 신뢰도 높은 실제 수신 시각
    let internalDate: String?
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
    let id_token: String?
}

private struct OAuthRejection: Decodable {
    let error: String
}

// MARK: - ASWebAuthenticationSession Presentation Context

private final class WindowProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WindowProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // iOS 26: UIWindowScene.windows와 UIWindow.init() 모두 deprecated
        // keyWindow 및 UIWindow(windowScene:)으로 대체
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        if let window = scene?.keyWindow { return window }
        if let scene { return UIWindow(windowScene: scene) }
        fatalError("No UIWindowScene — unreachable in a running iOS 26 app")
    }
}
