import Foundation
import CryptoKit
import Security
import Testing
@testable import todo

@MainActor private final class AuthMemoryStore: OpenAICredentialStore {
    var data: Data?
    var blocked: Set<String> = []
    var failWrites = false
    func load() throws -> Data? { data }
    func save(_ data: Data) throws {
        if failWrites { throw OpenAIConnectionError.storage }
        self.data = data
    }
    func deleteAll() throws {
        if failWrites { throw OpenAIConnectionError.storage }
        data = nil; blocked.removeAll()
    }
    func blockedClientIDs() -> Set<String> { blocked }
    func block(_ clientID: String) { blocked.insert(clientID) }
    func unblock(_ clientID: String) { blocked.remove(clientID) }
}

@MainActor private final class AuthTestListener: OpenAILoopbackListening {
    let redirect = URL(string: "http://127.0.0.1:45678/auth/callback")!
    var started = false
    var stopped = false
    var result: URL?
    var waiter: CheckedContinuation<URL, Error>?
    func start() async throws -> URL { started = true; return redirect }
    func callback() async throws -> URL {
        if let result { return result }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func stop() {
        stopped = true
        waiter?.resume(throwing: OpenAIConnectionError.cancelled); waiter = nil
    }
}

@MainActor private final class AuthTestBrowser: OpenAIAuthenticationBrowser {
    var onStart: ((URL) -> Bool)?
    var cancellation: (@MainActor () -> Void)?
    func start(url: URL, onCancel: @escaping @MainActor () -> Void) -> Bool {
        cancellation = onCancel
        return onStart?(url) ?? false
    }
    func cancel() { }
}

@MainActor private final class AuthTestTransport: OpenAIAuthTransport {
    var requests: [URLRequest] = []
    var handler: ((URLRequest) async throws -> (Data, Int))!
    var rejectCancelledRequests = false
    var cancelledRequestCount = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if Task.isCancelled { cancelledRequestCount += 1 }
        if rejectCancelledRequests { try Task.checkCancellation() }
        return try await handler(request)
    }
}

/// Real RSA signatures in tests exercise Security.framework verification, not a mocked JWT decoder.
@MainActor private final class AuthSigner {
    let key: SecKey
    let jwks: Data
    init() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var offset = 0
        func readElement(_ expected: UInt8) throws -> Data {
            #expect(der[offset] == expected)
            offset += 1
            var length = Int(der[offset]); offset += 1
            if length & 128 != 0 {
                let count = length & 127; length = 0
                for _ in 0..<count { length = length * 256 + Int(der[offset]); offset += 1 }
            }
            let result = der.subdata(in: offset..<(offset + length)); offset += length
            return result
        }
        // Enter SEQUENCE without consuming its children.
        offset = 1
        let firstLength = Int(der[offset]); offset += 1
        if firstLength & 128 != 0 { offset += firstLength & 127 }
        let n = Data(try readElement(2).drop(while: { $0 == 0 }))
        let e = try readElement(2)
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "test-key",
            "alg": "RS256", "use": "sig", "n": OpenAIOAuth.base64URL(n), "e": OpenAIOAuth.base64URL(e)]]])
    }
    func token(client: String, nonce: String, subject: String = "person-a", now: Date,
               overrides: [String: Any] = [:], algorithm: String = "RS256") throws -> String {
        var claims: [String: Any] = ["iss": OpenAIOAuth.issuer, "aud": client, "sub": subject,
                                   "exp": now.timeIntervalSince1970 + 3600, "nonce": nonce,
                                   "email": "same@example.com"]
        for (key, value) in overrides { claims[key] = value }
        let header = try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": "test-key"])
        let payload = try JSONSerialization.data(withJSONObject: claims)
        let input = "\(OpenAIOAuth.base64URL(header)).\(OpenAIOAuth.base64URL(payload))"
        let signature = try #require(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                                          Data(input.utf8) as CFData, nil)) as Data
        return input + "." + OpenAIOAuth.base64URL(signature)
    }
}

@MainActor private final class AuthHarness {
    let store = AuthMemoryStore()
    let transport = AuthTestTransport()
    let signer: AuthSigner
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var listener = AuthTestListener()
    var browser = AuthTestBrowser()
    var connection: OpenAIConnection!
    var authorization: [String: String] = [:]
    var authorizations: [[String: String]] = []
    var issuedID = "oaiapp_first"
    var subject = "person-a"
    var scope = OpenAIOAuth.scope
    var expires = 3600.0
    var tokenError: String?
    var callbackOverride: ((URL) -> URL)?
    var suspendBrowser = false
    var browserStarted: (() -> Void)?
    var refreshHandler: (() async throws -> (Data, Int))?
    var revocationStatus = 200

    init() throws {
        signer = try AuthSigner()
        connection = OpenAIConnection(store: store, transport: transport, now: { [now] in now },
                                      sleep: { _ in }, makeListener: { [unowned self] in
            self.listener = AuthTestListener(); return self.listener
        }, makeBrowser: { [unowned self] in
            self.browser = AuthTestBrowser()
            self.browser.onStart = { [unowned self] url in
                #expect(self.listener.started)
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                self.authorization = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
                self.authorizations.append(self.authorization)
                if !self.suspendBrowser {
                    var callback = URLComponents(url: self.listener.redirect, resolvingAgainstBaseURL: false)!
                    callback.queryItems = [URLQueryItem(name: "state", value: self.authorization["state"]),
                                           URLQueryItem(name: "code", value: "test-code"),
                                           URLQueryItem(name: "client_id", value: self.issuedID)]
                    self.listener.result = self.callbackOverride?(callback.url!) ?? callback.url!
                }
                self.browserStarted?()
                return true
            }
            return self.browser
        })
        transport.handler = { [unowned self] request in
            switch request.url!.path {
            case "/.well-known/openid-configuration":
                return (try JSONSerialization.data(withJSONObject: [
                    "issuer": OpenAIOAuth.issuer,
                    "authorization_endpoint": "https://auth.openai.com/api/accounts/authorize",
                    "token_endpoint": "https://auth.openai.com/api/accounts/oauth/token",
                    "revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke",
                    "jwks_uri": "https://auth.openai.com/.well-known/jwks.json"
                ]), 200)
            case "/.well-known/jwks.json": return (self.signer.jwks, 200)
            case "/api/accounts/oauth/revoke": return (Data(), self.revocationStatus)
            case "/api/accounts/oauth/token":
                let form = self.form(request)
                if form["grant_type"] == "refresh_token", let refreshHandler = self.refreshHandler {
                    return try await refreshHandler()
                }
                if let error = self.tokenError {
                    return (try JSONSerialization.data(withJSONObject: ["error": error]), 400)
                }
                let id = try #require(form["client_id"])
                return (try self.tokenResponse(client: id), 200)
            default: throw OpenAIConnectionError.network
            }
        }
    }
    func form(_ request: URLRequest) -> [String: String] {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    func tokenResponse(client: String = "oaiapp_first", access: String = "test-access", refresh: String = "test-refresh") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["access_token": access, "refresh_token": refresh,
            "id_token": signer.token(client: client, nonce: authorization["nonce"]!, subject: subject, now: now),
            "scope": scope, "token_type": "Bearer", "expires_in": expires])
    }
}

@Suite("Official native ChatGPT connection")
@MainActor struct OpenAIConnectionTests {
    @Test func publicPKCEFlowUsesStartedExactLoopbackAndNoSecret() async throws {
        let h = try AuthHarness()
        try await h.connection.signIn()
        let auth = h.authorization
        #expect(auth["client_id"] == "dynamic_agent_client")
        #expect(auth["agent_name_hint"] == "SIFT")
        #expect(auth["ext_agent_host_id"]?.hasPrefix("urn:uuid:") == true)
        #expect(auth["scope"] == OpenAIOAuth.scope)
        #expect(auth["resource"] == OpenAIOAuth.resource)
        #expect(auth["redirect_uri"] == h.listener.redirect.absoluteString)
        let request = try #require(h.transport.requests.first { $0.url?.path == "/api/accounts/oauth/token" })
        let form = h.form(request)
        #expect(form["client_id"] == "oaiapp_first")
        #expect(form["client_secret"] == nil)
        #expect(form["redirect_uri"] == auth["redirect_uri"])
        let verifier = try #require(form["code_verifier"])
        #expect(auth["code_challenge"] == OpenAIOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
        #expect(try await h.connection.authorizedAccessToken() == "test-access")
        #expect(h.connection.activeProfile?.subject == "person-a")
        #expect(h.connection.hasPlanPermission)
    }

    @Test func failedCodeExchangeRetainsIssuedRegistrationAcrossRestart() async throws {
        let h = try AuthHarness(); h.tokenError = "invalid_grant"
        await #expect(throws: OpenAIConnectionError.exchangeFailed) { try await h.connection.signIn(newAccount: true) }
        #expect(h.connection.profiles.isEmpty)
        #expect(h.connection.activeProfileID == nil)
        let host = h.authorization["ext_agent_host_id"]
        h.tokenError = nil
        h.connection = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now },
                                       makeListener: { h.listener = AuthTestListener(); return h.listener },
                                       makeBrowser: { h.browser })
        try await h.connection.signIn(newAccount: true)
        #expect(h.authorization["client_id"] == "oaiapp_first")
        #expect(h.authorization["agent_name_hint"] == nil)
        #expect(h.authorization["ext_agent_host_id"] == host)
        let resumed = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now })
        #expect(resumed.activeProfile?.clientID == "oaiapp_first")
        #expect(try await resumed.authorizedAccessToken() == "test-access")
    }

    @Test func missingPlanScopeKeepsIdentityButDeniesInference() async throws {
        let h = try AuthHarness(); h.scope = "openid profile email"
        try await h.connection.signIn()
        #expect(h.connection.activeProfile?.subject == "person-a")
        #expect(!h.connection.hasPlanPermission)
        await #expect(throws: OpenAIConnectionError.permissionRequired) { try await h.connection.authorizedAccessToken() }
    }

    @Test func returningSubjectAndClientCannotOverwriteSavedIdentity() async throws {
        let h = try AuthHarness(); try await h.connection.signIn()
        h.subject = "intruder"
        await #expect(throws: OpenAIConnectionError.invalidIdentity) { try await h.connection.signIn() }
        #expect(h.connection.activeProfile?.subject == "person-a")
        #expect(try await h.connection.authorizedAccessToken() == "test-access")
        h.issuedID = "oaiapp_different"
        await #expect(throws: OpenAIConnectionError.invalidCallback) { try await h.connection.signIn() }
        #expect(h.connection.profiles.count == 1)
    }

    @Test func separateRegistrationsAndSignoutKeepMappingsWithoutHints() async throws {
        let h = try AuthHarness(); try await h.connection.signIn()
        h.issuedID = "oaiapp_second"; h.subject = "person-b"
        try await h.connection.signIn(newAccount: true)
        #expect(h.connection.profiles.count == 2)
        #expect(h.connection.profiles[0].email == h.connection.profiles[1].email)
        let generation = h.connection.sessionGeneration
        try h.connection.selectProfile("oaiapp_first")
        #expect(h.connection.sessionGeneration != generation)
        await h.connection.signOut()
        #expect(h.connection.activeProfileID == nil)
        #expect(h.connection.profiles.count == 2)
        #expect(h.store.blocked.contains("oaiapp_first"))
        h.issuedID = "oaiapp_first"; h.subject = "person-a"
        try await h.connection.signIn()
        #expect(h.authorization["client_id"] == "oaiapp_first")
        #expect(h.authorization["id_token_hint"] == nil)
        #expect(!h.store.blocked.contains("oaiapp_first"))
    }

    @Test func invalidCallbacksNeverExchangeCode() async throws {
        for mutation in ["state", "duplicate", "host", "path", "error"] {
            let h = try AuthHarness()
            h.callbackOverride = { url in
                var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                switch mutation {
                case "state": parts.queryItems?.append(URLQueryItem(name: "state", value: "wrong"))
                case "duplicate": parts.queryItems?.append(URLQueryItem(name: "code", value: "replayed"))
                case "host": parts.host = "localhost"
                case "path": parts.path = "/callback"
                default: parts.queryItems?.append(URLQueryItem(name: "error", value: "access_denied"))
                }
                return parts.url!
            }
            await #expect(throws: (any Error).self) { try await h.connection.signIn() }
            #expect(!h.transport.requests.contains { $0.url?.path == "/api/accounts/oauth/token" })
            #expect(!h.connection.isSigningIn)
        }
    }

    @Test func signedJWTRejectsClaimAndSignatureAttacks() throws {
        let signer = try AuthSigner(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try signer.token(client: "oaiapp_first", nonce: "nonce", now: now)
        #expect(try OpenAIJWTValidator.validate(token, jwks: signer.jwks, clientID: "oaiapp_first", nonce: "nonce", now: now).subject == "person-a")
        let attacks: [[String: Any]] = [["iss": "https://attacker.example"], ["aud": "other"],
            ["nonce": "wrong"], ["exp": now.timeIntervalSince1970], ["sub": ""],
            ["aud": ["oaiapp_first", "other"]], ["nbf": now.timeIntervalSince1970 + 1000]]
        for claims in attacks {
            let invalid = try signer.token(client: "oaiapp_first", nonce: "nonce", now: now, overrides: claims)
            #expect(throws: OpenAIConnectionError.invalidIdentity) {
                try OpenAIJWTValidator.validate(invalid, jwks: signer.jwks, clientID: "oaiapp_first", nonce: "nonce", now: now)
            }
        }
        let none = try signer.token(client: "oaiapp_first", nonce: "nonce", now: now, algorithm: "none")
        #expect(throws: OpenAIConnectionError.invalidIdentity) {
            try OpenAIJWTValidator.validate(none, jwks: signer.jwks, clientID: "oaiapp_first", nonce: "nonce", now: now)
        }
        let unrelatedSigner = try AuthSigner()
        #expect(throws: OpenAIConnectionError.invalidIdentity) {
            try OpenAIJWTValidator.validate(token, jwks: unrelatedSigner.jwks, clientID: "oaiapp_first", nonce: "nonce", now: now)
        }
    }

    @Test func secureSaveFailureNeverActivatesNewProfile() async throws {
        let h = try AuthHarness(); h.store.failWrites = true
        await #expect(throws: OpenAIConnectionError.storage) { try await h.connection.signIn() }
        #expect(h.connection.activeProfileID == nil)
        #expect(h.authorizations.isEmpty)
    }

    @Test func terminalRefreshClearsCredentialsButTemporaryFailurePreservesThem() async throws {
        let h = try AuthHarness(); h.expires = 30
        try await h.connection.signIn()
        h.refreshHandler = { throw URLError(.notConnectedToInternet) }
        await #expect(throws: OpenAIConnectionError.network) { try await h.connection.authorizedAccessToken() }
        #expect(h.connection.hasPlanPermission)
        h.refreshHandler = { (Data("{\"error\":\"refresh_token_reused\"}".utf8), 400) }
        await #expect(throws: OpenAIConnectionError.signInRequired) { try await h.connection.authorizedAccessToken() }
        #expect(!h.connection.hasPlanPermission)
        await #expect(throws: OpenAIConnectionError.signInRequired) { try await h.connection.authorizedAccessToken() }
    }

    @Test func signoutTombstonePreventsRestartRestorationWhenKeychainWriteFails() async throws {
        let h = try AuthHarness(); try await h.connection.signIn()
        h.store.failWrites = true; h.revocationStatus = 503
        await h.connection.signOut()
        let resumed = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now })
        #expect(resumed.activeProfileID == nil)
        #expect(resumed.profiles.count == 1)
        await #expect(throws: OpenAIConnectionError.signInRequired) { try await resumed.authorizedAccessToken() }
        #expect(h.transport.requests.filter { $0.url?.path == "/api/accounts/oauth/revoke" }.count == 3)
        #expect(h.connection.statusMessage?.contains("test-refresh") == false)
    }
}

@MainActor private final class AuthRefreshGate {
    private var entered = false
    private var entering: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<(Data, Int), Never>?
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entering = $0 }
    }
    func suspend() async -> (Data, Int) {
        signal()
        return await withCheckedContinuation { response = $0 }
    }
    func signal() { entered = true; entering?.resume(); entering = nil }
    func resolve(_ data: Data) { response?.resume(returning: (data, 200)); response = nil }
}

extension OpenAIConnectionTests {
    @Test func concurrentRefreshIsSingleFlightAndCommitsRotationAtomically() async throws {
        let h = try AuthHarness(); h.expires = 30
        try await h.connection.signIn()
        let gate = AuthRefreshGate()
        h.refreshHandler = { await gate.suspend() }
        let first = Task { try await h.connection.authorizedAccessToken() }
        await gate.waitUntilEntered()
        let secondEntered = AuthRefreshGate()
        let second = Task {
            secondEntered.signal()
            return try await h.connection.authorizedAccessToken()
        }
        await secondEntered.waitUntilEntered()
        h.expires = 3600
        gate.resolve(try h.tokenResponse(access: "rotated-access", refresh: "rotated-refresh"))
        #expect(try await first.value == "rotated-access")
        #expect(try await second.value == "rotated-access")
        let refreshes = h.transport.requests.filter { h.form($0)["grant_type"] == "refresh_token" }
        #expect(refreshes.count == 1)
        let resumed = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now })
        #expect(try await resumed.authorizedAccessToken() == "rotated-access")
        await resumed.signOut()
        let revocation = try #require(h.transport.requests.last { $0.url?.path == "/api/accounts/oauth/revoke" })
        #expect(h.form(revocation)["token"] == "rotated-refresh")
    }

    @Test func logoutDuringRefreshRejectsLateTokensAndRevokesRotation() async throws {
        let h = try AuthHarness(); h.expires = 30
        try await h.connection.signIn()
        h.transport.rejectCancelledRequests = true
        let gate = AuthRefreshGate()
        h.refreshHandler = { await gate.suspend() }
        let request = Task { try await h.connection.authorizedAccessToken() }
        await gate.waitUntilEntered()
        let generation = h.connection.sessionGeneration
        await h.connection.signOut()
        #expect(h.connection.sessionGeneration != generation)
        gate.resolve(try h.tokenResponse(access: "late-access", refresh: "late-refresh"))
        await #expect(throws: OpenAIConnectionError.cancelled) { try await request.value }
        #expect(h.connection.activeProfileID == nil)
        #expect(!h.connection.hasPlanPermission)
        let revoked = h.transport.requests.filter { $0.url?.path == "/api/accounts/oauth/revoke" }.map { h.form($0)["token"] }
        #expect(revoked.contains("late-refresh"))
        #expect(h.transport.cancelledRequestCount == 0)
        let resumed = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now })
        await #expect(throws: OpenAIConnectionError.signInRequired) { try await resumed.authorizedAccessToken() }
    }

    @Test func switchDuringRefreshCannotReturnOrSavePreviousAccountsToken() async throws {
        let h = try AuthHarness(); h.expires = 30
        try await h.connection.signIn()
        h.issuedID = "oaiapp_second"; h.subject = "person-b"
        try await h.connection.signIn(newAccount: true)
        try h.connection.selectProfile("oaiapp_first")
        let gate = AuthRefreshGate()
        h.refreshHandler = { await gate.suspend() }
        let request = Task { try await h.connection.authorizedAccessToken() }
        await gate.waitUntilEntered()
        try h.connection.selectProfile("oaiapp_second")
        gate.resolve(try h.tokenResponse(access: "wrong-account-access", refresh: "late-refresh"))
        await #expect(throws: OpenAIConnectionError.cancelled) { try await request.value }
        #expect(h.connection.activeProfile?.subject == "person-b")
        #expect(h.connection.activeProfileID == "oaiapp_second")
    }

    @Test func cancellationAfterBrowserLaunchCannotExchangeOrActivate() async throws {
        let h = try AuthHarness()
        let launched = AuthRefreshGate()
        h.suspendBrowser = true
        h.browserStarted = { launched.signal() }
        let signIn = Task { try await h.connection.signIn() }
        await launched.waitUntilEntered()
        h.browser.cancellation?()
        await #expect(throws: OpenAIConnectionError.cancelled) { try await signIn.value }
        #expect(!h.connection.isSigningIn)
        #expect(h.connection.activeProfileID == nil)
        #expect(!h.transport.requests.contains { $0.url?.path == "/api/accounts/oauth/token" })
    }
    @Test func oldCallbackAndBrowserCancellationCannotCompleteNewAttempt() async throws {
        let h = try AuthHarness(); try await h.connection.signIn()
        let oldCallback = try #require(h.listener.result)
        let oldCancellation = h.browser.cancellation
        let originalState = h.authorization["state"]
        let originalNonce = h.authorization["nonce"]
        h.browserStarted = { oldCancellation?() }
        try await h.connection.signIn()
        #expect(h.authorization["state"] != originalState)
        #expect(h.authorization["nonce"] != originalNonce)
        h.callbackOverride = { _ in oldCallback }
        let exchanges = h.transport.requests.filter { $0.url?.path == "/api/accounts/oauth/token" }.count
        await #expect(throws: OpenAIConnectionError.invalidCallback) { try await h.connection.signIn() }
        #expect(h.transport.requests.filter { $0.url?.path == "/api/accounts/oauth/token" }.count == exchanges)
        #expect(h.connection.activeProfile?.subject == "person-a")
    }
    @Test func completeDeletionErasesAllMappingsHostAndLocalTombstones() async throws {
        let h = try AuthHarness(); try await h.connection.signIn()
        let previousHost = h.authorization["ext_agent_host_id"]
        h.issuedID = "oaiapp_second"; h.subject = "person-b"
        try await h.connection.signIn(newAccount: true)
        let generation = h.connection.sessionGeneration
        try await h.connection.deleteAllLocalCredentials()
        #expect(h.connection.sessionGeneration != generation)
        #expect(h.connection.profiles.isEmpty)
        #expect(h.connection.activeProfileID == nil)
        #expect(h.store.data == nil)
        #expect(h.store.blocked.isEmpty)
        let revokedClients = h.transport.requests.filter { $0.url?.path == "/api/accounts/oauth/revoke" }
            .compactMap { h.form($0)["client_id"] }
        #expect(Set(revokedClients) == ["oaiapp_first", "oaiapp_second"])
        try await h.connection.signIn()
        #expect(h.authorization["client_id"] == "dynamic_agent_client")
        #expect(h.authorization["ext_agent_host_id"] != previousHost)
    }

    @Test func failedCompleteDeletionThrowsAndBlocksEveryPersistedSession() async throws {
        let h = try AuthHarness(); try await h.connection.signIn()
        h.issuedID = "oaiapp_second"; h.subject = "person-b"
        try await h.connection.signIn(newAccount: true)
        h.store.failWrites = true
        await #expect(throws: OpenAIConnectionError.storage) { try await h.connection.deleteAllLocalCredentials() }
        #expect(h.connection.profiles.isEmpty)
        #expect(h.connection.activeProfileID == nil)
        #expect(h.store.blocked == ["oaiapp_first", "oaiapp_second"])
        let resumed = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now })
        #expect(resumed.activeProfileID == nil)
        #expect(resumed.profiles.allSatisfy { !$0.hasPlanPermission })
        await #expect(throws: OpenAIConnectionError.storage) { try await h.connection.signIn() }
        h.store.failWrites = false
        try await h.connection.deleteAllLocalCredentials()
        #expect(h.store.data == nil)
        #expect(h.store.blocked.isEmpty)
    }

    @Test func completeDeletionDuringRefreshCannotRestoreAccountsOrTokens() async throws {
        let h = try AuthHarness(); h.expires = 30
        try await h.connection.signIn()
        h.transport.rejectCancelledRequests = true
        let gate = AuthRefreshGate()
        h.refreshHandler = { await gate.suspend() }
        let request = Task { try await h.connection.authorizedAccessToken() }
        await gate.waitUntilEntered()
        try await h.connection.deleteAllLocalCredentials()
        gate.resolve(try h.tokenResponse(access: "deleted-access", refresh: "deleted-refresh"))
        await #expect(throws: OpenAIConnectionError.cancelled) { try await request.value }
        #expect(h.connection.profiles.isEmpty)
        #expect(h.store.data == nil)
        let resumed = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now })
        #expect(resumed.profiles.isEmpty)
        await #expect(throws: OpenAIConnectionError.signInRequired) { try await resumed.authorizedAccessToken() }
        #expect(h.transport.requests.contains { $0.url?.path == "/api/accounts/oauth/revoke" && h.form($0)["token"] == "deleted-refresh" })
        #expect(h.transport.cancelledRequestCount == 0)
    }
    @Test func invalidationCancelsOnlyRequestsFromPreviousGeneration() async throws {
        let h = try AuthHarness(); try await h.connection.signIn()
        let (events, continuation) = AsyncStream<UUID>.makeStream()
        let registry = OpenAIRequestRegistry.shared
        let first = h.connection.sessionGeneration
        let firstRequest = registry.register(generation: first, scope: .tasks, additionalScopes: []) { continuation.yield(first) }
        let unrelated = UUID()
        let unrelatedRequest = registry.register(generation: unrelated, scope: .tasks, additionalScopes: []) { continuation.yield(unrelated) }
        h.issuedID = "oaiapp_second"; h.subject = "person-b"
        try await h.connection.signIn(newAccount: true)
        let second = h.connection.sessionGeneration
        let secondRequest = registry.register(generation: second, scope: .tasks, additionalScopes: []) { continuation.yield(second) }
        try h.connection.selectProfile("oaiapp_first")
        let third = h.connection.sessionGeneration
        let thirdRequest = registry.register(generation: third, scope: .tasks, additionalScopes: []) { continuation.yield(third) }
        await h.connection.signOut()
        try h.connection.selectProfile("oaiapp_second")
        let fourth = h.connection.sessionGeneration
        let fourthRequest = registry.register(generation: fourth, scope: .tasks, additionalScopes: []) { continuation.yield(fourth) }
        try await h.connection.deleteAllLocalCredentials()
        continuation.finish()
        let received = await events.reduce(into: [UUID]()) { $0.append($1) }
        #expect(Set(received) == [first, second, third, fourth])
        #expect(received.count == 4)
        for id in [firstRequest, unrelatedRequest, secondRequest, thirdRequest, fourthRequest] { registry.remove(id) }
    }

    @Test func cancelledDeletionCallerStillRevokesEverySavedSession() async throws {
        let h = try AuthHarness(); try await h.connection.signIn()
        h.issuedID = "oaiapp_second"; h.subject = "person-b"
        try await h.connection.signIn(newAccount: true)
        h.transport.rejectCancelledRequests = true
        let entered = AuthRefreshGate()
        let deletion = Task {
            _ = await entered.suspend()
            try await h.connection.deleteAllLocalCredentials()
        }
        await entered.waitUntilEntered()
        deletion.cancel()
        entered.resolve(Data())
        try await deletion.value
        let revoked = h.transport.requests.filter { $0.url?.path == "/api/accounts/oauth/revoke" }
            .compactMap { h.form($0)["client_id"] }
        #expect(Set(revoked) == ["oaiapp_first", "oaiapp_second"])
        #expect(h.transport.cancelledRequestCount == 0)
        #expect(h.store.data == nil)
        #expect(h.connection.profiles.isEmpty)
    }
    @Test func cancelledSignoutCallerStillConfirmsRenewableSessionRevocation() async throws {
        let h = try AuthHarness(); try await h.connection.signIn()
        h.transport.rejectCancelledRequests = true
        let entered = AuthRefreshGate()
        let signout = Task {
            _ = await entered.suspend()
            await h.connection.signOut()
        }
        await entered.waitUntilEntered()
        signout.cancel()
        entered.resolve(Data())
        await signout.value
        #expect(h.transport.requests.contains { $0.url?.path == "/api/accounts/oauth/revoke" })
        #expect(h.transport.cancelledRequestCount == 0)
        #expect(h.connection.activeProfileID == nil)
        #expect(h.connection.statusMessage == nil)
    }

    @Test func cancelledCodeExchangeStillRevokesUncommittedRenewableSession() async throws {
        let h = try AuthHarness()
        h.transport.rejectCancelledRequests = true
        let gate = AuthRefreshGate()
        let original = h.transport.handler!
        h.transport.handler = { request in
            if request.url?.path == "/api/accounts/oauth/token" { return await gate.suspend() }
            return try await original(request)
        }
        let signIn = Task { try await h.connection.signIn() }
        await gate.waitUntilEntered()
        signIn.cancel()
        gate.resolve(try h.tokenResponse(refresh: "uncommitted-refresh"))
        await #expect(throws: OpenAIConnectionError.cancelled) { try await signIn.value }
        #expect(h.transport.requests.contains { $0.url?.path == "/api/accounts/oauth/revoke" && h.form($0)["token"] == "uncommitted-refresh" })
        #expect(h.transport.cancelledRequestCount == 0)
        #expect(h.connection.activeProfileID == nil)
        #expect(h.connection.profiles.isEmpty)
    }
    @Test func accountCycleCannotStartSecondExchangeAgainstAbandonedRefreshGrant() async throws {
        let h = try AuthHarness(); h.expires = 30
        try await h.connection.signIn()
        h.issuedID = "oaiapp_second"; h.subject = "person-b"; h.expires = 3600
        try await h.connection.signIn(newAccount: true)
        try h.connection.selectProfile("oaiapp_first")
        h.transport.rejectCancelledRequests = true
        let gate = AuthRefreshGate()
        h.refreshHandler = { await gate.suspend() }
        let first = Task { try await h.connection.authorizedAccessToken() }
        await gate.waitUntilEntered()
        try h.connection.selectProfile("oaiapp_second")
        try h.connection.selectProfile("oaiapp_first")
        let secondEntered = AuthRefreshGate()
        let second = Task {
            secondEntered.signal()
            return try await h.connection.authorizedAccessToken()
        }
        await secondEntered.waitUntilEntered()
        #expect(h.transport.requests.filter { h.form($0)["grant_type"] == "refresh_token" }.count == 1)
        gate.resolve(try h.tokenResponse(access: "abandoned-access", refresh: "abandoned-refresh"))
        await #expect(throws: OpenAIConnectionError.cancelled) { try await first.value }
        await #expect(throws: OpenAIConnectionError.cancelled) { try await second.value }
        #expect(h.transport.requests.filter { h.form($0)["grant_type"] == "refresh_token" }.count == 1)
        #expect(h.store.blocked.contains("oaiapp_first"))
        #expect(h.connection.profiles.first { $0.id == "oaiapp_first" }?.hasPlanPermission == false)
        await #expect(throws: OpenAIConnectionError.signInRequired) { try await h.connection.authorizedAccessToken() }
        try h.connection.selectProfile("oaiapp_second")
        #expect(try await h.connection.authorizedAccessToken() == "test-access")
        #expect(h.transport.cancelledRequestCount == 0)
    }

    @Test func abandonedRefreshCannotQuarantineNewlyReauthorizedCredentials() async throws {
        let h = try AuthHarness(); h.expires = 30
        try await h.connection.signIn()
        let gate = AuthRefreshGate()
        h.refreshHandler = { await gate.suspend() }
        let old = Task { try await h.connection.authorizedAccessToken() }
        await gate.waitUntilEntered()
        h.expires = 3600
        try await h.connection.signIn()
        let current = h.connection.sessionGeneration
        gate.resolve(try h.tokenResponse(access: "old-access", refresh: "old-refresh"))
        await #expect(throws: OpenAIConnectionError.cancelled) { try await old.value }
        #expect(h.connection.sessionGeneration == current)
        #expect(h.connection.activeProfileID == "oaiapp_first")
        #expect(!h.store.blocked.contains("oaiapp_first"))
        #expect(try await h.connection.authorizedAccessToken() == "test-access")
    }
}
