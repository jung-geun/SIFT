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

@MainActor
@Suite("OutlookMailService Graph 요청", .serialized)
struct OutlookMailServiceTests {
    private let sut = OutlookMailService.shared

    private func withIsolatedProviderState<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        try await AIProviderTestIsolation.shared.withLock {
            let originalSession = sut.session
            let originalTokenProvider = sut.testAccessTokenProvider
            let defaults = UserDefaults.standard
            let keys = [
                "pieroot.todo.iCloudSyncEnabled",
                "pieroot.todo.analyzedMessageIDs",
                "pieroot.todo.analyzedMessageIDs.isLocal",
                "pieroot.todo.lastEmailFetchDate"
            ]
            let savedDefaults = keys.map {
                ($0, defaults.object(forKey: $0))
            }
            defer {
                OutlookMockURLProtocol.requestHandler = nil
                sut.session = originalSession
                sut.testAccessTokenProvider = originalTokenProvider
                for (key, value) in savedDefaults {
                    if let value {
                        defaults.set(value, forKey: key)
                    } else {
                        defaults.removeObject(forKey: key)
                    }
                }
            }
            return try await operation()
        }
    }


    private func resetSharedState() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OutlookMockURLProtocol.self]
        sut.session = URLSession(configuration: config)
        sut.testAccessTokenProvider = nil
        OutlookMockURLProtocol.requestHandler = nil
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "pieroot.todo.iCloudSyncEnabled")
        defaults.removeObject(forKey: "pieroot.todo.analyzedMessageIDs")
        defaults.set(true, forKey: "pieroot.todo.analyzedMessageIDs.isLocal")
        defaults.removeObject(forKey: "pieroot.todo.lastEmailFetchDate")
    }

    private func makeEmailContainer() throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: AppDataContainer.emailSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: AppDataContainer.emailSchema,
            configurations: [config]
        )
    }

    private func makeTodoContainer() throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: AppDataContainer.appSchema,
            configurations: [config]
        )
    }


    @Test("Inbox page는 native metadata와 opaque nextLink를 보존한다")
    func testInboxPageUsesNativeMetadataAndOpaqueNextLink() async throws {
        try await withIsolatedProviderState {
            resetSharedState()
            defer {
                resetSharedState()
                sut.session = .shared
            }
            sut.testAccessTokenProvider = { "token" }

            let opaqueNextLink = "https://graph.microsoft.com/v1.0/opaque-page?cursor=abc%2B123"
            var capturedRequests: [URLRequest] = []
            OutlookMockURLProtocol.requestHandler = { request in
                let url = try #require(request.url)
                capturedRequests.append(request)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                if url.absoluteString == opaqueNextLink {
                    let payload = #"{"value":[{"id":"immutable-2","conversationId":"thread-2","internetMessageId":"<two@example.com>","subject":"Other","bodyPreview":"second preview","receivedDateTime":"2026-06-28T11:00:00Z","isRead":true,"parentFolderId":"inbox-folder","inferenceClassification":"other","categories":["Blue category"],"from":{"emailAddress":{"name":"Second","address":"second@example.com"}}}]}"#
                    return (response, payload.data(using: .utf8))
                }
                let payload = """
                {"value":[{"id":"immutable-1","conversationId":"thread-1","internetMessageId":"<one@example.com>","subject":"Focused","bodyPreview":"first preview","receivedDateTime":"2026-06-28T12:00:00Z","isRead":false,"parentFolderId":"inbox-folder","inferenceClassification":"focused","categories":["Red category","고객"] ,"from":{"emailAddress":{"name":"Sender","address":"sender@example.com"}}}],"@odata.nextLink":"\(opaqueNextLink)"}
                """
                return (response, payload.data(using: .utf8))
            }

            let firstPage = try await sut.fetchInboxPage(after: nil)
            #expect(firstPage.nextCursor == opaqueNextLink)
            let first = try #require(firstPage.messages.first)
            #expect(first.provider == .outlook)
            #expect(first.providerMessageID == "immutable-1")
            #expect(first.outlookInferenceClassificationRawValue == "focused")
            #expect(first.providerCategoryNames == ["Red category", "고객"])
            #expect(first.providerFolderID == "inbox-folder")
            #expect(first.isRead == false)
            #expect(first.isInInbox)

            let secondPage = try await sut.fetchInboxPage(after: firstPage.nextCursor)
            #expect(secondPage.messages.map(\.providerMessageID) == ["immutable-2"])
            #expect(secondPage.messages.first?.outlookInferenceClassificationRawValue == "other")
            #expect(secondPage.nextCursor == nil)

            #expect(capturedRequests.count == 2)
            let firstRequest = capturedRequests[0]
            let firstURL = try #require(firstRequest.url)
            let components = try #require(
                URLComponents(url: firstURL, resolvingAgainstBaseURL: false)
            )
            let select = components.queryItems?
                .first { $0.name == "$select" }?.value ?? ""
            let selectedFields = Set(select.split(separator: ",").map(String.init))
            #expect(firstURL.path == "/v1.0/me/mailFolders/inbox/messages")
            #expect(components.queryItems?.first { $0.name == "$top" }?.value == "100")
            #expect(
                components.queryItems?
                    .first { $0.name == "$orderby" }?.value == "receivedDateTime desc"
            )
            #expect(selectedFields.contains("body") == false)
            #expect(selectedFields.contains("inferenceClassification"))
            #expect(selectedFields.contains("categories"))
            #expect(selectedFields.contains("parentFolderId"))
            #expect(components.queryItems?.contains { $0.name == "$filter" } == false)
            #expect(
                firstRequest.value(forHTTPHeaderField: "Prefer")?
                    .contains("IdType=\"ImmutableId\"") == true
            )
            #expect(capturedRequests[1].url?.absoluteString == opaqueNextLink)
        }
    }

    @Test("recent Inbox sync는 positive metadata만 upsert하고 body/analysis를 보존한다")
    @MainActor
    func testRecentInboxSyncOnlyPositiveUpsertsMetadata() async throws {
        try await withIsolatedProviderState {
            resetSharedState()
            defer {
                resetSharedState()
                sut.session = .shared
            }
            sut.testAccessTokenProvider = { "token" }

            var capturedRequest: URLRequest?
            OutlookMockURLProtocol.requestHandler = { request in
                let url = try #require(request.url)
                capturedRequest = request
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                let payload = #"{"value":[{"id":"active-id","conversationId":"thread-1","internetMessageId":"<one@example.com>","subject":"Active","bodyPreview":"active preview","receivedDateTime":"2026-06-28T12:00:00Z","isRead":false,"parentFolderId":"inbox-folder","inferenceClassification":"focused","categories":["Project Alpha"],"from":{"emailAddress":{"name":"Sender","address":"sender@example.com"}}}]}"#
                return (response, payload.data(using: .utf8))
            }

            let emailContainer = try makeEmailContainer()
            let emailContext = ModelContext(emailContainer)
            let todoContainer = try makeTodoContainer()
            let todoContext = ModelContext(todoContainer)
            let active = EmailMessage(
                id: "active-id",
                subject: "Old subject",
                body: "preserved body",
                htmlBody: "<p>preserved HTML</p>",
                receivedAt: .distantPast,
                provider: .outlook,
                rawMessageID: "active-id",
                isInInbox: false,
                outlookInferenceClassificationRawValue: "other",
                providerCategoryNames: ["Old"],
                providerFolderID: "old-folder"
            )
            active.analysisState = .analyzed
            active.analysisSummary = "preserved summary"
            let unrelated = EmailMessage(
                id: "sent-id",
                subject: "Sent",
                provider: .outlook,
                rawMessageID: "sent-id",
                isInInbox: false
            )
            emailContext.insert(active)
            emailContext.insert(unrelated)
            try emailContext.save()

            let result = try await sut.syncRecentMessageCache(
                emailContext: emailContext,
                todoContext: todoContext
            )

            #expect(result.prunedMessageCount == 0)
            #expect(result.prunedTodoCount == 0)
            #expect(active.isInInbox)
            #expect(active.body == "preserved body")
            #expect(active.htmlBody == "<p>preserved HTML</p>")
            #expect(active.analysisState == .analyzed)
            #expect(active.analysisSummary == "preserved summary")
            #expect(active.outlookInboxClassification == .focused)
            #expect(active.providerCategoryNames == ["Project Alpha"])
            #expect(active.providerFolderID == "inbox-folder")
            #expect(unrelated.isInInbox == false)

            let request = try #require(capturedRequest)
            let url = try #require(request.url)
            let components = try #require(
                URLComponents(url: url, resolvingAgainstBaseURL: false)
            )
            let select = components.queryItems?
                .first { $0.name == "$select" }?.value ?? ""
            let selectedFields = Set(select.split(separator: ",").map(String.init))
            #expect(url.path == "/v1.0/me/mailFolders/inbox/messages")
            #expect(components.queryItems?.contains { $0.name == "$filter" } == true)
            #expect(selectedFields.contains("body") == false)
            #expect(selectedFields.contains("inferenceClassification"))
            #expect(selectedFields.contains("categories"))
            #expect(selectedFields.contains("parentFolderId"))
        }
    }

    @Test("markAsRead는 PATCH isRead=true 를 사용한다")
    func testMarkAsReadUsesPatchIsRead() async throws {
        try await withIsolatedProviderState {
            resetSharedState()
            defer {
                resetSharedState()
                sut.session = .shared
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
        try await withIsolatedProviderState {
            resetSharedState()
            defer {
                resetSharedState()
                sut.session = .shared
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
    @Test("complete Inbox index는 1000개 page를 끝까지 순회하고 partial failure를 버린다")
    func testInboxMessageIDsCompletesOrThrows() async throws {
        try await withIsolatedProviderState {
            resetSharedState()
            defer {
                resetSharedState()
                sut.session = .shared
            }
            sut.testAccessTokenProvider = { "token" }

            let nextLink = "https://graph.microsoft.com/v1.0/index-next?cursor=opaque"
            var capturedURLs: [URL] = []
            OutlookMockURLProtocol.requestHandler = { request in
                let url = try #require(request.url)
                capturedURLs.append(url)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                if url.absoluteString == nextLink {
                    return (
                        response,
                        #"{"value":[{"id":"b"},{"id":"c"}]}"#.data(using: .utf8)
                    )
                }
                let payload = """
                {"value":[{"id":"a"},{"id":"b"}],"@odata.nextLink":"\(nextLink)"}
                """
                return (response, payload.data(using: .utf8))
            }

            #expect(try await sut.fetchInboxMessageIDs() == Set(["a", "b", "c"]))
            #expect(capturedURLs.count == 2)
            let firstComponents = try #require(
                URLComponents(url: capturedURLs[0], resolvingAgainstBaseURL: false)
            )
            #expect(capturedURLs[0].path == "/v1.0/me/mailFolders/inbox/messages")
            #expect(
                firstComponents.queryItems?
                    .first { $0.name == "$top" }?.value == "1000"
            )
            #expect(
                firstComponents.queryItems?
                    .first { $0.name == "$select" }?.value == "id"
            )
            #expect(capturedURLs[1].absoluteString == nextLink)

            OutlookMockURLProtocol.requestHandler = { request in
                let url = try #require(request.url)
                if url.absoluteString == nextLink {
                    return (
                        HTTPURLResponse(
                            url: url,
                            statusCode: 500,
                            httpVersion: nil,
                            headerFields: nil
                        )!,
                        Data()
                    )
                }
                let payload = """
                {"value":[{"id":"partial"}],"@odata.nextLink":"\(nextLink)"}
                """
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    payload.data(using: .utf8)
                )
            }
            await #expect(throws: OutlookMailError.apiFailed) {
                try await sut.fetchInboxMessageIDs()
            }
        }
    }

    @Test("본문 fetch는 HTML과 Outlook native metadata를 함께 반환한다")
    func testFetchMessageContentReturnsBodyAndNativeMetadata() async throws {
        try await withIsolatedProviderState {
            resetSharedState()
            defer {
                resetSharedState()
                sut.session = .shared
            }
            sut.testAccessTokenProvider = { "token" }

            var capturedRequest: URLRequest?
            OutlookMockURLProtocol.requestHandler = { request in
                capturedRequest = request
                let url = try #require(request.url)
                let payload = #"{"id":"content-id","conversationId":"content-thread","internetMessageId":"<content@example.com>","subject":"Content","bodyPreview":"preview","body":{"contentType":"html","content":"<p>Hello <strong>Outlook</strong></p>"},"receivedDateTime":"2026-06-28T12:00:00Z","isRead":true,"parentFolderId":"inbox-folder","inferenceClassification":"focused","categories":["VIP","고객"],"from":{"emailAddress":{"name":"Sender","address":"sender@example.com"}}}"#
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    payload.data(using: .utf8)
                )
            }

            let content = try await sut.fetchMessageContent(messageID: "content-id")
            #expect(content.body.contains("Hello"))
            #expect(content.body.contains("Outlook"))
            #expect(content.htmlBody == "<p>Hello <strong>Outlook</strong></p>")
            #expect(content.metadata.provider == .outlook)
            #expect(content.metadata.providerMessageID == "content-id")
            #expect(content.metadata.outlookInferenceClassificationRawValue == "focused")
            #expect(content.metadata.providerCategoryNames == ["VIP", "고객"])
            #expect(content.metadata.providerFolderID == "inbox-folder")
            #expect(content.metadata.isRead)
            #expect(content.metadata.isInInbox)

            let request = try #require(capturedRequest)
            let url = try #require(request.url)
            let components = try #require(
                URLComponents(url: url, resolvingAgainstBaseURL: false)
            )
            let select = components.queryItems?
                .first { $0.name == "$select" }?.value ?? ""
            let selectedFields = Set(select.split(separator: ",").map(String.init))
            #expect(url.path == "/v1.0/me/messages/content-id")
            #expect(selectedFields.contains("body"))
            #expect(selectedFields.contains("inferenceClassification"))
            #expect(selectedFields.contains("categories"))
            #expect(selectedFields.contains("parentFolderId"))
            let prefer = request.value(forHTTPHeaderField: "Prefer") ?? ""
            #expect(prefer.contains("IdType=\"ImmutableId\""))
            #expect(prefer.contains("outlook.body-content-type") == false)
        }
    }

    @Test("broad extraction response는 EmailMessage Inbox 상태를 변경하지 않는다")
    @MainActor
    func testBroadExtractionDoesNotPersistMailboxRows() async throws {
        try await withIsolatedProviderState {
            let defaults = UserDefaults.standard
            let savedDefaults: [(String, Any?)] = [
                ("pieroot.todo.iCloudSyncEnabled", defaults.object(forKey: "pieroot.todo.iCloudSyncEnabled")),
                ("pieroot.todo.analyzedMessageIDs", defaults.object(forKey: "pieroot.todo.analyzedMessageIDs")),
                ("pieroot.todo.analyzedMessageIDs.isLocal", defaults.object(forKey: "pieroot.todo.analyzedMessageIDs.isLocal")),
                ("pieroot.todo.lastEmailFetchDate", defaults.object(forKey: "pieroot.todo.lastEmailFetchDate"))
            ]
            resetSharedState()
            defaults.set(false, forKey: "pieroot.todo.iCloudSyncEnabled")
            defer {
                resetSharedState()
                sut.session = .shared
                for (key, value) in savedDefaults {
                    if let value {
                        defaults.set(value, forKey: key)
                    } else {
                        defaults.removeObject(forKey: key)
                    }
                }
            }
            sut.testAccessTokenProvider = { "token" }

            var capturedBroadRequest: URLRequest?
            OutlookMockURLProtocol.requestHandler = { request in
                let url = try #require(request.url)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                if url.path.hasSuffix("/mailFolders/junkemail") {
                    return (response, #"{"id":"junk-folder"}"#.data(using: .utf8))
                }
                if url.path.hasSuffix("/mailFolders/deleteditems") {
                    return (response, #"{"id":"deleted-folder"}"#.data(using: .utf8))
                }
                if url.path.hasSuffix("/me/messages") {
                    capturedBroadRequest = request
                    let payload = #"{"value":[{"id":"sent-id","conversationId":"sent-thread","internetMessageId":"<sent@example.com>","subject":"Sent","bodyPreview":"sent preview","body":{"contentType":"text","content":"sent body"},"receivedDateTime":"2026-06-28T12:00:00Z","isRead":true,"parentFolderId":"sent-folder","from":{"emailAddress":{"name":"Me","address":"me@example.com"}}},{"id":"junk-id","conversationId":"junk-thread","internetMessageId":"<junk@example.com>","subject":"Junk","bodyPreview":"junk preview","body":{"contentType":"text","content":"junk body"},"receivedDateTime":"2026-06-28T11:00:00Z","isRead":false,"parentFolderId":"junk-folder","from":{"emailAddress":{"name":"Junk","address":"junk@example.com"}}}]}"#
                    return (response, payload.data(using: .utf8))
                }
                Issue.record("Unexpected request: \(url.absoluteString)")
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

            let emailContainer = try makeEmailContainer()
            let emailContext = ModelContext(emailContainer)
            let cachedSent = EmailMessage(
                id: "sent-id",
                subject: "Cached sent",
                provider: .outlook,
                rawMessageID: "sent-id",
                isInInbox: false
            )
            emailContext.insert(cachedSent)
            try emailContext.save()
            let todoContainer = try makeTodoContainer()
            let todoContext = ModelContext(todoContainer)

            _ = try await sut.fetchAndStoreExtractedItems(
                context: todoContext,
                allowFoundationModels: false
            )

            let stored = try emailContext.fetch(FetchDescriptor<EmailMessage>())
            #expect(stored.count == 1)
            #expect(stored.first === cachedSent)
            #expect(cachedSent.isInInbox == false)
            let request = try #require(capturedBroadRequest)
            let url = try #require(request.url)
            #expect(url.path == "/v1.0/me/messages")
            let components = try #require(
                URLComponents(url: url, resolvingAgainstBaseURL: false)
            )
            let select = components.queryItems?
                .first { $0.name == "$select" }?.value ?? ""
            #expect(Set(select.split(separator: ",").map(String.init)).contains("body"))
        }
    }

}
