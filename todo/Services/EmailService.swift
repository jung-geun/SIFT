import Foundation
import AuthenticationServices
import Security

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

// MARK: - Gmail Message Model

struct GmailMessage: Sendable {
    let id: String
    let threadID: String
    let messageID: String   // RFC822 Message-ID (원본 메일 permalink 생성용)
    let subject: String
    let from: String
    let snippet: String     // Gmail 제공 ~200자 미리보기 (메모용)
    let body: String        // MIME 디코딩 전체 평문 (날짜 감지용)
    let receivedAt: Date
    /// Gmail 카테고리 라벨 (예: CATEGORY_SOCIAL, CATEGORY_PROMOTIONS, CATEGORY_FORUMS)
    let labelIds: [String]
    /// List-Unsubscribe 또는 Precedence: bulk 헤더 존재 여부 (뉴스레터·대량발송 신호)
    let isBulk: Bool
}

// MARK: - Mail Provider Protocol

/// 메일 소스 추상화 프로토콜.
/// 현재 구현: EmailService (Gmail OAuth).
/// 향후 확장: IMAPProvider, GraphProvider(Outlook) 등.
///
/// ⚠️ 프라이버시 불변식: 어떤 구현이든 메일 본문은 온디바이스 전용
/// (NSDataDetector/AFM-PCC). 외부 서드파티 클라우드 전송 금지.
protocol MailProvider: AnyObject {
    /// 메일 계정 인증 (OAuth 등)
    func authenticate() async throws

    /// 최근 메시지 목록 가져오기
    func fetchRecentMessages() async throws -> [GmailMessage]

    /// 인증 해제 및 세션 종료
    func signOut()
}

// MARK: - Email Service

/// Gmail OAuth + 메시지 fetch + 온디바이스 FM 할 일 추출 (v2)
///
/// 사전 준비:
/// 1. Google Cloud Console에서 OAuth 클라이언트 ID 발급 (iOS 앱 유형)
/// 2. 리디렉트 URI 스킴을 Info.plist CFBundleURLSchemes에 등록
/// 3. `clientID`와 `clientSecret`에 실제 값 입력
final class EmailService: NSObject, MailProvider {
    static let shared = EmailService()
    private override init() {}

    // MARK: - Configuration (실제 값으로 교체 필요)

    private let clientID     = "746219534143-ij6p50gff6as4hn2bbhdc9a1u6os3jmp.apps.googleusercontent.com"
    private let clientSecret = ""
    private let redirectURI  = "com.googleusercontent.apps.746219534143-ij6p50gff6as4hn2bbhdc9a1u6os3jmp:/oauth2callback"
    private let scope        = "https://www.googleapis.com/auth/gmail.readonly"

    private let keychainService = "pieroot.todo.gmail"

    // MARK: - Authorization State

    var isAuthenticated: Bool { loadTokens().accessToken != nil }

    // MARK: - OAuth 2.0 (ASWebAuthenticationSession)

    func authenticate() async throws {
        guard let authURL = buildAuthURL() else {
            throw EmailError.invalidConfiguration
        }
        let callbackScheme = "com.googleusercontent.apps.746219534143-ij6p50gff6as4hn2bbhdc9a1u6os3jmp"

        let code: String = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url = callbackURL,
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    continuation.resume(throwing: EmailError.authorizationFailed)
                    return
                }
                continuation.resume(returning: code)
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = WindowProvider.shared
            session.start()
        }

        try await exchangeCodeForTokens(code: code)
    }

    func signOut() {
        deleteTokens()
    }

    /// MailProvider 프로토콜 구현 — 최근 메시지 목록 반환.
    /// 내부적으로 `listNewMessages(after:)`를 호출하며 Gmail 동작은 무변경.
    func fetchRecentMessages() async throws -> [GmailMessage] {
        try await listNewMessages(after: nil)
    }

    // MARK: - Fetch & Extract

    /// 새 메일을 가져와 FM으로 할 일을 추출하고 TodoSource.email로 SwiftData에 삽입.
    /// - Parameter after: 마지막 확인 이후 히스토리 ID (없으면 최근 50건)
    /// - Returns: 새로 생성된 할 일 목록
    func fetchAndExtractTodos(after historyID: String? = nil) async throws -> [Todo] {
        let (todos, _) = try await fetchAndExtractAll(after: historyID)
        return todos
    }

    /// 할 일과 캘린더 일정을 한 번의 Gmail fetch로 함께 추출합니다.
    ///
    /// - Parameter allowFoundationModels: 포그라운드(true, 기본) → AFM 분석.
    ///   백그라운드 BGTask(false) → NSDataDetector (ANE 백그라운드 미사용).
    func fetchAndExtractAll(after historyID: String? = nil, allowFoundationModels: Bool = true) async throws -> (todos: [Todo], events: [(event: ExtractedEmailEvent, sourceRef: String)]) {
        try await refreshTokenIfNeeded()
        let messages = try await listNewMessages(after: historyID)

        var todos: [Todo] = []
        for message in messages {
            todos += (try? await extractTodos(from: message, allowFoundationModels: allowFoundationModels)) ?? []
        }
        let events = (try? await extractCalendarEventsFromMessages(messages)) ?? []

        // 학습 필터: 억제된 발신자 또는 이미 처리한(dismissed) messageID 제거
        // → AppDelegate·설정화면 두 ingestion 경로 모두 혜택
        let store = EmailLearningStore.shared
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

    // MARK: - Gmail API

    private func listNewMessages(after historyID: String?) async throws -> [GmailMessage] {
        guard let token = loadTokens().accessToken else { throw EmailError.notAuthenticated }

        // 최근 수신 메일 ID 목록 조회
        let lookbackDays = {
            let v = UserDefaults.standard.integer(forKey: "pieroot.todo.emailLookbackDays")
            return v > 0 ? min(max(v, 1), 30) : 3
        }()
        var urlComponents = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        urlComponents.queryItems = [
            URLQueryItem(name: "q", value: "is:unread newer_than:\(lookbackDays)d"),
            URLQueryItem(name: "maxResults", value: "50")
        ]
        if let hid = historyID {
            urlComponents.queryItems?.append(URLQueryItem(name: "historyId", value: hid))
        }

        var request = URLRequest(url: urlComponents.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw EmailError.apiFailed
        }

        let list = try JSONDecoder().decode(MessageListResponse.self, from: data)
        guard let messageIDs = list.messages else { return [] }

        // 각 메시지 본문 조회 (병렬)
        return try await withThrowingTaskGroup(of: GmailMessage?.self) { group in
            let cap = min(50, max(10, lookbackDays * 3))
            for item in messageIDs.prefix(cap) {
                group.addTask { [weak self] in
                    try await self?.fetchMessage(id: item.id, token: token)
                }
            }
            var messages: [GmailMessage] = []
            for try await msg in group {
                if let m = msg { messages.append(m) }
            }
            return messages
        }
    }

    private func fetchMessage(id: String, token: String) async throws -> GmailMessage? {
        // format=full: 모든 헤더 + MIME 트리 + snippet 포함 (format=metadata보다 크지만 본문 파싱 가능)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        let raw = try JSONDecoder().decode(RawGmailMessage.self, from: data)

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

        let date     = parseRFC2822Date(dateStr) ?? Date()
        let snippet  = raw.snippet ?? ""
        let body     = extractPlainText(from: raw.payload)
        let labelIds = raw.labelIds ?? []

        return GmailMessage(
            id: raw.id,
            threadID: raw.threadId ?? "",
            messageID: messageID,
            subject: subject,
            from: from,
            snippet: snippet,
            body: body,
            receivedAt: date,
            labelIds: labelIds,
            isBulk: isBulk
        )
    }

    // MARK: - On-Device Extraction (NSDataDetector)

    /// 메일 한 건에서 마감일이 감지되면 Todo를 반환, 없으면 빈 배열.
    /// 완전 온디바이스 처리 — 본문이 기기 밖으로 나가지 않음 (프라이버시 규칙 준수).
    ///
    /// 3-way 분류:
    ///   - SOCIAL/FORUMS 카테고리 → drop (할 일·참고함 둘 다 생성 안 함)
    ///   - PROMOTIONS 또는 마감 키워드 없음(score==0) → review (참고함)
    ///   - PERSONAL/UPDATES/미분류 + 키워드 있음 → todo (메인 할 일)
    private func extractTodos(from message: GmailMessage, allowFoundationModels: Bool = true) async throws -> [Todo] {
        let engine = EmailAnalysisEngineFactory.makeEngine(allowFoundationModels: allowFoundationModels)
        guard let extraction = await engine.analyze(message, now: Date()) else {
            return []   // 마감일 미감지 → 할 일 미생성
        }

        // 1차 분류: Gmail 카테고리 라벨
        let labels = Set(message.labelIds)
        let dropLabels:   Set<String> = ["CATEGORY_SOCIAL", "CATEGORY_FORUMS"]
        let reviewLabels: Set<String> = ["CATEGORY_PROMOTIONS"]

        if !labels.isDisjoint(with: dropLabels) {
            return []   // 소셜/포럼 → drop
        }

        // 2차 분류: PROMOTIONS·벌크메일(List-Unsubscribe/Precedence:bulk) 또는 키워드 없음 → 참고함
        // isBulk: Gmail 카테고리 라벨이 없는 뉴스레터도 캐치 (List-Unsubscribe RFC 2369)
        let isPromotion = !labels.isDisjoint(with: reviewLabels) || message.isBulk
        let triage: TodoTriage = (isPromotion || extraction.keywordScore == 0) ? .review : .todo

        let todo = Todo(
            title: message.subject,
            notes: extraction.notes,
            dueDate: extraction.dueDate,
            source: .email,
            sourceRef: message.id
        )
        todo.sourceSender      = extraction.sender
        todo.sourceSenderEmail = extraction.senderEmail
        todo.sourceMessageID   = message.messageID
        todo.sourceThreadID    = message.threadID
        todo.triageStatus      = triage.rawValue
        return [todo]
    }

    /// 마감일이 감지된 메일만 캘린더 이벤트 후보로 반환.
    /// CalendarAutoPolicy.isAuto가 켜진 경우에만 실제 등록됨.
    private func extractCalendarEventsFromMessages(_ messages: [GmailMessage]) async throws -> [(event: ExtractedEmailEvent, sourceRef: String)] {
        let analyzer = EmailContentAnalyzer()
        let iso      = ISO8601DateFormatter()
        var results: [(ExtractedEmailEvent, String)] = []
        for msg in messages {
            guard let extraction = analyzer.analyze(msg, now: Date()) else { continue }
            let notesText = extraction.sender.isEmpty
                ? msg.snippet
                : "[\(extraction.sender)] \(msg.snippet)"
            let event = ExtractedEmailEvent(
                title:    msg.subject,
                startISO: iso.string(from: extraction.dueDate),
                endISO:   "",
                location: "",
                notes:    notesText,
                isAllDay: extraction.isAllDay
            )
            results.append((event, msg.id))
        }
        return results
    }

    // MARK: - MIME Body Extraction

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
        // 블록 태그 → 줄바꿈
        let blockTags = ["</p>", "</div>", "<br>", "<br/>", "<br />", "</li>",
                         "</h1>", "</h2>", "</h3>", "</h4>", "</tr>"]
        for tag in blockTags {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        // 나머지 태그 제거
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

    private func exchangeCodeForTokens(code: String) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
         .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        saveTokens(accessToken: tokens.access_token, refreshToken: tokens.refresh_token)
    }

    private func refreshTokenIfNeeded() async throws {
        guard let refresh = loadTokens().refreshToken else { throw EmailError.notAuthenticated }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&refresh_token=\(refresh)&client_id=\(clientID)&client_secret=\(clientSecret)"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        saveTokens(accessToken: tokens.access_token, refreshToken: refresh)
    }

    private func buildAuthURL() -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id",     value: clientID),
            URLQueryItem(name: "redirect_uri",  value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope",         value: scope),
            URLQueryItem(name: "access_type",   value: "offline"),
            URLQueryItem(name: "prompt",        value: "consent")
        ]
        return components.url
    }

    // MARK: - Keychain

    private func saveTokens(accessToken: String, refreshToken: String?) {
        setKeychainItem(key: "access_token",  value: accessToken)
        if let rt = refreshToken {
            setKeychainItem(key: "refresh_token", value: rt)
        }
    }

    private func loadTokens() -> (accessToken: String?, refreshToken: String?) {
        (getKeychainItem(key: "access_token"), getKeychainItem(key: "refresh_token"))
    }

    private func deleteTokens() {
        deleteKeychainItem(key: "access_token")
        deleteKeychainItem(key: "refresh_token")
    }

    private func setKeychainItem(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private func getKeychainItem(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKeychainItem(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Date Parsing

    private func parseRFC2822Date(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: string)
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

// MARK: - Error

enum EmailError: LocalizedError {
    case invalidConfiguration
    case authorizationFailed
    case notAuthenticated
    case apiFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Gmail OAuth 설정이 올바르지 않습니다."
        case .authorizationFailed:  "Gmail 인증에 실패했습니다."
        case .notAuthenticated:     "Gmail에 로그인되어 있지 않습니다."
        case .apiFailed:            "Gmail API 호출에 실패했습니다."
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
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
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
