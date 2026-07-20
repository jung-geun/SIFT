import Foundation
import SwiftData
import Testing
@testable import todo

class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            fatalError("Handler is not set.")
        }

        do {
            var normalizedRequest = request
            if normalizedRequest.httpBody == nil,
               let body = Self.bodyData(from: request) {
                normalizedRequest.httpBody = body
            }

            let (response, data) = try handler(normalizedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 1024
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }

    override func stopLoading() {}
}

private struct GmailListRequest: Equatable, Sendable {
    let query: String?
    let labelID: String?
}

private final class GmailSyncRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var listRequests: [GmailListRequest] = []
    private var metadataMessageIDs: Set<String> = []

    func recordList(_ request: GmailListRequest) {
        lock.lock()
        listRequests.append(request)
        lock.unlock()
    }

    func recordMetadata(messageID: String) {
        lock.lock()
        metadataMessageIDs.insert(messageID)
        lock.unlock()
    }

    func snapshot() -> (listRequests: [GmailListRequest], metadataMessageIDs: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        return (listRequests, metadataMessageIDs)
    }
}

private func makeGmailSyncRequestHandler(
    lookbackDays: Int,
    activeMessageIDs: [String],
    recentInboxMessageIDs: [String],
    metadataByID: [String: (receivedAt: Date, labelIDs: [String])],
    probe: GmailSyncRequestProbe
) -> (URLRequest) throws -> (HTTPURLResponse, Data?) {
    { request in
        let url = try #require(request.url)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        if url.host == "oauth2.googleapis.com" {
            return (
                response,
                #"{"access_token":"new-access","expires_in":3600}"#.data(using: .utf8)
            )
        }

        if url.path.hasSuffix("/messages") {
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = components.queryItems?.first(where: { $0.name == "q" })?.value
            let labelID = components.queryItems?.first(where: { $0.name == "labelIds" })?.value
            probe.recordList(GmailListRequest(query: query, labelID: labelID))

            let messageIDs: [String]
            if query == nil && labelID == nil {
                messageIDs = activeMessageIDs
            } else if query == "newer_than:\(lookbackDays)d" && labelID == "INBOX" {
                messageIDs = recentInboxMessageIDs
            } else {
                Issue.record("Unexpected Gmail list request: \(url.absoluteString)")
                messageIDs = []
            }

            let payload: [String: Any] = [
                "messages": messageIDs.map { ["id": $0] }
            ]
            return (response, try JSONSerialization.data(withJSONObject: payload))
        }

        if url.path.contains("/messages/") {
            let messageID = url.lastPathComponent
            probe.recordMetadata(messageID: messageID)
            guard let metadata = metadataByID[messageID] else {
                Issue.record("Unexpected Gmail metadata request: \(messageID)")
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    nil
                )
            }

            let payload: [String: Any] = [
                "id": messageID,
                "threadId": "thread-\(messageID)",
                "snippet": "snippet-\(messageID)",
                "internalDate": String(Int(metadata.receivedAt.timeIntervalSince1970 * 1_000)),
                "labelIds": metadata.labelIDs,
                "payload": [
                    "headers": [
                        ["name": "Subject", "value": messageID],
                        ["name": "From", "value": "sender@example.com"]
                    ]
                ]
            ]
            return (response, try JSONSerialization.data(withJSONObject: payload))
        }

        Issue.record("Unexpected Gmail request: \(url.absoluteString)")
        return (
            HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
            nil
        )
    }
}

private final class GmailMailboxRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var listURLs: [URL] = []
    private var metadataMessageIDs: [String] = []

    func recordList(_ url: URL) {
        lock.lock()
        listURLs.append(url)
        lock.unlock()
    }

    func recordMetadata(messageID: String) {
        lock.lock()
        metadataMessageIDs.append(messageID)
        lock.unlock()
    }

    func snapshot() -> (listURLs: [URL], metadataMessageIDs: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (listURLs, metadataMessageIDs)
    }
}

private final class GmailMailboxRetryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var metadataAttempts = 0
    private var pageTokens: [String?] = []

    func recordPageToken(_ token: String?) {
        lock.lock()
        pageTokens.append(token)
        lock.unlock()
    }

    func nextMetadataAttempt() -> Int {
        lock.lock()
        defer { lock.unlock() }
        metadataAttempts += 1
        return metadataAttempts
    }

    func capturedPageTokens() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return pageTokens
    }
}

private func gmailBase64URL(_ value: String) -> String {
    Data(value.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func gmailMessagePayload(
    id: String,
    receivedAt: Date,
    labelIDs: [String],
    subject: String? = nil,
    plainBody: String? = nil,
    htmlBody: String? = nil
) throws -> Data {
    var payload: [String: Any] = [
        "mimeType": plainBody == nil && htmlBody == nil
            ? "text/plain"
            : "multipart/alternative",
        "headers": [
            ["name": "Subject", "value": subject ?? id],
            ["name": "From", "value": "sender@example.com"],
            ["name": "Message-ID", "value": "<\(id)@example.com>"]
        ],
        "body": [String: String]()
    ]
    var parts: [[String: Any]] = []
    if let plainBody {
        parts.append([
            "mimeType": "text/plain",
            "headers": [[String: String]](),
            "body": ["data": gmailBase64URL(plainBody)]
        ])
    }
    if let htmlBody {
        parts.append([
            "mimeType": "text/html",
            "headers": [[String: String]](),
            "body": ["data": gmailBase64URL(htmlBody)]
        ])
    }
    if !parts.isEmpty {
        payload["parts"] = parts
    }
    return try JSONSerialization.data(withJSONObject: [
        "id": id,
        "threadId": "thread-\(id)",
        "snippet": "snippet-\(id)",
        "internalDate": String(Int(receivedAt.timeIntervalSince1970 * 1_000)),
        "labelIds": labelIDs,
        "payload": payload
    ])
}

@Suite("GmailService 에러 케이스 및 로그 검증", .serialized)
@MainActor
struct GmailServiceTests {

    private let sut = EmailService.shared

    private func withIsolatedProviderState<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        try await AIProviderTestIsolation.shared.withLock {
            let originalSession = sut.session
            let defaults = UserDefaults.standard
            let settingKeys = [
                EmailAnalysisLookbackPolicy.lookbackSettingKey,
                "pieroot.todo.dismissedMessageIDs",
                "pieroot.todo.analyzedMessageIDs",
                "pieroot.todo.senderDeletionCounts",
                "pieroot.todo.suppressedSenders",
                "pieroot.todo.iCloudSyncEnabled",
                "pieroot.todo.lastEmailFetchDate"
            ]
            let defaultKeys = settingKeys + settingKeys.map { "\($0).isLocal" }
            let savedDefaults = defaultKeys.map {
                ($0, defaults.object(forKey: $0))
            }
            let keychainAccounts = [
                "access_token",
                "refresh_token",
                "id_token",
                "scope_version"
            ]
            let savedSecrets = keychainAccounts.map {
                ($0, KeychainStore.get(service: "pieroot.todo.gmail", account: $0))
            }
            defer {
                MockURLProtocol.requestHandler = nil
                sut.session = originalSession
                for (key, value) in savedDefaults {
                    if let value {
                        defaults.set(value, forKey: key)
                    } else {
                        defaults.removeObject(forKey: key)
                    }
                }
                for account in keychainAccounts {
                    KeychainStore.deleteAny(
                        service: "pieroot.todo.gmail",
                        account: account
                    )
                }
                for (account, value) in savedSecrets {
                    if let value {
                        KeychainStore.set(
                            service: "pieroot.todo.gmail",
                            account: account,
                            value: value
                        )
                    }
                }
            }
            return try await operation()
        }
    }


    private func resetSharedState() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        sut.session = URLSession(configuration: config)
        MockURLProtocol.requestHandler = nil
        for account in ["access_token", "refresh_token", "id_token", "scope_version"] {
            KeychainStore.deleteAny(
                service: "pieroot.todo.gmail",
                account: account
            )
        }
        let defaults = UserDefaults.standard
        let settingKeys = [
            EmailAnalysisLookbackPolicy.lookbackSettingKey,
            "pieroot.todo.dismissedMessageIDs",
            "pieroot.todo.analyzedMessageIDs",
            "pieroot.todo.senderDeletionCounts",
            "pieroot.todo.suppressedSenders"
        ]
        for key in settingKeys {
            defaults.removeObject(forKey: key)
            defaults.set(true, forKey: "\(key).isLocal")
        }
        defaults.set(false, forKey: "pieroot.todo.iCloudSyncEnabled")
    }

    private func seedGmailTokens(scopeVersion: String? = "gmail.modify.openid.v2") {
        KeychainStore.set(service: "pieroot.todo.gmail", account: "access_token", value: "valid-access")
        KeychainStore.set(service: "pieroot.todo.gmail", account: "refresh_token", value: "valid-refresh")
        if let scopeVersion {
            KeychainStore.set(service: "pieroot.todo.gmail", account: "scope_version", value: scopeVersion)
        }
    }

    private func makeEmailContainer() throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: AppDataContainer.emailSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: AppDataContainer.emailSchema, configurations: [config])
    }

    private func makeTodoContainer() throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: AppDataContainer.appSchema, configurations: [config])
    }


    @Test("Refresh Token 실패 (400 invalid_grant) 시 토큰 삭제 및 에러 발생 확인")
    func testRefreshTokenInvalidGrant() async throws {
        try await withIsolatedProviderState {
        defer {
            resetSharedState()
            sut.session = .shared
        }
        resetSharedState()
        // 1. 초기 토큰 설정 (Keychain)
        seedGmailTokens()

        // 2. Mock 설정: 400 응답 (invalid_grant)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            let data = "{\"error\": \"invalid_grant\", \"error_description\": \"Token has been expired or revoked.\"}".data(using: .utf8)
            return (response, data)
        }

        // 3. 실행 및 검증
        await #expect(throws: EmailError.notAuthenticated) {
            try await sut.fetchAndExtractAll()
        }

        // 4. 토큰 삭제 확인
        #expect(KeychainStore.get(service: "pieroot.todo.gmail", account: "access_token") == nil)
        #expect(KeychainStore.get(service: "pieroot.todo.gmail", account: "refresh_token") == nil)
        }
    }

    @Test("Gmail API 호출 실패 (500) 시 apiFailed 에러 발생 확인")
    func testGmailAPIFailure500() async throws {
        try await withIsolatedProviderState {
        resetSharedState()
        defer {
            resetSharedState()
            sut.session = .shared
        }
        // 1. 토큰 설정
        seedGmailTokens()

        // 2. Mock 설정: Refresh Token은 성공(200), 하지만 API 호출은 실패(500)
        MockURLProtocol.requestHandler = { request in
            if request.url?.host == "oauth2.googleapis.com" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = "{\"access_token\": \"new-access\", \"expires_in\": 3600}".data(using: .utf8)
                return (response, data)
            } else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, nil)
            }
        }

        // 3. 실행 및 검증
        await #expect(throws: EmailError.apiFailed) {
            try await sut.fetchAndExtractAll()
        }
        }
    }

    @Test("권한 부족 (403 Forbidden) 시 markAsRead 실패 확인")
    func testMarkAsReadForbidden() async throws {
        try await withIsolatedProviderState {
        resetSharedState()
        defer {
            resetSharedState()
            sut.session = .shared
        }
        // 1. 토큰 설정
        seedGmailTokens()

        // 2. Mock 설정: 403 Forbidden
        MockURLProtocol.requestHandler = { request in
            if request.url?.host == "oauth2.googleapis.com" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = "{\"access_token\": \"new-access\", \"expires_in\": 3600}".data(using: .utf8)
                return (response, data)
            } else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
                let data = "{\"error\": {\"code\": 403, \"message\": \"Insufficient Permission\"}}".data(using: .utf8)
                return (response, data)
            }
        }

        // 3. 실행 및 검증
        await #expect(throws: EmailError.apiFailed) {
            try await sut.markAsRead(messageID: "test-msg-id")
        }
        }
    }

    @Test("구 readonly 토큰은 modify 전에 제거된다")
    func testReadonlyScopeTokensAreClearedBeforeModify() async throws {
        try await withIsolatedProviderState {
        resetSharedState()
        defer {
            resetSharedState()
            sut.session = .shared
        }

        seedGmailTokens(scopeVersion: nil)

        await #expect(throws: EmailError.notAuthenticated) {
            try await sut.markAsRead(messageID: "msg-old-scope")
        }

        #expect(KeychainStore.get(service: "pieroot.todo.gmail", account: "access_token") == nil)
        #expect(KeychainStore.get(service: "pieroot.todo.gmail", account: "refresh_token") == nil)
        #expect(KeychainStore.get(service: "pieroot.todo.gmail", account: "scope_version") == nil)
        }
    }

    @Test("markAsRead는 gmail.modify 본문을 사용한다")
    func testMarkAsReadUsesGmailModifyBody() async throws {
        try await withIsolatedProviderState {
        resetSharedState()
        defer {
            resetSharedState()
            sut.session = .shared
        }

        seedGmailTokens()
        var capturedMethod: String?
        var capturedRemoveLabelIDs: [String]?

        MockURLProtocol.requestHandler = { request in
            if request.url?.host == "oauth2.googleapis.com" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = "{\"access_token\": \"new-access\", \"expires_in\": 3600}".data(using: .utf8)
                return (response, data)
            }

            capturedMethod = request.httpMethod
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedRemoveLabelIDs = json["removeLabelIds"] as? [String]
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8))
        }

        try await sut.markAsRead(messageID: "msg-read")

        #expect(capturedMethod == "POST")
        #expect(capturedRemoveLabelIDs == ["UNREAD"])
        }
    }

    @Test("trashMessage는 Gmail trash 엔드포인트를 사용한다")
    func testTrashMessageUsesGmailTrashEndpoint() async throws {
        try await withIsolatedProviderState {
        resetSharedState()
        defer {
            resetSharedState()
            sut.session = .shared
        }

        seedGmailTokens()
        var capturedMethod: String?
        var capturedPath: String?

        MockURLProtocol.requestHandler = { request in
            if request.url?.host == "oauth2.googleapis.com" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = "{\"access_token\": \"new-access\", \"expires_in\": 3600}".data(using: .utf8)
                return (response, data)
            }

            capturedMethod = request.httpMethod
            capturedPath = request.url?.path
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8))
        }

        try await sut.trashMessage(messageID: "msg-trash")

        #expect(capturedMethod == "POST")
        #expect(capturedPath?.hasSuffix("/messages/msg-trash/trash") == true)
        }
    }

    @Test("여러 메시지 조회 시 배치 처리 및 바디 fallback 확인")
    func testFetchRecentMessagesBatchingAndFallback() async throws {
        try await withIsolatedProviderState {
        defer {
            resetSharedState()
            sut.session = .shared
        }
        resetSharedState()
        // 기간을 늘려 cap(최대 50) 검증: 15건 모두 처리되는지 확인
        UserDefaults.standard.set(10, forKey: "pieroot.todo.emailLookbackDays")
        // 1. 토큰 설정
        seedGmailTokens()

        // 2. Mock 설정
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                return (HTTPURLResponse(url: URL(string: "about:blank")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
            }

            if url.host == "oauth2.googleapis.com" {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = "{\"access_token\": \"new-access\", \"expires_in\": 3600}".data(using: .utf8)
                return (response, data)
            } else if url.path.hasSuffix("/messages") {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let ids = (1...15).map { "{\"id\": \"msg-\($0)\"}" }.joined(separator: ",")
                let data = "{\"messages\": [\(ids)]}".data(using: .utf8)
                return (response, data)
            } else if url.path.contains("/messages/") {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let msgID = url.lastPathComponent.components(separatedBy: "?").first!
                let data = "{\"id\": \"\(msgID)\", \"snippet\": \"snippet-\(msgID)\", \"payload\": {\"headers\": []}}".data(using: .utf8)
                return (response, data)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, "{}".data(using: .utf8))
        }

        // 3. 실행
        let messages = try await sut.fetchRecentMessages()

        // 4. 검증: 15개 모두 가져왔는지 확인
        #expect(messages.count == 15)
        #expect(messages.contains(where: { $0.id == "msg-1" }))
        #expect(messages.contains(where: { $0.id == "msg-15" }))
        #expect(messages.allSatisfy { $0.body.hasPrefix("snippet-") })
        }
    }

    @Test("메일 sync는 완전한 활성 snapshot으로 cache만 prune하고 연결 todo는 유지한다")
    @MainActor
    func testSyncRecentMessageCachePrunesOnlyTrulyMissingMessages() async throws {
        try await withIsolatedProviderState {
        defer {
            resetSharedState()
            sut.session = .shared
        }
        resetSharedState()
        UserDefaults.standard.set(7, forKey: "pieroot.todo.emailLookbackDays")
        seedGmailTokens()

        let emailContainer = try makeEmailContainer()
        let emailContext = ModelContext(emailContainer)
        let todoContainer = try makeTodoContainer()
        let todoContext = ModelContext(todoContainer)
        let now = Date()

        let staleEmail = EmailMessage(
            id: "msg-delete",
            threadID: "thread-delete",
            subject: "삭제 예정",
            from: "sender@example.com",
            snippet: "stale",
            body: "",
            htmlBody: nil,
            receivedAt: now
        )
        let pagedEmail = EmailMessage(
            id: "msg-101",
            threadID: "thread-101",
            subject: "페이지 2 메일",
            from: "sender@example.com",
            snippet: "keep",
            body: "",
            htmlBody: nil,
            receivedAt: now
        )
        let oldEmail = EmailMessage(
            id: "msg-old-local",
            threadID: "thread-old",
            subject: "오래된 로컬 메일",
            from: "sender@example.com",
            snippet: "old",
            body: "",
            htmlBody: nil,
            receivedAt: now.addingTimeInterval(-9 * 24 * 3600)
        )
        emailContext.insert(staleEmail)
        emailContext.insert(pagedEmail)
        emailContext.insert(oldEmail)
        try emailContext.save()

        let staleTodo = Todo(title: "삭제될 메일 todo", source: .email, sourceRef: "msg-delete")
        let pagedTodo = Todo(title: "유지될 메일 todo", source: .email, sourceRef: "msg-101")
        let orphanTodo = Todo(title: "캐시 없는 메일 todo", source: .email, sourceRef: "msg-delete-no-cache")
        let trashTodo = Todo(title: "휴지통 메일 todo", source: .email, sourceRef: "msg-trash")
        todoContext.insert(staleTodo)
        todoContext.insert(pagedTodo)
        todoContext.insert(orphanTodo)
        todoContext.insert(trashTodo)
        try todoContext.save()

        let firstPageIDs = (1...100).map { "msg-\($0)" }
        let referenceMillis = Int(now.timeIntervalSince1970 * 1000)

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                return (
                    HTTPURLResponse(url: URL(string: "about:blank")!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    nil
                )
            }

            if url.host == "oauth2.googleapis.com" {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = #"{"access_token":"new-access","expires_in":3600}"#.data(using: .utf8)
                return (response, data)
            }

            if url.path.hasSuffix("/messages") {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let pageToken = components?.queryItems?.first(where: { $0.name == "pageToken" })?.value
                let payload: String
                if pageToken == "page-2" {
                    payload = #"{"messages":[{"id":"msg-101"}]}"#
                } else {
                    let ids = firstPageIDs.map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
                    payload = #"{"messages":[\#(ids)],"nextPageToken":"page-2"}"#
                }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, payload.data(using: .utf8))
            }

            if url.path.contains("/messages/") {
                let msgID = url.lastPathComponent.components(separatedBy: "?").first!
                if msgID == "msg-delete-no-cache" {
                    let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
                    return (response, "{}".data(using: .utf8))
                }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let labels = msgID == "msg-trash" ? #"["TRASH"]"# : #"["INBOX"]"#
                let payload = """
                {"id":"\(msgID)","threadId":"thread-\(msgID)","snippet":"snippet-\(msgID)","internalDate":"\(referenceMillis)","labelIds":\(labels),"payload":{"headers":[{"name":"Subject","value":"\(msgID)"},{"name":"From","value":"sender@example.com"}]}}
                """
                return (response, payload.data(using: .utf8))
            }

            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, "{}".data(using: .utf8))
        }

        let result = try await sut.syncRecentMessageCache(emailContext: emailContext, todoContext: todoContext)
        let storedEmails = try emailContext.fetch(FetchDescriptor<EmailMessage>())
        let storedTodos = try todoContext.fetch(FetchDescriptor<Todo>())

        #expect(result.prunedMessageCount == 1)
        #expect(result.prunedTodoCount == 0)
        #expect(storedEmails.contains(where: { $0.id == "msg-101" }))
        #expect(storedEmails.contains(where: { $0.id == "msg-old-local" }))
        #expect(storedEmails.contains(where: { $0.id == "msg-delete" }) == false)
        #expect(storedTodos.contains(where: { $0.sourceRef == "msg-101" }))
        #expect(storedTodos.contains(where: { $0.sourceRef == "msg-delete" }))
        #expect(storedTodos.contains(where: { $0.sourceRef == "msg-delete-no-cache" }))
        #expect(storedTodos.contains(where: { $0.sourceRef == "msg-trash" }))
        #expect(EmailLearningStore.shared.isDismissed("msg-delete") == false)
        }
    }

    @Test("메일 sync는 최근 INBOX를 positive-upsert하고 absence로 기존 행을 숨기지 않는다")
    @MainActor
    func testSyncRecentMessageCacheUsesLookbackAndRehydratesOlderInboxMail() async throws {
        try await withIsolatedProviderState {
            let defaults = UserDefaults.standard
            let key = EmailAnalysisLookbackPolicy.lookbackSettingKey
            let hadStoredLookback = defaults.object(forKey: key) != nil
            let priorLookback = defaults.integer(forKey: key)
            defer {
                resetSharedState()
                if hadStoredLookback {
                    defaults.set(priorLookback, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
                sut.session = .shared
            }

            resetSharedState()
            defaults.set(3, forKey: key)
            seedGmailTokens()

            let emailContainer = try makeEmailContainer()
            let emailContext = ModelContext(emailContainer)
            let todoContainer = try makeTodoContainer()
            let todoContext = ModelContext(todoContainer)
            let now = Date()
            let recentDate = now.addingTimeInterval(-60 * 60)
            let oldDate = now.addingTimeInterval(-10 * 24 * 60 * 60)
            let updatesID = "recent-updates"
            let socialID = "recent-social"
            let archivedID = "recent-archived"
            let oldID = "older-active-inbox"
            let activeIDs = [updatesID, socialID, archivedID, oldID]

            let archivedEmail = EmailMessage(
                id: archivedID,
                threadID: "thread-\(archivedID)",
                subject: "Archived",
                from: "sender@example.com",
                snippet: "archived",
                receivedAt: recentDate,
                labelIDs: ["INBOX", "CATEGORY_UPDATES"],
                isInInbox: true
            )
            let oldEmail = EmailMessage(
                id: oldID,
                threadID: "thread-\(oldID)",
                subject: "Old",
                from: "sender@example.com",
                snippet: "old",
                receivedAt: oldDate,
                labelIDs: ["INBOX", "CATEGORY_PERSONAL"],
                isInInbox: true
            )
            emailContext.insert(archivedEmail)
            emailContext.insert(oldEmail)
            try emailContext.save()

            let archivedTodo = Todo(
                title: "Archived mail todo",
                source: .email,
                sourceRef: archivedID
            )
            archivedTodo.calendarEventID = "calendar-event-id"
            archivedTodo.calendarEventExternalID = "calendar-external-id"
            todoContext.insert(archivedTodo)
            let outlookTodo = Todo(
                title: "Outlook mail todo",
                source: .email,
                sourceRef: "outlook:active-message"
            )
            outlookTodo.calendarEventID = "outlook-calendar-event-id"
            outlookTodo.calendarEventExternalID = "outlook-calendar-external-id"
            todoContext.insert(outlookTodo)
            try todoContext.save()

            let metadataByID: [String: (receivedAt: Date, labelIDs: [String])] = [
                updatesID: (recentDate, ["INBOX", "CATEGORY_UPDATES", "CATEGORY_SOCIAL"]),
                socialID: (recentDate.addingTimeInterval(-60), ["INBOX", "CATEGORY_SOCIAL"]),
                archivedID: (recentDate, ["CATEGORY_UPDATES"]),
                oldID: (oldDate, ["INBOX", "CATEGORY_PERSONAL"])
            ]

            let firstProbe = GmailSyncRequestProbe()
            MockURLProtocol.requestHandler = makeGmailSyncRequestHandler(
                lookbackDays: 3,
                activeMessageIDs: activeIDs,
                recentInboxMessageIDs: [updatesID, socialID],
                metadataByID: metadataByID,
                probe: firstProbe
            )

            _ = try await sut.syncRecentMessageCache(
                emailContext: emailContext,
                todoContext: todoContext
            )

            let firstEmails = try emailContext.fetch(FetchDescriptor<EmailMessage>())
            let storedUpdates = try #require(firstEmails.first { $0.id == updatesID })
            let storedArchived = try #require(firstEmails.first { $0.id == archivedID })
            let storedOld = try #require(firstEmails.first { $0.id == oldID })
            let storedArchivedTodo = try #require(
                try todoContext.fetch(FetchDescriptor<Todo>())
                    .first { $0.sourceRef == archivedID }
            )
            let storedOutlookTodo = try #require(
                try todoContext.fetch(FetchDescriptor<Todo>())
                    .first { $0.sourceRef == "outlook:active-message" }
            )
            let firstRequests = firstProbe.snapshot()

            #expect(storedUpdates.gmailInboxCategories == Set([.updates, .social]))
            #expect(storedArchived.isInInbox)
            #expect(storedOld.isInInbox)
            #expect(storedArchivedTodo.calendarEventID == "calendar-event-id")
            #expect(storedArchivedTodo.calendarEventExternalID == "calendar-external-id")
            #expect(storedOutlookTodo.calendarEventID == "outlook-calendar-event-id")
            #expect(storedOutlookTodo.calendarEventExternalID == "outlook-calendar-external-id")
            #expect(firstRequests.listRequests.count == 2)
            #expect(
                firstRequests.listRequests.contains(
                    GmailListRequest(query: nil, labelID: nil)
                )
            )
            #expect(
                firstRequests.listRequests.contains(
                    GmailListRequest(query: "newer_than:3d", labelID: "INBOX")
                )
            )
            #expect(firstRequests.metadataMessageIDs == Set([updatesID, socialID]))

            defaults.set(30, forKey: key)
            let secondProbe = GmailSyncRequestProbe()
            MockURLProtocol.requestHandler = makeGmailSyncRequestHandler(
                lookbackDays: 30,
                activeMessageIDs: activeIDs,
                recentInboxMessageIDs: [updatesID, socialID, oldID],
                metadataByID: metadataByID,
                probe: secondProbe
            )

            _ = try await sut.syncRecentMessageCache(
                emailContext: emailContext,
                todoContext: todoContext
            )

            let refreshedEmails = try emailContext.fetch(FetchDescriptor<EmailMessage>())
            let rehydratedOld = try #require(refreshedEmails.first { $0.id == oldID })
            let stillArchived = try #require(refreshedEmails.first { $0.id == archivedID })
            let secondRequests = secondProbe.snapshot()

            #expect(rehydratedOld.isInInbox)
            #expect(stillArchived.isInInbox)
            #expect(
                secondRequests.listRequests.contains(
                    GmailListRequest(query: "newer_than:30d", labelID: "INBOX")
                )
            )
            #expect(secondRequests.metadataMessageIDs.contains(oldID))
        }
    }

    @Test("최근 metadata가 없어도 기존 받은편지함 상태를 유지한다")
    @MainActor
    func testSyncPersistsVisibilityWithoutMetadataUpserts() async throws {
        try await withIsolatedProviderState {
            let defaults = UserDefaults.standard
            let key = EmailAnalysisLookbackPolicy.lookbackSettingKey
            let hadStoredLookback = defaults.object(forKey: key) != nil
            let priorLookback = defaults.integer(forKey: key)
            defer {
                resetSharedState()
                if hadStoredLookback {
                    defaults.set(priorLookback, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
                sut.session = .shared
            }

            resetSharedState()
            defaults.set(3, forKey: key)
            seedGmailTokens()

            let emailContainer = try makeEmailContainer()
            let emailContext = ModelContext(emailContainer)
            emailContext.autosaveEnabled = false
            let archivedID = "active-outside-recent-inbox"
            let archivedEmail = EmailMessage(
                id: archivedID,
                subject: "Archived",
                receivedAt: Date(),
                labelIDs: ["INBOX", "CATEGORY_UPDATES"],
                isInInbox: true
            )
            emailContext.insert(archivedEmail)
            try emailContext.save()

            let probe = GmailSyncRequestProbe()
            MockURLProtocol.requestHandler = makeGmailSyncRequestHandler(
                lookbackDays: 3,
                activeMessageIDs: [archivedID],
                recentInboxMessageIDs: [],
                metadataByID: [
                    archivedID: (Date(), ["CATEGORY_UPDATES"])
                ],
                probe: probe
            )

            _ = try await sut.syncRecentMessageCache(emailContext: emailContext)

            #expect(archivedEmail.isInInbox)
            #expect(emailContext.hasChanges == false)
            #expect(probe.snapshot().metadataMessageIDs.isEmpty)
        }
    }

    @Test("최근 INBOX 관측은 앞선 활성 목록에서 누락된 메일의 삭제를 막는다")
    @MainActor
    func testRecentInboxSnapshotProtectsMailFromStaleDeletionProof() async throws {
        try await withIsolatedProviderState {
            let defaults = UserDefaults.standard
            let key = EmailAnalysisLookbackPolicy.lookbackSettingKey
            let hadStoredLookback = defaults.object(forKey: key) != nil
            let priorLookback = defaults.integer(forKey: key)
            defer {
                resetSharedState()
                if hadStoredLookback {
                    defaults.set(priorLookback, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
                sut.session = .shared
            }

            resetSharedState()
            defaults.set(3, forKey: key)
            seedGmailTokens()

            let emailContainer = try makeEmailContainer()
            let emailContext = ModelContext(emailContainer)
            let todoContainer = try makeTodoContainer()
            let todoContext = ModelContext(todoContainer)
            let messageID = "recently-restored-inbox"
            let receivedAt = Date().addingTimeInterval(-60)
            emailContext.insert(
                EmailMessage(
                    id: messageID,
                    subject: "Restored",
                    receivedAt: receivedAt,
                    labelIDs: ["INBOX", "CATEGORY_UPDATES"],
                    isInInbox: true
                )
            )
            let linkedTodo = Todo(
                title: "Restored mail todo",
                source: .email,
                sourceRef: messageID
            )
            linkedTodo.calendarEventID = "restored-calendar-event-id"
            linkedTodo.calendarEventExternalID = "restored-calendar-external-id"
            todoContext.insert(linkedTodo)
            try emailContext.save()
            try todoContext.save()

            let probe = GmailSyncRequestProbe()
            MockURLProtocol.requestHandler = makeGmailSyncRequestHandler(
                lookbackDays: 3,
                activeMessageIDs: [],
                recentInboxMessageIDs: [messageID],
                metadataByID: [
                    messageID: (receivedAt, ["INBOX", "CATEGORY_UPDATES"])
                ],
                probe: probe
            )

            _ = try await sut.syncRecentMessageCache(
                emailContext: emailContext,
                todoContext: todoContext
            )

            let storedEmail = try #require(
                try emailContext.fetch(FetchDescriptor<EmailMessage>())
                    .first { $0.id == messageID }
            )
            let storedTodo = try #require(
                try todoContext.fetch(FetchDescriptor<Todo>())
                    .first { $0.sourceRef == messageID }
            )
            #expect(storedEmail.isInInbox)
            #expect(storedTodo.calendarEventID == "restored-calendar-event-id")
            #expect(storedTodo.calendarEventExternalID == "restored-calendar-external-id")
            #expect(probe.snapshot().metadataMessageIDs == Set([messageID]))
        }
    }

    @Test("받은편지함 page는 INBOX 전체 기간을 요청하고 metadata를 안정 정렬한다")
    func testFetchInboxPageUsesNativePagingAndStableMetadataOrder() async throws {
        try await withIsolatedProviderState {
            resetSharedState()
            defer {
                resetSharedState()
                sut.session = .shared
            }
            seedGmailTokens()

            let probe = GmailMailboxRequestProbe()
            let tiedDate = Date(timeIntervalSince1970: 1_800_000_000)
            MockURLProtocol.requestHandler = { request in
                let url = try #require(request.url)
                if url.host == "oauth2.googleapis.com" {
                    return (
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        #"{"access_token":"new-access","expires_in":3600}"#.data(using: .utf8)
                    )
                }
                if url.path.hasSuffix("/messages") {
                    probe.recordList(url)
                    let components = try #require(
                        URLComponents(url: url, resolvingAgainstBaseURL: false)
                    )
                    let pageToken = components.queryItems?
                        .first { $0.name == "pageToken" }?.value
                    let payload = pageToken == "opaque-next"
                        ? #"{"messages":[{"id":"older"}]}"#
                        : #"{"messages":[{"id":"first"},{"id":"second"},{"id":"gone"}],"nextPageToken":"opaque-next"}"#
                    return (
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        payload.data(using: .utf8)
                    )
                }

                let messageID = url.lastPathComponent
                probe.recordMetadata(messageID: messageID)
                if messageID == "gone" {
                    return (
                        HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                        Data()
                    )
                }
                if messageID == "first" {
                    Thread.sleep(forTimeInterval: 0.03)
                }
                let receivedAt = messageID == "older"
                    ? tiedDate.addingTimeInterval(-60)
                    : tiedDate
                let labels = messageID == "first"
                    ? ["INBOX", "UNREAD", "CATEGORY_PERSONAL"]
                    : ["INBOX", "CATEGORY_UPDATES"]
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try gmailMessagePayload(
                        id: messageID,
                        receivedAt: receivedAt,
                        labelIDs: labels
                    )
                )
            }

            let firstPage = try await sut.fetchInboxPage(after: nil)
            #expect(firstPage.messages.map(\.providerMessageID) == ["first", "second"])
            #expect(firstPage.messages.map(\.isRead) == [false, true])
            #expect(firstPage.nextCursor == "opaque-next")
            #expect(firstPage.messages.allSatisfy { $0.isInInbox })
            #expect(firstPage.messages[0].gmailLabelIDs.contains("CATEGORY_PERSONAL"))

            let secondPage = try await sut.fetchInboxPage(after: firstPage.nextCursor)
            #expect(secondPage.messages.map(\.providerMessageID) == ["older"])
            #expect(secondPage.nextCursor == nil)

            let listURLs = probe.snapshot().listURLs
            #expect(listURLs.count == 2)
            for url in listURLs {
                let components = try #require(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)
                )
                let query = components.queryItems ?? []
                #expect(query.first { $0.name == "maxResults" }?.value == "100")
                #expect(query.first { $0.name == "labelIds" }?.value == "INBOX")
                #expect(query.contains { $0.name == "q" } == false)
            }
            let secondComponents = try #require(
                URLComponents(url: listURLs[1], resolvingAgainstBaseURL: false)
            )
            #expect(
                secondComponents.queryItems?
                    .first { $0.name == "pageToken" }?.value == "opaque-next"
            )
        }
    }

    @Test("받은편지함 complete index는 500개 page를 끝까지 순회하고 partial failure를 버린다")
    func testFetchInboxMessageIDsCompletesOrThrows() async throws {
        try await withIsolatedProviderState {
            resetSharedState()
            defer {
                resetSharedState()
                sut.session = .shared
            }
            seedGmailTokens()

            let probe = GmailMailboxRequestProbe()
            MockURLProtocol.requestHandler = { request in
                let url = try #require(request.url)
                if url.host == "oauth2.googleapis.com" {
                    return (
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        #"{"access_token":"new-access","expires_in":3600}"#.data(using: .utf8)
                    )
                }
                probe.recordList(url)
                let components = try #require(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)
                )
                let token = components.queryItems?
                    .first { $0.name == "pageToken" }?.value
                let payload = token == "index-next"
                    ? #"{"messages":[{"id":"b"},{"id":"c"}]}"#
                    : #"{"messages":[{"id":"a"},{"id":"b"}],"nextPageToken":"index-next"}"#
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    payload.data(using: .utf8)
                )
            }

            #expect(try await sut.fetchInboxMessageIDs() == Set(["a", "b", "c"]))
            let successfulURLs = probe.snapshot().listURLs
            #expect(successfulURLs.count == 2)
            for url in successfulURLs {
                let components = try #require(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)
                )
                #expect(
                    components.queryItems?
                        .first { $0.name == "maxResults" }?.value == "500"
                )
                #expect(
                    components.queryItems?
                        .first { $0.name == "labelIds" }?.value == "INBOX"
                )
            }

            MockURLProtocol.requestHandler = { request in
                let url = try #require(request.url)
                if url.host == "oauth2.googleapis.com" {
                    return (
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        #"{"access_token":"new-access","expires_in":3600}"#.data(using: .utf8)
                    )
                }
                let components = try #require(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)
                )
                let token = components.queryItems?
                    .first { $0.name == "pageToken" }?.value
                if token == "index-next" {
                    return (
                        HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        Data()
                    )
                }
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"messages":[{"id":"partial"}],"nextPageToken":"index-next"}"#
                        .data(using: .utf8)
                )
            }
            await #expect(throws: EmailError.apiFailed) {
                try await sut.fetchInboxMessageIDs()
            }
        }
    }

    @Test("본문 fetch는 최신 Gmail metadata와 plain/html을 함께 반환한다")
    func testFetchMessageContentReturnsBodyAndLatestMetadata() async throws {
        try await withIsolatedProviderState {
            resetSharedState()
            defer {
                resetSharedState()
                sut.session = .shared
            }
            seedGmailTokens()

            let receivedAt = Date(timeIntervalSince1970: 1_800_000_100)
            MockURLProtocol.requestHandler = { request in
                let url = try #require(request.url)
                if url.host == "oauth2.googleapis.com" {
                    return (
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        #"{"access_token":"new-access","expires_in":3600}"#.data(using: .utf8)
                    )
                }
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try gmailMessagePayload(
                        id: "content-id",
                        receivedAt: receivedAt,
                        labelIDs: ["INBOX", "CATEGORY_SOCIAL"],
                        subject: "Content subject",
                        plainBody: "Plain content",
                        htmlBody: "<p>HTML content</p>"
                    )
                )
            }

            let content = try await sut.fetchMessageContent(messageID: "content-id")
            #expect(content.body == "Plain content")
            #expect(content.htmlBody == "<p>HTML content</p>")
            #expect(content.metadata.provider == .gmail)
            #expect(content.metadata.providerMessageID == "content-id")
            #expect(content.metadata.subject == "Content subject")
            #expect(content.metadata.receivedAt == receivedAt)
            #expect(content.metadata.isRead)
            #expect(content.metadata.isInInbox)
            #expect(content.metadata.gmailLabelIDs == ["INBOX", "CATEGORY_SOCIAL"])
        }
    }

    @Test("metadata 5xx 뒤 같은 cursor로 받은편지함 page를 재시도할 수 있다")
    func testFetchInboxPageRetriesSameCursorAfterMetadataFailure() async throws {
        try await withIsolatedProviderState {
            resetSharedState()
            defer {
                resetSharedState()
                sut.session = .shared
            }
            seedGmailTokens()

            let probe = GmailMailboxRetryProbe()
            MockURLProtocol.requestHandler = { request in
                let url = try #require(request.url)
                if url.host == "oauth2.googleapis.com" {
                    return (
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        #"{"access_token":"new-access","expires_in":3600}"#.data(using: .utf8)
                    )
                }
                if url.path.hasSuffix("/messages") {
                    let components = try #require(
                        URLComponents(url: url, resolvingAgainstBaseURL: false)
                    )
                    probe.recordPageToken(
                        components.queryItems?
                            .first { $0.name == "pageToken" }?.value
                    )
                    return (
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        #"{"messages":[{"id":"retry-id"}],"nextPageToken":"after-retry"}"#
                            .data(using: .utf8)
                    )
                }
                let attempt = probe.nextMetadataAttempt()
                if attempt == 1 {
                    return (
                        HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        Data()
                    )
                }
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try gmailMessagePayload(
                        id: "retry-id",
                        receivedAt: Date(timeIntervalSince1970: 1_800_000_200),
                        labelIDs: ["INBOX"]
                    )
                )
            }

            await #expect(throws: EmailError.apiFailed) {
                try await sut.fetchInboxPage(after: "same-cursor")
            }
            let page = try await sut.fetchInboxPage(after: "same-cursor")
            #expect(page.messages.map(\.providerMessageID) == ["retry-id"])
            #expect(page.nextCursor == "after-retry")
            let capturedTokens = probe.capturedPageTokens()
            #expect(capturedTokens.count == 2)
            #expect(capturedTokens.allSatisfy { $0 == "same-cursor" })
        }
    }

}
