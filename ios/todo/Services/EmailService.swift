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
            return language == .english
                ? "The change was applied by the provider, but the local state could not be saved. Sync the mailbox again."
                : "프로바이더에는 반영되었지만 로컬 상태 저장에 실패했습니다. 메일 목록을 다시 동기화합니다."
        case .mutationIdentityUnavailable(let provider):
            let providerName = provider == .outlook ? "Outlook" : "Gmail"
            return language == .english
                ? "\(providerName) could not verify this message. Refresh the mailbox and try again."
                : "\(providerName)에서 이 메일을 확인할 수 없습니다. 메일함을 새로 고친 뒤 다시 시도하세요."
        }
    }
}

// MARK: - Email Service

/// Gmail OAuth + 메시지 fetch + 온디바이스 FM 할 일 추출 (v2)
///
/// 사전 준비:
/// 1. Google Cloud Console에서 OAuth 클라이언트 ID 발급 (iOS 앱 유형)
/// 2. 리디렉트 URI 스킴을 Info.plist CFBundleURLSchemes에 등록
/// 3. `clientID`와 `clientSecret`에 실제 값 입력
final class EmailService: NSObject, MailboxPagingProvider {
    static let shared = EmailService()
    let provider: MailProvider = .gmail
    private override init() {}

    // MARK: - Configuration
    //
    // Native OAuth clients are public clients. Authorization-code binding is
    // provided by PKCE; do not embed a client secret in the application.
    private let clientID     = "746219534143-ij6p50gff6as4hn2bbhdc9a1u6os3jmp.apps.googleusercontent.com"
    private let redirectURI  = "com.googleusercontent.apps.746219534143-ij6p50gff6as4hn2bbhdc9a1u6os3jmp:/oauth2callback"
    private let scope        = "openid email profile https://www.googleapis.com/auth/gmail.modify"
    private let requiredTokenScopeVersion = "gmail.modify.openid.v2"
    private let tokenScopeVersionAccount = "scope_version"
    private let accessTokenExpiryAccount = "access_token_expires_at"
    private let accessTokenRefreshSkew: TimeInterval = 300

    private let keychainService = "pieroot.todo.gmail"
    static var firebaseIDToken: String? {
        KeychainStore.get(service: "pieroot.todo.gmail", account: "id_token")
    }

    /// Reads only the locally-held ID-token subject; callers must never persist it.
    static var authenticatedAccountSubject: String? {
        guard let token = firebaseIDToken,
              let payloadPart = token.split(separator: ".").dropFirst().first
        else { return nil }
        let padding = String(repeating: "=", count: (4 - payloadPart.count % 4) % 4)
        guard let data = Data(base64Encoded: String(payloadPart) + padding, options: .ignoreUnknownCharacters),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = payload["sub"] as? String,
              !subject.isEmpty
        else { return nil }
        return subject
    }
    private let logger = Logger(subsystem: "pieroot.todo", category: "GmailOAuth")
    private let tokenRefreshLock = NSLock()
    private var activeTokenRefreshTask: Task<Void, Error>?
    
    var session: URLSession = .shared

    // ASWebAuthenticationSession은 완료까지 강한 참조를 유지해야 합니다.

    // withCheckedThrowingContinuation 클로저 리턴 후 로컬 변수가 해제되는 것을 방지합니다.
    private var authSession: ASWebAuthenticationSession?

    // MARK: - Authorization State

    var isAuthenticated: Bool {
        let tokens = loadTokens()
        guard tokens.accessToken != nil || tokens.refreshToken != nil else { return false }
        guard tokens.scopeVersion == requiredTokenScopeVersion else {
            clearTokensIfScopeIsStale(loadedTokens: tokens)
            return false
        }
        return tokens.accessToken != nil
    }

    private func clearTokensIfScopeIsStale(
        loadedTokens: (accessToken: String?, refreshToken: String?, accessTokenExpiry: Date?, scopeVersion: String?)? = nil
    ) {
        let tokens = loadedTokens ?? loadTokens()
        guard tokens.accessToken != nil || tokens.refreshToken != nil else { return }
        guard tokens.scopeVersion != requiredTokenScopeVersion else { return }
        deleteTokens()
        NotificationCenter.default.post(name: .gmailAuthChanged, object: false)
    }
    // MARK: - OAuth 2.0 (ASWebAuthenticationSession)

    // ASWebAuthenticationSession은 반드시 메인 스레드에서 실행해야 합니다.
    @MainActor
    func authenticate() async throws {
        logger.info("Starting Gmail OAuth authentication")
        let binding = makeOAuthBinding()
        guard let authURL = buildAuthURL(state: binding.state, codeChallenge: binding.challenge) else {
            logger.error("Failed to build auth URL: invalid configuration")
            throw EmailError.invalidConfiguration
        }
        let callbackScheme = "com.googleusercontent.apps.746219534143-ij6p50gff6as4hn2bbhdc9a1u6os3jmp"

        let code: String = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                self?.authSession = nil
                if let error {
                    DiagnosticRecorder.shared.record(
                        error: error,
                        component: "mail.gmail",
                        operation: "authenticate"
                    )
                    self?.logger.error("ASWebAuthenticationSession failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                guard let url = callbackURL,
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                      let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value,
                      returnedState == binding.state
                else {
                    DiagnosticRecorder.shared.record(
                        error: EmailError.authorizationFailed,
                        component: "mail.gmail",
                        operation: "authenticate"
                    )
                    self?.logger.error("Authorization failed: missing code or invalid state")
                    continuation.resume(throwing: EmailError.authorizationFailed)
                    return
                }
                self?.logger.info("OAuth callback validated")
                continuation.resume(returning: code)
            }

            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = WindowProvider.shared
            authSession = session
            session.start()
        }

        try await exchangeCodeForTokens(code: code, codeVerifier: binding.verifier)
        logger.info("Gmail authentication completed successfully")
        NotificationCenter.default.post(name: .gmailAuthChanged, object: true)
    }

    func signOut() {
        deleteTokens()
        NotificationCenter.default.post(name: .gmailAuthChanged, object: false)
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
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        var upsertedMessageCount = 0
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
                emailContext.insert(email)
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
            prunedTodoCount: prunedTodoCount
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
        for message in messages {
            todos += (try? await ingestionEngine.extractTodos(from: message, allowFoundationModels: allowFoundationModels)) ?? []
        }
        let events = (try? await ingestionEngine.extractCalendarEvents(from: messages)) ?? []

        // 추출 완료 메시지 ID를 분석 이력으로 기록 — 기간 반복 시 중복 fetch/분석 방지.
        store.recordAnalyzed(messageIDs: messages.map(\.id))

        // 학습 필터: 억제된 발신자 또는 이미 처리한(dismissed) messageID 제거
        // → AppDelegate·설정화면 두 ingestion 경로 모두 혜택
        let filteredTodos = todos.filter {
            !store.isSuppressed($0.sourceSenderEmail) && !store.isDismissed($0.sourceRef)
        }

        // 캘린더 이벤트도 동일 기준으로 필터:
        // - extractTodos에서 triage == .todo 로 확정된 항목의 메시지만 캘린더에 등록
        // - review·drop(SOCIAL/FORUMS)·억제·dismissed는 캘린더에서도 제외
        // - 이렇게 하지 않으면 우리카드 약관 같은 review 메일이 사용자 캘린더에도 나타남
        let todoSourceRefs = Set(filteredTodos.filter { $0.triage == .todo }.map { $0.sourceRef })
        let filteredEvents = events.filter { todoSourceRefs.contains($0.sourceRef) }

        return (filteredTodos, filteredEvents)
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
        if let ignoredHistoryID = historyID {
            logger.debug("historyID 기반 조회는 users.messages.list에서 미지원: \(ignoredHistoryID)")
        }

        let list = try await fetchMessageListPage(
            token: token,
            maxResults: 100,
            requiredLabelID: "INBOX",
            lookbackDays: lookbackDays
        )
        guard let messageIDs = list.messages else {
            logger.info("No new messages found")
            return []
        }

        // 각 메시지 본문 조회 (배치 처리로 429 방지)
        let cap = min(50, max(10, lookbackDays * 3))
        let targetIDs = messageIDs
            .filter { !excludingMessageIDs.contains($0.id) }
            .prefix(cap)
            .map { $0.id }
        logger.debug(
            "Gmail analysis scan: listed \(messageIDs.count) recent inbox IDs; fetching \(targetIDs.count) unhandled messages (cap \(cap))"
        )

        return try await fetchMessagesInBatches(ids: Array(targetIDs), token: token)
    }

    private func fetchMessage(id: String, token: String) async throws -> GmailMessage? {
        logger.debug("Fetching message: \(id)")
        // format=full: 모든 헤더 + MIME 트리 + snippet 포함 (format=metadata보다 크지만 본문 파싱 가능)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "no body"
            logger.error("fetchMessage failed for \(id): status \(httpResponse.statusCode), body: \(errorBody)")
            return nil
        }

        let raw: RawGmailMessage
        do {
            raw = try JSONDecoder().decode(RawGmailMessage.self, from: data)
        } catch {
            logger.error("Failed to decode message \(id): \(error.localizedDescription)")
            throw error
        }

        let headers   = raw.payload.headers ?? []
        // RFC2047 encoded-word 디코딩 적용 (예: =?UTF-8?B?7L+g7Yyh?= → 쿠팡)

        let subject   = decodeRFC2047(headers.first { $0.name == "Subject" }?.value ?? "(제목 없음)")
        let from      = decodeRFC2047(headers.first { $0.name == "From" }?.value ?? "")
        let dateStr   = headers.first { $0.name == "Date" }?.value ?? ""
        let messageID = headers.first { $0.name == "Message-ID" }?.value ?? ""

        // 대량발송 신호 — List-Unsubscribe(RFC 2369) 또는 Precedence: bulk
        let hasUnsubscribe = headers.contains { $0.name.lowercased() == "list-unsubscribe" }
        let precedence     = headers.first { $0.name.lowercased() == "precedence" }?.value.lowercased() ?? ""
        let isBulk         = hasUnsubscribe || precedence.contains("bulk") || precedence.contains("list")

        // internalDate(epoch-ms 문자열)를 1순위 수신 시각으로 사용 — Date 헤더는 발신자 주장이라 신뢰도 낮음
        let date     = raw.internalDate.flatMap { Double($0).map { Date(timeIntervalSince1970: $0 / 1000) } }
                     ?? parseRFC2822Date(dateStr) ?? Date()
        let snippet  = raw.snippet ?? ""
        let extractedBody = extractPlainText(from: raw.payload)
        let body     = extractedBody.isEmpty ? snippet : extractedBody
        let htmlBody = extractHTML(from: raw.payload)
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
        let urlStr = "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=metadata"
            + "&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date"
            + "&metadataHeaders=Message-ID&metadataHeaders=List-Unsubscribe&metadataHeaders=Precedence"
        var request = URLRequest(url: URL(string: urlStr)!)
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

            let headers   = raw.payload.headers ?? []
            let subject   = decodeRFC2047(headers.first { $0.name == "Subject"    }?.value ?? "(제목 없음)")
            let from      = decodeRFC2047(headers.first { $0.name == "From"       }?.value ?? "")
            let dateStr   = headers.first { $0.name == "Date"       }?.value ?? ""
            let messageID = headers.first { $0.name == "Message-ID" }?.value ?? ""

            let hasUnsubscribe = headers.contains { $0.name.lowercased() == "list-unsubscribe" }
            let precedence     = headers.first { $0.name.lowercased() == "precedence" }?.value.lowercased() ?? ""
            let isBulk         = hasUnsubscribe || precedence.contains("bulk") || precedence.contains("list")
            let date           = raw.internalDate.flatMap { Double($0).map { Date(timeIntervalSince1970: $0 / 1000) } }
                               ?? parseRFC2822Date(dateStr) ?? Date()

            return GmailMessage(
                id: raw.id, threadID: raw.threadId ?? "", messageID: messageID,
                subject: subject, from: from, snippet: raw.snippet ?? "",
                body: "", htmlBody: nil, receivedAt: date,
                labelIds: raw.labelIds ?? [], isBulk: isBulk,
                provider: .gmail, providerMessageID: raw.id
            )
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
                try? await Task.sleep(nanoseconds: isMetadata ? 50_000_000 : 100_000_000)
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

    private func fetchGmailProfile(token: String) async throws -> GmailProfileResponse {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EmailError.apiFailed }
        return try JSONDecoder().decode(GmailProfileResponse.self, from: data)
    }

    private func fetchGmailHistory(token: String, startHistoryID: String, pageToken: String? = nil) async throws -> GmailHistoryListResponse {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/history")!
        var query = [URLQueryItem(name: "startHistoryId", value: startHistoryID)]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw EmailError.apiFailed }
        if status == 404 { throw GmailHistoryError.expiredCursor }
        guard status == 200 else { throw EmailError.apiFailed }
        return try JSONDecoder().decode(GmailHistoryListResponse.self, from: data)
    }

    private func listMessageIDs(
        token: String,
        maxResults: Int = 100,
        requiredLabelID: String? = nil,
        lookbackDays: Int? = nil
    ) async throws -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        var pageToken: String?
        repeat {
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
            pageToken = list.nextPageToken
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
        let mime = payload.mimeType ?? ""

        if mime.hasPrefix("text/html"),
           let data = payload.body?.data, !data.isEmpty {
            return decodeBase64URL(data)
        }

        guard let parts = payload.parts, !parts.isEmpty else { return nil }

        if mime.hasPrefix("multipart/alternative") {
            // alternative: text/html 우선
            if let html = parts.first(where: { $0.mimeType?.hasPrefix("text/html") == true }),
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
            if let plain = parts.first(where: { $0.mimeType?.hasPrefix("text/plain") == true }),
               let data = plain.body?.data, !data.isEmpty {
                return decodeBase64URL(data) ?? ""
            }
            if let html = parts.first(where: { $0.mimeType?.hasPrefix("text/html") == true }),
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

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws {
        logger.info("Exchanging code for tokens")
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyParts = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
        let bodyString = bodyParts.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            logger.info("Token exchange response status: \(httpResponse.statusCode)")
            if httpResponse.statusCode != 200 {
                DiagnosticRecorder.shared.record(
                    error: DiagnosticFailure(code: httpResponse.statusCode, reason: "Gmail token exchange rejected"),
                    component: "mail.gmail",
                    operation: "tokenExchange"
                )
                let errorBody = String(data: data, encoding: .utf8) ?? "no body"
                logger.error("Token exchange failed: \(errorBody)")
            }
        }

        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        saveTokens(
            accessToken: tokens.access_token,
            refreshToken: tokens.refresh_token,
            idToken: tokens.id_token,
            expiresIn: tokens.expires_in
        )
        logger.info("Tokens saved successfully")
    }

    private func refreshTokenIfNeeded() async throws -> String {
        let tokens = loadTokens()
        guard tokens.scopeVersion == requiredTokenScopeVersion else {
            clearTokensIfScopeIsStale(loadedTokens: tokens)
            throw EmailError.notAuthenticated
        }
        if let accessToken = tokens.accessToken,
           !accessToken.isEmpty,
           accessTokenIsFresh(tokens.accessTokenExpiry) {
            return accessToken
        }
        guard let refresh = tokens.refreshToken else {
            logger.debug("No refresh token available, skipping refresh")
            throw EmailError.notAuthenticated
        }

        try await runSingleTokenRefresh(refreshToken: refresh)
        guard let refreshedAccessToken = loadTokens().accessToken,
              !refreshedAccessToken.isEmpty else {
            throw EmailError.notAuthenticated
        }
        return refreshedAccessToken
    }

    private func runSingleTokenRefresh(refreshToken: String) async throws {
        let (task, createdTask) = tokenRefreshTask(refreshToken: refreshToken)
        defer {
            if createdTask {
                clearTokenRefreshTask()
            }
        }
        try await task.value
    }

    private func tokenRefreshTask(refreshToken: String) -> (task: Task<Void, Error>, createdTask: Bool) {
        tokenRefreshLock.lock()
        defer { tokenRefreshLock.unlock() }

        if let activeTokenRefreshTask {
            return (activeTokenRefreshTask, false)
        }

        let task = Task { [self] in
            try await performTokenRefresh(refreshToken: refreshToken)
        }
        activeTokenRefreshTask = task
        return (task, true)
    }

    private func clearTokenRefreshTask() {
        tokenRefreshLock.lock()
        activeTokenRefreshTask = nil
        tokenRefreshLock.unlock()
    }

    private func performTokenRefresh(refreshToken refresh: String) async throws {
        logger.info("Refreshing access token")
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&refresh_token=\(refresh)&client_id=\(clientID)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            DiagnosticRecorder.shared.record(
                error: EmailError.apiFailed,
                component: "mail.gmail",
                operation: "tokenRefresh"
            )
            logger.error("Refresh token failed: No HTTP response")
            throw EmailError.apiFailed
        }


        guard httpResponse.statusCode == 200 else {
            // 400 invalid_grant 등: refresh token 만료 → 키체인 삭제 후 재인증 안내
            DiagnosticRecorder.shared.record(
                error: DiagnosticFailure(code: httpResponse.statusCode, reason: "Gmail token refresh rejected"),
                component: "mail.gmail",
                operation: "tokenRefresh"
            )
            let errorBody = String(data: data, encoding: .utf8) ?? "no body"
            logger.error("Refresh token failed: \(errorBody)")
            deleteTokens()
            throw EmailError.notAuthenticated
        }

        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        saveTokens(
            accessToken: tokens.access_token,
            refreshToken: refresh,
            idToken: tokens.id_token,
            expiresIn: tokens.expires_in
        )
        logger.debug("Access token refreshed successfully")
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

    private func makeOAuthBinding() -> (state: String, verifier: String, challenge: String) {
        let verifier = randomOAuthValue(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return (state: randomOAuthValue(byteCount: 32), verifier: verifier, challenge: challenge)
    }

    private func randomOAuthValue(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain (KeychainStore 위임)

    private func saveTokens(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        expiresIn: Int?
    ) {
        KeychainStore.set(service: keychainService, account: "access_token", value: accessToken)
        if let rt = refreshToken {
            KeychainStore.set(service: keychainService, account: "refresh_token", value: rt)
        }
        if let idToken, !idToken.isEmpty {
            KeychainStore.set(service: keychainService, account: "id_token", value: idToken)
        }
        let expiry = Date().addingTimeInterval(TimeInterval(expiresIn ?? 3600)).timeIntervalSince1970
        KeychainStore.set(service: keychainService, account: accessTokenExpiryAccount, value: String(expiry))
        KeychainStore.set(service: keychainService, account: tokenScopeVersionAccount, value: requiredTokenScopeVersion)
    }

    private func loadTokens() -> (accessToken: String?, refreshToken: String?, accessTokenExpiry: Date?, scopeVersion: String?) {
        let accessToken = KeychainStore.get(service: keychainService, account: "access_token")
        let refreshToken = KeychainStore.get(service: keychainService, account: "refresh_token")
        let expiry = KeychainStore.get(service: keychainService, account: accessTokenExpiryAccount)
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        let scopeVersion = KeychainStore.get(service: keychainService, account: tokenScopeVersionAccount)
        return (accessToken, refreshToken, expiry, scopeVersion)
    }

    private func accessTokenIsFresh(_ expiry: Date?, now: Date = Date()) -> Bool {
        guard let expiry else { return false }
        return expiry.timeIntervalSince(now) > accessTokenRefreshSkew
    }

    private func deleteTokens() {
        KeychainStore.deleteAny(service: keychainService, account: "access_token")
        KeychainStore.deleteAny(service: keychainService, account: "refresh_token")
        KeychainStore.deleteAny(service: keychainService, account: "id_token")
        KeychainStore.deleteAny(service: keychainService, account: accessTokenExpiryAccount)
        KeychainStore.deleteAny(service: keychainService, account: tokenScopeVersionAccount)
    }

    // MARK: - Read State Sync

    /// Gmail 서버에서 UNREAD 라벨을 제거하여 읽음 처리.
    /// `gmail.modify` 스코프 필요 — 이전 `gmail.readonly` 토큰이면 403으로 무음 실패.
    func markAsRead(
        messageID: String,
        expectedGlobalMessageID _: String? = nil
    ) async throws {
        logger.info("Marking message as read: \(messageID)")
        let token = try await refreshTokenIfNeeded()
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageID)/modify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["removeLabelIds": ["UNREAD"]])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            logger.error("markAsRead failed: No HTTP response")
            throw EmailError.apiFailed
        }

        logger.info("markAsRead response status: \(http.statusCode)")

        if !(200...299).contains(http.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? "no body"
            logger.error("markAsRead failed for \(messageID): \(errorBody)")
            throw EmailError.apiFailed
        }
        logger.info("Message \(messageID) marked as read successfully")
    }

    func trashMessage(
        messageID: String,
        expectedGlobalMessageID _: String? = nil
    ) async throws {
        logger.info("Trashing message: \(messageID)")
        let token = try await refreshTokenIfNeeded()

        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageID)/trash")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            logger.error("trashMessage failed: No HTTP response")
            throw EmailError.apiFailed
        }

        logger.info("trashMessage response status: \(http.statusCode)")

        if !(200...299).contains(http.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? "no body"
            logger.error("trashMessage failed for \(messageID): \(errorBody)")
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
    case authorizationFailed
    case notAuthenticated
    case apiFailed

    var errorDescription: String? {
        errorDescription(language: .current)
    }

    func errorDescription(language: AppLanguage) -> String {
        switch self {
        case .invalidConfiguration:
            return language == .english ? "Gmail OAuth configuration is invalid." : "Gmail OAuth 설정이 올바르지 않습니다."
        case .authorizationFailed:
            return language == .english ? "Gmail authorization failed." : "Gmail 인증에 실패했습니다."
        case .notAuthenticated:
            return language == .english ? "You are not signed in to Gmail." : "Gmail에 로그인되어 있지 않습니다."
        case .apiFailed:
            return language == .english ? "The Gmail API request failed." : "Gmail API 호출에 실패했습니다."
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
