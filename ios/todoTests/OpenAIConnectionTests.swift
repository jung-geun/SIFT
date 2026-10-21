import Foundation
import CryptoKit
import Security
import Testing
@testable import todo

@MainActor private final class AuthMemoryStore: OpenAICredentialStore {
    var synchronizationEnabled = false
    var data: Data?
    var blocked: Set<String> = []
    var quarantined: [String: Set<String>] = [:]
    var failWrites = false
    func load() throws -> Data? { data }
    func save(_ data: Data) throws {
        if failWrites { throw OpenAIConnectionError.storage }
        self.data = data
    }
    func deleteAll() throws {
        if failWrites { throw OpenAIConnectionError.storage }
        data = nil
    }
    func blockedClientIDs() -> Set<String> { blocked }
    func block(_ clientID: String) { blocked.insert(clientID) }
    func unblock(_ clientID: String) throws { blocked.remove(clientID); quarantined.removeValue(forKey: clientID) }
    func quarantinedCredentialIDs() -> [String: Set<String>] { quarantined }
    func quarantine(clientID: String, credentialID: String) { quarantined[clientID, default: []].insert(credentialID) }
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
    var cancelled = false
    func start(url: URL, onCancel: @escaping @MainActor () -> Void) -> Bool {
        cancellation = onCancel
        return onStart?(url) ?? false
    }
    func cancel() { cancelled = true }
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
    var regionAllowed = true
    var listenerCreations = 0
    var browserCreations = 0

    init(credentialStore: (any OpenAICredentialStore)? = nil) throws {
        signer = try AuthSigner()
        connection = OpenAIConnection(store: credentialStore ?? store, transport: transport, now: { [now] in now },
                                      sleep: { _ in }, makeListener: { [unowned self] in
            self.listenerCreations += 1
            self.listener = AuthTestListener(); return self.listener
        }, makeBrowser: { [unowned self] in
            self.browserCreations += 1
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
        }, regionAllowed: { [unowned self] in self.regionAllowed })
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
    @Test("restricted storefront prevents OAuth setup, listener, browser, and all network")
    func restrictedRegionBlocksOAuthEntry() async throws {
        let h = try AuthHarness(); h.regionAllowed = false
        await #expect(throws: OpenAIConnectionError.unavailable) { try await h.connection.signIn() }
        await #expect(throws: OpenAIConnectionError.unavailable) { try await h.connection.signIn(newAccount: true) }
        await #expect(throws: OpenAIConnectionError.unavailable) { try await h.connection.enablePlanPermission() }
        #expect(h.listenerCreations == 0)
        #expect(h.browserCreations == 0)
        #expect(!h.listener.started)
        #expect(h.browser.cancellation == nil)
        #expect(h.transport.requests.isEmpty)
        #expect(!h.connection.isSigningIn)
        #expect(h.connection.profiles.isEmpty)
    }

    @Test("restriction during OAuth discovery prevents starting the listener or browser")
    func restrictionDuringDiscoveryStopsOAuth() async throws {
        let h = try AuthHarness()
        let handler = try #require(h.transport.handler)
        h.transport.handler = { request in
            let response = try await handler(request)
            h.regionAllowed = false
            return response
        }
        await #expect(throws: OpenAIConnectionError.unavailable) { try await h.connection.signIn() }
        #expect(h.transport.requests.map { $0.url!.path } == ["/.well-known/openid-configuration"])
        #expect(!h.listener.started)
        #expect(h.browser.cancellation == nil)
        #expect(!h.connection.isSigningIn)
        #expect(h.connection.profiles.isEmpty)
    }

    @Test("regional suspension closes an active OAuth listener and browser without exchanging a code")
    func regionalSuspensionStopsPendingOAuth() async throws {
        let h = try AuthHarness(); h.suspendBrowser = true
        let started = AuthRefreshGate()
        h.browserStarted = { started.signal() }
        let signIn = Task { try await h.connection.signIn() }
        await started.waitUntilEntered()
        let generation = h.connection.sessionGeneration
        h.regionAllowed = false
        h.connection.suspendForRegionalRestriction()
        await #expect(throws: OpenAIConnectionError.cancelled) { try await signIn.value }
        #expect(h.listener.stopped)
        #expect(h.browser.cancelled)
        #expect(!h.connection.isSigningIn)
        #expect(h.connection.sessionGeneration != generation)
        #expect(h.connection.profiles.isEmpty)
        #expect(h.transport.requests.map { $0.url!.path } == ["/.well-known/openid-configuration"])
        await #expect(throws: OpenAIConnectionError.unavailable) { try await h.connection.signIn() }
        #expect(h.browserCreations == 1)
        #expect(h.transport.requests.count == 1)
    }

    @Test("a blocked token lookup never refreshes or quarantines healthy credentials and recovers outside China",
          arguments: [30.0, 3600.0])
    func regionalRestrictionPreservesUndispatchedCredentials(expires: Double) async throws {
        let h = try AuthHarness(); h.expires = expires
        try await h.connection.signIn()
        let saved = try #require(h.store.data)
        let activeID = h.connection.activeProfileID
        let requestCount = h.transport.requests.count
        h.regionAllowed = false
        h.connection.suspendForRegionalRestriction()
        await #expect(throws: OpenAIConnectionError.unavailable) { try await h.connection.authorizedAccessToken() }
        #expect(h.transport.requests.count == requestCount)
        #expect(h.store.data == saved)
        #expect(h.store.blocked.isEmpty)
        #expect(h.store.quarantined.isEmpty)
        #expect(h.connection.activeProfileID == activeID)
        h.regionAllowed = true
        h.expires = 3600
        #expect(try await h.connection.authorizedAccessToken() == "test-access")
        #expect(h.transport.requests.filter { h.form($0)["grant_type"] == "refresh_token" }.count == (expires <= 60 ? 1 : 0))
        #expect(h.store.blocked.isEmpty)
        #expect(h.store.quarantined.isEmpty)
    }

    @Test("restriction during refresh discovery preserves the unconsumed credential and allows later recovery")
    func restrictionDuringRefreshDiscoveryPreservesCredentials() async throws {
        let h = try AuthHarness(); h.expires = 30
        try await h.connection.signIn()
        // A restarted connection has no discovery cache, but keeps the healthy expiring grant.
        h.connection = OpenAIConnection(store: h.store, transport: h.transport, now: { [unowned h] in h.now },
                                        regionAllowed: { [unowned h] in h.regionAllowed })
        let saved = try #require(h.store.data)
        let requestCount = h.transport.requests.count
        let handler = try #require(h.transport.handler)
        h.transport.handler = { request in
            let response = try await handler(request)
            if request.url?.path == "/.well-known/openid-configuration" { h.regionAllowed = false }
            return response
        }
        await #expect(throws: OpenAIConnectionError.unavailable) { try await h.connection.authorizedAccessToken() }
        #expect(h.transport.requests.count == requestCount + 1)
        #expect(!h.transport.requests.contains { h.form($0)["grant_type"] == "refresh_token" })
        #expect(h.store.data == saved)
        #expect(h.store.blocked.isEmpty)
        #expect(h.store.quarantined.isEmpty)
        h.transport.handler = handler
        h.regionAllowed = true
        h.expires = 3600
        #expect(try await h.connection.authorizedAccessToken() == "test-access")
        #expect(h.transport.requests.filter { h.form($0)["grant_type"] == "refresh_token" }.count == 1)
    }

    @Test("local sign-out and deletion do not disclose revocation tokens while the region is restricted",
          arguments: [false, true])
    func restrictedRegionBlocksRevocation(deleteAll: Bool) async throws {
        let h = try AuthHarness()
        try await h.connection.signIn()
        let requestCount = h.transport.requests.count
        h.regionAllowed = false
        if deleteAll { try await h.connection.deleteAllLocalCredentials() }
        else { await h.connection.signOut() }
        #expect(h.connection.activeProfileID == nil)
        if deleteAll { #expect(h.connection.profiles.isEmpty) }
        #expect(h.transport.requests.count == requestCount)
        #expect(!h.transport.requests.contains { $0.url?.path == "/api/accounts/oauth/revoke" })
    }

    @Test("a refresh already in flight cannot publish late credentials or issue cleanup requests after restriction")
    func regionalSuspensionRejectsLateRefreshWithoutNetworkCleanup() async throws {
        let h = try AuthHarness(); h.expires = 30
        try await h.connection.signIn()
        let gate = AuthRefreshGate()
        h.refreshHandler = { await gate.suspend() }
        let request = Task { try await h.connection.authorizedAccessToken() }
        await gate.waitUntilEntered()
        let requestCount = h.transport.requests.count
        h.regionAllowed = false
        h.connection.suspendForRegionalRestriction()
        gate.resolve(try h.tokenResponse(access: "late-access", refresh: "late-refresh"))
        await #expect(throws: OpenAIConnectionError.cancelled) { try await request.value }
        let saved = try JSONDecoder().decode(OpenAIConnection.Snapshot.self, from: #require(h.store.data))
        #expect(saved.registrations.allSatisfy { $0.tokens?.access != "late-access" })
        #expect(h.transport.requests.count == requestCount)
        #expect(!h.transport.requests.contains { $0.url?.path == "/api/accounts/oauth/revoke" })
        await #expect(throws: OpenAIConnectionError.unavailable) { try await h.connection.authorizedAccessToken() }
        #expect(h.transport.requests.count == requestCount)
    }

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
                                       makeBrowser: { h.browser }, regionAllowed: { true })
        try await h.connection.signIn(newAccount: true)
        #expect(h.authorization["client_id"] == "oaiapp_first")
        #expect(h.authorization["agent_name_hint"] == nil)
        #expect(h.authorization["ext_agent_host_id"] == host)
        let resumed = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now }, regionAllowed: { true })
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
        let resumed = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now }, regionAllowed: { true })
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
    func resolve(_ data: Data, status: Int = 200) { response?.resume(returning: (data, status)); response = nil }
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
        let resumed = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now }, regionAllowed: { true })
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
        let resumed = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now }, regionAllowed: { true })
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

    @Test("tokenless saved accounts reuse their registration without replacing the active account until success",
          arguments: ["cancel", "exchangeFailure", "invalidIdentity", "success"])
    func savedAccountReauthorizationPreservesActiveAccount(outcome: String) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let consentKeys = [SettingsStore.betaOpenAIEnabledKey]
                + OpenAIDataScope.allCases.map { OpenAIPrivacy.consentKey(for: $0) }
            let previous = consentKeys.map { defaults.object(forKey: $0) }
            let selectedProvider = defaults.string(forKey: SettingsStore.betaSelectedProviderKey)
            defer {
                for (key, value) in zip(consentKeys, previous) {
                    if let value { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }
            for key in consentKeys { defaults.set(false, forKey: key) }

            let h = try AuthHarness()
            try await h.connection.signIn()
            h.issuedID = "oaiapp_second"; h.subject = "person-b"
            try await h.connection.signIn(newAccount: true)
            await h.connection.signOut()
            try h.connection.selectProfile("oaiapp_first")
            let generation = h.connection.sessionGeneration
            let requestCount = h.transport.requests.count

            // This is the settings saved-account action's returning-sign-in path:
            // selection remembers tokenless B, throws, and leaves authenticated A usable.
            #expect(throws: OpenAIConnectionError.signInRequired) {
                try h.connection.selectProfile("oaiapp_second")
            }
            #expect(h.connection.activeProfileID == "oaiapp_first")
            #expect(h.connection.hasPlanPermission)
            #expect(h.connection.sessionGeneration == generation)
            #expect(try await h.connection.authorizedAccessToken() == "test-access")
            #expect(h.connection.profiles.first { $0.id == "oaiapp_second" }?.hasPlanPermission == false)

            switch outcome {
            case "cancel":
                let launched = AuthRefreshGate()
                h.suspendBrowser = true
                h.browserStarted = { launched.signal() }
                let signIn = Task { try await h.connection.signIn(newAccount: false) }
                await launched.waitUntilEntered()
                #expect(h.connection.isSigningIn)
                #expect(h.connection.activeProfileID == "oaiapp_first")
                #expect(h.connection.hasPlanPermission)
                #expect(try await h.connection.authorizedAccessToken() == "test-access")
                h.browser.cancellation?()
                await #expect(throws: OpenAIConnectionError.cancelled) { try await signIn.value }
            case "exchangeFailure":
                h.tokenError = "invalid_grant"
                await #expect(throws: OpenAIConnectionError.exchangeFailed) {
                    try await h.connection.signIn(newAccount: false)
                }
            case "invalidIdentity":
                h.subject = "intruder"
                await #expect(throws: OpenAIConnectionError.invalidIdentity) {
                    try await h.connection.signIn(newAccount: false)
                }
            default:
                try await h.connection.signIn(newAccount: false)
            }

            #expect(!h.connection.isSigningIn)
            #expect(h.connection.profiles.count == 2)
            #expect(Set(h.connection.profiles.map(\.id)) == ["oaiapp_first", "oaiapp_second"])
            #expect(h.connection.profiles.first { $0.id == "oaiapp_second" }?.subject == "person-b")
            #expect(h.authorizations.count == 3)
            #expect(h.authorization["client_id"] == "oaiapp_second")
            #expect(h.authorization["agent_name_hint"] == nil)
            #expect(h.authorization["id_token_hint"] == nil)
            #expect(h.authorization["login_hint"] == "same@example.com")
            #expect(h.authorization["prompt"] == nil)
            #expect(h.authorization["ext_agent_host_id"] == h.authorizations.first?["ext_agent_host_id"])
            let attemptRequests = h.transport.requests.dropFirst(requestCount)
            let exchanges = attemptRequests.filter { $0.url?.path == "/api/accounts/oauth/token" }
            #expect(exchanges.count == (outcome == "cancel" ? 0 : 1))
            #expect(exchanges.allSatisfy { h.form($0)["client_id"] == "oaiapp_second" })
            #expect(!attemptRequests.contains {
                $0.url?.path == "/api/accounts/oauth/revoke" && h.form($0)["client_id"] == "oaiapp_first"
            })

            let succeeded = outcome == "success"
            let expectedActiveID = succeeded ? "oaiapp_second" : "oaiapp_first"
            #expect(h.connection.activeProfileID == expectedActiveID)
            #expect(h.connection.hasPlanPermission)
            #expect((h.connection.sessionGeneration != generation) == succeeded)
            #expect(h.store.blocked.contains("oaiapp_second") == !succeeded)
            #expect(h.connection.profiles.first { $0.id == "oaiapp_second" }?.hasPlanPermission == succeeded)
            let resumed = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now }, regionAllowed: { true })
            #expect(resumed.activeProfileID == expectedActiveID)
            #expect(try await resumed.authorizedAccessToken() == "test-access")
            // Even after B succeeds, A's saved credentials remain valid and selectable.
            try resumed.selectProfile("oaiapp_first")
            #expect(resumed.activeProfile?.subject == "person-a")
            #expect(resumed.hasPlanPermission)
            #expect(try await resumed.authorizedAccessToken() == "test-access")
            #expect(!h.store.blocked.contains("oaiapp_first"))
            #expect(consentKeys.allSatisfy { !defaults.bool(forKey: $0) })
            #expect(defaults.string(forKey: SettingsStore.betaSelectedProviderKey) == selectedProvider)
        }
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
    @Test func completeDeletionErasesMappingsAndHostButRetainsLocalTombstones() async throws {
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
        #expect(h.store.blocked == ["oaiapp_first", "oaiapp_second"])
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
        let resumed = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now }, regionAllowed: { true })
        #expect(resumed.activeProfileID == nil)
        #expect(resumed.profiles.allSatisfy { !$0.hasPlanPermission })
        await #expect(throws: OpenAIConnectionError.storage) { try await h.connection.signIn() }
        h.store.failWrites = false
        try await h.connection.deleteAllLocalCredentials()
        #expect(h.store.data == nil)
        #expect(h.store.blocked == ["oaiapp_first", "oaiapp_second"])
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
        let resumed = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now }, regionAllowed: { true })
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

/// Two installations share only the portable Keychain service, never a device record or defaults suite.
@MainActor private final class AuthKeychainFixture {
    let namespace = "pieroot.todo.tests.openai.\(UUID().uuidString)"
    let firstDefaults: UserDefaults
    let secondDefaults: UserDefaults
    let firstSuite: String
    let secondSuite: String
    let previousSyncPreference: Any?
    let previousConsentVersion: Any?
    var firstService: String { namespace + ".first" }
    var secondService: String { namespace + ".second" }
    var portableService: String { namespace + ".portable" }

    init(sync: Bool) throws {
        firstSuite = namespace + ".first.defaults"
        secondSuite = namespace + ".second.defaults"
        firstDefaults = try #require(UserDefaults(suiteName: firstSuite))
        secondDefaults = try #require(UserDefaults(suiteName: secondSuite))
        previousSyncPreference = UserDefaults.standard.object(forKey: "pieroot.todo.iCloudSyncEnabled")
        previousConsentVersion = UserDefaults.standard.object(forKey: UserCloudSyncPolicy.consentKey)
        setSync(sync)
    }
    func setSync(_ enabled: Bool) {
        UserDefaults.standard.set(UserCloudSyncPolicy.consentVersion, forKey: UserCloudSyncPolicy.consentKey)
        UserDefaults.standard.set(enabled, forKey: UserCloudSyncPolicy.syncKey)
    }
    func store(second: Bool = false) -> OpenAIKeychainCredentialStore {
        OpenAIKeychainCredentialStore(deviceService: second ? secondService : firstService,
                                     portableService: portableService, defaults: second ? secondDefaults : firstDefaults)
    }
    func local(second: Bool = false) throws -> OpenAIConnection.Snapshot? {
        try KeychainStore.getDeviceOnly(service: second ? secondService : firstService, account: "connections.v1")
            .map { try JSONDecoder().decode(OpenAIConnection.Snapshot.self, from: $0) }
    }
    func portable() throws -> String? {
        try KeychainStore.getSynchronizable(service: portableService, account: "connections.v1")
            .map { String(decoding: $0, as: UTF8.self) }
    }
    func deliver(_ value: String) throws {
        try KeychainStore.setSynchronizable(service: portableService, account: "connections.v1", data: Data(value.utf8))
    }
    func cleanup() {
        KeychainStore.setWriteFailureForTesting(service: firstService, status: nil)
        KeychainStore.setWriteFailureForTesting(service: portableService, status: nil)
        try? KeychainStore.deleteDeviceOnly(service: firstService, account: "connections.v1")
        try? KeychainStore.deleteDeviceOnly(service: secondService, account: "connections.v1")
        try? KeychainStore.deleteSynchronizable(service: portableService, account: "connections.v1")
        firstDefaults.removePersistentDomain(forName: firstSuite)
        secondDefaults.removePersistentDomain(forName: secondSuite)
        if let previousSyncPreference {
            UserDefaults.standard.set(previousSyncPreference, forKey: "pieroot.todo.iCloudSyncEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "pieroot.todo.iCloudSyncEnabled")
        }
        if let previousConsentVersion { UserDefaults.standard.set(previousConsentVersion, forKey: UserCloudSyncPolicy.consentKey) }
        else { UserDefaults.standard.removeObject(forKey: UserCloudSyncPolicy.consentKey) }
    }
}

extension OpenAIConnectionTests {
    @Test("A receiver's off-state account choice does not freeze a newer refresh-owner rotation")
    func pendingAccountChoiceAdoptsOwnerRotation() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard SettingsStore.supportsICloud else { return }
            let fixture = try AuthKeychainFixture(sync: true)
            defer { fixture.cleanup() }
            let owner = try AuthHarness(credentialStore: fixture.store())
            owner.expires = 30
            try await owner.connection.signIn()
            owner.issuedID = "oaiapp_second"
            owner.subject = "person-b"
            owner.expires = 3600
            try await owner.connection.signIn(newAccount: true)
            try owner.connection.selectProfile("oaiapp_first")
            let original = try #require(try fixture.local())
            let firstGrant = try #require(original.registrations.first { $0.clientID == "oaiapp_first" }?.tokens)
            let receiver = try AuthHarness(credentialStore: fixture.store(second: true))
            let receiverHost = try #require(try fixture.local(second: true)?.hostID)
            fixture.setSync(false)
            try receiver.connection.selectProfile("oaiapp_second")
            #expect(receiver.connection.activeProfileID == "oaiapp_second")
            #expect(receiver.connection.synchronizationIssue == .synchronizationPending)
            fixture.setSync(true)
            owner.refreshHandler = {
                (Data(#"{"access_token":"owner-R2-access","refresh_token":"owner-R2-refresh","token_type":"Bearer","expires_in":3600}"#.utf8), 200)
            }
            #expect(try await owner.connection.authorizedAccessToken() == "owner-R2-access")
            // Recreate the recipient while its durable selection intent is dirty.
            let resumed = try AuthHarness(credentialStore: fixture.store(second: true))
            let restored = try #require(try fixture.local(second: true))
            let replacement = try #require(restored.registrations.first { $0.clientID == "oaiapp_first" }?.tokens)
            #expect(replacement.access == "owner-R2-access" && replacement.refresh == "owner-R2-refresh")
            #expect(replacement.nonce == firstGrant.nonce && replacement.refreshOwnerID == firstGrant.refreshOwnerID)
            #expect(replacement.rotation == 1)
            #expect(restored.hostID == receiverHost && restored.hostID != original.hostID)
            #expect(restored.selectedID == "oaiapp_second" && restored.activeID == "oaiapp_second")
            let shared = try JSONDecoder().decode(OpenAIConnection.PortableSnapshot.self,
                from: Data(#require(try fixture.portable()).utf8))
            #expect(shared.selectedID == "oaiapp_second" && shared.activeID == "oaiapp_second")
            #expect(resumed.connection.synchronizationIssue == nil)
            try resumed.connection.selectProfile("oaiapp_first")
            #expect(try await resumed.connection.authorizedAccessToken() == "owner-R2-access")
            #expect(resumed.authorizations.isEmpty && resumed.transport.requests.isEmpty)
        }
    }

    @Test("a fresh local login survives expired publication and restart without importing an older or conflicting grant",
          arguments: [false, true], ["disable", "newEpoch"])
    func deferredReauthorizationSurvivesRestart(remoteChanged: Bool, expiry: String) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard SettingsStore.supportsICloud else { return }
            let fixture = try AuthKeychainFixture(sync: true)
            defer { fixture.cleanup() }
            let store = fixture.store()
            let first = try AuthHarness(credentialStore: store)
            try await first.connection.signIn()
            let original = try #require(try fixture.local())
            let oldNonce = try #require(original.registrations.first?.tokens?.nonce)
            var expiredAfterLocalCommit = false
            store.afterPortableReadForTesting = {
                guard !expiredAfterLocalCommit,
                      let current = try? fixture.local(),
                      let tokens = current.registrations.first?.tokens,
                      tokens.nonce != oldNonce else { return }
                expiredAfterLocalCommit = true
                fixture.setSync(false)
                if expiry == "newEpoch" {
                    UserCloudSyncPolicy.revokeAccountAuthorization()
                    fixture.setSync(true)
                }
            }
            // Real synthetic OAuth validation commits a NEW nonce, not merely a
            // higher rotation ordinal that the pre-existing merge already protects.
            try await first.connection.signIn()
            #expect(expiredAfterLocalCommit)
            let fresh = try #require(try fixture.local())
            #expect(fresh.registrations.first?.tokens?.nonce != oldNonce)
            #expect(first.connection.activeProfileID == original.activeID)
            #expect(first.connection.hasPlanPermission)
            #expect(first.connection.synchronizationIssue == .synchronizationPending)
            let retainedValue = try #require(try fixture.portable())
            let retained = try JSONDecoder().decode(OpenAIConnection.PortableSnapshot.self, from: Data(retainedValue.utf8))
            #expect(retained.registrations == original.registrations)
            #expect(retained.activeID == original.activeID && retained.selectedID == original.selectedID)
            store.afterPortableReadForTesting = nil

            if remoteChanged {
                var remote = original
                let previous = try #require(remote.registrations[0].tokens)
                remote.registrations[0].tokens = OpenAIConnection.Tokens(
                    access: "another-device-access", refresh: "another-device-refresh",
                    identity: previous.identity, nonce: "another-device-new-authorization",
                    scopes: previous.scopes, expiresAt: previous.expiresAt,
                    refreshOwnerID: "another-device-owner", rotation: 0
                )
                try fixture.deliver(String(decoding: JSONEncoder().encode(OpenAIConnection.PortableSnapshot(remote)), as: UTF8.self))
            }
            let beforeRestart = try fixture.portable()
            fixture.setSync(true)
            let restoredStore = fixture.store()
            let restored = try AuthHarness(credentialStore: restoredStore)
            #expect(try fixture.local() == fresh)
            #expect(restored.connection.activeProfileID == fresh.activeID)
            #expect(restored.connection.hasPlanPermission)
            #expect(try await restored.connection.authorizedAccessToken() == "test-access")
            #expect(restored.authorizations.isEmpty)
            #expect(restored.transport.requests.isEmpty)
            if remoteChanged {
                #expect(try fixture.portable() == beforeRestart)
                #expect(restoredStore.synchronizationIssue == .synchronizationConflict)
                // Recreating both the store and connection cannot erase the conflict or either grant.
                let restartedAgain = try AuthHarness(credentialStore: fixture.store())
                #expect(restartedAgain.connection.activeProfileID == fresh.activeID)
                #expect(restartedAgain.connection.synchronizationIssue == .synchronizationConflict)
                #expect(try fixture.local() == fresh)
                #expect(try fixture.portable() == beforeRestart)
            } else {
                let published = try JSONDecoder().decode(OpenAIConnection.PortableSnapshot.self,
                    from: Data(#require(try fixture.portable()).utf8))
                #expect(published.registrations == fresh.registrations)
                #expect(restoredStore.synchronizationIssue == nil)
                #expect(restored.connection.statusMessage == nil)
            }
            // Publication intents/receipts contain only hashes and flags, never credentials.
            for value in fixture.firstDefaults.dictionaryRepresentation().values {
                if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
                    #expect(!text.contains("test-access"))
                    #expect(!text.contains("test-refresh"))
                    #expect(!text.contains(oldNonce))
                }
            }
        }
    }

    @Test("portable reads cannot import or publish after their captured account authorization expires",
          arguments: ["save", "migration", "import", "reauthorization"], ["disable", "newEpoch"])
    func portableOperationKeepsItsOriginalAuthorization(operation: String, expiry: String) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard SettingsStore.supportsICloud else { return }
            let fixture = try AuthKeychainFixture(sync: false)
            defer { fixture.cleanup() }
            let store = fixture.store()
            let first = try AuthHarness(credentialStore: store)
            try await first.connection.signIn()
            let original = try #require(try fixture.local())
            fixture.setSync(true)
            if operation != "migration" { _ = try store.load() }
            let shared = try fixture.portable()
            let target = operation == "import" ? fixture.store(second: true) : store
            target.afterPortableReadForTesting = {
                fixture.setSync(false)
                if expiry == "newEpoch" {
                    // Returning to the same enabled state must not revive the
                    // pass that captured the previous account authorization.
                    UserCloudSyncPolicy.revokeAccountAuthorization()
                    fixture.setSync(true)
                }
            }

            switch operation {
            case "save":
                var updated = original
                let previous = try #require(updated.registrations[0].tokens)
                updated.registrations[0].tokens = OpenAIConnection.Tokens(
                    access: "locally-committed-access", refresh: "locally-committed-refresh",
                    identity: previous.identity, nonce: previous.nonce, scopes: previous.scopes,
                    expiresAt: previous.expiresAt, refreshOwnerID: previous.refreshOwnerID,
                    rotation: previous.rotation
                )
                try target.save(JSONEncoder().encode(updated))
                #expect(try fixture.local() == updated)
            case "import":
                #expect(try target.load() == nil)
                #expect(try fixture.local(second: true) == nil)
            case "reauthorization":
                let clientID = try #require(original.activeID)
                target.block(clientID)
                target.quarantine(clientID: clientID, credentialID: "old-failed-credential")
                try target.unblock(clientID)
                #expect(!target.blockedClientIDs().contains(clientID))
                #expect(target.quarantinedCredentialIDs()[clientID] == nil)
                #expect(try fixture.local() == original)
            default:
                let restored = try #require(try target.load())
                #expect(try JSONDecoder().decode(OpenAIConnection.Snapshot.self, from: restored) == original)
                #expect(try fixture.local() == original)
            }
            #expect(target.synchronizationEnabled == (expiry == "newEpoch"))
            #expect(try fixture.portable() == shared)
        }
    }

    @Test func optInMigratesLegacyLoginAndRestoresWithoutCopyingHostOrGrantingConsent() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard SettingsStore.supportsICloud else { return }
            let fixture = try AuthKeychainFixture(sync: false)
            defer { fixture.cleanup() }
            let defaults = UserDefaults.standard
            let consentKeys = [SettingsStore.betaOpenAIEnabledKey]
                + OpenAIDataScope.allCases.map { OpenAIPrivacy.consentKey(for: $0) }
            let saved = consentKeys.map { defaults.object(forKey: $0) }
            let provider = defaults.object(forKey: SettingsStore.betaSelectedProviderKey)
            defer {
                for (key, value) in zip(consentKeys, saved) {
                    if let value { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }
            for key in consentKeys { defaults.set(false, forKey: key) }

            let first = try AuthHarness(credentialStore: fixture.store())
            try await first.connection.signIn()
            let original = try #require(try fixture.local())
            #expect(try fixture.portable() == nil)
            // This is the existing device-only v1 record; no browser flow is run during migration.
            fixture.setSync(true)
            first.connection.refreshCredentials()
            #expect(first.authorizations.count == 1)
            let portable = try #require(try fixture.portable())
            let object = try #require(try JSONSerialization.jsonObject(with: Data(portable.utf8)) as? [String: Any])
            #expect(object["hostID"] == nil)
            #expect(!portable.contains(original.hostID))
            #expect(try fixture.local()?.hostID == original.hostID)

            let second = try AuthHarness(credentialStore: fixture.store(second: true))
            #expect(second.connection.activeProfile?.clientID == "oaiapp_first")
            #expect(try await second.connection.authorizedAccessToken() == "test-access")
            #expect(second.authorizations.isEmpty)
            #expect(second.transport.requests.isEmpty)
            let restored = try #require(try fixture.local(second: true))
            #expect(restored.hostID != original.hostID)
            #expect(restored.registrations == original.registrations)
            // A later returning authorization uses the shared registration but this installation's own host.
            try await second.connection.signIn()
            #expect(second.authorization["client_id"] == "oaiapp_first")
            #expect(second.authorization["ext_agent_host_id"] == restored.hostID)
            #expect(try fixture.local()?.hostID == original.hostID)
            #expect(consentKeys.allSatisfy { !defaults.bool(forKey: $0) })
            #expect(defaults.object(forKey: SettingsStore.betaSelectedProviderKey) as? String == provider as? String)
            #expect(fixture.firstDefaults.dictionaryRepresentation().values.allSatisfy { !String(describing: $0).contains("test-access") })
            #expect(fixture.secondDefaults.dictionaryRepresentation().values.allSatisfy { !String(describing: $0).contains("test-refresh") })
        }
    }

    @Test("late Keychain arrival is reconciled without restart", arguments: ["foreground", "request"])
    func lateDeliveryAdoptsCredentialsAndUnchangedRefreshKeepsGeneration(trigger: String) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard SettingsStore.supportsICloud else { return }
            let fixture = try AuthKeychainFixture(sync: true)
            defer { fixture.cleanup() }
            let receiver = try AuthHarness(credentialStore: fixture.store(second: true))
            #expect(receiver.connection.activeProfileID == nil)
            let generation = receiver.connection.sessionGeneration
            let sender = try AuthHarness(credentialStore: fixture.store())
            try await sender.connection.signIn()
            if trigger == "foreground" { receiver.connection.refreshCredentials() }
            #expect(try await receiver.connection.authorizedAccessToken() == "test-access")
            #expect(receiver.connection.activeProfileID == "oaiapp_first")
            #expect(receiver.connection.sessionGeneration != generation)
            #expect(receiver.authorizations.isEmpty)
            let adopted = receiver.connection.sessionGeneration
            receiver.connection.refreshCredentials()
            receiver.connection.refreshCredentials()
            #expect(receiver.connection.sessionGeneration == adopted)
        }
    }

    @Test func staleAccountListSavePreservesAnotherDevicesNewAccount() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard SettingsStore.supportsICloud else { return }
            let fixture = try AuthKeychainFixture(sync: true)
            defer { fixture.cleanup() }
            let firstStore = fixture.store()
            let first = try AuthHarness(credentialStore: firstStore)
            try await first.connection.signIn()
            let stale = try #require(try fixture.local())
            let second = try AuthHarness(credentialStore: fixture.store(second: true))
            second.issuedID = "oaiapp_second"
            second.subject = "person-b"
            try await second.connection.signIn(newAccount: true)
            try firstStore.save(JSONEncoder().encode(stale))
            let portable = try JSONDecoder().decode(OpenAIConnection.PortableSnapshot.self,
                from: Data(#require(try fixture.portable()).utf8))
            #expect(Set(portable.registrations.map(\.clientID)) == ["oaiapp_first", "oaiapp_second"])
            #expect(portable.registrations.first { $0.clientID == "oaiapp_second" }?.subject == "person-b")
            #expect(portable.registrations.first { $0.clientID == "oaiapp_second" }?.tokens?.access == "test-access")
        }
    }

    @Test func optingOutKeepsLocalAndSharedConnectionsForOtherDevices() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard SettingsStore.supportsICloud else { return }
            let fixture = try AuthKeychainFixture(sync: true)
            defer { fixture.cleanup() }
            let original = try AuthHarness(credentialStore: fixture.store())
            try await original.connection.signIn()
            let shared = try #require(try fixture.portable())
            fixture.setSync(false)
            original.connection.refreshCredentials()
            #expect(try await original.connection.authorizedAccessToken() == "test-access")
            #expect(try fixture.portable() == shared)
            fixture.setSync(true)
            let receiver = try AuthHarness(credentialStore: fixture.store(second: true))
            #expect(try await receiver.connection.authorizedAccessToken() == "test-access")
            #expect(receiver.authorizations.isEmpty)
        }
    }

    @Test func disabledSyncNeitherImportsRemoteLoginNorPublishesLocalLogin() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let fixture = try AuthKeychainFixture(sync: false)
            defer { fixture.cleanup() }
            let local = try AuthHarness(credentialStore: fixture.store())
            try await local.connection.signIn()
            #expect(try fixture.portable() == nil)
            let snapshot = try #require(try fixture.local())
            let cloud = try JSONEncoder().encode(OpenAIConnection.PortableSnapshot(snapshot))
            let incoming = try #require(String(data: cloud, encoding: .utf8))
            try fixture.deliver(incoming)
            let isolated = try AuthHarness(credentialStore: fixture.store(second: true))
            #expect(isolated.connection.profiles.isEmpty)
            await #expect(throws: OpenAIConnectionError.signInRequired) {
                try await isolated.connection.authorizedAccessToken()
            }
            // Local sign-in/refresh must leave even an already-arrived cloud record untouched.
            try await local.connection.signIn()
            #expect(try await local.connection.authorizedAccessToken() == "test-access")
            #expect(try fixture.portable() == incoming)
            #expect(try fixture.local(second: true) == nil)
        }
    }

    @Test func localOnlyBuildIgnoresPersistedCloudOptIn() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard !SettingsStore.supportsICloud else { return }
            let fixture = try AuthKeychainFixture(sync: true)
            defer { fixture.cleanup() }
            let firstStore = fixture.store()
            #expect(!firstStore.synchronizationEnabled)
            let first = try AuthHarness(credentialStore: firstStore)
            try await first.connection.signIn()
            #expect(try fixture.portable() == nil)
            let data = try JSONEncoder().encode(OpenAIConnection.PortableSnapshot(#require(try fixture.local())))
            try fixture.deliver(#require(String(data: data, encoding: .utf8)))
            let second = try AuthHarness(credentialStore: fixture.store(second: true))
            #expect(second.connection.activeProfileID == nil)
            #expect(second.connection.profiles.isEmpty)
        }
    }

    @Test func failedCheckedMigrationPreservesDeviceRecordAndNeverClaimsRestoration() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard SettingsStore.supportsICloud else { return }
            let fixture = try AuthKeychainFixture(sync: false)
            defer { fixture.cleanup() }
            let h = try AuthHarness(credentialStore: fixture.store())
            try await h.connection.signIn()
            let original = try fixture.local()
            KeychainStore.setWriteFailureForTesting(service: fixture.portableService, status: errSecNotAvailable)
            fixture.setSync(true)
            h.connection.refreshCredentials()
            #expect(h.connection.statusMessage == OpenAIConnectionError.synchronizationPending.errorDescription)
            #expect(h.connection.activeProfileID == original?.activeID)
            #expect(h.connection.hasPlanPermission)
            #expect(try fixture.local() == original)
            #expect(try fixture.portable() == nil)
            let receiver = try AuthHarness(credentialStore: fixture.store(second: true))
            #expect(receiver.connection.activeProfileID == nil)
            KeychainStore.setWriteFailureForTesting(service: fixture.portableService, status: nil)
            h.connection.refreshCredentials()
            #expect(try await h.connection.authorizedAccessToken() == "test-access")
            #expect(try fixture.portable() != nil)
        }
    }

    @Test func delayedCloudDeliveryCannotUndoSignoutOrAppDataDeletion() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard SettingsStore.supportsICloud else { return }
            let fixture = try AuthKeychainFixture(sync: true)
            defer { fixture.cleanup() }
            let h = try AuthHarness(credentialStore: fixture.store())
            try await h.connection.signIn()
            let delayed = try #require(try fixture.portable())
            let oldHost = try #require(try fixture.local()).hostID
            await h.connection.signOut()
            try fixture.deliver(delayed)
            h.connection.refreshCredentials()
            #expect(h.connection.activeProfileID == nil)
            #expect(!h.connection.hasPlanPermission)
            let signedOut = try AuthHarness(credentialStore: fixture.store())
            #expect(signedOut.connection.activeProfileID == nil)
            #expect(signedOut.connection.profiles.allSatisfy { !$0.hasPlanPermission })
            // Erasure retains an installation-local import tombstone, including after restart.
            try await h.connection.deleteAllLocalCredentials()
            try fixture.deliver(delayed)
            let deleted = try AuthHarness(credentialStore: fixture.store())
            #expect(deleted.connection.profiles.isEmpty)
            await #expect(throws: OpenAIConnectionError.signInRequired) {
                try await deleted.connection.authorizedAccessToken()
            }
            // Only verified explicit OAuth lifts the deletion/sign-out tombstones.
            try await deleted.connection.signIn()
            #expect(deleted.authorization["client_id"] == "dynamic_agent_client")
            #expect(deleted.authorization["ext_agent_host_id"] != oldHost)
            #expect(try await deleted.connection.authorizedAccessToken() == "test-access")
            #expect(fixture.store().blockedClientIDs().isEmpty)
        }
    }

    @Test func failedSignoutWriteCannotReexportTombstonedCredentialsDuringMigration() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard SettingsStore.supportsICloud else { return }
            let fixture = try AuthKeychainFixture(sync: false)
            defer { fixture.cleanup() }
            let h = try AuthHarness(credentialStore: fixture.store())
            try await h.connection.signIn()
            KeychainStore.setWriteFailureForTesting(service: fixture.firstService, status: errSecNotAvailable)
            await h.connection.signOut()
            KeychainStore.setWriteFailureForTesting(service: fixture.firstService, status: nil)
            fixture.setSync(true)
            h.connection.refreshCredentials()
            let portable = try #require(try fixture.portable())
            #expect(!portable.contains("test-access"))
            #expect(!portable.contains("test-refresh"))
            let receiver = try AuthHarness(credentialStore: fixture.store(second: true))
            #expect(receiver.connection.activeProfileID == nil)
            #expect(receiver.connection.profiles.allSatisfy { !$0.hasPlanPermission })
        }
    }

    @Test func incomingCredentialsCancelStaleRefreshWithoutPublishingItsResult() async throws {
        let h = try AuthHarness(); h.expires = 30
        try await h.connection.signIn()
        let gate = AuthRefreshGate()
        h.refreshHandler = { await gate.suspend() }
        let stale = Task { try await h.connection.authorizedAccessToken() }
        await gate.waitUntilEntered()
        let replacement = try AuthHarness()
        try await replacement.connection.signIn()
        var arrived = try JSONDecoder().decode(OpenAIConnection.Snapshot.self, from: #require(replacement.store.data))
        let local = try JSONDecoder().decode(OpenAIConnection.Snapshot.self, from: #require(h.store.data))
        arrived.hostID = local.hostID
        h.store.data = try JSONEncoder().encode(arrived)
        let oldGeneration = h.connection.sessionGeneration
        h.connection.refreshCredentials()
        let adoptedGeneration = h.connection.sessionGeneration
        #expect(adoptedGeneration != oldGeneration)
        gate.resolve(try h.tokenResponse(access: "stale-access", refresh: "stale-refresh"))
        await #expect(throws: OpenAIConnectionError.cancelled) { try await stale.value }
        #expect(h.connection.sessionGeneration == adoptedGeneration)
        #expect(try await h.connection.authorizedAccessToken() == "test-access")
        #expect(!h.store.blocked.contains("oaiapp_first"))
    }

    @Test func syncPolicyChangeCancelsInFlightRefreshEvenWhenCredentialsAreUnchanged() async throws {
        let h = try AuthHarness(); h.store.synchronizationEnabled = true; h.expires = 30
        try await h.connection.signIn()
        let gate = AuthRefreshGate()
        h.refreshHandler = { await gate.suspend() }
        let stale = Task { try await h.connection.authorizedAccessToken() }
        await gate.waitUntilEntered()
        let oldGeneration = h.connection.sessionGeneration
        h.store.synchronizationEnabled = false
        h.connection.refreshCredentials()
        #expect(h.connection.sessionGeneration != oldGeneration)
        gate.resolve(try h.tokenResponse(access: "disabled-stale-access", refresh: "disabled-stale-refresh"))
        await #expect(throws: OpenAIConnectionError.cancelled) { try await stale.value }
        #expect(!h.connection.hasPlanPermission)
        #expect(h.transport.requests.filter { h.form($0)["grant_type"] == "refresh_token" }.count == 1)
    }
}

extension OpenAIConnectionTests {
    @Test func receiverReauthorizationOwnsItsRefreshWithoutWakingOriginalHost() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard SettingsStore.supportsICloud else { return }
            let fixture = try AuthKeychainFixture(sync: true)
            defer { fixture.cleanup() }
            let original = try AuthHarness(credentialStore: fixture.store())
            try await original.connection.signIn()
            let receiver = try AuthHarness(credentialStore: fixture.store(second: true))
            receiver.expires = 30
            try await receiver.connection.signIn()
            receiver.expires = 3600
            receiver.refreshHandler = { (try receiver.tokenResponse(access: "receiver-owned-access", refresh: "receiver-owned-refresh"), 200) }
            #expect(try await receiver.connection.authorizedAccessToken() == "receiver-owned-access")
            #expect(try await original.connection.authorizedAccessToken() == "receiver-owned-access")
            #expect(receiver.transport.requests.filter { receiver.form($0)["grant_type"] == "refresh_token" }.count == 1)
            #expect(!original.transport.requests.contains { original.form($0)["grant_type"] == "refresh_token" })
            #expect(original.connection.refreshOwnedElsewhere)
        }
    }

    @Test("failed refresh quarantines only its grant across restart", arguments: [false, true])
    func lateReplacementSurvivesTerminalOrAbandonedRefresh(abandoned: Bool) async throws {
        let h = try AuthHarness(); h.expires = 30
        try await h.connection.signIn()
        var replacement = try JSONDecoder().decode(OpenAIConnection.Snapshot.self, from: #require(h.store.data))
        let previous = try #require(replacement.registrations.first?.tokens)
        let gate = AuthRefreshGate()
        h.refreshHandler = {
            if abandoned { return await gate.suspend() }
            return (Data("{\"error\":\"invalid_grant\"}".utf8), 400)
        }
        let request = Task { try await h.connection.authorizedAccessToken() }
        if abandoned {
            await gate.waitUntilEntered()
            h.store.synchronizationEnabled.toggle()
            h.connection.refreshCredentials()
            gate.resolve(Data("{\"error\":\"invalid_grant\"}".utf8), status: 400)
        }
        await #expect(throws: abandoned ? OpenAIConnectionError.cancelled : .signInRequired) { try await request.value }
        let resumed = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now }, regionAllowed: { true })
        await #expect(throws: OpenAIConnectionError.signInRequired) { try await resumed.authorizedAccessToken() }
        #expect(h.transport.requests.filter { h.form($0)["grant_type"] == "refresh_token" }.count == 1)
        replacement.registrations[0].tokens = OpenAIConnection.Tokens(
            access: "late-R2-access", refresh: "late-R2-refresh", identity: previous.identity,
            nonce: previous.nonce, scopes: previous.scopes, expiresAt: h.now.addingTimeInterval(3600),
            refreshOwnerID: previous.refreshOwnerID, rotation: 1)
        h.store.data = try JSONEncoder().encode(replacement)
        #expect(try await resumed.authorizedAccessToken() == "late-R2-access")
        #expect(resumed.activeProfileID == "oaiapp_first")
    }

    @Test func oldCloudRotationCannotRollBackOwnersNewerGrant() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard SettingsStore.supportsICloud else { return }
            let fixture = try AuthKeychainFixture(sync: true)
            defer { fixture.cleanup() }
            let h = try AuthHarness(credentialStore: fixture.store()); h.expires = 30
            try await h.connection.signIn()
            let stale = try #require(try fixture.portable())
            h.expires = 3600
            h.refreshHandler = { (try h.tokenResponse(access: "owner-R2-access", refresh: "owner-R2-refresh"), 200) }
            #expect(try await h.connection.authorizedAccessToken() == "owner-R2-access")
            try fixture.deliver(stale)
            #expect(try await h.connection.authorizedAccessToken() == "owner-R2-access")
            #expect(h.transport.requests.filter { h.form($0)["grant_type"] == "refresh_token" }.count == 1)
            let receiver = try AuthHarness(credentialStore: fixture.store(second: true))
            #expect(try await receiver.connection.authorizedAccessToken() == "owner-R2-access")
            #expect(receiver.transport.requests.isEmpty)
        }
    }

    @Test func delayedRotationAfterReceiverFailureRestoresBothInstallations() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            guard SettingsStore.supportsICloud else { return }
            let fixture = try AuthKeychainFixture(sync: true)
            defer { fixture.cleanup() }
            let first = try AuthHarness(credentialStore: fixture.store())
            first.expires = 30
            try await first.connection.signIn()
            let stale = try #require(try fixture.portable())
            let second = try AuthHarness(credentialStore: fixture.store(second: true))
            first.expires = 3600
            first.refreshHandler = { (try first.tokenResponse(access: "rotated-access", refresh: "rotated-refresh"), 200) }
            #expect(try await first.connection.authorizedAccessToken() == "rotated-access")
            let replacement = try #require(try fixture.portable())
            // B has not received R2 when it tries to use the old, expiring R1.
            try fixture.deliver(stale)
            second.refreshHandler = { (Data("{\"error\":\"invalid_grant\"}".utf8), 400) }
            await #expect(throws: OpenAIConnectionError.refreshOwnerRequired) { try await second.connection.authorizedAccessToken() }
            #expect(second.transport.requests.isEmpty)
            #expect(try fixture.portable() == stale)
            // Delivery deliberately occurs AFTER B's failure, not while its refresh is pending.
            try fixture.deliver(replacement)
            #expect(try await second.connection.authorizedAccessToken() == "rotated-access")
            #expect(try await first.connection.authorizedAccessToken() == "rotated-access")
            #expect(try fixture.local()?.hostID != fixture.local(second: true)?.hostID)
            #expect(second.authorizations.isEmpty)
        }
    }

    @Test("a newly arrived shared rotation survives an older refresh result", arguments: ["success", "invalidGrant"])
    func sharedRotationIsReconciledBeforeOldRefreshCommitsOrInvalidates(result: String) async throws {
        let h = try AuthHarness(); h.expires = 30
        try await h.connection.signIn()
        let gate = AuthRefreshGate()
        h.refreshHandler = { await gate.suspend() }
        let stale = Task { try await h.connection.authorizedAccessToken() }
        await gate.waitUntilEntered()
        var arrived = try JSONDecoder().decode(OpenAIConnection.Snapshot.self, from: #require(h.store.data))
        let previous = try #require(arrived.registrations.first?.tokens)
        arrived.registrations[0].tokens = OpenAIConnection.Tokens(
            access: "shared-access", refresh: "shared-refresh", identity: previous.identity,
            nonce: previous.nonce, scopes: previous.scopes, expiresAt: h.now.addingTimeInterval(3600))
        h.store.data = try JSONEncoder().encode(arrived)
        // No explicit foreground refresh: the old request itself must reconcile before committing/clearing.
        if result == "success" {
            gate.resolve(try h.tokenResponse(access: "older-access", refresh: "older-refresh"))
        } else {
            gate.resolve(Data("{\"error\":\"invalid_grant\"}".utf8), status: 400)
        }
        await #expect(throws: OpenAIConnectionError.cancelled) { try await stale.value }
        #expect(try await h.connection.authorizedAccessToken() == "shared-access")
        #expect(!h.store.blocked.contains("oaiapp_first"))
        let restarted = OpenAIConnection(store: h.store, transport: h.transport, now: { h.now }, regionAllowed: { true })
        #expect(try await restarted.authorizedAccessToken() == "shared-access")
        // Revoking a losing rotation can revoke the newer shared session as well.
        #expect(!h.transport.requests.contains { $0.url?.path == "/api/accounts/oauth/revoke" })
    }

    @Test func incomingLoginCancelsPendingBrowserExchangeBeforeItCanPublish() async throws {
        let h = try AuthHarness()
        let gate = AuthRefreshGate()
        let original = h.transport.handler!
        h.transport.handler = { request in
            if request.url?.path == "/api/accounts/oauth/token" { return await gate.suspend() }
            return try await original(request)
        }
        let stale = Task { try await h.connection.signIn() }
        await gate.waitUntilEntered()
        let replacement = try AuthHarness()
        try await replacement.connection.signIn()
        var arrived = try JSONDecoder().decode(OpenAIConnection.Snapshot.self, from: #require(replacement.store.data))
        let staged = try JSONDecoder().decode(OpenAIConnection.Snapshot.self, from: #require(h.store.data))
        arrived.hostID = staged.hostID
        h.store.data = try JSONEncoder().encode(arrived)
        h.connection.refreshCredentials()
        let generation = h.connection.sessionGeneration
        gate.resolve(try h.tokenResponse(access: "late-browser-access", refresh: "late-browser-refresh"))
        await #expect(throws: OpenAIConnectionError.cancelled) { try await stale.value }
        #expect(h.connection.sessionGeneration == generation)
        #expect(try await h.connection.authorizedAccessToken() == "test-access")
        #expect(!h.connection.isSigningIn)
    }
}
