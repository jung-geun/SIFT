import Foundation

nonisolated enum OpenAIAnalysisTier: String, Sendable {
    case basic, advanced
    var modelID: String { self == .basic ? "gpt-6-luna" : "gpt-6.1-sol" }
}

nonisolated enum OpenAIDataScope: String, CaseIterable, Sendable {
    case tasks, email, routines, persona
}

nonisolated enum OpenAIPrivacy {
    static func consentKey(for scope: OpenAIDataScope) -> String {
        "pieroot.todo.openai.consent.\(scope.rawValue)"
    }
    static func allows(_ scope: OpenAIDataScope) -> Bool {
        UserDefaults.standard.bool(forKey: consentKey(for: scope))
    }
}

nonisolated enum OpenAIRequestError: LocalizedError, Equatable {
    case disabled, consentRequired, modelUnavailable(String), http(Int), usageLimit
    case invalidResponse, interrupted, failed
    var errorDescription: String? {
        errorDescription(language: .current)
    }

    func errorDescription(language: AppLanguage) -> String {
        switch self {
        case .disabled:
            return AppLanguage.localized(
                "error.openai.request.disabled",
                defaultValue: language == .english ? "Enable the OpenAI provider before requesting remote analysis." : "원격 분석을 요청하려면 먼저 OpenAI 제공자를 활성화해 주세요.",
                language: language,
                comment: "OpenAI analysis error when the provider is disabled."
            )
        case .consentRequired:
            return AppLanguage.localized(
                "error.openai.request.consentRequired",
                defaultValue: language == .english ? "Allow sharing this data scope with OpenAI before requesting analysis." : "분석을 요청하려면 먼저 이 범위의 데이터를 OpenAI와 공유하도록 허용해 주세요.",
                language: language,
                comment: "OpenAI analysis error requiring consent for the requested data scope."
            )
        case .modelUnavailable(let model):
            let format = AppLanguage.localized(
                "error.openai.request.modelUnavailable",
                defaultValue: language == .english
                    ? "%@ is not available to the selected ChatGPT account. No replacement model was used."
                    : "선택한 ChatGPT 계정에서 %@ 모델을 사용할 수 없습니다. 다른 모델로 대체하지 않았습니다.",
                language: language,
                comment: "OpenAI analysis error. Argument 1 is the raw model ID; do not translate it."
            )
            return String(format: format, locale: language.locale, model)
        case .http(let status):
            let format = AppLanguage.localized(
                "error.openai.request.http",
                defaultValue: language == .english
                    ? "OpenAI could not complete the request (HTTP %lld)."
                    : "OpenAI가 요청을 완료하지 못했습니다(HTTP %lld).",
                language: language,
                comment: "OpenAI request error. Argument 1 is the HTTP status code, not a response body."
            )
            return String(format: format, locale: language.locale, Int64(status))
        case .usageLimit:
            return AppLanguage.localized(
                "error.openai.request.usageLimit",
                defaultValue: language == .english ? "ChatGPT plan usage is unavailable or its limit was reached. Manage usage in ChatGPT settings." : "ChatGPT 요금제 사용량을 이용할 수 없거나 한도에 도달했습니다. ChatGPT 설정에서 사용량을 관리해 주세요.",
                language: language,
                comment: "OpenAI analysis error when ChatGPT plan usage is unavailable or exhausted."
            )
        case .invalidResponse:
            return AppLanguage.localized(
                "error.openai.request.invalidResponse",
                defaultValue: language == .english ? "OpenAI returned an invalid analysis. The original was not changed." : "OpenAI가 올바르지 않은 분석을 반환했습니다. 원본은 변경되지 않았습니다.",
                language: language,
                comment: "OpenAI analysis error for an invalid response; the original remains unchanged."
            )
        case .interrupted:
            return AppLanguage.localized(
                "error.openai.request.interrupted",
                defaultValue: language == .english ? "The OpenAI response was interrupted before completion. Please request it again explicitly." : "OpenAI 응답이 완료되기 전에 중단되었습니다. 직접 다시 요청해 주세요.",
                language: language,
                comment: "OpenAI analysis error for an interrupted response; retry requires an explicit user request."
            )
        case .failed:
            return AppLanguage.localized(
                "error.openai.request.failed",
                defaultValue: language == .english ? "OpenAI did not complete the analysis. The original was not changed." : "OpenAI가 분석을 완료하지 못했습니다. 원본은 변경되지 않았습니다.",
                language: language,
                comment: "Generic OpenAI analysis failure; never include underlying errors or response bodies."
            )
        }
    }
}

@MainActor struct OpenAIEventStream {
    let response: HTTPURLResponse
    let lines: AsyncThrowingStream<String, Error>
    let cancel: @Sendable () -> Void
}

@MainActor protocol OpenAIResponseTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func stream(for request: URLRequest) async throws -> OpenAIEventStream
}

@MainActor final class OpenAIURLSessionResponseTransport: OpenAIResponseTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 240
        session = URLSession(configuration: configuration, delegate: OpenAIResponseRedirectDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 1_048_576 else {
            throw OpenAIRequestError.invalidResponse
        }
        return (data, http)
    }

    func stream(for request: URLRequest) async throws -> OpenAIEventStream {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIRequestError.invalidResponse }
        let pair = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let reader = Task {
            do {
                var line = Data()
                var followsCR = false
                func emitLine() throws {
                    guard let text = String(data: line, encoding: .utf8) else { throw OpenAIRequestError.invalidResponse }
                    if case .dropped = pair.continuation.yield(text) { throw OpenAIRequestError.interrupted }
                    line.removeAll(keepingCapacity: true)
                }
                // AsyncBytes.lines drops empty lines; SSE requires them as event delimiters.
                for try await byte in bytes {
                    try Task.checkCancellation()
                    if byte == 10 && followsCR { followsCR = false; continue }
                    followsCR = false
                    if byte == 10 || byte == 13 {
                        try emitLine()
                        followsCR = byte == 13
                    } else {
                        guard line.count < 524_288 else { throw OpenAIRequestError.invalidResponse }
                        line.append(byte)
                    }
                }
                if !line.isEmpty { try emitLine() }
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { _ in reader.cancel() }
        return OpenAIEventStream(response: http, lines: pair.stream, cancel: { reader.cancel() })
    }

}

private final class OpenAIResponseRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Only completed responses cross this boundary. Credentials and request/response contents are never logged.
@MainActor struct OpenAIProviderService {
    private let transport: any OpenAIResponseTransport
    private let accessToken: @MainActor () async throws -> String
    private let generation: @MainActor () -> UUID
    private let consent: @Sendable (OpenAIDataScope) -> Bool
    private let enabled: @MainActor () -> Bool

    init(
        transport: (any OpenAIResponseTransport)? = nil,
        accessToken: @escaping @MainActor () async throws -> String = { try await OpenAIConnection.shared.authorizedAccessToken() },
        generation: @escaping @MainActor () -> UUID = { OpenAIConnection.shared.sessionGeneration },
        consent: @escaping @Sendable (OpenAIDataScope) -> Bool = OpenAIPrivacy.allows,
        enabled: @escaping @MainActor () -> Bool = { SettingsStore.betaProviderEnabled(.openAI) }
    ) {
        self.transport = transport ?? OpenAIURLSessionResponseTransport()
        self.accessToken = accessToken
        self.generation = generation
        self.consent = consent
        self.enabled = enabled
    }

    /// Explicitly checks the selected account with a fixed message, never with stored app data.
    func verifySubscriptionConnection() async throws -> String {
        let output = try await performJSON(
            systemInstruction: "This is a connection check. Return only the JSON object {\"connection\":\"ok\"}.",
            userPrompt: "Confirm this ChatGPT plan connection.",
            scope: nil, tier: .basic, language: .current
        )
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String],
              object["connection"] == "ok" else { throw OpenAIRequestError.invalidResponse }
        return OpenAIAnalysisTier.basic.modelID
    }

    func generateJSON(
        systemInstruction: String,
        userPrompt: String,
        scope: OpenAIDataScope,
        additionalScopes: [OpenAIDataScope] = [],
        tier: OpenAIAnalysisTier = .basic,
        language: AppLanguage = .current
    ) async throws -> String {
        try await performJSON(systemInstruction: systemInstruction, userPrompt: userPrompt, scope: scope,
                              additionalScopes: additionalScopes, tier: tier, language: language)
    }

    private func performJSON(
        systemInstruction: String,
        userPrompt: String,
        scope: OpenAIDataScope?,
        additionalScopes: [OpenAIDataScope] = [],
        tier: OpenAIAnalysisTier,
        language: AppLanguage
    ) async throws -> String {
        try preflight(scope)
        for additional in additionalScopes { try preflight(additional) }
        let session = generation()
        let request = Task {
            try await executeJSON(systemInstruction: systemInstruction, userPrompt: userPrompt, scope: scope,
                                  additionalScopes: additionalScopes, tier: tier, language: language, session: session)
        }
        let id = OpenAIRequestRegistry.shared.register(generation: session, scope: scope, additionalScopes: additionalScopes, cancel: { request.cancel() })
        defer { OpenAIRequestRegistry.shared.remove(id) }
        do {
            return try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
        } catch {
            if request.isCancelled || Task.isCancelled || (error as? OpenAIConnectionError) == .cancelled {
                throw CancellationError()
            }
            if error is CancellationError { throw error }
            if let error = error as? OpenAIRequestError { throw error }
            if let error = error as? OpenAIConnectionError { throw error }
            throw OpenAIRequestError.failed
        }
    }

    private func executeJSON(
        systemInstruction: String,
        userPrompt: String,
        scope: OpenAIDataScope?,
        additionalScopes: [OpenAIDataScope] = [],
        tier: OpenAIAnalysisTier = .basic,
        language _: AppLanguage,
        session: UUID
    ) async throws -> String {
        try preflight(scope)
        for additional in additionalScopes { try preflight(additional) }
        let token = try await accessToken()
        try validateSession(session, scope: scope, additionalScopes: additionalScopes)
        var catalogRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        catalogRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (catalogData, catalogResponse) = try await transport.data(for: catalogRequest)
        try validateSession(session, scope: scope, additionalScopes: additionalScopes)
        try validateHTTP(catalogResponse.statusCode)
        guard let catalog = try? JSONSerialization.jsonObject(with: catalogData) as? [String: Any],
              let models = catalog["models"] as? [[String: Any]] else {
            throw OpenAIRequestError.invalidResponse
        }
        guard models.contains(where: { $0["slug"] as? String == tier.modelID && $0["visibility"] as? String == "list" }) else {
            throw OpenAIRequestError.modelUnavailable(tier.modelID)
        }
        try validateSession(session, scope: scope, additionalScopes: additionalScopes)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": tier.modelID,
            "instructions": systemInstruction,
            "input": [["role": "user", "content": userPrompt]],
            "store": false,
            "stream": true
        ])
        let stream = try await transport.stream(for: request)
        defer { stream.cancel() }
        try validateSession(session, scope: scope, additionalScopes: additionalScopes)
        try validateHTTP(stream.response.statusCode)
        guard stream.response.mimeType == "text/event-stream" else { throw OpenAIRequestError.invalidResponse }
        var eventData = ""
        var output = ""
        var completed = false
        for try await line in stream.lines {
            try validateSession(session, scope: scope, additionalScopes: additionalScopes)
            if line.isEmpty {
                if !eventData.isEmpty {
                    let result = try Self.consumeEvent(eventData)
                    switch result {
                    case .delta(let delta): output += delta
                    case .completed(let text):
                        if let text { output = text }
                        completed = true
                    case .ignored: break
                    }
                    eventData.removeAll(keepingCapacity: true)
                }
                if completed { break }
                guard output.utf8.count <= 524_288 else { throw OpenAIRequestError.invalidResponse }
            } else if line.hasPrefix("data:") {
                if !eventData.isEmpty { eventData += "\n" }
                let value = line.dropFirst(5)
                eventData += value.hasPrefix(" ") ? String(value.dropFirst()) : String(value)
                guard eventData.utf8.count <= 524_288 else { throw OpenAIRequestError.invalidResponse }
            }
        }
        // A terminal event may be the final line without a blank separator.
        if !completed, !eventData.isEmpty {
            if case .completed(let text) = try Self.consumeEvent(eventData) {
                if let text { output = text }
                completed = true
            }
        }
        try validateSession(session, scope: scope, additionalScopes: additionalScopes)
        guard completed else { throw OpenAIRequestError.interrupted }
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              json is [String: Any] else { throw OpenAIRequestError.invalidResponse }
        return output
    }

    private func preflight(_ scope: OpenAIDataScope?) throws {
        try Task.checkCancellation()
        guard enabled() else { throw OpenAIRequestError.disabled }
        if let scope, !consent(scope) { throw OpenAIRequestError.consentRequired }
    }

    private func validateSession(_ session: UUID, scope: OpenAIDataScope?, additionalScopes: [OpenAIDataScope] = []) throws {
        try Task.checkCancellation()
        guard session == generation() else { throw CancellationError() }
        try preflight(scope)
        for additional in additionalScopes { try preflight(additional) }
    }

    private func validateHTTP(_ status: Int) throws {
        guard (200...299).contains(status) else {
            if status == 429 { throw OpenAIRequestError.usageLimit }
            throw OpenAIRequestError.http(status)
        }
    }

    private enum EventResult { case delta(String), completed(String?), ignored }
    private static func consumeEvent(_ data: String) throws -> EventResult {
        if data == "[DONE]" { return .ignored }
        guard let bytes = data.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let type = event["type"] as? String else { throw OpenAIRequestError.invalidResponse }
        if ["error", "response.failed", "response.incomplete"].contains(type) {
            let response = event["response"] as? [String: Any]
            let error = (response?["error"] ?? event["error"]) as? [String: Any]
            let code = error?["code"] as? String ?? event["code"] as? String ?? ""
            if code == "subscription_sharing_usage_limit_exceeded" || code == "subscription_sharing_usage_unavailable" {
                throw OpenAIRequestError.usageLimit
            }
            throw OpenAIRequestError.failed
        }
        if type == "response.output_text.delta" {
            guard let delta = event["delta"] as? String else { throw OpenAIRequestError.invalidResponse }
            return .delta(delta)
        }
        guard type == "response.completed" else { return .ignored }
        guard let response = event["response"] as? [String: Any],
              response["status"] as? String == "completed" else { throw OpenAIRequestError.invalidResponse }
        if let error = response["error"], !(error is NSNull) { throw OpenAIRequestError.failed }
        if let output = response["output"] as? [[String: Any]] {
            let text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return .completed(text) }
        }
        return .completed(nil)
    }
}

@MainActor final class OpenAIIntelligenceEngine: IntelligenceService {
    private let service: OpenAIProviderService
    private let heuristic = HeuristicEngine()
    init(service: OpenAIProviderService? = nil) { self.service = service ?? OpenAIProviderService() }

    func prioritize(todos: [Todo], events: [CalendarService.CalendarEventSummary],
                    persona: PersonaContext, progress: IntelligenceProgressHandler?) async throws -> [PriorityResult] {
        let eligible = todos.filter(\.isEligibleForAutomaticPriority)
        // Automatic priority work never authorizes mail/meeting source disclosure.
        let local = eligible.filter { $0.hasLocalOnlySourceContent || $0.calendarOrigin == .siftMeeting || $0.calendarOrigin == .siftEmail }
        let localIDs = Set(local.map(\.id))
        let remote = eligible.filter { !localIDs.contains($0.id) }
        var results = try await heuristic.prioritize(todos: local, events: events, persona: persona, progress: nil)
        for index in results.indices {
            results[index].requestedProviderRawValue = PersonaAIProvider.openAI.rawValue
            results[index].fallbackReason = RuleFallbackReason.providerNotApplicable.rawValue
            results[index].executionPath = .rules(.providerNotApplicable)
        }
        guard !remote.isEmpty else { return results }
        let sharedPersona = OpenAIPrivacy.allows(.persona) ? persona : .empty
        let additionalScopes: [OpenAIDataScope] = sharedPersona.types.isEmpty && sharedPersona.description.isEmpty ? [] : [.persona]
        let prompt = ScheduleLLMAdapter.buildScheduleInput(
            todos: remote, persona: sharedPersona, events: events, allowsPrivateCalendarTitles: false,
            usesBehaviorAvailability: false, includeCalendarTitles: false
        )
        let raw = try await service.generateJSON(systemInstruction: ScheduleLLMAdapter.systemPrompt(),
                                                 userPrompt: prompt, scope: .tasks, additionalScopes: additionalScopes)
        guard let parsed = ScheduleLLMAdapter.parseScheduleResponseV9(text: raw, todos: remote,
                                                                       persona: sharedPersona, engine: .openAI),
              Set(parsed.map(\.todoID)) == Set(remote.map(\.id)) else { throw OpenAIRequestError.invalidResponse }
        results += parsed
        for (index, result) in results.enumerated() {
            let title = eligible.first(where: { $0.id == result.todoID })?.title ?? ""
            progress?(.result(result, index: index + 1, total: results.count, title: title))
        }
        return results
    }
}
