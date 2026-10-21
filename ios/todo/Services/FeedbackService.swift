import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum FeedbackKind: String, Codable, CaseIterable, Sendable {
    case bug, feature
}

nonisolated struct FeedbackAppMetadata: Codable, Equatable, Sendable {
    let version: String
    let build: String
    let platform: String
    let osVersion: String
    let language: String

    @MainActor static func current() -> Self {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if targetEnvironment(macCatalyst)
        let platform = "macOS"
        #elseif canImport(UIKit)
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #else
        let platform = "macOS"
        #endif
        return Self(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            platform: platform,
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            language: AppLanguage.current.rawValue
        )
    }

    fileprivate var isValid: Bool {
        func valid(_ value: String, maximum: Int) -> Bool {
            (1...maximum).contains(value.unicodeScalars.count)
                && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return valid(version, maximum: 32) && valid(build, maximum: 32)
            && ["iOS", "iPadOS", "macOS"].contains(platform)
            && valid(osVersion, maximum: 64) && valid(language, maximum: 32)
    }
}

/// An immutable, in-memory consent snapshot. Retries send these same bytes and ID.
/// Neither the draft nor its random per-submission ID is persisted.
nonisolated struct FeedbackSubmission: Sendable {
    let submissionID: String
    let kind: FeedbackKind
    let title: String
    let message: String
    let app: FeedbackAppMetadata
    let diagnostics: String?
    let body: Data

    var includesDiagnostics: Bool { diagnostics != nil }

    init(
        kind: FeedbackKind,
        title: String,
        message: String,
        app: FeedbackAppMetadata,
        diagnostics: Data? = nil
    ) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(title.unicodeScalars.count),
              (1...8000).contains(message.unicodeScalars.count), app.isValid else {
            throw FeedbackFailure.invalidInput
        }
        let diagnosticText: String?
        if let diagnostics {
            guard kind == .bug, diagnostics.count <= 524_288,
                  let text = String(data: diagnostics, encoding: .utf8),
                  Data(text.utf8) == diagnostics,
                  let object = try? JSONSerialization.jsonObject(with: diagnostics),
                  object is [String: Any] else {
                throw FeedbackFailure.invalidDiagnostics
            }
            // Do not parse/re-encode or normalize the previewed report. JSON escaping
            // in the outer envelope must round-trip to the original UTF-8 bytes.
            diagnosticText = text
        } else {
            diagnosticText = nil
        }
        let id = UUID().uuidString.lowercased()
        let payload = Payload(
            schemaVersion: 1, submissionID: id, kind: kind, title: title,
            message: message, app: app, diagnostics: diagnosticText
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(payload)
        guard body.count <= 786_432 else { throw FeedbackFailure.requestTooLarge }
        self.submissionID = id
        self.kind = kind
        self.title = title
        self.message = message
        self.app = app
        self.diagnostics = diagnosticText
        self.body = body
    }

    private struct Payload: Encodable {
        let schemaVersion: Int
        let submissionID: String
        let kind: FeedbackKind
        let title: String
        let message: String
        let app: FeedbackAppMetadata
        let diagnostics: String?
    }
}

nonisolated struct FeedbackReceipt: Codable, Equatable, Sendable {
    let ticketID: String
    let receivedAt: String

    fileprivate var isValid: Bool {
        let uuidPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
        let datePattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"
        guard ticketID.range(of: uuidPattern, options: .regularExpression) != nil,
              receivedAt.range(of: datePattern, options: .regularExpression) != nil else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if receivedAt.contains(".") { formatter.formatOptions.insert(.withFractionalSeconds) }
        return formatter.date(from: receivedAt) != nil
    }
}

nonisolated enum FeedbackFailure: Error, Equatable, Sendable {
    case configuration, invalidInput, invalidDiagnostics, requestTooLarge
    case transport, cancelled, invalidResponse, conflict
    case rateLimited(retryAfter: Int?)
    case unavailable, rejected

    var localizationKey: String {
        let suffix: String
        switch self {
        case .configuration: suffix = "configuration"
        case .invalidInput: suffix = "invalidInput"
        case .invalidDiagnostics: suffix = "invalidDiagnostics"
        case .requestTooLarge: suffix = "requestTooLarge"
        case .transport: suffix = "transport"
        case .cancelled: suffix = "cancelled"
        case .invalidResponse: suffix = "invalidResponse"
        case .conflict: suffix = "conflict"
        case .rateLimited: suffix = "rateLimited"
        case .unavailable: suffix = "unavailable"
        case .rejected: suffix = "rejected"
        }
        return "feedback.failure.\(suffix)"
    }
}

nonisolated protocol FeedbackSubmitting: Sendable {
    func submit(_ submission: FeedbackSubmission) async throws -> FeedbackReceipt
}

/// Never follows even same-origin redirects: a redirect is not consent to send
/// private content elsewhere. No app/provider session, credentials or cookies are used.
nonisolated final class FeedbackRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

nonisolated final class FeedbackService: FeedbackSubmitting {
    private let endpoint: URL?
    private let session: URLSession

    init(
        baseURL: String? = Bundle.main.object(forInfoDictionaryKey: "SIFTFeedbackBaseURL") as? String,
        protocolClasses: [AnyClass]? = nil
    ) {
        endpoint = Self.endpoint(from: baseURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = [:]
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: FeedbackRedirectBlocker(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    private static func endpoint(from raw: String?) -> URL? {
        guard let raw, let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" else { return nil }
        var secure = scheme == "https"
        #if DEBUG
        if scheme == "http", ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) { secure = true }
        #endif
        guard secure, let base = components.url else { return nil }
        return base.appendingPathComponent("v1/feedback")
    }

    func submit(_ submission: FeedbackSubmission) async throws -> FeedbackReceipt {
        guard let endpoint else { throw FeedbackFailure.configuration }
        try Self.checkCancellation()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpShouldHandleCookies = false
        request.httpBody = submission.body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw FeedbackFailure.cancelled
            }
            throw FeedbackFailure.transport
        }
        try Self.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw FeedbackFailure.invalidResponse }
        let isJSON = http.mimeType?.lowercased() == "application/json"
        if http.statusCode == 200 || http.statusCode == 201 {
            guard isJSON, data.count <= 65_536,
                  let receipt = try? JSONDecoder().decode(FeedbackReceipt.self, from: data),
                  receipt.isValid else { throw FeedbackFailure.invalidResponse }
            return receipt
        }
        guard isJSON, data.count <= 65_536,
              let failure = try? JSONDecoder().decode(ServerFailure.self, from: data) else {
            throw FeedbackFailure.invalidResponse
        }
        switch (http.statusCode, failure.errorCode) {
        case (400, "INVALID_REQUEST"): throw FeedbackFailure.rejected
        case (413, "REQUEST_TOO_LARGE"): throw FeedbackFailure.requestTooLarge
        case (409, "SUBMISSION_CONFLICT"): throw FeedbackFailure.conflict
        case (429, "RATE_LIMITED"):
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
            throw FeedbackFailure.rateLimited(retryAfter: seconds)
        case (503, "INTAKE_UNAVAILABLE"), (503, "CAPACITY_REACHED"): throw FeedbackFailure.unavailable
        default: throw FeedbackFailure.invalidResponse
        }
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw FeedbackFailure.cancelled }
    }

    private struct ServerFailure: Decodable { let errorCode: String }
}

/// The draft stays in memory through review, failure and cancellation. Only an
/// explicit consented send invokes the service; preparing a preview is local.
@MainActor final class FeedbackComposer: ObservableObject {
    @Published var kind: FeedbackKind { didSet { if kind != oldValue { invalidateReview() } } }
    @Published var title = "" { didSet { if title != oldValue { invalidateReview() } } }
    @Published var message = "" { didSet { if message != oldValue { invalidateReview() } } }
    @Published var includeDiagnostics: Bool { didSet { if includeDiagnostics != oldValue { invalidateReview() } } }
    @Published var consent = false
    @Published private(set) var submission: FeedbackSubmission?
    @Published private(set) var receipt: FeedbackReceipt?
    @Published private(set) var failure: FeedbackFailure?
    @Published private(set) var isSending = false

    let preparedDiagnostics: Data?
    private let app: FeedbackAppMetadata
    private let service: any FeedbackSubmitting
    private var inFlight: Task<FeedbackReceipt, Error>?
    private var attemptID: UUID?

    init(
        initialKind: FeedbackKind = .bug,
        preparedDiagnostics: Data? = nil,
        app: FeedbackAppMetadata? = nil,
        service: any FeedbackSubmitting = FeedbackService()
    ) {
        kind = initialKind
        self.preparedDiagnostics = preparedDiagnostics
        includeDiagnostics = initialKind == .bug && preparedDiagnostics != nil
        self.app = app ?? .current()
        self.service = service
    }

    @discardableResult func prepareReview() -> Bool {
        guard !isSending, receipt == nil else { return false }
        do {
            if submission == nil {
                submission = try FeedbackSubmission(
                    kind: kind, title: title, message: message, app: app,
                    diagnostics: kind == .bug && includeDiagnostics ? preparedDiagnostics : nil
                )
            }
            failure = nil
            consent = false
            return true
        } catch {
            failure = error as? FeedbackFailure ?? .invalidInput
            return false
        }
    }

    func returnToEditing() { invalidateReview() }

    func send() async -> FeedbackReceipt? {
        guard !isSending, receipt == nil, consent, let frozen = submission else { return nil }
        guard !Task.isCancelled else {
            failure = .cancelled
            return nil
        }
        let id = UUID()
        attemptID = id
        isSending = true
        failure = nil
        let service = service
        let task = Task { try await service.submit(frozen) }
        inFlight = task
        return await withTaskCancellationHandler {
            do {
                let delivered = try await task.value
                guard attemptID == id else { return nil }
                inFlight = nil
                attemptID = nil
                isSending = false
                guard !Task.isCancelled, !task.isCancelled else {
                    failure = .cancelled
                    return nil
                }
                receipt = delivered
                return delivered
            } catch {
                guard attemptID == id else { return nil }
                inFlight = nil
                attemptID = nil
                isSending = false
                failure = Task.isCancelled || task.isCancelled ? .cancelled : (error as? FeedbackFailure ?? .transport)
                return nil
            }
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() {
        guard isSending else { return }
        inFlight?.cancel()
        inFlight = nil
        attemptID = nil
        isSending = false
        failure = .cancelled
    }

    private func invalidateReview() {
        cancel()
        submission = nil
        receipt = nil
        failure = nil
        consent = false
    }
}
