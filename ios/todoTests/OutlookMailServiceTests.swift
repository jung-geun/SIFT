import Foundation
import SwiftData
import Testing
@testable import todo

final class OutlookMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
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
            if let data {
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

@Suite("OutlookMailService Graph 요청", .serialized)
struct OutlookMailServiceTests {
    private let sut = OutlookMailService.shared

    private func resetSharedState() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OutlookMockURLProtocol.self]
        sut.session = URLSession(configuration: config)
        sut.testAccessTokenProvider = nil
        OutlookMockURLProtocol.requestHandler = nil
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
    }

    @Test("list는 /me/messages 와 ImmutableId 헤더를 사용한다")
    func testListMessagesUsesBroadMessagesEndpointAndImmutableHeader() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            resetSharedState()
            defer {
                sut.session = .shared
                sut.testAccessTokenProvider = nil
                resetSharedState()
            }

            sut.testAccessTokenProvider = { "token" }

            var capturedListRequest: URLRequest?

            OutlookMockURLProtocol.requestHandler = { request in
                let url = try #require(request.url)
                let path = url.path
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!

                if path.hasSuffix("/mailFolders/junkemail") {
                    return (response, #"{"id":"junk-folder"}"#.data(using: .utf8))
                }
                if path.hasSuffix("/mailFolders/deleteditems") {
                    return (response, #"{"id":"deleted-folder"}"#.data(using: .utf8))
                }
                if path.hasSuffix("/me/messages") {
                    capturedListRequest = request
                    let payload = #"{"value":[{"id":"immutable-1","conversationId":"thread-1","internetMessageId":"<one@example.com>","subject":"subject","bodyPreview":"preview","body":{"contentType":"text","content":"body"},"receivedDateTime":"2026-06-28T12:00:00Z","isRead":false,"parentFolderId":"inbox-folder","from":{"emailAddress":{"name":"Sender","address":"sender@example.com"}}}]}"#
                    return (response, payload.data(using: .utf8))
                }

                Issue.record("Unexpected request: \(path)")
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
            }

            let emailContext = ModelContext(try makeEmailContainer())
            let todoContext = ModelContext(try makeTodoContainer())
            _ = try await sut.syncRecentMessageCache(emailContext: emailContext, todoContext: todoContext)

            let request = try #require(capturedListRequest)
            let requestURL = try #require(request.url)
            let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
            let prefer = request.value(forHTTPHeaderField: "Prefer") ?? ""

            #expect(requestURL.path == "/v1.0/me/messages")
            #expect(components.queryItems?.contains(where: { $0.name == "$filter" && ($0.value ?? "").contains("receivedDateTime ge") }) == true)
            #expect(components.queryItems?.contains(where: { $0.name == "$orderby" && $0.value == "receivedDateTime desc" }) == true)
            #expect(prefer.contains("IdType=\"ImmutableId\""))
            #expect(!requestURL.path.contains("/mailFolders/inbox/messages"))
        }
    }

    @Test("sync는 Junk/Deleted 부모 폴더 메일을 제외한다")
    @MainActor
    func testSyncExcludesJunkAndDeletedParentFolders() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            resetSharedState()
            defer {
                sut.session = .shared
                sut.testAccessTokenProvider = nil
                resetSharedState()
            }

            sut.testAccessTokenProvider = { "token" }

            OutlookMockURLProtocol.requestHandler = { request in
                let url = try #require(request.url)
                let path = url.path
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!

                if path.hasSuffix("/mailFolders/junkemail") {
                    return (response, #"{"id":"junk-folder"}"#.data(using: .utf8))
                }
                if path.hasSuffix("/mailFolders/deleteditems") {
                    return (response, #"{"id":"deleted-folder"}"#.data(using: .utf8))
                }
                if path.hasSuffix("/me/messages") {
                    let payload = #"{"value":[{"id":"active-id","conversationId":"thread-1","internetMessageId":"<one@example.com>","subject":"Active","bodyPreview":"active preview","body":{"contentType":"text","content":"active body"},"receivedDateTime":"2026-06-28T12:00:00Z","isRead":false,"parentFolderId":"inbox-folder","from":{"emailAddress":{"name":"Sender","address":"sender@example.com"}}},{"id":"junk-id","conversationId":"thread-2","internetMessageId":"<two@example.com>","subject":"Junk","bodyPreview":"junk preview","body":{"contentType":"text","content":"junk body"},"receivedDateTime":"2026-06-28T11:00:00Z","isRead":true,"parentFolderId":"junk-folder","from":{"emailAddress":{"name":"Junk","address":"junk@example.com"}}},{"id":"deleted-id","conversationId":"thread-3","internetMessageId":"<three@example.com>","subject":"Deleted","bodyPreview":"deleted preview","body":{"contentType":"text","content":"deleted body"},"receivedDateTime":"2026-06-28T10:00:00Z","isRead":true,"parentFolderId":"deleted-folder","from":{"emailAddress":{"name":"Deleted","address":"deleted@example.com"}}}]}"#
                    return (response, payload.data(using: .utf8))
                }

                Issue.record("Unexpected request: \(path)")
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
            }

            let emailContext = ModelContext(try makeEmailContainer())
            let todoContext = ModelContext(try makeTodoContainer())
            _ = try await sut.syncRecentMessageCache(emailContext: emailContext, todoContext: todoContext)

            let providerRawValue = MailProvider.outlook.rawValue
            let descriptor = FetchDescriptor<EmailMessage>(
                predicate: #Predicate<EmailMessage> { email in
                    email.providerRawValue == providerRawValue
                }
            )
            let stored = try emailContext.fetch(descriptor)

            #expect(stored.count == 1)
            let email = try #require(stored.first)
            #expect(email.provider == .outlook)
            #expect(email.providerMessageID == "active-id")
            #expect(email.todoSourceRef == "outlook:active-id")
        }
    }

    @Test("markAsRead는 PATCH isRead=true 를 사용한다")
    func testMarkAsReadUsesPatchIsRead() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            resetSharedState()
            defer {
                sut.session = .shared
                sut.testAccessTokenProvider = nil
                resetSharedState()
            }

            sut.testAccessTokenProvider = { "token" }
            var capturedRequest: URLRequest?

            OutlookMockURLProtocol.requestHandler = { request in
                capturedRequest = request
                let url = try #require(request.url)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, #"{}"#.data(using: .utf8))
            }

            try await sut.markAsRead(messageID: "immutable-id")

            let request = try #require(capturedRequest)
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let prefer = request.value(forHTTPHeaderField: "Prefer") ?? ""

            #expect(request.httpMethod == "PATCH")
            #expect(try #require(request.url).path.hasSuffix("/me/messages/immutable-id"))
            #expect(json["isRead"] as? Bool == true)
            #expect(prefer.contains("IdType=\"ImmutableId\""))
        }
    }

    @Test("trash는 deleteditems 이동 엔드포인트를 사용한다")
    func testTrashUsesMoveToDeletedItems() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            resetSharedState()
            defer {
                sut.session = .shared
                sut.testAccessTokenProvider = nil
                resetSharedState()
            }

            sut.testAccessTokenProvider = { "token" }
            var capturedRequest: URLRequest?

            OutlookMockURLProtocol.requestHandler = { request in
                capturedRequest = request
                let url = try #require(request.url)
                let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, #"{}"#.data(using: .utf8))
            }

            try await sut.trashMessage(messageID: "immutable-id")

            let request = try #require(capturedRequest)
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

            #expect(request.httpMethod == "POST")
            #expect(try #require(request.url).path.hasSuffix("/me/messages/immutable-id/move"))
            #expect(json["destinationId"] as? String == "deleteditems")
        }
    }
}
