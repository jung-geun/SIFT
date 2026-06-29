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

@Suite("GmailService 에러 케이스 및 로그 검증", .serialized)
struct GmailServiceTests {
    
    private let sut = EmailService.shared
    
    private func resetSharedState() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        sut.session = URLSession(configuration: config)
        MockURLProtocol.requestHandler = nil
        KeychainStore.deleteAny(service: "pieroot.todo.gmail", account: "access_token")
        KeychainStore.deleteAny(service: "pieroot.todo.gmail", account: "refresh_token")
        KeychainStore.deleteAny(service: "pieroot.todo.gmail", account: "scope_version")
        UserDefaults.standard.removeObject(forKey: "pieroot.todo.emailLookbackDays")
        UserDefaults.standard.removeObject(forKey: "pieroot.todo.dismissedMessageIDs")
        UserDefaults.standard.removeObject(forKey: "pieroot.todo.analyzedMessageIDs")
        UserDefaults.standard.removeObject(forKey: "pieroot.todo.senderDeletionCounts")
        UserDefaults.standard.removeObject(forKey: "pieroot.todo.suppressedSenders")
        UserDefaults.standard.set(false, forKey: "pieroot.todo.iCloudSyncEnabled")
    }

    private func seedGmailTokens(scopeVersion: String? = "gmail.modify.v1") {
        KeychainStore.set(service: "pieroot.todo.gmail", account: "access_token", value: "valid-access")
        KeychainStore.set(service: "pieroot.todo.gmail", account: "refresh_token", value: "valid-refresh")
        if let scopeVersion {
            KeychainStore.set(service: "pieroot.todo.gmail", account: "scope_version", value: scopeVersion)
        }
    }

    private func makeEmailContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: AppDataContainer.emailSchema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: AppDataContainer.emailSchema, configurations: [config])
    }

    private func makeTodoContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: AppDataContainer.appSchema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: AppDataContainer.appSchema, configurations: [config])
    }

    init() {
        resetSharedState()
        // UserDefaults.standard.set(false, forKey: "pieroot.todo.iCloudSyncEnabled")
    }
    
    @Test("Refresh Token 실패 (400 invalid_grant) 시 토큰 삭제 및 에러 발생 확인")
    func testRefreshTokenInvalidGrant() async throws {
        defer {
            sut.session = .shared
            resetSharedState()
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
    
    @Test("Gmail API 호출 실패 (500) 시 apiFailed 에러 발생 확인")
    func testGmailAPIFailure500() async throws {
        resetSharedState()
        defer {
            sut.session = .shared
            resetSharedState()
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

    @Test("권한 부족 (403 Forbidden) 시 markAsRead 실패 확인")
    func testMarkAsReadForbidden() async throws {
        resetSharedState()
        defer {
            sut.session = .shared
            resetSharedState()
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

    @Test("구 readonly 토큰은 modify 전에 제거된다")
    func testReadonlyScopeTokensAreClearedBeforeModify() async throws {
        resetSharedState()
        defer {
            sut.session = .shared
            resetSharedState()
        }

        seedGmailTokens(scopeVersion: nil)

        await #expect(throws: EmailError.notAuthenticated) {
            try await sut.markAsRead(messageID: "msg-old-scope")
        }

        #expect(KeychainStore.get(service: "pieroot.todo.gmail", account: "access_token") == nil)
        #expect(KeychainStore.get(service: "pieroot.todo.gmail", account: "refresh_token") == nil)
        #expect(KeychainStore.get(service: "pieroot.todo.gmail", account: "scope_version") == nil)
    }

    @Test("markAsRead는 gmail.modify 본문을 사용한다")
    func testMarkAsReadUsesGmailModifyBody() async throws {
        resetSharedState()
        defer {
            sut.session = .shared
            resetSharedState()
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

    @Test("trashMessage는 Gmail trash 엔드포인트를 사용한다")
    func testTrashMessageUsesGmailTrashEndpoint() async throws {
        resetSharedState()
        defer {
            sut.session = .shared
            resetSharedState()
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

    @Test("여러 메시지 조회 시 배치 처리 및 바디 fallback 확인")
    func testFetchRecentMessagesBatchingAndFallback() async throws {
        defer {
            sut.session = .shared
            resetSharedState()
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

    @Test("메일 sync는 삭제된 로컬 메일과 연결 todo만 prune하고 페이지 밖 원격 메일은 유지한다")
    @MainActor
    func testSyncRecentMessageCachePrunesOnlyTrulyMissingMessages() async throws {
        defer {
            sut.session = .shared
            resetSharedState()
        }
        resetSharedState()
        UserDefaults.standard.set(7, forKey: "pieroot.todo.emailLookbackDays")
        seedGmailTokens()

        let emailContext = ModelContext(try makeEmailContainer())
        let todoContext = ModelContext(try makeTodoContainer())
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
        #expect(result.prunedTodoCount == 3)
        #expect(storedEmails.contains(where: { $0.id == "msg-101" }))
        #expect(storedEmails.contains(where: { $0.id == "msg-old-local" }))
        #expect(storedEmails.contains(where: { $0.id == "msg-delete" }) == false)
        #expect(storedTodos.contains(where: { $0.sourceRef == "msg-101" }))
        #expect(storedTodos.contains(where: { $0.sourceRef == "msg-delete" }) == false)
        #expect(storedTodos.contains(where: { $0.sourceRef == "msg-delete-no-cache" }) == false)
        #expect(storedTodos.contains(where: { $0.sourceRef == "msg-trash" }) == false)
        #expect(EmailLearningStore.shared.isDismissed("msg-delete") == false)
    }

}
