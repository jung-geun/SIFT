import Foundation
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
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {}
}

@Suite("GmailService 에러 케이스 및 로그 검증", .serialized)
struct GmailServiceTests {
    
    private let sut = EmailService.shared
    
    private func resetSharedState() {
        MockURLProtocol.requestHandler = nil
        KeychainStore.deleteAny(service: "pieroot.todo.gmail", account: "access_token")
        KeychainStore.deleteAny(service: "pieroot.todo.gmail", account: "refresh_token")
        UserDefaults.standard.removeObject(forKey: "pieroot.todo.emailLookbackDays")
    }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        sut.session = URLSession(configuration: config)
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
        KeychainStore.set(service: "pieroot.todo.gmail", account: "access_token", value: "old-access")
        KeychainStore.set(service: "pieroot.todo.gmail", account: "refresh_token", value: "old-refresh")

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
        KeychainStore.set(service: "pieroot.todo.gmail", account: "access_token", value: "valid-access")
        KeychainStore.set(service: "pieroot.todo.gmail", account: "refresh_token", value: "valid-refresh")

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
        KeychainStore.set(service: "pieroot.todo.gmail", account: "access_token", value: "valid-access")
        KeychainStore.set(service: "pieroot.todo.gmail", account: "refresh_token", value: "valid-refresh")

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
        KeychainStore.set(service: "pieroot.todo.gmail", account: "access_token", value: "valid-access")

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
