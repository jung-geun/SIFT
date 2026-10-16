import Foundation
import Testing
@testable import todo

@MainActor private final class ProviderSession {
    var generation = UUID()
}

private final class ProviderConsent: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = true
    func allows(_ scope: OpenAIDataScope) -> Bool { lock.withLock { granted } }
    func revoke() { lock.withLock { granted = false } }
}

@MainActor private final class ResponseTransport: OpenAIResponseTransport {
    var requests: [URLRequest] = []
    var models: [[String: String]] = [
        ["slug": "gpt-6-luna", "visibility": "list"],
        ["slug": "gpt-6.1-sol", "visibility": "list"]
    ]
    var lines: [String] = []
    var afterCatalog: (() -> Void)?
    var onLine: ((Int) -> Void)?
    var cancellationCount = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        afterCatalog?()
        return (try JSONSerialization.data(withJSONObject: ["models": models]), response(request, streaming: false))
    }
    func stream(for request: URLRequest) async throws -> OpenAIEventStream {
        requests.append(request)
        // SIWC plan requests reject this ordinary API option instead of starting inference.
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let status = body?["max_output_tokens"] == nil ? 200 : 400
        let cursor = Cursor(lines: lines, onLine: onLine)
        let stream = AsyncThrowingStream<String, Error>(unfolding: { await cursor.next() })
        return OpenAIEventStream(response: response(request, streaming: true, status: status), lines: stream,
                                 cancel: { Task { @MainActor in self.cancellationCount += 1 } })
    }
    private func response(_ request: URLRequest, streaming: Bool, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                        headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!
    }
    @MainActor private final class Cursor {
        let lines: [String]
        let onLine: ((Int) -> Void)?
        var index = 0
        init(lines: [String], onLine: ((Int) -> Void)?) { self.lines = lines; self.onLine = onLine }
        func next() -> String? {
            guard index < lines.count else { return nil }
            onLine?(index)
            defer { index += 1 }
            return lines[index]
        }
    }
}

@Suite("OpenAI completed-response and privacy boundaries")
@MainActor struct OpenAIProviderServiceTests {
    private func service(_ transport: ResponseTransport, session: ProviderSession? = nil,
                         consent: ProviderConsent = ProviderConsent()) -> OpenAIProviderService {
        let session = session ?? ProviderSession()
        return OpenAIProviderService(transport: transport, accessToken: { "synthetic-test-credential" },
                                     generation: { session.generation }, consent: consent.allows, enabled: { true })
    }
    private func event(_ object: [String: Any], separator: Bool = true) throws -> [String] {
        let data = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return separator ? ["data: \(data)", ""] : ["data: \(data)"]
    }
    private func delta(_ text: String) throws -> [String] { try event(["type": "response.output_text.delta", "delta": text]) }
    private func completed(separator: Bool = true) throws -> [String] {
        try event(["type": "response.completed", "response": ["status": "completed"]], separator: separator)
    }

    @Test("scope consent blocks disclosure before authentication or any request")
    func missingConsent() async throws {
        let transport = ResponseTransport()
        let consent = ProviderConsent(); consent.revoke()
        await #expect(throws: OpenAIRequestError.consentRequired) {
            try await service(transport, consent: consent).generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .email)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("an unavailable exact advanced model is rejected without submitting inference")
    func unavailableAdvancedModel() async throws {
        let transport = ResponseTransport()
        transport.models = [["slug": "gpt-6-luna", "visibility": "list"], ["slug": "gpt-6.1-sol", "visibility": "hidden"]]
        await #expect(throws: OpenAIRequestError.modelUnavailable("gpt-6.1-sol")) {
            try await service(transport).generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .persona, tier: .advanced)
        }
        #expect(transport.requests.map { $0.url!.path } == ["/v1/models"])
    }

    @Test("valid JSON deltas are not accepted without response.completed")
    func incompleteStreamCannotPublish() async throws {
        let transport = ResponseTransport()
        transport.lines = try delta("{\"summary\":\"partial\"}")
        await #expect(throws: OpenAIRequestError.interrupted) {
            try await service(transport).generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .routines)
        }
    }

    @Test("usage failure after valid partial output discards the output")
    func lateUsageFailure() async throws {
        let transport = ResponseTransport()
        transport.lines = try delta("{\"summary\":\"partial\"}") + event([
            "type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded"]]
        ])
        await #expect(throws: OpenAIRequestError.usageLimit) {
            try await service(transport).generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .email)
        }
    }

    @Test("an explicitly incomplete response never becomes a successful preview")
    func terminalIncomplete() async throws {
        let transport = ResponseTransport()
        transport.lines = try delta("{\"summary\":\"partial\"}") + event(["type": "response.incomplete", "response": ["status": "incomplete"]])
        await #expect(throws: OpenAIRequestError.failed) {
            try await service(transport).generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .persona)
        }
    }

    @Test("completed but truncated JSON is rejected, not partially parsed")
    func truncatedJSON() async throws {
        let transport = ResponseTransport()
        transport.lines = try delta("{\"summary\":\"truncated") + completed()
        await #expect(throws: OpenAIRequestError.invalidResponse) {
            try await service(transport).generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .tasks)
        }
    }

    @Test("fragmented output and a terminal event without trailing newline produce one completed object")
    func fragmentedCompletedOutput() async throws {
        let transport = ResponseTransport()
        transport.lines = [": keepalive", "event: response.output_text.delta"]
            + (try delta("{\"summary\":")) + (try delta("\"reviewable\"}")) + (try completed(separator: false))
        let result = try await service(transport).generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .email)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: String])
        #expect(object["summary"] == "reviewable")
    }

    @Test("switching accounts during model discovery prevents a request under stale credentials")
    func accountSwitchInvalidatesRequest() async throws {
        let transport = ResponseTransport()
        let session = ProviderSession()
        transport.afterCatalog = { session.generation = UUID() }
        await #expect(throws: CancellationError.self) {
            try await service(transport, session: session).generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .tasks)
        }
        #expect(transport.requests.map { $0.url!.path } == ["/v1/models"])
    }

    @Test("scope revocation during inference prevents publishing even completed content")
    func revocationInvalidatesPreview() async throws {
        let transport = ResponseTransport()
        let consent = ProviderConsent()
        transport.lines = try delta("{\"summary\":\"private\"}") + completed()
        transport.onLine = { index in if index == 2 { consent.revoke() } }
        await #expect(throws: OpenAIRequestError.consentRequired) {
            try await service(transport, consent: consent).generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .email)
        }
    }

    @Test("a completed unrelated reply does not prove a working subscription connection")
    func connectionCheckRequiresItsAcknowledgement() async throws {
        let transport = ResponseTransport()
        let consent = ProviderConsent(); consent.revoke()
        transport.lines = try delta("{\"summary\":\"unrelated\"}") + completed()
        await #expect(throws: OpenAIRequestError.invalidResponse) {
            try await service(transport, consent: consent).verifySubscriptionConnection()
        }
    }

    @Test("a no-app-data connection check cannot publish success from an invalidated account")
    func connectionCheckRejectsInvalidatedAccount() async throws {
        let transport = ResponseTransport()
        let session = ProviderSession()
        let consent = ProviderConsent(); consent.revoke()
        transport.lines = try delta("{\"connection\":\"ok\"}") + completed()
        transport.onLine = { index in if index == 2 { session.generation = UUID() } }
        await #expect(throws: CancellationError.self) {
            try await service(transport, session: session, consent: consent).verifySubscriptionConnection()
        }
    }

    @Test("automatic email, meeting, and restored-private tasks remain local", arguments: [TodoSource.email, .meeting, .manual])
    func privateTasksCannotLeak(source: TodoSource) async throws {
        let transport = ResponseTransport()
        let todo = Todo(title: "Urgent private source", notes: "Sensitive original", source: source)
        if source == .manual { todo.sourceMessageID = "retained-mail-provenance" }
        let results = try await OpenAIIntelligenceEngine(service: service(transport))
            .prioritize(todos: [todo], events: [], persona: .empty, progress: nil)
        #expect(transport.requests.isEmpty)
        let result = try #require(results.first)
        #expect(result.todoID == todo.id)
        #expect(result.engine == .heuristic)
        #expect(result.executionPath == .rules(.providerNotApplicable))
    }
}
