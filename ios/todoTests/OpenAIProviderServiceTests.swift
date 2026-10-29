import Foundation
import Testing
@preconcurrency import Network
@testable import todo

@MainActor private final class ProviderSession {
    var generation = UUID()
    var authenticationCount = 0
    var preparationCount = 0
}

@MainActor private final class ProviderRegion {
    var allowed = true
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
    var catalog: [String: Any]?
    var lines: [String] = []
    var afterCatalog: (() -> Void)?
    var onLine: ((Int) -> Void)?
    var cancellationCount = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        afterCatalog?()
        return (try JSONSerialization.data(withJSONObject: catalog ?? ["models": models]), response(request, streaming: false))
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
    private func service(_ transport: any OpenAIResponseTransport, session: ProviderSession? = nil,
                         consent: ProviderConsent = ProviderConsent(), enabled: Bool = true,
                         region: ProviderRegion? = nil) -> OpenAIProviderService {
        let session = session ?? ProviderSession()
        let regionAllowed: @MainActor () -> Bool
        if let region { regionAllowed = { region.allowed } }
        else { regionAllowed = { true } }
        return OpenAIProviderService(transport: transport, accessToken: {
            session.authenticationCount += 1
            return "synthetic-test-credential"
        }, generation: { session.generation }, consent: consent.allows, enabled: { enabled }, prepareSession: {
            session.preparationCount += 1
        }, regionAllowed: regionAllowed)
    }

    @Test("restricted storefront denies every remote entry before authentication or network",
          arguments: ["models", "connection", "inference"])
    func restrictedRegionBlocksRemoteEntry(operation: String) async throws {
        let transport = ResponseTransport()
        let session = ProviderSession()
        let region = ProviderRegion(); region.allowed = false
        let provider = service(transport, session: session, region: region)
        await #expect(throws: OpenAIRequestError.disabled) {
            switch operation {
            case "models": _ = try await provider.availableModels()
            case "connection": _ = try await provider.verifySubscriptionConnection()
            default: _ = try await provider.generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .tasks)
            }
        }
        #expect(session.authenticationCount == 0)
        #expect(session.preparationCount == 0)
        #expect(transport.requests.isEmpty)
    }

    @Test("restriction while obtaining credentials prevents the first catalog request",
          arguments: ["models", "connection", "inference"])
    func restrictionDuringAuthenticationPreventsNetwork(operation: String) async throws {
        let transport = ResponseTransport()
        let session = ProviderSession()
        let region = ProviderRegion()
        let provider = OpenAIProviderService(transport: transport, accessToken: {
            session.authenticationCount += 1
            region.allowed = false
            return "synthetic-test-credential"
        }, generation: { session.generation }, consent: { _ in true }, enabled: { true },
           prepareSession: {}, regionAllowed: { region.allowed })
        await #expect(throws: OpenAIRequestError.disabled) {
            switch operation {
            case "models": _ = try await provider.availableModels()
            case "connection": _ = try await provider.verifySubscriptionConnection()
            default: _ = try await provider.generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .tasks)
            }
        }
        #expect(session.authenticationCount == 1)
        #expect(transport.requests.isEmpty)
    }

    @Test("restriction while preparing a session prevents entering authentication",
          arguments: ["models", "connection", "inference"])
    func restrictionDuringPreparationPreventsAuthentication(operation: String) async throws {
        let transport = ResponseTransport()
        let session = ProviderSession()
        let region = ProviderRegion()
        let provider = OpenAIProviderService(transport: transport, accessToken: {
            session.authenticationCount += 1
            return "synthetic-test-credential"
        }, generation: { session.generation }, consent: { _ in true }, enabled: { true },
           prepareSession: { region.allowed = false }, regionAllowed: { region.allowed })
        await #expect(throws: OpenAIRequestError.disabled) {
            switch operation {
            case "models": _ = try await provider.availableModels()
            case "connection": _ = try await provider.verifySubscriptionConnection()
            default: _ = try await provider.generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .tasks)
            }
        }
        #expect(session.authenticationCount == 0)
        #expect(transport.requests.isEmpty)
    }

    @Test("restriction during catalog loading discards account metadata and prevents later requests")
    func restrictionDiscardsLateModelCatalog() async throws {
        let transport = ResponseTransport()
        let region = ProviderRegion()
        transport.afterCatalog = { region.allowed = false }
        let provider = service(transport, region: region)
        await #expect(throws: OpenAIRequestError.disabled) { try await provider.availableModels() }
        #expect(transport.requests.map { $0.url!.path } == ["/v1/models"])
        await #expect(throws: OpenAIRequestError.disabled) { try await provider.availableModels() }
        #expect(transport.requests.count == 1)
    }

    @Test("restriction after discovery prevents both fixed-message checks and app-data inference",
          arguments: [false, true])
    func restrictionAfterCatalogPreventsResponse(connectionCheck: Bool) async throws {
        let transport = ResponseTransport()
        let region = ProviderRegion()
        transport.afterCatalog = { region.allowed = false }
        let provider = service(transport, region: region)
        await #expect(throws: OpenAIRequestError.disabled) {
            if connectionCheck { _ = try await provider.verifySubscriptionConnection() }
            else { _ = try await provider.generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .email) }
        }
        #expect(transport.requests.map { $0.url!.path } == ["/v1/models"])
    }

    @Test("restriction during a valid response suppresses completed output and all further requests",
          arguments: [false, true])
    func restrictionDuringStreamSuppressesOutput(connectionCheck: Bool) async throws {
        let transport = ResponseTransport()
        let region = ProviderRegion()
        transport.lines = try delta("{\"summary\":\"private\"}") + completed()
        transport.onLine = { index in if index == 2 { region.allowed = false } }
        let provider = service(transport, region: region)
        await #expect(throws: OpenAIRequestError.disabled) {
            if connectionCheck { _ = try await provider.verifySubscriptionConnection() }
            else { _ = try await provider.generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .email) }
        }
        #expect(transport.requests.map { $0.url!.path } == ["/v1/models", "/v1/responses"])
        await #expect(throws: OpenAIRequestError.disabled) { try await provider.availableModels() }
        await #expect(throws: OpenAIRequestError.disabled) { try await provider.verifySubscriptionConnection() }
        await #expect(throws: OpenAIRequestError.disabled) {
            try await provider.generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .email)
        }
        #expect(transport.requests.count == 2)
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

    @Test("the explicit fixed-message check works with all analysis and app-data consent off")
    func connectionCheckIsIndependentOfAnalysisOptIn() async throws {
        let transport = ResponseTransport()
        let consent = ProviderConsent(); consent.revoke()
        transport.lines = try delta("Connection confirmed.") + completed()
        let model = try await service(transport, consent: consent, enabled: false).verifySubscriptionConnection()
        #expect(model == OpenAIAnalysisTier.basic.modelID)
        let request = try #require(transport.requests.last)
        let payload = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(transport.requests.map { $0.url!.path } == ["/v1/models", "/v1/responses"])
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["text"] == nil)
        #expect(body["max_output_tokens"] == nil)
    }

    @Test("an authenticated catalog in the public data/id envelope can complete a subscription check")
    func publicModelCatalogConnection() async throws {
        let transport = ResponseTransport()
        transport.catalog = ["object": "list", "data": [["id": "gpt-6-luna"], ["id": "gpt-6.1-sol"]]]
        transport.lines = try delta("{\"connection\":\"ok\"}") + completed()
        let model = try await service(transport, enabled: false).verifySubscriptionConnection()
        #expect(model == "gpt-6-luna")
    }

    @Test("account discovery keeps server order and display names but excludes hidden and duplicate entries")
    func visibleAccountModels() async throws {
        let transport = ResponseTransport()
        transport.models = [
            ["slug": "gpt-6.1-sol", "display_name": "GPT-6.1 Sol", "visibility": "list"],
            ["slug": "internal-model", "visibility": "hidden"],
            ["slug": "gpt-6-luna", "visibility": "list"],
            ["slug": "gpt-6.1-sol", "visibility": "list"]
        ]
        let consent = ProviderConsent(); consent.revoke()
        let models = try await service(transport, consent: consent, enabled: false).availableModels()
        #expect(models == [OpenAIAvailableModel(id: "gpt-6.1-sol", displayName: "GPT-6.1 Sol"),
                           OpenAIAvailableModel(id: "gpt-6-luna", displayName: "gpt-6-luna")])
        #expect(transport.requests.map { $0.url!.path } == ["/v1/models"])
    }

    @Test("a secondary public envelope cannot override explicit hidden subscription visibility")
    func explicitVisibilityCannotBeBypassed() async throws {
        let transport = ResponseTransport()
        transport.catalog = ["models": [["slug": "gpt-6-luna", "visibility": "hidden"]],
                             "data": [["id": "gpt-6-luna"]]]
        await #expect(throws: OpenAIRequestError.modelUnavailable("gpt-6-luna")) {
            try await service(transport).verifySubscriptionConnection()
        }
        #expect(transport.requests.map { $0.url!.path } == ["/v1/models"])
    }

    @Test("account discovery discards a catalog from an invalidated session")
    func staleAccountCatalog() async throws {
        let transport = ResponseTransport()
        let session = ProviderSession()
        transport.afterCatalog = { session.generation = UUID() }
        await #expect(throws: CancellationError.self) {
            try await service(transport, session: session).availableModels()
        }
    }

    @Test("a successful account check never enables disabled app-data analysis", arguments: OpenAIDataScope.allCases)
    func connectionCheckCannotGrantAnalysis(scope: OpenAIDataScope) async throws {
        let transport = ResponseTransport()
        transport.lines = try delta("{\"connection\":\"ok\"}") + completed()
        let provider = service(transport, enabled: false)
        _ = try await provider.verifySubscriptionConnection()
        let checkRequests = transport.requests.count
        await #expect(throws: OpenAIRequestError.disabled) {
            try await provider.generateJSON(systemInstruction: "Analyze", userPrompt: "Private app data", scope: scope)
        }
        #expect(transport.requests.count == checkRequests)
    }

    @Test("a completed nonempty reply proves connectivity without an app-specific JSON schema",
          arguments: ["Connection confirmed.", "{\"connection\":\"ok\"}", "{\"summary\":\"Connected\"}"])
    func connectionCheckAcceptsCompletedText(reply: String) async throws {
        let transport = ResponseTransport()
        transport.lines = try delta(reply) + completed()
        #expect(try await service(transport).verifySubscriptionConnection() == OpenAIAnalysisTier.basic.modelID)
    }

    @Test("a terminal Responses output envelope needs no preceding text deltas")
    func connectionCheckAcceptsTerminalOutput() async throws {
        let transport = ResponseTransport()
        transport.lines = try event([
            "type": "response.completed",
            "response": ["status": "completed", "output": [
                ["type": "message", "content": [["type": "output_text", "text": "Connection confirmed."]]]
            ]]
        ], separator: false)
        #expect(try await service(transport).verifySubscriptionConnection() == OpenAIAnalysisTier.basic.modelID)
    }

    @Test("empty, interrupted, incomplete, and usage-failed probes cannot report success",
          arguments: ["empty", "whitespace", "interrupted", "incomplete", "usageLimit"])
    func connectionCheckRejectsUnsuccessfulResponse(outcome: String) async throws {
        let transport = ResponseTransport()
        let expected: OpenAIRequestError
        switch outcome {
        case "empty":
            transport.lines = try completed()
            expected = .invalidResponse
        case "whitespace":
            transport.lines = try delta(" \n ") + completed()
            expected = .invalidResponse
        case "interrupted":
            transport.lines = try delta("Connected")
            expected = .interrupted
        case "incomplete":
            transport.lines = try delta("Connected") + event([
                "type": "response.incomplete", "response": ["status": "incomplete"]
            ])
            expected = .failed
        default:
            transport.lines = try delta("Connected") + event([
                "type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded"]]
            ])
            expected = .usageLimit
        }
        await #expect(throws: expected) {
            try await service(transport).verifySubscriptionConnection()
        }
    }

    @Test("accepting text for a connectivity probe does not relax analysis JSON validation")
    func analysisStillRequiresJSONObject() async throws {
        let transport = ResponseTransport()
        transport.lines = try delta("Connection confirmed.") + completed()
        await #expect(throws: OpenAIRequestError.invalidResponse) {
            try await service(transport).generateJSON(systemInstruction: "Analyze", userPrompt: "private", scope: .tasks)
        }
        let payload = try #require(transport.requests.last?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let text = try #require(body["text"] as? [String: [String: String]])
        #expect(text["format"]?["type"] == "json_object")
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

    // The Responses reference makes response.status optional. Before the parser
    // fix this actual HTTP/SSE exchange fails at its mandatory-status guard.
    @Test("URLSession accepts a completed subscription response with optional status omitted")
    func subscriptionHTTPCompletionContract() async throws {
        let fixture = try ProviderHTTPFixture(sse: """
        event: response.created
        data: {"type":"response.created","sequence_number":0,"response":{"id":"resp_fixture","object":"response","status":"in_progress","output":[]}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","sequence_number":1,"item_id":"msg_fixture","output_index":0,"content_index":0,"delta":"Connection confirmed."}

        event: response.completed
        data: {"type":"response.completed","sequence_number":2,"response":{"id":"resp_fixture","object":"response","model":"gpt-6-luna","error":null,"incomplete_details":null,"output":[{"id":"msg_fixture","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Connection confirmed.","annotations":[]}]}]}}


        """)
        let endpoint = try await fixture.start()
        defer { fixture.stop() }
        let transport = ProviderLoopbackTransport(endpoint: endpoint)
        let provider = OpenAIProviderService(
            transport: transport, accessToken: { "synthetic-loopback-only" }, generation: { fixture.generation },
            consent: { _ in false }, enabled: { false }, prepareSession: {}, regionAllowed: { true }
        )
        #expect(try await provider.verifySubscriptionConnection() == "gpt-6-luna")
        #expect(transport.requests.map { $0.url!.path } == ["/v1/models", "/v1/responses"])
        let payload = try #require(transport.requests.last?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(body["model"] as? String == "gpt-6-luna")
        #expect(body["instructions"] as? String == "This is a connection check. Reply briefly to confirm receipt.")
        #expect(body["input"] as? [[String: String]] == [["role": "user", "content": "Confirm this ChatGPT plan connection."]])
        #expect(Set(body.keys) == ["model", "instructions", "input", "store", "stream"])
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
    }

    @Test("a catalog and partial text cannot authorize an invalid HTTP completion",
          arguments: ["missingCompletion", "malformedJSON", "missingResponse", "missingStatusAndOutput", "nullStatus", "incompleteStatus",
                      "error", "incompleteDetails", "badOutput", "emptyOutput", "badText", "incompleteMessage"])
    func subscriptionHTTPRejectsInvalidCompletion(outcome: String) async throws {
        var response: [String: Any] = ["status": "completed"]
        var expected: OpenAIRequestError = .invalidResponse
        switch outcome {
        case "missingStatusAndOutput": response = [:]
        case "nullStatus": response["status"] = NSNull()
        case "incompleteStatus": response["status"] = "incomplete"
        case "error": response["error"] = ["code": "server_error"]; expected = .failed
        case "incompleteDetails": response["incomplete_details"] = ["reason": "max_output_tokens"]; expected = .failed
        case "badOutput": response["output"] = "not an array"
        case "emptyOutput": response["output"] = [] as [String]
        case "badText": response["output"] = [["type": "message", "content": [["type": "output_text", "text": 7]]]]
        case "incompleteMessage": response["output"] = [["type": "message", "status": "incomplete", "content": [["type": "output_text", "text": "Connected"]]]]
        default: break
        }
        let terminal: [String]
        switch outcome {
        case "missingCompletion": terminal = ["data: [DONE]", ""]; expected = .interrupted
        case "malformedJSON": terminal = ["data: {not-json}", ""]
        case "missingResponse": terminal = try event(["type": "response.completed"])
        default: terminal = try event(["type": "response.completed", "response": response])
        }
        let sse = (try delta("Connection confirmed.") + terminal).joined(separator: "\n") + "\n"
        let fixture = try ProviderHTTPFixture(sse: sse)
        let endpoint = try await fixture.start()
        defer { fixture.stop() }
        let transport = ProviderLoopbackTransport(endpoint: endpoint)
        await #expect(throws: expected) { try await service(transport).verifySubscriptionConnection() }
        #expect(transport.requests.map { $0.url!.path } == ["/v1/models", "/v1/responses"])
    }

    @Test("successful HTTP model discovery does not establish inference admission", arguments: [401, 403, 503])
    func subscriptionHTTPCatalogIsNotAuthorization(status: Int) async throws {
        let fixture = try ProviderHTTPFixture(sse: #"{"detail":"Synthetic inference admission denied"}"#, inferenceStatus: status)
        let endpoint = try await fixture.start()
        defer { fixture.stop() }
        let transport = ProviderLoopbackTransport(endpoint: endpoint)
        let provider = service(transport)
        #expect(try await provider.availableModels().map(\.id) == ["gpt-6-luna"])
        await #expect(throws: OpenAIRequestError.http(status)) { try await provider.verifySubscriptionConnection() }
        #expect(transport.requests.map { $0.url!.path } == ["/v1/models", "/v1/models", "/v1/responses"])
    }

    @Test("optional terminal status does not relax the structured analysis object requirement",
          arguments: ["Connection confirmed.", "{\"summary\":", "[]", "7"])
    func optionalStatusStillRejectsInvalidAnalysis(reply: String) async throws {
        let transport = ResponseTransport()
        transport.lines = try event(["type": "response.completed", "response": ["error": NSNull(), "output": [
            ["type": "message", "status": "completed", "content": [["type": "output_text", "text": reply]]]
        ]]])
        await #expect(throws: OpenAIRequestError.invalidResponse) {
            try await service(transport).generateJSON(systemInstruction: "Analyze", userPrompt: "synthetic input", scope: .tasks)
        }
    }


    @Test("a completed structured object also accepts the documented optional response status")
    func optionalStatusAcceptsValidAnalysis() async throws {
        let transport = ResponseTransport()
        transport.lines = try event(["type": "response.completed", "response": ["error": NSNull(), "output": [
            ["type": "message", "status": "completed", "content": [["type": "output_text", "text": "{\"summary\":\"reviewable\"}"]]]
        ]]])
        #expect(try await service(transport).generateJSON(systemInstruction: "Analyze", userPrompt: "synthetic input", scope: .tasks)
                == "{\"summary\":\"reviewable\"}")
    }

    @Test("automatic private-source tasks remain local after source restoration", arguments: ["email", "meeting", "restored-mail", "health:workout", "HEALTH:medication"])
    func privateTasksCannotLeak(provenance: String) async throws {
        let transport = ResponseTransport()
        let source: TodoSource = provenance == "email" ? .email : provenance == "meeting" ? .meeting : .manual
        let todo = Todo(title: "Urgent private source", notes: "Sensitive original", source: source)
        if provenance == "restored-mail" { todo.sourceMessageID = "retained-mail-provenance" }
        if provenance.lowercased().hasPrefix("health:") { todo.sourceRef = provenance }
        let results = try await OpenAIIntelligenceEngine(service: service(transport))
            .prioritize(todos: [todo], events: [], persona: .empty, progress: nil)
        #expect(transport.requests.isEmpty)
        let result = try #require(results.first)
        #expect(result.todoID == todo.id)
        #expect(result.engine == .heuristic)
        #expect(result.executionPath == .rules(.providerNotApplicable))
    }
}

/// Rewrites only the destination, retaining production request construction,
/// URLSession AsyncBytes, byte-to-line framing, and provider completion validation.
@MainActor private final class ProviderLoopbackTransport: OpenAIResponseTransport {
    private let endpoint: URL
    private let transport = OpenAIURLSessionResponseTransport()
    var requests: [URLRequest] = []
    init(endpoint: URL) { self.endpoint = endpoint }
    private func local(_ request: URLRequest) -> URLRequest {
        requests.append(request)
        var local = request
        local.url = endpoint.appendingPathComponent(request.url!.path)
        local.timeoutInterval = 5
        return local
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await transport.data(for: local(request))
    }
    func stream(for request: URLRequest) async throws -> OpenAIEventStream {
        try await transport.stream(for: local(request))
    }
}

/// IPv4 loopback only; no real account, external requests, or stored app data.
private nonisolated final class ProviderHTTPFixture: @unchecked Sendable {
    let generation = UUID()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "todo.tests.openai.responses")
    private let sse: String
    private let inferenceStatus: Int
    // Mutable socket state is confined to queue, never the test's busy MainActor.
    private var readiness: CheckedContinuation<URL, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var timeout: DispatchWorkItem?
    private var stopped = false

    init(sse: String, inferenceStatus: Int = 200) throws {
        self.sse = sse
        self.inferenceStatus = inferenceStatus
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !self.stopped else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.readiness = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self, !self.stopped else { return }
                    switch state {
                    case .ready:
                        if let port = self.listener.port {
                            self.timeout?.cancel()
                            self.timeout = nil
                            let waiting = self.readiness
                            self.readiness = nil
                            waiting?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)")!)
                        }
                    case .failed(let error):
                        let waiting = self.readiness
                        self.readiness = nil
                        self.stopOnQueue()
                        waiting?.resume(throwing: error)
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    guard let self, !self.stopped else { connection.cancel(); return }
                    let id = UUID()
                    self.connections[id] = connection
                    connection.start(queue: self.queue)
                    self.receive(connection, id: id, buffer: Data())
                }
                let timeout = DispatchWorkItem { [weak self] in self?.stopOnQueue() }
                self.timeout = timeout
                self.queue.asyncAfter(deadline: .now() + 10, execute: timeout)
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.sync { stopOnQueue() }
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        stopped = true
        timeout?.cancel()
        timeout = nil
        listener.cancel()
        let waiting = readiness
        readiness = nil
        waiting?.resume(throwing: URLError(.timedOut))
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var bytes = buffer
            if let data { bytes.append(data) }
            guard error == nil, bytes.count <= 32768 else { self.close(id); return }
            if let separator = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: bytes[..<separator.lowerBound], as: UTF8.self)
                let lines = headers.components(separatedBy: "\r\n")
                let length = lines.first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                if bytes.count - separator.upperBound >= length {
                    let catalog = #"{"models":[{"slug":"gpt-6-luna","display_name":"GPT-6 Luna","visibility":"list"}]}"#
                    let isCatalog = lines.first == "GET /v1/models HTTP/1.1"
                    let isInference = lines.first == "POST /v1/responses HTTP/1.1"
                    let body = isCatalog ? catalog : isInference ? self.sse : "{}"
                    let type = isInference && self.inferenceStatus == 200 ? "text/event-stream; charset=utf-8" : "application/json"
                    let status = isCatalog ? "200 OK" : isInference ? "\(self.inferenceStatus) Fixture" : "404 Not Found"
                    // CRLF exercises the real byte framer's empty-line handling.
                    let payload = isInference ? body.replacingOccurrences(of: "\n", with: "\r\n") : body
                    let response = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                        self?.close(id)
                    })
                    return
                }
            }
            if complete { self.close(id) }
            else { self.receive(connection, id: id, buffer: bytes) }
        }
    }

    private func close(_ id: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        connections.removeValue(forKey: id)?.cancel()
    }
}
