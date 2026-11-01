import Foundation

enum LLMDebugLogger {
    #if DEBUG
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PIEROOT_LLM_DEBUG"] == "1"
    }
    #endif

    static func request(provider: String, operation: String, metadata: [String] = [], systemPrompt: String, userPrompt: String) {
        #if DEBUG
        guard isEnabled else { return }
        print("[LLM] provider=\(provider) operation=\(operation) event=request metadataCount=\(metadata.count) systemChars=\(systemPrompt.count) userChars=\(userPrompt.count)")
        #endif
    }

    static func response(provider: String, operation: String, text: String) {
        #if DEBUG
        guard isEnabled else { return }
        print("[LLM] provider=\(provider) operation=\(operation) event=response chars=\(text.count)")
        #endif
    }

    static func event(provider: String, operation: String, title: String, details: String) {
        #if DEBUG
        guard isEnabled else { return }
        print("[LLM] provider=\(provider) operation=\(operation) event=\(title) detailChars=\(details.count)")
        #endif
    }

    static func failure(provider: String, operation: String, error: Error) {
        #if DEBUG
        guard isEnabled else { return }
        print("[LLM] provider=\(provider) operation=\(operation) event=failure errorType=\(String(describing: type(of: error)))")
        #endif
    }

    /// DEBUG lifecycle diagnostics exclude content unless explicitly enabled.
    @MainActor
    static var hasOpenAITrace: Bool {
        #if DEBUG
        openAITrace?.includesContent == true
        #else
        false
        #endif
    }

    @MainActor
    static func withOpenAITrace<T>(operation: String, includeContent: Bool? = nil,
                                  body: @MainActor () async throws -> T) async rethrows -> T {
        #if DEBUG
        if openAITrace == nil {
            let trace = OpenAITrace(operation: operation, includesContent: includeContent ?? isEnabled)
            return try await $openAITrace.withValue(trace) {
                trace.record(stage: "operation.started", text: "")
                do {
                    let result = try await body()
                    trace.record(stage: "operation.completed", text: "")
                    return result
                } catch {
                    openAIFailure(error)
                    throw error
                }
            }
        }
        #endif
        return try await body()
    }

    @MainActor
    static func openAIEvent(_ stage: String, _ text: @autoclosure () -> String = "") {
        #if DEBUG
        guard let trace = openAITrace else { return }
        if trace.includesContent {
            trace.record(stage: stage, text: text())
        } else {
            trace.record(stage: stage, text: "")
        }
        #endif
    }

    @MainActor
    static func openAIFailure(_ error: Error) {
        #if DEBUG
        guard let trace = openAITrace, trace.stage != "failure" else { return }
        let diagnostic = error as NSError
        var detail = "type=\(String(reflecting: type(of: error))) domain=\(diagnostic.domain) code=\(diagnostic.code)"
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            detail += " missingKey=\(key.stringValue) path=\(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.typeMismatch(let type, let context):
            detail += " expectedType=\(type) path=\(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.valueNotFound(let type, let context):
            detail += " missingType=\(type) path=\(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.dataCorrupted(let context):
            detail += " corruptPath=\(context.codingPath.map(\.stringValue).joined(separator: "."))"
        default: break
        }
        trace.record(stage: "failure", text: "after=\(trace.stage) \(detail)", contentFree: true)
        #endif
    }

    @MainActor
    static func openAIRequest(_ request: URLRequest, accessToken: String) {
        #if DEBUG
        guard let trace = openAITrace else { return }
        if trace.includesContent { trace.protect(accessToken) }
        trace.requestNumber += 1
        // Never dump allHTTPHeaderFields, cookies, URL query/fragment, or credentials.
        trace.record(stage: "http.request", text: "", contentFree: true)
        if trace.includesContent {
            trace.record(stage: "http.request.metadata", text: "method=\(request.httpMethod ?? "GET") host=\(request.url?.host ?? "") path=\(request.url?.path ?? "")")
            trace.record(stage: "http.request.body", text: request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        #endif
    }

    @MainActor
    static func openAIResponse(_ response: HTTPURLResponse) {
        #if DEBUG
        guard let trace = openAITrace else { return }
        trace.record(stage: "http.response", text: "status=\(response.statusCode)", contentFree: true)
        if trace.includesContent {
            trace.record(stage: "http.response.metadata", text: "contentType=\(response.value(forHTTPHeaderField: "Content-Type") ?? "") requestID=\(response.value(forHTTPHeaderField: "x-request-id") ?? "")")
        }
        #endif
    }

    #if DEBUG
    @TaskLocal private static var openAITrace: OpenAITrace?

    @MainActor private final class OpenAITrace {
        let id = UUID().uuidString
        let operation: String
        let includesContent: Bool
        var requestNumber = 0
        private(set) var stage = "operation.started"
        private var secrets: [String] = []

        init(operation: String, includesContent: Bool) {
            self.operation = operation
            self.includesContent = includesContent
        }

        func protect(_ secret: String) {
            guard !secret.isEmpty, !secrets.contains(secret) else { return }
            secrets.append(secret)
            // JSON bodies may escape characters in an echoed credential.
            if let data = try? JSONEncoder().encode(secret), let json = String(data: data, encoding: .utf8) {
                let escaped = String(json.dropFirst().dropLast())
                if escaped != secret { secrets.append(escaped) }
            }
        }

        func record(stage: String, text: String, contentFree: Bool = false) {
            // Do not emit per-line SSE/body events when private content tracing is off.
            if !includesContent {
                switch stage {
                case "http.request.body", "http.response.body", "http.response.body.line",
                     "response.sse.line", "response.output": return
                default: break
                }
            }
            self.stage = stage
            guard includesContent || contentFree else {
                print("[LLM][OpenAI] trace=\(id) operation=\(operation) request=\(requestNumber) stage=\(stage) contents=disabled")
                return
            }
            var safe = text
            for secret in secrets { safe = safe.replacingOccurrences(of: secret, with: "<redacted>") }
            let scalars = safe.unicodeScalars
            let parts = max(1, (scalars.count + 511) / 512)
            var start = scalars.startIndex
            for part in 1...parts {
                let end = scalars.index(start, offsetBy: 512, limitedBy: scalars.endIndex) ?? scalars.endIndex
                let chunk = String(scalars[start..<end])
                // JSON strings preserve whitespace/newlines and keep each console record unambiguous.
                let quoted = (try? JSONEncoder().encode(chunk)).map { String(decoding: $0, as: UTF8.self) } ?? "\"<encoding-failed>\""
                print("[LLM][OpenAI] trace=\(id) operation=\(operation) request=\(requestNumber) stage=\(stage) part=\(part)/\(parts) text=\(quoted)")
                start = end
            }
        }
    }
    #endif
}
