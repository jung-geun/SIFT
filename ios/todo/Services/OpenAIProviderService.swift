import Foundation

nonisolated enum OpenAIAnalysisTier: String, Sendable {
    case basic, advanced
    var modelID: String { self == .basic ? "gpt-6-luna" : "gpt-6.1-sol" }
}

nonisolated struct OpenAIAvailableModel: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
}

private nonisolated struct OpenAIModelCatalog: Decodable {
    let models: [OpenAIAvailableModel]

    private struct PlanModel: Decodable {
        let slug: String
        let display_name: String?
        let visibility: String
    }
    private struct APIModel: Decodable { let id: String }
    private enum CodingKeys: String, CodingKey { case models, data }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var visible: [OpenAIAvailableModel] = []
        var seen = Set<String>()
        if container.contains(.models) {
            // SIWC catalogs have explicit visibility. Never fall through to a
            // second envelope that could accidentally expose hidden models.
            for model in try container.decode([PlanModel].self, forKey: .models) where model.visibility == "list" {
                guard !model.slug.isEmpty else { throw OpenAIRequestError.invalidResponse }
                if seen.insert(model.slug).inserted {
                    visible.append(OpenAIAvailableModel(id: model.slug, displayName: model.display_name ?? model.slug))
                }
            }
        } else {
            // The public Models API uses data/id rather than models/slug.
            for model in try container.decode([APIModel].self, forKey: .data) {
                guard !model.id.isEmpty else { throw OpenAIRequestError.invalidResponse }
                if seen.insert(model.id).inserted {
                    visible.append(OpenAIAvailableModel(id: model.id, displayName: model.id))
                }
            }
        }
        models = visible
    }
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
    private let prepareSession: @MainActor () -> Void
    private let regionAllowed: @MainActor () -> Bool

    init(
        transport: (any OpenAIResponseTransport)? = nil,
        accessToken: @escaping @MainActor () async throws -> String = { try await OpenAIConnection.shared.authorizedAccessToken() },
        generation: @escaping @MainActor () -> UUID = { OpenAIConnection.shared.sessionGeneration },
        consent: @escaping @Sendable (OpenAIDataScope) -> Bool = OpenAIPrivacy.allows,
        enabled: @escaping @MainActor () -> Bool = { SettingsStore.betaProviderEnabled(.openAI) },
        prepareSession: @escaping @MainActor () -> Void = { OpenAIConnection.shared.refreshCredentials() },
        regionAllowed: @escaping @MainActor () -> Bool = { OpenAIRegionalAvailability.allowsRequests }
    ) {
        self.transport = transport ?? OpenAIURLSessionResponseTransport()
        self.accessToken = accessToken
        self.generation = generation
        self.consent = consent
        self.enabled = enabled
        self.prepareSession = prepareSession
        self.regionAllowed = regionAllowed
    }

    /// Account metadata only: this neither runs inference nor authorizes app-data sharing.
    func availableModels() async throws -> [OpenAIAvailableModel] {
        try preflight(nil)
        prepareSession()
        let session = generation()
        let request = Task {
            try validateSession(session, scope: nil)
            let token = try await accessToken()
            try validateSession(session, scope: nil)
            return try await loadModels(token: token, session: session, scope: nil, additionalScopes: [])
        }
        let id = OpenAIRequestRegistry.shared.register(generation: session, scope: nil, additionalScopes: [], cancel: { request.cancel() })
        defer { OpenAIRequestRegistry.shared.remove(id) }
        let models = try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
        try validateSession(session, scope: nil)
        return models
    }

    /// Explicitly checks the selected account with a fixed message, never with stored app data.
    func verifySubscriptionConnection() async throws -> String {
        _ = try await performResponse(
            systemInstruction: "This is a connection check. Reply briefly to confirm receipt.",
            userPrompt: "Confirm this ChatGPT plan connection.",
            scope: nil, tier: .basic, language: .current, requiresJSONObject: false
        )
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
        try await performResponse(systemInstruction: systemInstruction, userPrompt: userPrompt, scope: scope,
                                  additionalScopes: additionalScopes, tier: tier, language: language, requiresJSONObject: true)
    }

    private func performResponse(
        systemInstruction: String,
        userPrompt: String,
        scope: OpenAIDataScope?,
        additionalScopes: [OpenAIDataScope] = [],
        tier: OpenAIAnalysisTier,
        language: AppLanguage,
        requiresJSONObject: Bool
    ) async throws -> String {
        try preflight(scope)
        for additional in additionalScopes { try preflight(additional) }
        prepareSession()
        let session = generation()
        let request = Task {
            try await executeResponse(systemInstruction: systemInstruction, userPrompt: userPrompt, scope: scope,
                                      additionalScopes: additionalScopes, tier: tier, language: language,
                                      session: session, requiresJSONObject: requiresJSONObject)
        }
        let id = OpenAIRequestRegistry.shared.register(generation: session, scope: scope, additionalScopes: additionalScopes, cancel: { request.cancel() })
        defer { OpenAIRequestRegistry.shared.remove(id) }
        do {
            let response = try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
            try validateSession(session, scope: scope, additionalScopes: additionalScopes)
            return response
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

    private func executeResponse(
        systemInstruction: String,
        userPrompt: String,
        scope: OpenAIDataScope?,
        additionalScopes: [OpenAIDataScope] = [],
        tier: OpenAIAnalysisTier = .basic,
        language _: AppLanguage,
        session: UUID,
        requiresJSONObject: Bool
    ) async throws -> String {
        try preflight(scope)
        for additional in additionalScopes { try preflight(additional) }
        let token = try await accessToken()
        try validateSession(session, scope: scope, additionalScopes: additionalScopes)
        let models = try await loadModels(token: token, session: session, scope: scope, additionalScopes: additionalScopes)
        guard models.contains(where: { $0.id == tier.modelID }) else {
            throw OpenAIRequestError.modelUnavailable(tier.modelID)
        }
        try validateSession(session, scope: scope, additionalScopes: additionalScopes)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "model": tier.modelID,
            "instructions": systemInstruction,
            "input": [["role": "user", "content": userPrompt]],
            "store": false,
            "stream": true
        ]
        if requiresJSONObject { body["text"] = ["format": ["type": "json_object"]] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIRequestError.invalidResponse
        }
        if requiresJSONObject {
            guard let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  json is [String: Any] else { throw OpenAIRequestError.invalidResponse }
        }
        return output
    }

    private func loadModels(token: String, session: UUID, scope: OpenAIDataScope?, additionalScopes: [OpenAIDataScope]) async throws -> [OpenAIAvailableModel] {
        try validateSession(session, scope: scope, additionalScopes: additionalScopes)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        try validateSession(session, scope: scope, additionalScopes: additionalScopes)
        try validateHTTP(response.statusCode)
        guard let catalog = try? JSONDecoder().decode(OpenAIModelCatalog.self, from: data) else {
            throw OpenAIRequestError.invalidResponse
        }
        return catalog.models
    }

    private func preflight(_ scope: OpenAIDataScope?) throws {
        try Task.checkCancellation()
        guard regionAllowed() else { throw OpenAIRequestError.disabled }
        // Only the explicit fixed-message check uses nil. App-data requests
        // still require both provider opt-in and consent for every scope.
        if let scope {
            guard enabled() else { throw OpenAIRequestError.disabled }
            guard consent(scope) else { throw OpenAIRequestError.consentRequired }
        }
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
        guard let response = event["response"] as? [String: Any] else { throw OpenAIRequestError.invalidResponse }
        // The terminal event establishes completion; Response.status is optional
        // in the public schema. A supplied contradictory/malformed status is not.
        if let status = response["status"] {
            guard status as? String == "completed" else { throw OpenAIRequestError.invalidResponse }
        } else {
            // Without the optional status, require the final output snapshot;
            // an empty/malformed response object is not evidence of success.
            guard response["output"] != nil else { throw OpenAIRequestError.invalidResponse }
        }
        if let error = response["error"], !(error is NSNull) { throw OpenAIRequestError.failed }
        if let details = response["incomplete_details"], !(details is NSNull) { throw OpenAIRequestError.failed }
        if let value = response["output"] {
            guard let output = value as? [[String: Any]] else { throw OpenAIRequestError.invalidResponse }
            var text = ""
            for item in output where item["type"] as? String == "message" {
                if let status = item["status"] {
                    guard status as? String == "completed" else { throw OpenAIRequestError.invalidResponse }
                }
                guard let content = item["content"] as? [[String: Any]] else { throw OpenAIRequestError.invalidResponse }
                for part in content where part["type"] as? String == "output_text" {
                    guard let value = part["text"] as? String else { throw OpenAIRequestError.invalidResponse }
                    text += value
                }
            }
            // An explicit final snapshot is authoritative, even if empty or
            // invalid. Never resurrect earlier deltas over a bad final output.
            guard !text.isEmpty else { throw OpenAIRequestError.invalidResponse }
            return .completed(text)
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
