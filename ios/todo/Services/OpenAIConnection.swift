import Foundation
import Combine
import CryptoKit

@MainActor final class OpenAIConnection: ObservableObject {
    static let shared = OpenAIConnection()
    @Published private(set) var profiles: [OpenAIProfile] = []
    @Published private(set) var activeProfileID: String?
    @Published private(set) var isSigningIn = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var sessionGeneration = UUID()
    var activeProfile: OpenAIProfile? { profiles.first { $0.id == activeProfileID } }
    var hasPlanPermission: Bool { activeProfile?.hasPlanPermission == true }
    var synchronizationIssue: OpenAIConnectionError? { store.synchronizationIssue }
    var refreshOwnedElsewhere: Bool {
        guard let tokens = activeTokens else { return false }
        return tokens.refreshOwnerID != localRefreshOwnerID
    }
    var needsLocalReauthorization: Bool {
        guard let tokens = activeTokens else { return false }
        return tokens.expiresAt.timeIntervalSince(now()) <= 60 && tokens.refreshOwnerID != localRefreshOwnerID
    }
    private var activeTokens: Tokens? {
        snapshot.registrations.first { $0.clientID == snapshot.activeID }?.tokens
    }
    private var refreshOwnerIdentity: (host: String, id: String)?
    private var localRefreshOwnerID: String {
        if let owner = refreshOwnerIdentity, owner.host == snapshot.hostID { return owner.id }
        let id = OpenAIOAuth.refreshOwnerID(for: snapshot.hostID)
        refreshOwnerIdentity = (snapshot.hostID, id)
        return id
    }

    struct Tokens: Codable, Equatable {
        let access: String
        let refresh: String?
        let identity: String
        let nonce: String
        let scopes: Set<String>
        let expiresAt: Date
        var refreshOwnerID: String? = nil
        var rotation: UInt64? = nil
        var quarantineID: String {
            OpenAIOAuth.base64URL(Data(SHA256.hash(data: Data((nonce + "\u{0}" + (refresh ?? access)).utf8))))
        }
        func isNewerRotation(than other: Tokens) -> Bool {
            nonce == other.nonce && (rotation ?? 0) > (other.rotation ?? 0)
        }
    }
    struct Registration: Codable, Equatable {
        let clientID: String
        var subject: String?
        var email: String?
        var tokens: Tokens?
    }
    struct Snapshot: Codable, Equatable {
        var hostID = "urn:uuid:\(UUID().uuidString.lowercased())"
        var registrations: [Registration] = []
        var selectedID: String?
        var activeID: String?
        var incompleteID: String?
    }
    /// Deliberately excludes ext_agent_host_id: a transferred registration is not a transferred host.
    struct PortableSnapshot: Codable {
        var registrations: [Registration]
        var selectedID: String?
        var activeID: String?
        var incompleteID: String?

        init(_ snapshot: Snapshot) {
            registrations = snapshot.registrations
            selectedID = snapshot.selectedID
            activeID = snapshot.activeID
            incompleteID = snapshot.incompleteID
        }
    }
    private struct Discovery: Decodable {
        let issuer: String
        let authorization_endpoint: URL
        let token_endpoint: URL
        let revocation_endpoint: URL
        let jwks_uri: URL
    }
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let token_type: String
        let expires_in: Double
        let scope: String?
    }
    private struct OAuthError: Decodable { let error: String }
    private struct Pending {
        let id: UUID
        let listener: any OpenAILoopbackListening
        let browser: any OpenAIAuthenticationBrowser
    }
    private var snapshot = Snapshot()
    private var storageAvailable = true
    private let store: any OpenAICredentialStore
    private var synchronizationStatusMessage: String?
    private let transport: any OpenAIAuthTransport
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (Duration) async throws -> Void
    private let makeListener: @MainActor () -> any OpenAILoopbackListening
    private let makeBrowser: @MainActor () -> any OpenAIAuthenticationBrowser
    private let regionAllowed: @MainActor () -> Bool
    private var pending: Pending?
    private var refreshes: [String: (id: UUID, generation: UUID, task: Task<String, Error>)] = [:]
    private var discoveryCache: Discovery?
    private var synchronizationEnabled: Bool

    init(store: (any OpenAICredentialStore)? = nil,
         transport: (any OpenAIAuthTransport)? = nil,
         now: @escaping @MainActor () -> Date = { Date() },
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         makeListener: @escaping @MainActor () -> any OpenAILoopbackListening = { OpenAILoopbackListener() },
         makeBrowser: @escaping @MainActor () -> any OpenAIAuthenticationBrowser = { OpenAISystemAuthenticationBrowser() },
         regionAllowed: @escaping @MainActor () -> Bool = { OpenAIRegionalAvailability.allowsRequests }) {
        self.store = store ?? OpenAIKeychainCredentialStore()
        self.transport = transport ?? OpenAIURLSessionTransport()
        self.now = now; self.sleep = sleep
        self.makeListener = makeListener; self.makeBrowser = makeBrowser
        self.regionAllowed = regionAllowed
        synchronizationEnabled = self.store.synchronizationEnabled
        refreshCredentials()
    }

    /// Reconcile late iCloud Keychain delivery on foreground, policy changes, and before use.
    /// This updates authentication only; provider toggles and app-data consents remain device-local.
    func refreshCredentials() {
        do {
            var loaded = snapshot
            if let data = try store.load() { loaded = try JSONDecoder().decode(Snapshot.self, from: data) }
            else { loaded.registrations = []; loaded.selectedID = nil; loaded.activeID = nil; loaded.incompleteID = nil }
            let blocked = store.blockedClientIDs()
            let quarantined = store.quarantinedCredentialIDs()
            var migrated = false
            for index in loaded.registrations.indices {
                let registration = loaded.registrations[index]
                if blocked.contains(registration.clientID)
                    || registration.tokens.map({ quarantined[registration.clientID]?.contains($0.quarantineID) == true }) == true {
                    loaded.registrations[index].tokens = nil
                } else if var tokens = registration.tokens, tokens.refreshOwnerID == nil {
                    // Only a legacy device record can lack ownership. Imports are marked by the store.
                    tokens.refreshOwnerID = OpenAIOAuth.refreshOwnerID(for: loaded.hostID)
                    loaded.registrations[index].tokens = tokens
                    migrated = true
                }
            }
            if let active = loaded.activeID,
               !loaded.registrations.contains(where: { $0.clientID == active && $0.subject != nil && $0.tokens != nil }) {
                loaded.activeID = nil
            }
            if migrated { try store.save(JSONEncoder().encode(loaded)) }
            let policy = store.synchronizationEnabled
            if loaded != snapshot || policy != synchronizationEnabled {
                cancelSignIn(); invalidateSession()
                snapshot = loaded
                synchronizationEnabled = policy
                publish()
            }
            if !storageAvailable { statusMessage = nil }
            storageAvailable = true
            updateSynchronizationStatus()
        } catch {
            cancelSignIn(); invalidateSession()
            storageAvailable = false
            snapshot.registrations = snapshot.registrations.map {
                var registration = $0; registration.tokens = nil; return registration
            }
            snapshot.activeID = nil
            publish()
            statusMessage = OpenAIConnectionError.storage.errorDescription
        }
    }

    /// Explicit consent recovery only; ordinary returning sign-in does not force consent.
    func enablePlanPermission() async throws { try await signIn(newAccount: false, requestPlanConsent: true) }

    func signIn(newAccount: Bool = false) async throws {
        try await signIn(newAccount: newAccount, requestPlanConsent: false)
    }

    private func signIn(newAccount: Bool, requestPlanConsent: Bool) async throws {
        try requireRegion()
        refreshCredentials()
        cancelSignIn()
        try Task.checkCancellation()
        guard storageAvailable else { throw OpenAIConnectionError.storage }
        // Save the stable host identity BEFORE opening any browser.
        try persist(snapshot)
        let selected = newAccount ? snapshot.incompleteID : snapshot.selectedID ?? snapshot.incompleteID
        let registration = snapshot.registrations.first { $0.clientID == selected }
        let state = try OpenAIOAuth.random(), nonce = try OpenAIOAuth.random(), verifier = try OpenAIOAuth.random()
        let attempt = Pending(id: UUID(), listener: makeListener(), browser: makeBrowser())
        pending = attempt; isSigningIn = true; statusMessage = nil
        defer {
            if pending?.id == attempt.id {
                pending = nil; isSigningIn = false
                attempt.listener.stop(); attempt.browser.cancel()
            }
        }
        var uncommitted: (TokenResponse, String, Discovery)?
        do {
            try await withTaskCancellationHandler {
                let configuration = try await discovery()
                try checkAttempt(attempt.id)
                let redirect = try await attempt.listener.start()
                try checkAttempt(attempt.id)
                var values: [String: String] = [
                    "client_id": registration?.clientID ?? "dynamic_agent_client",
                    "ext_agent_host_id": snapshot.hostID, "response_type": "code",
                    "redirect_uri": redirect.absoluteString, "scope": OpenAIOAuth.scope,
                    "resource": OpenAIOAuth.resource, "state": state, "nonce": nonce,
                    "code_challenge_method": "S256",
                    "code_challenge": OpenAIOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
                ]
                if registration == nil { values["agent_name_hint"] = "SIFT" }
                if let hint = registration?.tokens?.identity { values["id_token_hint"] = hint }
                if let email = registration?.email { values["login_hint"] = email }
                if requestPlanConsent { values["prompt"] = "consent" }
                var components = URLComponents(url: configuration.authorization_endpoint, resolvingAgainstBaseURL: false)!
                components.queryItems = values.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
                guard let url = components.url, attempt.browser.start(url: url, onCancel: { [weak self] in
                    guard self?.pending?.id == attempt.id else { return }
                    self?.cancelSignIn()
                }) else { throw OpenAIConnectionError.unavailable }
                let callback = try await attempt.listener.callback()
                try checkAttempt(attempt.id)
                // The listener owns completion. Keep cancellation available through token exchange;
                // dismiss the system browser only after invalidating its attempt identifier.
                attempt.listener.stop()
                let accepted = try OpenAIOAuth.callbackValues(callback, redirect: redirect, state: state,
                                                             clientID: registration?.clientID)
                if registration == nil {
                    guard !snapshot.registrations.contains(where: { $0.clientID == accepted.clientID }) else {
                        throw OpenAIConnectionError.invalidCallback
                    }
                    var staged = snapshot
                    staged.registrations.append(Registration(clientID: accepted.clientID))
                    staged.incompleteID = accepted.clientID
                    // Keep the issued ID even when code exchange fails; never repeat dynamic registration for this attempt.
                    try persist(staged)
                }
                let response = try await tokenRequest(configuration.token_endpoint, values: [
                    "grant_type": "authorization_code", "client_id": accepted.clientID,
                    "code": accepted.code, "code_verifier": verifier,
                    "redirect_uri": redirect.absoluteString, "resource": OpenAIOAuth.resource
                ])
                uncommitted = (response, accepted.clientID, configuration)
                guard pending?.id == attempt.id, !Task.isCancelled else {
                    throw OpenAIConnectionError.cancelled
                }
                guard let identityToken = response.id_token else { throw OpenAIConnectionError.invalidIdentity }
                let jwks = try await get(configuration.jwks_uri)
                try checkAttempt(attempt.id)
                let identity = try OpenAIJWTValidator.validate(identityToken, jwks: jwks, clientID: accepted.clientID,
                                                               nonce: nonce, now: now())
                guard registration?.subject == nil || registration?.subject == identity.subject else {
                    throw OpenAIConnectionError.invalidIdentity
                }
                let tokens = try makeTokens(response, previous: nil, nonce: nonce)
                var updated = snapshot
                guard let index = updated.registrations.firstIndex(where: { $0.clientID == accepted.clientID }) else {
                    throw OpenAIConnectionError.invalidCallback
                }
                updated.registrations[index].subject = identity.subject
                updated.registrations[index].email = identity.email
                updated.registrations[index].tokens = tokens
                updated.activeID = accepted.clientID; updated.selectedID = accepted.clientID
                if updated.incompleteID == accepted.clientID { updated.incompleteID = nil }
                try checkAttempt(attempt.id)
                try persist(updated, reauthorizing: accepted.clientID)
                uncommitted = nil
                invalidateSession()
                pending = nil; isSigningIn = false
                attempt.browser.cancel()
                publish()
                if !hasPlanPermission { statusMessage = OpenAIConnectionError.permissionRequired.errorDescription }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard self?.pending?.id == attempt.id else { return }
                    self?.cancelSignIn()
                }
            }
        } catch {
            if let (response, clientID, configuration) = uncommitted {
                await discard(response, clientID: clientID, configuration: configuration)
            }
            let sanitized = sanitize(error)
            if pending?.id == attempt.id { statusMessage = sanitized.errorDescription }
            throw sanitized
        }
    }

    func cancelSignIn() {
        guard let attempt = pending else { return }
        pending = nil; isSigningIn = false
        attempt.listener.stop(); attempt.browser.cancel()
    }

    /// Stop active work without erasing credentials or the user's existing opt-ins.
    func suspendForRegionalRestriction() {
        cancelSignIn()
        invalidateSession()
    }

    func selectProfile(_ id: String) throws {
        try requireRegion()
        refreshCredentials()
        guard let registration = snapshot.registrations.first(where: { $0.clientID == id && $0.subject != nil }) else {
            throw OpenAIConnectionError.signInRequired
        }
        cancelSignIn()
        var updated = snapshot
        updated.selectedID = id
        if registration.tokens == nil {
            // Remember which saved mapping to reauthorize, without activating an unauthenticated profile.
            try persist(updated)
            throw OpenAIConnectionError.signInRequired
        }
        updated.activeID = id
        try persist(updated)
        invalidateSession(); publish(); statusMessage = nil
        updateSynchronizationStatus()
    }

    func signOut() async {
        refreshCredentials()
        cancelSignIn(); invalidateSession()
        guard let id = snapshot.activeID,
              let index = snapshot.registrations.firstIndex(where: { $0.clientID == id }) else { return }
        let token = snapshot.registrations[index].tokens?.refresh
        store.block(id)
        var updated = snapshot
        updated.registrations[index].tokens = nil
        updated.activeID = nil
        var cleared = true
        do { try persist(updated) } catch {
            snapshot = updated; cleared = false
        }
        publish()
        let signOutGeneration = sessionGeneration
        // Requests stop immediately. A private captured refresh token exists only for bounded revocation.
        let renewable = token.map { [(id, $0)] } ?? []
        let revoked = await endRenewableSessions(renewable)
        guard sessionGeneration == signOutGeneration else { return }
        let language = AppLanguage.current
        switch (cleared, revoked) {
        case (true, true):
            statusMessage = nil
        case (false, true):
            statusMessage = AppLanguage.localized(
                "openai.connection.status.signOutCleanupUnconfirmed",
                defaultValue: language == .english
                    ? "Signed out locally. Secure credential cleanup could not be confirmed."
                    : "이 기기에서 로그아웃했습니다. 인증 정보가 안전하게 삭제되었는지 확인할 수 없습니다.",
                language: language,
                comment: "ChatGPT sign-out status when local secure cleanup is unconfirmed but remote revocation succeeded."
            )
        case (true, false):
            statusMessage = AppLanguage.localized(
                "openai.connection.status.signOutRevocationUnconfirmed",
                defaultValue: language == .english
                    ? "Signed out locally. Remote revocation was not confirmed. Disconnect SIFT in ChatGPT Settings."
                    : "이 기기에서 로그아웃했습니다. 원격 접근 권한 해제가 확인되지 않았습니다. ChatGPT 설정에서 SIFT 연결을 해제해 주세요.",
                language: language,
                comment: "ChatGPT sign-out status when local cleanup succeeded but remote revocation is unconfirmed."
            )
        case (false, false):
            statusMessage = AppLanguage.localized(
                "openai.connection.status.signOutCleanupAndRevocationUnconfirmed",
                defaultValue: language == .english
                    ? "Signed out locally. Secure credential cleanup could not be confirmed. Remote revocation was not confirmed. Disconnect SIFT in ChatGPT Settings."
                    : "이 기기에서 로그아웃했습니다. 인증 정보가 안전하게 삭제되었는지 확인할 수 없습니다. 원격 접근 권한 해제가 확인되지 않았습니다. ChatGPT 설정에서 SIFT 연결을 해제해 주세요.",
                language: language,
                comment: "ChatGPT sign-out status when both secure cleanup and remote revocation are unconfirmed."
            )
        }
    }

    /// App-data deletion, unlike signOut(), forgets every registration and this host identity.
    /// Returns only after bounded revocation attempts; failed secure erasure is never reported as success.
    func deleteAllLocalCredentials() async throws {
        cancelSignIn(); invalidateSession()
        let deletionGeneration = sessionGeneration
        let renewable = snapshot.registrations.compactMap { registration -> (String, String)? in
            guard let token = registration.tokens?.refresh else { return nil }
            return (registration.clientID, token)
        }
        for registration in snapshot.registrations { store.block(registration.clientID) }
        snapshot = Snapshot()
        discoveryCache = nil
        publish()
        var erased = true
        do { try store.deleteAll(); storageAvailable = true }
        catch { erased = false; storageAvailable = false }
        let revoked = await endRenewableSessions(renewable)
        if sessionGeneration == deletionGeneration {
            discoveryCache = nil
            let language = AppLanguage.current
            statusMessage = revoked ? nil : AppLanguage.localized(
                "openai.connection.status.deletionRevocationUnconfirmed",
                defaultValue: language == .english
                    ? "Local ChatGPT data was cleared. Remote revocation was not confirmed. Disconnect SIFT in ChatGPT Settings."
                    : "로컬 ChatGPT 데이터가 삭제되었습니다. 원격 접근 권한 해제가 확인되지 않았습니다. ChatGPT 설정에서 SIFT 연결을 해제해 주세요.",
                language: language,
                comment: "ChatGPT data deletion status when local data was cleared but remote revocation is unconfirmed."
            )
            if !erased { statusMessage = OpenAIConnectionError.storage.errorDescription }
        }
        guard erased else { throw OpenAIConnectionError.storage }
    }

    func authorizedAccessToken() async throws -> String {
        try Task.checkCancellation()
        try requireRegion()
        refreshCredentials()
        guard storageAvailable else { throw OpenAIConnectionError.storage }
        guard let id = snapshot.activeID,
              let registration = snapshot.registrations.first(where: { $0.clientID == id }),
              let tokens = registration.tokens else { throw OpenAIConnectionError.signInRequired }
        guard tokens.scopes.contains("chatgpt.tokens.use.direct") else { throw OpenAIConnectionError.permissionRequired }
        if tokens.expiresAt.timeIntervalSince(now()) > 60 { return tokens.access }
        guard tokens.refreshOwnerID == localRefreshOwnerID else {
            statusMessage = OpenAIConnectionError.refreshOwnerRequired.errorDescription
            publish()
            throw OpenAIConnectionError.refreshOwnerRequired
        }
        if let refresh = refreshes[id] {
            let generation = sessionGeneration
            let access = try await refresh.task.value
            try checkSession(id, generation)
            return access
        }
        let generation = sessionGeneration, taskID = UUID()
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw OpenAIConnectionError.cancelled }
            return try await self.refreshTokens(clientID: id, generation: generation)
        }
        refreshes[id] = (taskID, generation, task)
        defer { if refreshes[id]?.id == taskID { refreshes[id] = nil } }
        let access = try await task.value
        try checkSession(id, generation)
        return access
    }

    private func refreshTokens(clientID: String, generation: UUID) async throws -> String {
        try requireRegion()
        guard let registration = snapshot.registrations.first(where: { $0.clientID == clientID }),
              let previous = registration.tokens, let refreshToken = previous.refresh else {
            throw OpenAIConnectionError.signInRequired
        }
        var uncommitted: (TokenResponse, Discovery)?
        var refreshDispatched = false
        do {
            let configuration = try await discovery()
            try checkSession(clientID, generation)
            refreshDispatched = true
            let response = try await tokenRequest(configuration.token_endpoint, values: [
                "grant_type": "refresh_token", "client_id": clientID,
                "refresh_token": refreshToken, "resource": OpenAIOAuth.resource
            ], isRefresh: true)
            uncommitted = (response, configuration)
            guard sessionGeneration == generation, snapshot.activeID == clientID, !Task.isCancelled else {
                throw OpenAIConnectionError.cancelled
            }
            if let identityToken = response.id_token {
                let keys = try await get(configuration.jwks_uri)
                try checkSession(clientID, generation)
                let identity = try OpenAIJWTValidator.validate(identityToken, jwks: keys, clientID: clientID,
                                                               nonce: previous.nonce, now: now(), requireNonce: false)
                guard identity.subject == registration.subject else { throw OpenAIConnectionError.invalidIdentity }
            }
            let tokens = try makeTokens(response, previous: previous, nonce: previous.nonce)
            try checkSession(clientID, generation)
            var updated = snapshot
            guard let index = updated.registrations.firstIndex(where: { $0.clientID == clientID }) else {
                throw OpenAIConnectionError.cancelled
            }
            updated.registrations[index].tokens = tokens
            try persist(updated); publish()
            uncommitted = nil
            guard tokens.scopes.contains("chatgpt.tokens.use.direct") else { throw OpenAIConnectionError.permissionRequired }
            return tokens.access
        } catch {
            // Reconcile before cleanup: a transferred session may have rotated on another host.
            refreshCredentials()
            let current = snapshot.registrations.first { $0.clientID == clientID }?.tokens
            let hasSharedReplacement = current.map { $0 != previous && $0.nonce == previous.nonce } ?? false
            if let (response, configuration) = uncommitted, !hasSharedReplacement {
                await discard(response, clientID: clientID, configuration: configuration)
                // Revocation suspends; delivery may also occur during its bounded retries.
                refreshCredentials()
            }
            let sanitized: OpenAIConnectionError = sessionGeneration == generation ? sanitize(error) : .cancelled
            if refreshDispatched, sanitized == .cancelled || !regionAllowed() {
                quarantineRefresh(clientID: clientID, previous: previous)
            }
            if sessionGeneration == generation, sanitized == .signInRequired || sanitized == .invalidIdentity {
                quarantineRefresh(clientID: clientID, previous: previous)
            }
            throw sanitized
        }
    }

    private func quarantineRefresh(clientID: String, previous: Tokens) {
        guard let index = snapshot.registrations.firstIndex(where: { $0.clientID == clientID }),
              let current = snapshot.registrations[index].tokens,
              current == previous else { return }
        // A rejected/abandoned rotating grant is not a sign-out. Keep the shared record intact:
        // a replacement may arrive later, even after this process restarts.
        store.quarantine(clientID: clientID, credentialID: previous.quarantineID)
        snapshot.registrations[index].tokens = nil
        let wasActive = snapshot.activeID == clientID
        if wasActive { snapshot.activeID = nil }
        if wasActive { invalidateSession() }
        publish()
    }

    private func makeTokens(_ response: TokenResponse, previous: Tokens?, nonce: String) throws -> Tokens {
        guard !response.access_token.isEmpty, response.token_type.lowercased() == "bearer",
              response.expires_in.isFinite, response.expires_in > 0,
              let identity = response.id_token ?? previous?.identity else { throw OpenAIConnectionError.exchangeFailed }
        let scopes: Set<String>
        if let scope = response.scope { scopes = Set(scope.split(whereSeparator: { $0.isWhitespace }).map(String.init)) }
        else if let previous { scopes = previous.scopes }
        else { scopes = [] } // Missing granted scope never implies plan permission on initial exchange.
        return Tokens(access: response.access_token, refresh: response.refresh_token ?? previous?.refresh,
                      identity: identity, nonce: nonce, scopes: scopes,
                      expiresAt: now().addingTimeInterval(response.expires_in),
                      refreshOwnerID: localRefreshOwnerID, rotation: previous.map { ($0.rotation ?? 0) + 1 } ?? 0)
    }

    private func discovery() async throws -> Discovery {
        try requireRegion()
        if let discoveryCache { return discoveryCache }
        let data = try await get(URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
        let value: Discovery
        do { value = try JSONDecoder().decode(Discovery.self, from: data) } catch { throw OpenAIConnectionError.unavailable }
        func isTrustedEndpoint(_ url: URL) -> Bool {
            guard url.scheme == "https", url.host == "auth.openai.com" else { return false }
            guard url.port == nil || url.port == 443 else { return false }
            guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
            return true
        }
        guard value.issuer == OpenAIOAuth.issuer,
              value.authorization_endpoint.absoluteString == "https://auth.openai.com/api/accounts/authorize",
              value.token_endpoint.absoluteString == "https://auth.openai.com/api/accounts/oauth/token",
              isTrustedEndpoint(value.revocation_endpoint), isTrustedEndpoint(value.jwks_uri)
        else { throw OpenAIConnectionError.unavailable }
        discoveryCache = value
        return value
    }

    private func get(_ url: URL) async throws -> Data {
        try requireRegion()
        var request = URLRequest(url: url); request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, status) = try await transport.send(request)
        try requireRegion()
        guard status == 200 else { throw OpenAIConnectionError.network }
        return data
    }
    private func tokenRequest(_ endpoint: URL, values: [String: String], isRefresh: Bool = false) async throws -> TokenResponse {
        try requireRegion()
        let (data, status) = try await transport.send(formRequest(endpoint, values: values))
        try requireRegion()
        guard status == 200 else {
            let code = (try? JSONDecoder().decode(OAuthError.self, from: data))?.error
            if code == "invalid_client" { throw OpenAIConnectionError.invalidClient }
            let terminal = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                            "refresh_token_invalidated", "refresh_token_reused"]
            if isRefresh, let code, terminal.contains(code) { throw OpenAIConnectionError.signInRequired }
            throw status >= 500 ? OpenAIConnectionError.network : .exchangeFailed
        }
        do { return try JSONDecoder().decode(TokenResponse.self, from: data) }
        catch { throw OpenAIConnectionError.exchangeFailed }
    }
    private func formRequest(_ endpoint: URL, values: [String: String]) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OpenAIOAuth.form(values)
        return request
    }
    /// Unstructured work intentionally does not inherit caller cancellation. A cancelled refresh may
    /// already have rotated remotely, so cleanup must still attempt its bounded network/backoff work.
    private func endRenewableSessions(_ sessions: [(String, String)], using configuration: Discovery? = nil) async -> Bool {
        await Task { @MainActor in
            guard !sessions.isEmpty else { return true }
            guard regionAllowed() else { return false }
            do {
                let metadata: Discovery
                if let configuration { metadata = configuration }
                else { metadata = try await discovery() }
                var confirmed = true
                for (clientID, token) in sessions {
                    let result = await performRevocation(token, clientID: clientID, endpoint: metadata.revocation_endpoint)
                    confirmed = confirmed && result
                }
                return confirmed
            } catch { return false }
        }.value
    }

    private func performRevocation(_ token: String, clientID: String, endpoint: URL) async -> Bool {
        for attempt in 0..<3 {
            guard regionAllowed() else { return false }
            do {
                let (_, status) = try await transport.send(formRequest(endpoint, values: [
                    "token": token, "token_type_hint": "refresh_token", "client_id": clientID
                ]))
                guard regionAllowed() else { return false }
                if status == 200 { return true }
                if status < 500 { return false }
            } catch { }
            if attempt < 2 { do { try await sleep(.seconds(attempt + 1)) } catch { return false } }
        }
        return false
    }
    private func discard(_ response: TokenResponse, clientID: String, configuration: Discovery) async {
        if let token = response.refresh_token {
            _ = await endRenewableSessions([(clientID, token)], using: configuration)
        }
    }
    private func persist(_ updated: Snapshot, reauthorizing clientID: String? = nil) throws {
        do {
            try store.save(JSONEncoder().encode(updated))
            if let clientID { try store.unblock(clientID) }
        }
        catch { throw OpenAIConnectionError.storage }
        snapshot = updated
        updateSynchronizationStatus()
    }
    private func updateSynchronizationStatus() {
        let message = snapshot.activeID == nil ? nil : store.synchronizationIssue?.errorDescription
        if let message { statusMessage = message }
        else if statusMessage == synchronizationStatusMessage { statusMessage = nil }
        synchronizationStatusMessage = message
    }

    private func publish() {
        profiles = snapshot.registrations.compactMap { registration in
            guard let subject = registration.subject else { return nil }
            return OpenAIProfile(id: registration.clientID, clientID: registration.clientID,
                                 subject: subject, email: registration.email,
                                 hasPlanPermission: registration.tokens?.scopes.contains("chatgpt.tokens.use.direct") == true)
        }
        activeProfileID = snapshot.activeID
    }
    private func invalidateSession() {
        let previous = sessionGeneration
        OpenAIRequestRegistry.shared.cancel(generation: previous)
        sessionGeneration = UUID()
        // Keep ownership until each task finishes cleanup; account switches must not launch
        // another exchange against an abandoned rotating refresh token.
        for flight in refreshes.values where flight.generation == previous { flight.task.cancel() }
    }
    private func requireRegion() throws {
        guard regionAllowed() else { throw OpenAIConnectionError.unavailable }
    }
    private func checkAttempt(_ id: UUID) throws {
        try requireRegion()
        refreshCredentials()
        guard !Task.isCancelled, pending?.id == id else { throw OpenAIConnectionError.cancelled }
    }
    private func checkSession(_ id: String, _ generation: UUID) throws {
        try requireRegion()
        refreshCredentials()
        guard !Task.isCancelled, sessionGeneration == generation, snapshot.activeID == id else {
            throw OpenAIConnectionError.cancelled
        }
    }
    private func sanitize(_ error: Error) -> OpenAIConnectionError {
        if let error = error as? OpenAIConnectionError { return error }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        return .network
    }
}
