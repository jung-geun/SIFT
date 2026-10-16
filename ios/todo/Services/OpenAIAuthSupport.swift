import Foundation
import AuthenticationServices
import UIKit
import CryptoKit
import Security

nonisolated struct OpenAIProfile: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let clientID: String
    let subject: String
    let email: String?
    let hasPlanPermission: Bool
}

nonisolated enum OpenAIConnectionError: Error, LocalizedError, Equatable {
    case cancelled, unavailable, invalidCallback, invalidIdentity, signInRequired
    case permissionRequired, storage, network, invalidClient, exchangeFailed
    var errorDescription: String? {
        errorDescription(language: .current)
    }

    func errorDescription(language: AppLanguage) -> String {
        switch self {
        case .cancelled:
            return AppLanguage.localized(
                "error.openai.connection.cancelled",
                defaultValue: language == .english ? "ChatGPT sign-in was cancelled." : "ChatGPT 로그인이 취소되었습니다.",
                language: language,
                comment: "ChatGPT connection error when sign-in is cancelled."
            )
        case .unavailable:
            return AppLanguage.localized(
                "error.openai.connection.unavailable",
                defaultValue: language == .english ? "Unable to open ChatGPT sign-in on this device." : "이 기기에서 ChatGPT 로그인을 열 수 없습니다.",
                language: language,
                comment: "ChatGPT connection error when sign-in cannot be opened."
            )
        case .invalidCallback:
            return AppLanguage.localized(
                "error.openai.connection.invalidCallback",
                defaultValue: language == .english ? "ChatGPT sign-in could not be verified. Please try again." : "ChatGPT 로그인을 확인할 수 없습니다. 다시 시도해 주세요.",
                language: language,
                comment: "ChatGPT connection error when the sign-in callback cannot be verified."
            )
        case .invalidIdentity:
            return AppLanguage.localized(
                "error.openai.connection.invalidIdentity",
                defaultValue: language == .english ? "The ChatGPT identity could not be verified. Please sign in again." : "ChatGPT 계정의 신원을 확인할 수 없습니다. 다시 로그인해 주세요.",
                language: language,
                comment: "ChatGPT connection error when account identity cannot be verified."
            )
        case .signInRequired:
            return AppLanguage.localized(
                "error.openai.connection.signInRequired",
                defaultValue: language == .english ? "Please sign in to ChatGPT again." : "ChatGPT에 다시 로그인해 주세요.",
                language: language,
                comment: "ChatGPT connection error requiring a new sign-in."
            )
        case .permissionRequired:
            return AppLanguage.localized(
                "error.openai.connection.permissionRequired",
                defaultValue: language == .english ? "Allow this app to use your ChatGPT plan before continuing." : "계속하려면 이 앱이 ChatGPT 요금제를 사용하도록 허용해 주세요.",
                language: language,
                comment: "ChatGPT connection error requiring permission to use the account's plan."
            )
        case .storage:
            return AppLanguage.localized(
                "error.openai.connection.storage",
                defaultValue: language == .english ? "Unable to save ChatGPT credentials securely on this device." : "이 기기에 ChatGPT 인증 정보를 안전하게 저장할 수 없습니다.",
                language: language,
                comment: "Generic ChatGPT secure credential storage error; never include underlying diagnostics."
            )
        case .network:
            return AppLanguage.localized(
                "error.openai.connection.network",
                defaultValue: language == .english ? "Unable to reach ChatGPT. Please try again." : "ChatGPT에 연결할 수 없습니다. 다시 시도해 주세요.",
                language: language,
                comment: "Generic ChatGPT connection error; never include tokens or response bodies."
            )
        case .invalidClient:
            return AppLanguage.localized(
                "error.openai.connection.invalidClient",
                defaultValue: language == .english ? "This ChatGPT registration is not accepted. Reconnect the app in ChatGPT settings." : "이 ChatGPT 앱 등록을 사용할 수 없습니다. ChatGPT 설정에서 앱을 다시 연결해 주세요.",
                language: language,
                comment: "ChatGPT connection error when the app registration must be reconnected."
            )
        case .exchangeFailed:
            return AppLanguage.localized(
                "error.openai.connection.exchangeFailed",
                defaultValue: language == .english ? "ChatGPT sign-in was not completed. Please try again." : "ChatGPT 로그인이 완료되지 않았습니다. 다시 시도해 주세요.",
                language: language,
                comment: "Generic ChatGPT sign-in exchange error; never include server response details."
            )
        }
    }
}

/// The store receives opaque encoded records. Production never uses synchronizable Keychain items.
@MainActor protocol OpenAICredentialStore {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func deleteAll() throws
    func blockedClientIDs() -> Set<String>
    func block(_ clientID: String)
    func unblock(_ clientID: String)
}

@MainActor final class OpenAIDeviceCredentialStore: OpenAICredentialStore {
    private let service = "pieroot.todo.openai.device"
    private let blockedKey = "pieroot.todo.openai.signedOutClientIDs"
    func load() throws -> Data? { try KeychainStore.getDeviceOnly(service: service, account: "connections.v1") }
    func save(_ data: Data) throws {
        try KeychainStore.setDeviceOnly(service: service, account: "connections.v1", data: data,
                                        access: .backgroundAfterFirstUnlock)
    }
    func deleteAll() throws {
        try KeychainStore.deleteDeviceOnly(service: service, account: "connections.v1")
        // Only remove tombstones after secure deletion succeeds.
        UserDefaults.standard.removeObject(forKey: blockedKey)
    }
    // Nonsecret, local-only tombstones prevent restoration even if secure erasure fails.
    func blockedClientIDs() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: blockedKey) ?? []) }
    func block(_ clientID: String) {
        var ids = blockedClientIDs(); ids.insert(clientID)
        UserDefaults.standard.set(Array(ids), forKey: blockedKey)
    }
    func unblock(_ clientID: String) {
        var ids = blockedClientIDs(); ids.remove(clientID)
        UserDefaults.standard.set(Array(ids), forKey: blockedKey)
    }
}

@MainActor protocol OpenAIAuthTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

@MainActor final class OpenAIURLSessionTransport: NSObject, OpenAIAuthTransport, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 1_048_576 else {
            throw OpenAIConnectionError.network
        }
        return (data, response.statusCode)
    }
    // Never forward a code, refresh token, or ID-token hint across a server redirect.
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor protocol OpenAILoopbackListening: AnyObject {
    func start() async throws -> URL
    func callback() async throws -> URL
    func stop()
}

@MainActor protocol OpenAIAuthenticationBrowser: AnyObject {
    func start(url: URL, onCancel: @escaping @MainActor () -> Void) -> Bool
    func cancel()
}

@MainActor final class OpenAISystemAuthenticationBrowser: NSObject, OpenAIAuthenticationBrowser,
                                                            ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var anchor: UIWindow?
    func start(url: URL, onCancel: @escaping @MainActor () -> Void) -> Bool {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }), let window = scene.keyWindow else { return false }
        anchor = window
        // Apple's native callback matcher supports custom schemes and HTTPS, not SIWC's HTTP loopback.
        // The local listener completes the attempt; no unsupported "http" callback interception is used.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, _ in
            Task { @MainActor in onCancel() }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        self.session = session
        return session.start()
    }
    // Keep the real anchor until this per-attempt browser is released: UIKit may still be dismissing it.
    func cancel() { session?.cancel(); session = nil }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // start() requires a real foreground window before the authentication session exists.
        anchor!
    }
}

nonisolated enum OpenAIOAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OpenAIConnectionError.unavailable
        }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ text: String) -> Data? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
            || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
    static func issuedClient(_ value: String) -> Bool {
        value.hasPrefix("oaiapp_") && value.count > 7 && value.count < 256
            && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func callbackValues(_ url: URL, redirect: URL, state: String, clientID: String?) throws -> (code: String, clientID: String) {
        guard let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
              actual.scheme == "http", actual.host == "127.0.0.1", actual.port == redirect.port,
              actual.path == "/auth/callback", actual.user == nil, actual.password == nil, actual.fragment == nil else {
            throw OpenAIConnectionError.invalidCallback
        }
        var values = [String: String]()
        for item in actual.queryItems ?? [] {
            guard values[item.name] == nil, let value = item.value else { throw OpenAIConnectionError.invalidCallback }
            values[item.name] = value
        }
        guard values["state"] == state else { throw OpenAIConnectionError.invalidCallback }
        if let error = values["error"] {
            throw error == "access_denied" ? OpenAIConnectionError.permissionRequired : .exchangeFailed
        }
        guard let code = values["code"], !code.isEmpty, code.count < 16384,
              let issued = values["client_id"] ?? clientID, issuedClient(issued),
              clientID == nil || issued == clientID else { throw OpenAIConnectionError.invalidCallback }
        return (code, issued)
    }
}
