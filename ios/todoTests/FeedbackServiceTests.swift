import Foundation
import Testing
@testable import todo

@Suite("Anonymous feedback submission boundaries")
@MainActor
struct FeedbackServiceTests {
    private let app = FeedbackAppMetadata(
        version: "1.2.3", build: "42", platform: "iOS", osVersion: "18.0", language: "ko"
    )
    private let ticketID = "2f4ce4cc-2fa9-4e8f-9fa6-9cde589ebdec"
    private let receivedAt = "2026-10-16T10:20:30.123Z"

    private func submission(diagnostics: Data? = nil) throws -> FeedbackSubmission {
        try FeedbackSubmission(kind: .bug, title: "Report", message: "Details", app: app, diagnostics: diagnostics)
    }

    private func receiptBody(ticketID: String? = nil, receivedAt: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "ticketID": ticketID ?? self.ticketID, "receivedAt": receivedAt ?? self.receivedAt
        ])
    }

    @Test("JSON envelope preserves the exact previewed diagnostic UTF8 text")
    func diagnosticUTF8SurvivesEnvelopeEncoding() throws {
        let text = " \r\n{\n  \"한글\": \"café 👩🏽‍💻\",\n  \"escaped\": \"quote: \\\" slash: \\\\ tab: \\t unicode: \\u0061\",\n  \"number\": 1.00\n}\t\n"
        let original = Data(text.utf8)
        let frozen = try submission(diagnostics: original)
        let envelope = try #require(JSONSerialization.jsonObject(with: frozen.body) as? [String: Any])
        let decoded = try #require(envelope["diagnostics"] as? String)
        #expect(Data(decoded.utf8) == original)
        #expect(frozen.diagnostics == text)
        #expect(frozen.includesDiagnostics)
        #expect(envelope["submissionID"] as? String == frozen.submissionID)
    }

    @Test("Invalid UTF8, invalid JSON and non-object diagnostics are rejected")
    func rejectsInvalidOrNonObjectDiagnostics() {
        let inputs = [
            Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D]),
            Data(), Data("{broken}".utf8), Data("{} trailing".utf8),
            Data("[]".utf8), Data("null".utf8), Data("42".utf8), Data("\"text\"".utf8)
        ]
        for input in inputs {
            #expect(throws: FeedbackFailure.invalidDiagnostics) { try submission(diagnostics: input) }
        }
    }

    @Test("Diagnostic size is bounded by original UTF8 bytes, inclusively")
    func diagnosticByteLimitIsInclusive() throws {
        let exact = Data((String(repeating: " ", count: 524_286) + "{}").utf8)
        #expect(try submission(diagnostics: exact).includesDiagnostics)
        #expect(throws: FeedbackFailure.invalidDiagnostics) {
            try submission(diagnostics: exact + Data(" ".utf8))
        }
        let multibyte = Data(("{\"text\":\"" + String(repeating: "한", count: 174_763) + "\"}").utf8)
        #expect(multibyte.count > 524_288)
        #expect(throws: FeedbackFailure.invalidDiagnostics) { try submission(diagnostics: multibyte) }
    }

    @Test("Feature requests cannot attach diagnostics")
    func featureCannotAttachDiagnostics() throws {
        #expect(throws: FeedbackFailure.invalidDiagnostics) {
            try FeedbackSubmission(kind: .feature, title: "Idea", message: "Details", app: app, diagnostics: Data("{}".utf8))
        }
        let feature = try FeedbackSubmission(kind: .feature, title: "Idea", message: "Details", app: app)
        let body = try #require(JSONSerialization.jsonObject(with: feature.body) as? [String: Any])
        #expect(feature.includesDiagnostics == false)
        #expect(body["diagnostics"] == nil)
    }

    @Test("Title and message trim whitespace and enforce scalar rather than grapheme limits")
    func trimsAndCountsUnicodeScalars() throws {
        let cluster = "e\u{301}"
        let title = String(repeating: cluster, count: 60)
        let message = String(repeating: cluster, count: 4_000)
        let frozen = try FeedbackSubmission(
            kind: .bug, title: " \t\n" + title + "\r\n", message: "\u{2003}" + message + " \n", app: app
        )
        #expect(frozen.title == title)
        #expect(frozen.message == message)
        let body = try #require(JSONSerialization.jsonObject(with: frozen.body) as? [String: Any])
        #expect(body["title"] as? String == title)
        #expect(body["message"] as? String == message)
        for invalidTitle in [" \t\n", title + "a", String(repeating: cluster, count: 61)] {
            #expect(throws: FeedbackFailure.invalidInput) {
                try FeedbackSubmission(kind: .bug, title: invalidTitle, message: "Details", app: app)
            }
        }
        for invalidMessage in ["\u{2003}\r\n", message + "a", String(repeating: cluster, count: 4_001)] {
            #expect(throws: FeedbackFailure.invalidInput) {
                try FeedbackSubmission(kind: .bug, title: "Report", message: invalidMessage, app: app)
            }
        }
    }

    @Test("Unicode diagnostic text below its own cap can exceed the escaped JSON body cap")
    func expandedUnicodeJSONBodyIsBounded() throws {
        func diagnostics(repetitions: Int) -> Data {
            Data(("{\"text\":\"한글 👩🏽‍💻\",\"escaped\":\"" + String(repeating: "\\\"", count: repetitions) + "\"}").utf8)
        }
        let accepted = try submission(diagnostics: diagnostics(repetitions: 150_000))
        #expect(accepted.body.count <= 786_432)
        let expanded = diagnostics(repetitions: 200_000)
        #expect(expanded.count < 524_288)
        #expect(try JSONSerialization.jsonObject(with: expanded) is [String: Any])
        #expect(throws: FeedbackFailure.requestTooLarge) { try submission(diagnostics: expanded) }
    }

    @Test("Only 201 created and 200 replay produce a validated receipt", arguments: [201, 200])
    func acceptsDurableReceiptsOnly(status: Int) async throws {
        let fixture = FeedbackHTTPFixture(action: .response(status, [:], try receiptBody()))
        defer { fixture.remove() }
        let service = FeedbackService(baseURL: fixture.baseURL, protocolClasses: [FeedbackTestURLProtocol.self])
        let receipt = try await service.submit(submission())
        #expect(receipt == FeedbackReceipt(ticketID: ticketID, receivedAt: receivedAt))
        #expect(fixture.exchange.requests.count == 1)
    }

    @Test("Accepted, HTML and malformed successful responses are not delivery")
    func rejectsNonReceiptResponses() async throws {
        let cases: [(Int, [String: String], Data)] = [
            (202, [:], try receiptBody()),
            (204, [:], Data()),
            (201, ["Content-Type": "text/html"], Data("<html>ok</html>".utf8)),
            (200, ["Content-Type": "text/html"], try receiptBody()),
            (201, [:], Data("not JSON".utf8)),
            (200, [:], Data("{}".utf8)),
            (201, [:], Data("[]".utf8)),
            (200, [:], Data(repeating: 32, count: 65_537))
        ]
        for (status, headers, data) in cases {
            let fixture = FeedbackHTTPFixture(action: .response(status, headers, data))
            defer { fixture.remove() }
            let service = FeedbackService(baseURL: fixture.baseURL, protocolClasses: [FeedbackTestURLProtocol.self])
            await #expect(throws: FeedbackFailure.invalidResponse) { try await service.submit(submission()) }
            #expect(fixture.exchange.requests.count == 1)
        }
    }

    @Test("Malformed or non-v4 ticket IDs and non-UTC dates are not receipts")
    func rejectsMalformedReceiptFields() async throws {
        let fields = [
            ("not-a-uuid", receivedAt),
            ("2f4ce4cc-2fa9-1e8f-9fa6-9cde589ebdec", receivedAt),
            ("2f4ce4cc-2fa9-4e8f-7fa6-9cde589ebdec", receivedAt),
            (ticketID, "yesterday"), (ticketID, "2026-13-16T10:20:30Z"),
            (ticketID, "2026-10-16T10:20:30+09:00"), (ticketID, "2026-10-16")
        ]
        for (id, date) in fields {
            let fixture = FeedbackHTTPFixture(action: .response(201, [:], try receiptBody(ticketID: id, receivedAt: date)))
            defer { fixture.remove() }
            let service = FeedbackService(baseURL: fixture.baseURL, protocolClasses: [FeedbackTestURLProtocol.self])
            await #expect(throws: FeedbackFailure.invalidResponse) { try await service.submit(submission()) }
        }
    }

    @Test("Missing, insecure and ambiguous endpoints fail without starting a request")
    func rejectsUnsafeOrMissingEndpoints() async throws {
        let fixture = FeedbackHTTPFixture(action: .failure(.cannotConnectToHost))
        defer { fixture.remove() }
        let root = fixture.baseURL
        let endpoints: [String?] = [
            nil, "", "not a URL", "https:///", "http://\(fixture.host)", "ftp://\(fixture.host)",
            "http://localhost.evil.invalid", "http://127.0.0.2", "https://user@\(fixture.host)",
            "https://user:password@\(fixture.host)", root + "?", root + "?token=secret",
            root + "#", root + "#fragment", root + "/other", root + "/%2F"
        ]
        for endpoint in endpoints {
            let service = FeedbackService(baseURL: endpoint, protocolClasses: [FeedbackTestURLProtocol.self])
            await #expect(throws: FeedbackFailure.configuration) { try await service.submit(submission()) }
        }
        #expect(fixture.exchange.requests.isEmpty)
    }

    @Test("Production request posts exact consented bytes without cookie or authorization headers")
    func sendsAnonymousFrozenRequest() async throws {
        let fixture = FeedbackHTTPFixture(action: .response(201, ["Set-Cookie": "session=must-not-be-resent; Path=/; Secure"], try receiptBody()))
        defer { fixture.remove() }
        let frozen = try submission(diagnostics: Data("{\"text\":\"private\"}".utf8))
        let service = FeedbackService(baseURL: fixture.baseURL + "/", protocolClasses: [FeedbackTestURLProtocol.self])
        _ = try await service.submit(frozen)
        let request = try #require(fixture.exchange.requests.first)
        #expect(request.url?.absoluteString == fixture.baseURL + "/v1/feedback")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(try requestBody(request) == frozen.body)
        _ = try await service.submit(frozen) // A deliberate second call must not resend the response cookie.
        #expect(fixture.exchange.requests.count == 2)
        for sent in fixture.exchange.requests {
            #expect(sent.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(sent.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
        }
    }

    @Test("Rate limiting exposes valid Retry-After seconds and never automatically retries")
    func rateLimitRetryAfterWithoutAutomaticRetry() async throws {
        let values: [(String?, Int?)] = [("120", 120), ("0", 0), ("-1", nil), ("later", nil), (nil, nil)]
        for (header, expected) in values {
            let headers = header.map { ["Retry-After": $0] } ?? [:]
            let fixture = FeedbackHTTPFixture(action: .response(429, headers, Data("{\"errorCode\":\"RATE_LIMITED\"}".utf8)))
            defer { fixture.remove() }
            let service = FeedbackService(baseURL: fixture.baseURL, protocolClasses: [FeedbackTestURLProtocol.self])
            await #expect(throws: FeedbackFailure.rateLimited(retryAfter: expected)) { try await service.submit(submission()) }
            #expect(fixture.exchange.requests.count == 1)
        }
    }

    @Test("Server failures and transport errors never automatically retry")
    func failuresDoNotAutomaticallyRetry() async throws {
        let cases: [(FeedbackHTTPAction, FeedbackFailure)] = [
            (.response(400, [:], Data("{\"errorCode\":\"INVALID_REQUEST\"}".utf8)), .rejected),
            (.response(409, [:], Data("{\"errorCode\":\"SUBMISSION_CONFLICT\"}".utf8)), .conflict),
            (.response(413, [:], Data("{\"errorCode\":\"REQUEST_TOO_LARGE\"}".utf8)), .requestTooLarge),
            (.response(503, [:], Data("{\"errorCode\":\"INTAKE_UNAVAILABLE\"}".utf8)), .unavailable),
            (.response(503, [:], Data("{\"errorCode\":\"CAPACITY_REACHED\"}".utf8)), .unavailable),
            (.failure(.networkConnectionLost), .transport)
        ]
        for (action, failure) in cases {
            let fixture = FeedbackHTTPFixture(action: action)
            defer { fixture.remove() }
            let service = FeedbackService(baseURL: fixture.baseURL, protocolClasses: [FeedbackTestURLProtocol.self])
            await #expect(throws: failure) { try await service.submit(submission()) }
            #expect(fixture.exchange.requests.count == 1)
        }
    }

    @Test("In-flight task cancellation stops transport and cannot return a receipt")
    func cancellationStopsInFlightRequest() async throws {
        let fixture = FeedbackHTTPFixture(action: .pending)
        defer { fixture.remove() }
        let service = FeedbackService(baseURL: fixture.baseURL, protocolClasses: [FeedbackTestURLProtocol.self])
        let frozen = try submission()
        let task = Task { try await service.submit(frozen) }
        await fixture.exchange.waitUntilStarted()
        task.cancel()
        await #expect(throws: FeedbackFailure.cancelled) { try await task.value }
        await fixture.exchange.waitUntilStopped()
        #expect(fixture.exchange.requests.count == 1)
    }

    @Test("Already cancelled callers do not begin a request")
    func preCancelledTaskDoesNotSend() async throws {
        let fixture = FeedbackHTTPFixture(action: .failure(.cannotConnectToHost))
        defer { fixture.remove() }
        let service = FeedbackService(baseURL: fixture.baseURL, protocolClasses: [FeedbackTestURLProtocol.self])
        let frozen = try submission()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.submit(frozen)
        }
        await #expect(throws: FeedbackFailure.cancelled) { try await task.value }
        #expect(fixture.exchange.requests.isEmpty)
    }

    @Test("Redirect delegate refuses same-origin and cross-origin resubmission")
    func redirectPolicyRefusesEveryDestination() throws {
        let delegate = FeedbackRedirectBlocker()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = try #require(URL(string: "https://feedback.invalid/v1/feedback"))
        let task = session.dataTask(with: origin) // Never resumed: delegate policy only, no network.
        for destination in ["https://feedback.invalid/elsewhere", "https://other.invalid/intake", "http://feedback.invalid/intake"] {
            let url = try #require(URL(string: destination))
            let response = try #require(HTTPURLResponse(url: origin, statusCode: 307, httpVersion: nil, headerFields: ["Location": destination]))
            let probe = FeedbackRedirectProbe()
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)) {
                probe.record($0)
            }
            #expect(probe.called)
            #expect(probe.request == nil)
        }
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return data }
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

// Each service gets a distinct reserved host. A missing fixture fails locally;
// this URLProtocol never delegates to external networking or shared app sessions.
nonisolated private enum FeedbackHTTPAction: Sendable {
    case response(Int, [String: String], Data)
    case failure(URLError.Code)
    case pending
}

nonisolated private struct FeedbackHTTPFixture {
    let host = "feedback-\(UUID().uuidString.lowercased()).invalid"
    let exchange: FeedbackHTTPExchange
    var baseURL: String { "https://\(host)" }

    init(action: FeedbackHTTPAction) {
        exchange = FeedbackHTTPExchange(action: action)
        FeedbackTestURLProtocol.registry.insert(exchange, host: host)
    }

    func remove() { FeedbackTestURLProtocol.registry.remove(host: host) }
}

nonisolated private final class FeedbackHTTPExchange: @unchecked Sendable {
    private let lock = NSLock()
    let action: FeedbackHTTPAction
    private var recorded: [URLRequest] = []
    private var stopped = false
    private var startObservers: [CheckedContinuation<Void, Never>] = []
    private var stopObservers: [CheckedContinuation<Void, Never>] = []
    var requests: [URLRequest] { lock.withLock { recorded } }

    init(action: FeedbackHTTPAction) { self.action = action }

    func record(_ request: URLRequest) {
        let observers = lock.withLock {
            recorded.append(request)
            let observers = startObservers
            startObservers.removeAll()
            return observers
        }
        for observer in observers { observer.resume() }
    }

    func markStopped() {
        let observers = lock.withLock {
            stopped = true
            let observers = stopObservers
            stopObservers.removeAll()
            return observers
        }
        for observer in observers { observer.resume() }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if !recorded.isEmpty { return true }
                startObservers.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if stopped { return true }
                stopObservers.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

nonisolated private final class FeedbackHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: FeedbackHTTPExchange] = [:]
    func insert(_ exchange: FeedbackHTTPExchange, host: String) { lock.withLock { entries[host] = exchange } }
    func remove(host: String) { _ = lock.withLock { entries.removeValue(forKey: host) } }
    func exchange(host: String?) -> FeedbackHTTPExchange? { lock.withLock { host.flatMap { entries[$0] } } }
}

nonisolated private final class FeedbackTestURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = FeedbackHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let exchange = Self.registry.exchange(host: request.url?.host), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        exchange.record(request)
        switch exchange.action {
        case let .response(status, headers, body):
            var headers = headers
            if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .pending:
            break // URLSession cancellation drives stopLoading; no timers or polling.
        }
    }

    override func stopLoading() { Self.registry.exchange(host: request.url?.host)?.markStopped() }
}

nonisolated private final class FeedbackRedirectProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didCall = false
    private var recorded: URLRequest?
    var called: Bool { lock.withLock { didCall } }
    var request: URLRequest? { lock.withLock { recorded } }
    func record(_ request: URLRequest?) { lock.withLock { didCall = true; recorded = request } }
}
