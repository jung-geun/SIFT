import CryptoKit
import Foundation
import LocalAuthentication
import Security
import OSLog

/// 앱의 모든 민감 정보(Gmail 토큰 등 보안정보) Keychain 접근을 단일화.
///
/// **정책 요약:**
/// - 동기화 가능 여부: 빌드의 iCloud 지원 여부와 앱 iCloud 토글에 연동.
///   지원 빌드 + ON → `synchronizable=true` (iCloud Keychain, E2E 암호화)
///   미지원 빌드 또는 OFF → `synchronizable=false` (ThisDeviceOnly, 완전 로컬)
/// - 접근성: 배경 BGTask 메인 스레드에서 토큰을 읽을 수 있도록
///   `AfterFirstUnlock` 계열 사용 (기본값 `WhenUnlocked` 대신).
/// - 마이그레이션: 동기화 상태 변경 중에도 기존 데이터를 항상 찾을 수 있도록
///   `get`과 `delete`는 `kSecAttrSynchronizableAny`를 사용.
/// - 교체: SecItemUpdate를 우선 사용해 실패해도 기존 비밀을 보존.
enum KeychainStoreError: Error, Equatable {
    case security(OSStatus)
    case authorizationChanged
    case authenticationRequired
    case authenticationCancelled
}

enum GmailCredentialPortabilityError: Error, Equatable {
    case conflict
    case revoked
}

nonisolated struct GmailCredentialRollbackError: Error {
    let operationError: any Error
    let rollbackError: any Error
}

nonisolated struct GmailCredentialDeletionError: Error {
    let credentialError: (any Error)?
    let fenceError: (any Error)?
}

nonisolated enum DeviceOnlyCredentialAccess: Sendable, Equatable {
    case foregroundUserPresence
    case backgroundAfterFirstUnlock
}

/// Metadata cannot always distinguish an existing protected item without UI.
/// Only an already-verified receipt may interpret authenticationRequired as
/// unchanged availability; it never authorizes a credential read or new receipt.
nonisolated enum DeviceOnlyCredentialPresence: Sendable, Equatable {
    case present
    case missing
    case authenticationRequired
}

nonisolated enum KeychainStore {
    private static let logger = Logger(subsystem: "pieroot.todo", category: "KeychainStore")
    private static let gmailCopyLock = NSRecursiveLock()
    private static let gmailStateService = "pieroot.todo.gmail.portability-state.v1"

    /// A task inherits its attempt, never an app-wide authentication switch.
    /// The context holds OS authorization only; no credential bytes are cached.
    private final class AuthenticationAttempt: @unchecked Sendable {
        let context = LAContext()
        let allowsUI: Bool
        private let parent: AuthenticationAttempt?
        private let lock = NSLock()
        private let operationLock = NSRecursiveLock()
        private var failure: KeychainStoreError?
        private var ended = false
        private var taskCancelled = false

        init(allowsUI: Bool, parent: AuthenticationAttempt?) {
            self.allowsUI = allowsUI
            self.parent = parent
            context.interactionNotAllowed = !allowsUI
            context.localizedReason = AppLanguage.localized(
                allowsUI ? "security.keychain.syncPurpose" : "security.keychain.quietPurpose",
                defaultValue: allowsUI
                    ? "Unlock saved account connections to sync them with iCloud. Cancel to leave protected connections unchanged."
                    : "Check saved account connections without requesting authentication.",
                language: .current)
        }

        func beginOperation() throws {
            operationLock.lock()
            do { try check() }
            catch { operationLock.unlock(); throw error }
        }

        func endOperation() { operationLock.unlock() }

        func check() throws {
            try parent?.check()
            lock.lock()
            defer { lock.unlock() }
            if taskCancelled { throw CancellationError() }
            if let failure { throw failure }
            guard !ended else { throw KeychainStoreError.authorizationChanged }
        }

        func fail(_ error: KeychainStoreError) {
            lock.lock()
            if failure == nil { failure = error }
            lock.unlock()
            context.invalidate()
        }

        func cancelTask() {
            lock.lock()
            taskCancelled = true
            lock.unlock()
            context.invalidate()
        }

        func finish() {
            lock.lock()
            ended = true
            lock.unlock()
            context.invalidate()
        }
    }

    @TaskLocal private static var authenticationAttempt: AuthenticationAttempt?

    /// Automatic sync must use this scope for reads AND mutations, including
    /// slot migrations. An unavailable protected item is not an absent item.
    static func withoutAuthenticationUI<T>(
        isolation: isolated (any Actor)? = #isolation, _ operation: () async throws -> T
    ) async throws -> T {
        try await withAuthenticationAttempt(allowsUI: false, isolation: isolation, operation)
    }

    /// Only a dedicated, explained user action may enter this scope. One OS
    /// context is reused across families; the OS still decides the prompt count.
    static func withUserInitiatedCredentialSync<T>(
        isolation: isolated (any Actor)? = #isolation, _ operation: () async throws -> T
    ) async throws -> T {
        try await withAuthenticationAttempt(allowsUI: true, isolation: isolation, operation)
    }

    static func checkAuthenticationAttempt() throws {
        try authenticationAttempt?.check()
    }

    private static func withAuthenticationAttempt<T>(
        allowsUI: Bool, isolation: isolated (any Actor)?, _ operation: () async throws -> T
    ) async throws -> T {
        // Each quiet family has its own failure boundary, so a protected account
        // cannot block unrelated app data. Parent cancellation/end still wins.
        // An interactive helper inherits the parent and can never escalate it.
        try checkAuthenticationAttempt()
        if let current = authenticationAttempt, allowsUI {
            let value = try await operation()
            try current.check()
            return value
        }
        let attempt = AuthenticationAttempt(allowsUI: allowsUI, parent: authenticationAttempt)
        defer { attempt.finish() }
        return try await withTaskCancellationHandler {
            try await $authenticationAttempt.withValue(attempt) {
                if Task.isCancelled { attempt.cancelTask() }
                try attempt.check()
                do {
                    let value = try await operation()
                    try attempt.check() // Legacy optional/best-effort APIs may catch.
                    return value
                } catch {
                    // Preserve a swallowed/wrapped authentication error over a
                    // later decoding, rollback, or missing-credential error.
                    try attempt.check()
                    throw error
                }
            }
        } onCancel: {
            attempt.cancelTask()
        }
    }

    private enum SecurityOperation: String { case read, update, add, delete }

    /// Every Security.framework entry point goes through the same policy.
    /// Query-only parameters never become stored ACL/accessibility attributes.
    private static func performSecurityOperation(
        _ operation: SecurityOperation, query: [String: Any], attributes: [String: Any] = [:],
        noninteractiveProbe: Bool = false, result: inout AnyObject?
    ) throws -> OSStatus {
        try checkAuthenticationAttempt()
        let attempt = authenticationAttempt
        try attempt?.beginOperation()
        defer { attempt?.endOperation() }
        let context = noninteractiveProbe ? LAContext() : (attempt?.context ?? LAContext())
        if noninteractiveProbe { context.interactionNotAllowed = true }
        if attempt == nil || noninteractiveProbe {
            context.localizedReason = AppLanguage.localized("security.keychain.actionPurpose",
                defaultValue: "Unlock saved credentials for the action you requested.", language: .current)
        }
        defer { if attempt == nil || noninteractiveProbe { context.invalidate() } }
        var authenticatedQuery = query
        authenticatedQuery[kSecUseAuthenticationContext as String] = context
        let status: OSStatus
        #if DEBUG
        if let backend = securityBackendForTesting {
            let response = backend.perform(operation.rawValue, authenticatedQuery, attributes)
            status = response.0
            result = response.1
        } else {
            status = callSecurity(operation, query: authenticatedQuery, attributes: attributes, result: &result)
        }
        #else
        status = callSecurity(operation, query: authenticatedQuery, attributes: attributes, result: &result)
        #endif
        if !noninteractiveProbe && status != errSecSuccess && status != errSecItemNotFound && status != errSecDuplicateItem {
            if attempt != nil { throw securityError(status) }
        }
        return status
    }

    private static func securityError(_ status: OSStatus) -> KeychainStoreError {
        guard let attempt = authenticationAttempt else { return .security(status) }
        let error: KeychainStoreError
        switch status {
        case errSecUserCanceled: error = .authenticationCancelled
        case errSecInteractionNotAllowed, errSecAuthFailed: error = .authenticationRequired
        // A malformed/unavailable item is a family failure, not revocation of
        // the user's authorization for other families in this explicit attempt.
        default: return .security(status)
        }
        attempt.fail(error)
        return error
    }

    private static func callSecurity(
        _ operation: SecurityOperation, query: [String: Any], attributes: [String: Any],
        result: inout AnyObject?
    ) -> OSStatus {
        switch operation {
        case .read: return SecItemCopyMatching(query as CFDictionary, &result)
        case .update: return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        case .add: return SecItemAdd(query as CFDictionary, nil)
        case .delete: return SecItemDelete(query as CFDictionary)
        }
    }

    /// Validate the lease captured before any potentially blocking operation.
    /// A new authorization must never make an older in-flight pass valid again.
    static func requirePortableAuthorization(_ authorization: () -> Bool) throws {
        guard authorization() else { throw KeychainStoreError.authorizationChanged }
    }

    /// Digests only, stored device-locally in Keychain. A clean copy is a cache,
    /// never authority to overwrite a newer portable token. Pending explicit
    /// writes may publish only against their observed portable base.
    private struct GmailCopyState: Codable, Equatable {
        let localDigest: Data?
        let baseDigest: Data?
        let pending: Bool
        var revoked: Bool? = nil
    }

    #if DEBUG
    /// Runs the production query builder against a task-local fake transport.
    /// Unlike the in-memory value store this observes every Security operation.
    private final class SecurityBackend: @unchecked Sendable {
        let perform: (String, [String: Any], [String: Any]) -> (OSStatus, AnyObject?)
        init(_ perform: @escaping (String, [String: Any], [String: Any]) -> (OSStatus, AnyObject?)) {
            self.perform = perform
        }
    }
    @TaskLocal private static var securityBackendForTesting: SecurityBackend?

    static func withSecurityOperationForTesting<T>(
        _ perform: @escaping (String, [String: Any], [String: Any]) -> (OSStatus, AnyObject?),
        isolation: isolated (any Actor)? = #isolation, operation: () async throws -> T
    ) async rethrows -> T {
        try await $securityBackendForTesting.withValue(SecurityBackend(perform), operation: operation)
    }

    nonisolated private static let testStoreLock = NSLock()
    nonisolated(unsafe) private static var testDataStore: [String: Data] = [:]
    nonisolated(unsafe) private static var testWriteFailures: [String: OSStatus] = [:]
    nonisolated(unsafe) private static var testSynchronizableWriteFailures: [String: OSStatus] = [:]
    nonisolated(unsafe) private static var testReadFailures: [String: OSStatus] = [:]
    nonisolated(unsafe) private static var testDeleteFailures: [String: OSStatus] = [:]
    nonisolated(unsafe) private static var testSynchronizableStore: [String: Data] = [:]
    nonisolated(unsafe) private static var testDeviceAccess: [String: DeviceOnlyCredentialAccess] = [:]
    nonisolated(unsafe) private static var testGmailAuthorizationCapture: ((Bool) -> (() -> Bool))?

    nonisolated static func setWriteFailureForTesting(service: String, status: OSStatus?) {
        testStoreLock.lock()
        testWriteFailures[service] = status
        testStoreLock.unlock()
    }

    nonisolated static func setSynchronizableWriteFailureForTesting(service: String, status: OSStatus?) {
        testStoreLock.lock()
        testSynchronizableWriteFailures[service] = status
        testStoreLock.unlock()
    }

    nonisolated static func setGmailAuthorizationCaptureForTesting(_ capture: ((Bool) -> (() -> Bool))?) {
        testStoreLock.lock()
        testGmailAuthorizationCapture = capture
        testStoreLock.unlock()
    }

    nonisolated static func setReadFailureForTesting(service: String, status: OSStatus?) {
        testStoreLock.lock()
        testReadFailures[service] = status
        testStoreLock.unlock()
    }

    nonisolated static func setDeleteFailureForTesting(service: String, status: OSStatus?) {
        testStoreLock.lock()
        testDeleteFailures[service] = status
        testStoreLock.unlock()
    }

    nonisolated static func deviceOnlyAccessForTesting(service: String, account: String) -> DeviceOnlyCredentialAccess? {
        testStoreLock.lock()
        defer { testStoreLock.unlock() }
        return testDeviceAccess[testKey(service: service, account: account)]
    }

    /// Explicit test seam. Unit-test hosts provide XCTestConfigurationFilePath;
    /// UI tests opt in through SIFT_UI_TESTING. Production always uses
    /// Security.framework.
    nonisolated private static var usesTestStore: Bool {
        if securityBackendForTesting != nil { return false }
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["SIFT_UI_TESTING"] == "1"
    }

    nonisolated private static func testKey(service: String, account: String?) -> String {
        "\(service)\u{1F}\(account ?? "")"
    }
    #endif

    // MARK: - 동기화 정책

    private static var shouldSync: Bool {
        SettingsStore.isICloudSyncEnabled
    }

    /// 동기화 정책에 따른 접근성 클래스.
    /// synchronizable 항목은 ThisDeviceOnly 플래그와 함께 사용할 수 없음.
    private static func accessibility(sync: Bool) -> CFString {
        sync ? kSecAttrAccessibleAfterFirstUnlock
             : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    // MARK: - CRUD

    /// Best-effort API for existing callers. Credential commits use `setChecked`.
    static func set(service: String, account: String? = nil, value: String) {
        do { try setChecked(service: service, account: account, value: value) }
        catch { record(error, operation: "set") }
    }

    static func setChecked(service: String, account: String? = nil, value: String) throws {
        try checkAuthenticationAttempt()
        if usesFullScopeGmailCopies(service: service) {
            try saveFullScopeGmail(account: account ?? "", data: Data(value.utf8))
            return
        }
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            if let status = testWriteFailures[service] { throw securityError(status) }
            let key = testKey(service: service, account: account)
            let data = Data(value.utf8)
            // Generic and binary APIs address the same Security.framework item.
            // Keep their test representation shared so legacy migrations exercise
            // the production storage domains instead of an artificial string silo.
            if shouldSync {
                testSynchronizableStore[key] = data
                testDataStore.removeValue(forKey: key)
                testDeviceAccess.removeValue(forKey: key)
            } else {
                testDataStore[key] = data
                testSynchronizableStore.removeValue(forKey: key)
            }
            return
        }
        #endif
        let sync = shouldSync
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        query[kSecAttrAccount as String] = account ?? ""
        try upsert(query: query, attributes: [
            kSecAttrSynchronizable as String: sync,
            kSecAttrAccessible as String: accessibility(sync: sync),
            kSecValueData as String: Data(value.utf8)
        ])
    }

    /// Updating the canonical item is atomic; never delete it to replace its value.
    private static func upsert(query: [String: Any], attributes: [String: Any]) throws {
        var result: AnyObject?
        let status = try performSecurityOperation(.update, query: query, attributes: attributes, result: &result)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainStoreError.security(status) }
        let item = query.merging(attributes) { _, new in new }
        let addStatus = try performSecurityOperation(.add, query: item, result: &result)
        if addStatus == errSecDuplicateItem {
            let retry = try performSecurityOperation(.update, query: query, attributes: attributes, result: &result)
            guard retry == errSecSuccess else { throw KeychainStoreError.security(retry) }
        } else if addStatus != errSecSuccess {
            throw KeychainStoreError.security(addStatus)
        }
    }

    private static func record(_ error: Error, operation: String) {
        DiagnosticRecorder.shared.record(error: error, component: "security.keychain", operation: operation)
        logger.error("Keychain \(operation) failed")
    }

    /// Gmail always uses independent local/shared copies. The retired raw toggle
    /// never authorizes publication or downgrading a shared credential.
    private static func usesFullScopeGmailCopies(service: String) -> Bool {
        service == "pieroot.todo.gmail"
    }

    /// Only fresh interactive OAuth authorization may lift a local sign-out fence.
    /// Refresh persistence must continue to call normal `setChecked`.
    static func setGmailAfterExplicitSignIn(account: String = "oauth_tokens", value: String) throws {
        try saveFullScopeGmail(account: account, data: Data(value.utf8), allowsReconnect: true)
    }

    private static func gmailRevocationKey(_ account: String) -> String {
        "pieroot.todo.gmail.revoked.v1." + account
    }

    private static func captureGmailAuthorization(forRevocation: Bool = false) -> () -> Bool {
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            let capture = testGmailAuthorizationCapture
            testStoreLock.unlock()
            if let capture { return capture(forRevocation) }
        }
        #endif
        return UserCloudSyncPolicy.captureAuthorization(forRevocation: forRevocation)
    }

    private static func gmailDigest(_ data: Data?) -> Data? {
        data.map { Data(SHA256.hash(data: $0)) }
    }

    private static func gmailState(account: String) throws -> GmailCopyState? {
        try getDeviceOnly(service: gmailStateService, account: account).map {
            try JSONDecoder().decode(GmailCopyState.self, from: $0)
        }
    }

    private static func setGmailState(_ state: GmailCopyState, account: String) throws {
        try setDeviceOnly(service: gmailStateService, account: account, data: JSONEncoder().encode(state))
    }

    private static func acknowledgeGmailState(_ state: GmailCopyState, prior: GmailCopyState?, account: String,
                                               authorization: () -> Bool) throws {
        try requirePortableAuthorization(authorization)
        do {
            try setGmailState(state, account: account)
            try requirePortableAuthorization(authorization)
        } catch let operationError {
            do {
                if let prior { try setGmailState(prior, account: account) }
                else { try deleteDeviceOnly(service: gmailStateService, account: account) }
            } catch let rollbackError {
                throw GmailCredentialRollbackError(operationError: operationError, rollbackError: rollbackError)
            }
            throw operationError
        }
    }

    private static func saveFullScopeGmail(account: String, data: Data, allowsReconnect: Bool = false) throws {
        let authorization = captureGmailAuthorization()
        let enabled = UserCloudSyncPolicy.isEnabled
        gmailCopyLock.lock()
        defer { gmailCopyLock.unlock() }
        if !allowsReconnect, UserDefaults.standard.bool(forKey: gmailRevocationKey(account)) {
            throw GmailCredentialPortabilityError.revoked
        }
        let prior = try gmailState(account: account)
        if !allowsReconnect, prior?.revoked == true { throw GmailCredentialPortabilityError.revoked }
        var base = prior?.baseDigest
        if enabled, authorization() {
            let portable = try getSynchronizable(service: "pieroot.todo.gmail", account: account)
            // Expiry during a blocking read cannot bind a local write to a
            // different account's portable base. Keep the last known base.
            if authorization() { base = gmailDigest(portable) }
        }
        let pending = GmailCopyState(localDigest: Data(SHA256.hash(data: data)), baseDigest: base, pending: true)
        // Journal first. If either local write or publication fails, no later
        // automatic reconciliation may overwrite the possibly committed value.
        try setGmailState(pending, account: account)
        do {
            try setDeviceOnly(service: "pieroot.todo.gmail", account: account, data: data)
        } catch let operationError {
            do {
                let current = try getDeviceOnly(service: "pieroot.todo.gmail", account: account)
                if current != data || gmailDigest(current) == prior?.localDigest {
                    // The desired replacement did not commit, or the unchanged
                    // prior value already matched it. Do not strand a valid prior
                    // token behind a journal describing a different credential.
                    if let prior { try setGmailState(prior, account: account) }
                    else { try deleteDeviceOnly(service: gmailStateService, account: account) }
                }
            } catch let rollbackError {
                throw GmailCredentialRollbackError(operationError: operationError, rollbackError: rollbackError)
            }
            throw operationError
        }
        if allowsReconnect { UserDefaults.standard.removeObject(forKey: gmailRevocationKey(account)) }
        if enabled {
            try requirePortableAuthorization(authorization)
            let portable = try getSynchronizable(service: "pieroot.todo.gmail", account: account)
            try requirePortableAuthorization(authorization)
            try publishPendingGmail(account: account, local: data, portable: portable, state: pending, authorization: authorization)
        }
    }

    private static func publishPendingGmail(account: String, local: Data, portable: Data?, state: GmailCopyState,
                                           authorization: () -> Bool) throws {
        try requirePortableAuthorization(authorization)
        guard gmailDigest(local) == state.localDigest else { throw GmailCredentialPortabilityError.conflict }
        let remoteDigest = gmailDigest(portable)
        if remoteDigest != state.localDigest {
            guard remoteDigest == state.baseDigest else { throw GmailCredentialPortabilityError.conflict }
            try requirePortableAuthorization(authorization)
            try setSynchronizable(service: "pieroot.todo.gmail", account: account, data: local)
        }
        try requirePortableAuthorization(authorization)
        try acknowledgeGmailState(.init(localDigest: state.localDigest, baseDigest: state.localDigest, pending: false),
                                  prior: state, account: account, authorization: authorization)
    }

    private static func readFullScopeGmail(account: String) throws -> Data? {
        let authorization = captureGmailAuthorization()
        let enabled = UserCloudSyncPolicy.isEnabled
        gmailCopyLock.lock()
        defer { gmailCopyLock.unlock() }
        if UserDefaults.standard.bool(forKey: gmailRevocationKey(account)) { return nil }
        let state = try gmailState(account: account)
        if state?.revoked == true { return nil }
        guard enabled else {
            // Keep legacy availability through opt-out without modifying shared data.
            if let local = try getDeviceOnly(service: "pieroot.todo.gmail", account: account) { return local }
            return try getSynchronizable(service: "pieroot.todo.gmail", account: account)
        }
        if let state, state.pending {
            let local = try getDeviceOnly(service: "pieroot.todo.gmail", account: account)
            guard gmailDigest(local) == state.localDigest else { throw GmailCredentialPortabilityError.conflict }
            return local
        }
        try requirePortableAuthorization(authorization)
        let portable = try getSynchronizable(service: "pieroot.todo.gmail", account: account)
        try requirePortableAuthorization(authorization)
        guard let portable else {
            // A previously synchronized item that disappeared is not an invitation
            // to resurrect a stale cache. Keep its bytes, but do not use/publish them.
            if state == nil { return try getDeviceOnly(service: "pieroot.todo.gmail", account: account) }
            return nil
        }
        let digest = Data(SHA256.hash(data: portable))
        let clean = GmailCopyState(localDigest: digest, baseDigest: digest, pending: false)
        if state != clean {
            let local = try getDeviceOnly(service: "pieroot.todo.gmail", account: account)
            try requirePortableAuthorization(authorization)
            if let local, local != portable, gmailDigest(local) != state?.localDigest {
                throw GmailCredentialPortabilityError.conflict
            }
            if local != portable {
                try requirePortableAuthorization(authorization)
                try setDeviceOnly(service: "pieroot.todo.gmail", account: account, data: portable)
            }
            try acknowledgeGmailState(clean, prior: state, account: account, authorization: authorization)
        }
        return portable
    }

    /// Per-item reconciliation also supports isolated credential regressions.
    /// Clean local caches always follow portable data; only journaled explicit
    /// writes can publish, and then only if the portable base is unchanged.
    static func reconcileFullScopeGmailCredential(account: String, authorization capturedAuthorization: (() -> Bool)? = nil) throws {
        let authorization = capturedAuthorization ?? captureGmailAuthorization()
        guard UserCloudSyncPolicy.isEnabled else { return }
        gmailCopyLock.lock()
        defer { gmailCopyLock.unlock() }
        if UserDefaults.standard.bool(forKey: gmailRevocationKey(account)) { return }
        let state = try gmailState(account: account)
        if state?.revoked == true { return }
        try requirePortableAuthorization(authorization)
        let local = try getDeviceOnly(service: "pieroot.todo.gmail", account: account)
        try requirePortableAuthorization(authorization)
        let portable = try getSynchronizable(service: "pieroot.todo.gmail", account: account)
        try requirePortableAuthorization(authorization)
        if let state, state.pending {
            guard let local else { throw GmailCredentialPortabilityError.conflict }
            try publishPendingGmail(account: account, local: local, portable: portable, state: state, authorization: authorization)
            return
        }
        if let portable {
            if let local, local != portable, gmailDigest(local) != state?.localDigest {
                throw GmailCredentialPortabilityError.conflict
            }
            if local != portable {
                try requirePortableAuthorization(authorization)
                try setDeviceOnly(service: "pieroot.todo.gmail", account: account, data: portable)
            }
            let digest = Data(SHA256.hash(data: portable))
            let clean = GmailCopyState(localDigest: digest, baseDigest: digest, pending: false)
            if state != clean { try acknowledgeGmailState(clean, prior: state, account: account, authorization: authorization) }
        } else if let local {
            guard state == nil else { throw GmailCredentialPortabilityError.conflict }
            let pending = GmailCopyState(localDigest: Data(SHA256.hash(data: local)), baseDigest: nil, pending: true)
            try setGmailState(pending, account: account)
            try publishPendingGmail(account: account, local: local, portable: nil, state: pending, authorization: authorization)
        }
    }

    /// 동기화 상태 무관하게 조회(SynchronizableAny)하여 전환 중에도 항상 찾음.
    static func get(service: String, account: String? = nil) -> String? {
        do { return try getChecked(service: service, account: account) }
        catch { record(error, operation: "get"); return nil }
    }

    static func getChecked(service: String, account: String? = nil) throws -> String? {
        try checkAuthenticationAttempt()
        if usesFullScopeGmailCopies(service: service) {
            let data = try readFullScopeGmail(account: account ?? "")
            guard let data else { return nil }
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainStoreError.security(errSecDecode)
            }
            return value
        }
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            if let status = testReadFailures[service] { throw securityError(status) }
            let key = testKey(service: service, account: account)
            guard let data = testDataStore[key] ?? testSynchronizableStore[key] else { return nil }
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainStoreError.security(errSecDecode)
            }
            return value
        }
        #endif
        var query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        if let account { query[kSecAttrAccount as String] = account }
        
        var result: AnyObject?
        let status = try performSecurityOperation(.read, query: query, result: &result)
        
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.security(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.security(errSecDecode)
        }
        return value
    }

    /// 삭제 — 동기화/비동기화 항목 모두 제거.
    static func deleteAny(service: String, account: String? = nil) {
        do { try deleteChecked(service: service, account: account) }
        catch { record(error, operation: "delete") }
    }

    static func deleteChecked(service: String, account: String? = nil) throws {
        try checkAuthenticationAttempt()
        guard service == "pieroot.todo.gmail" else {
            return try deleteItemsChecked(service: service, account: account)
        }
        let authorization = captureGmailAuthorization(forRevocation: true)
        let mayRevoke = UserCloudSyncPolicy.canRevokePortableCredentials
        gmailCopyLock.lock()
        defer { gmailCopyLock.unlock() }
        let accounts = account.map { [$0] } ?? knownGmailAccounts
        // Non-secret device-local guards also protect sign-out while Keychain is
        // unavailable. These revocation keys must never be cloud preferences.
        for account in accounts { UserDefaults.standard.set(true, forKey: gmailRevocationKey(account)) }
        var fenceError: (any Error)?
        for account in accounts {
            do {
                try setGmailState(.init(localDigest: nil, baseDigest: nil, pending: false, revoked: true), account: account)
            } catch {
                if fenceError == nil { fenceError = error }
            }
        }
        var credentialError: (any Error)?
        do { try deleteItemsChecked(service: service, account: account, synchronizable: false) }
        catch { credentialError = error }
        if mayRevoke {
            do {
                try requirePortableAuthorization(authorization)
                try deleteItemsChecked(service: service, account: account, synchronizable: true)
                try requirePortableAuthorization(authorization)
            } catch {
                if credentialError == nil { credentialError = error }
            }
        }
        if credentialError != nil || fenceError != nil {
            throw GmailCredentialDeletionError(credentialError: credentialError, fenceError: fenceError)
        }
    }

    private static func deleteItemsChecked(service: String, account: String?, synchronizable: Bool? = nil) throws {
        try checkAuthenticationAttempt()
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            if let status = testDeleteFailures[service] { throw securityError(status) }
            if let account {
                let key = testKey(service: service, account: account)
                if synchronizable != true {
                    testDataStore.removeValue(forKey: key)
                    testDeviceAccess.removeValue(forKey: key)
                }
                if synchronizable != false { testSynchronizableStore.removeValue(forKey: key) }
            } else {
                let prefix = "\(service)\u{1F}"
                if synchronizable != true {
                    testDataStore = testDataStore.filter { !$0.key.hasPrefix(prefix) }
                    testDeviceAccess = testDeviceAccess.filter { !$0.key.hasPrefix(prefix) }
                }
                if synchronizable != false { testSynchronizableStore = testSynchronizableStore.filter { !$0.key.hasPrefix(prefix) } }
            }
            return
        }
        #endif
        var query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service
        ]
        if let synchronizable { query[kSecAttrSynchronizable as String] = synchronizable }
        else { query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny }
        if let account { query[kSecAttrAccount as String] = account }
        
        var result: AnyObject?
        let status = try performSecurityOperation(.delete, query: query, result: &result)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.security(status)
        }
    }

    // MARK: - Device-only binary values


    nonisolated static func setDeviceOnly(
        service: String,
        account: String,
        data: Data,
        access: DeviceOnlyCredentialAccess
    ) throws {
        try checkAuthenticationAttempt()
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            if let status = testWriteFailures[service] { throw securityError(status) }
            testDataStore[testKey(service: service, account: account)] = data
            testDeviceAccess[testKey(service: service, account: account)] = access
            return
        }
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        try upsert(query: query, attributes: deviceOnlyAttributes(data: data, access: access))
    }

    private nonisolated static func deviceOnlyAttributes(
        data: Data,
        access: DeviceOnlyCredentialAccess
    ) throws -> [String: Any] {
        let protection: CFString
        let flags: SecAccessControlCreateFlags
        switch access {
        case .foregroundUserPresence:
            protection = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            flags = .userPresence
        case .backgroundAfterFirstUnlock:
            protection = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            flags = []
        }
        // Replace the whole ACL in either direction. Updating only accessibility
        // must not accidentally retain an old user-presence requirement.
        guard let control = SecAccessControlCreateWithFlags(nil, protection, flags, nil) else {
            throw KeychainStoreError.security(errSecAuthFailed)
        }
        return [kSecValueData as String: data, kSecAttrAccessControl as String: control]
    }
    /// Stores a value outside the app's iCloud-keychain sync policy.
    nonisolated static func setDeviceOnly(service: String, account: String, data: Data) throws {
        try setDeviceOnly(service: service, account: account, data: data, access: .backgroundAfterFirstUnlock)
    }

    nonisolated static func getDeviceOnly(service: String, account: String) throws -> Data? {
        try checkAuthenticationAttempt()
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            if let status = testReadFailures[service] { throw securityError(status) }
            return testDataStore[testKey(service: service, account: account)]
        }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = try performSecurityOperation(.read, query: query, result: &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.security(status) }
        guard let data = result as? Data else { throw KeychainStoreError.security(errSecDecode) }
        return data
    }

    /// UI-facing existence checks remain conservative; a protected metadata
    /// result is not proof of a readable credential.
    nonisolated static func hasDeviceOnlyItem(service: String, account: String) -> Bool {
        (try? deviceOnlyItemPresence(service: service, account: account)) == .present
    }

    /// Noninteractive, nonsecret metadata for validating a prior sync receipt.
    /// Unexpected OS failures propagate rather than masquerading as deletion.
    nonisolated static func deviceOnlyItemPresence(service: String, account: String) throws -> DeviceOnlyCredentialPresence {
        try checkAuthenticationAttempt()
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            if let status = testReadFailures[service] {
                if status == errSecInteractionNotAllowed { return .authenticationRequired }
                if status == errSecItemNotFound { return .missing }
                throw KeychainStoreError.security(status)
            }
            return testDataStore[testKey(service: service, account: account)] == nil ? .missing : .present
        }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = try performSecurityOperation(.read, query: query, noninteractiveProbe: true, result: &result)
        switch status {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed: return .authenticationRequired
        default: throw KeychainStoreError.security(status)
        }
    }

    nonisolated static func deleteDeviceOnly(service: String, account: String) throws {
        try checkAuthenticationAttempt()
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            if let status = testDeleteFailures[service] { throw securityError(status) }
            testDataStore.removeValue(forKey: testKey(service: service, account: account))
            testDeviceAccess.removeValue(forKey: testKey(service: service, account: account))
            return
        }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!
        ]
        var result: AnyObject?
        let status = try performSecurityOperation(.delete, query: query, result: &result)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.security(status)
        }
    }

    // MARK: - Explicit portable copies

    /// Low-level portable storage. Owners must gate publishing/restoring with
    /// UserCloudSyncPolicy.isEnabled. Unlike generic CRUD, these queries never
    /// match, downgrade, or delete a device-local item with the same identity.
    /// Portable items deliberately carry no device-local user-presence ACL.
    nonisolated static func setSynchronizable(service: String, account: String, data: Data) throws {
        try checkAuthenticationAttempt()
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            if let status = testWriteFailures[service] { throw securityError(status) }
            if let status = testSynchronizableWriteFailures[service] { throw securityError(status) }
            testSynchronizableStore[testKey(service: service, account: account)] = data
            return
        }
        #endif
        try upsert(query: synchronizableQuery(service: service, account: account), attributes: [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ])
    }

    nonisolated static func getSynchronizable(service: String, account: String) throws -> Data? {
        try checkAuthenticationAttempt()
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            if let status = testReadFailures[service] { throw securityError(status) }
            return testSynchronizableStore[testKey(service: service, account: account)]
        }
        #endif
        var query = synchronizableQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = try performSecurityOperation(.read, query: query, result: &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.security(status) }
        guard let data = result as? Data else { throw KeychainStoreError.security(errSecDecode) }
        return data
    }

    /// The per-account records themselves form a merge-friendly portable manifest.
    /// Enumerate attributes only; do not put a parallel secret registry in defaults.
    nonisolated static func synchronizableAccounts(service: String) throws -> [String] {
        try checkAuthenticationAttempt()
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            if let status = testReadFailures[service] { throw securityError(status) }
            let prefix = "\(service)\u{1F}"
            return testSynchronizableStore.keys.compactMap {
                $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil
            }.sorted()
        }
        #endif
        var query = synchronizableQuery(service: service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        let status = try performSecurityOperation(.read, query: query, result: &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainStoreError.security(status) }
        guard let items = result as? [[String: Any]] else {
            throw KeychainStoreError.security(errSecDecode)
        }
        return try items.map {
            guard let account = $0[kSecAttrAccount as String] as? String else {
                throw KeychainStoreError.security(errSecDecode)
            }
            return account
        }.sorted()
    }

    /// Explicit disconnect only. Opting out of sync must never call this API.
    nonisolated static func deleteSynchronizable(service: String, account: String) throws {
        try checkAuthenticationAttempt()
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            if let status = testDeleteFailures[service] { throw securityError(status) }
            testSynchronizableStore.removeValue(forKey: testKey(service: service, account: account))
            return
        }
        #endif
        var result: AnyObject?
        let status = try performSecurityOperation(.delete, query: synchronizableQuery(service: service, account: account), result: &result)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.security(status)
        }
    }

    private nonisolated static func synchronizableQuery(service: String, account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: true
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    // MARK: - 동기화 정책 마이그레이션

    /// Compatibility entrypoint with the same safe full-scope gates. No raw
    /// preference can authorize upload or mutate shared items on local opt-out.
    /// New orchestration uses the throwing entrypoint to surface copy failures.
    static func applySyncPolicy() {
        logger.info("Applying keychain sync policy migration")
        do { try applyFullSyncPolicyChecked() }
        catch { record(error, operation: "fullSyncPolicy") }
        do { try MailAnalysisLedgerKeyStore.applyFullSyncPolicy() }
        catch { record(error, operation: "ledgerSyncPolicy") }
    }

    /// Explicit full-scope Gmail copy/restore. Disabled is a strict no-op; callers
    /// invoke this on enable/foreground, not a continuous secret-reading loop.
    /// A successful Keychain write is local commit evidence, not remote delivery.
    /// IMAP and identity families have their own checked lifecycle entrypoints.
    static func applyFullSyncPolicyChecked() throws {
        let authorization = captureGmailAuthorization()
        guard UserCloudSyncPolicy.isEnabled else { return }
        try requirePortableAuthorization(authorization)
        for account in knownGmailAccounts {
            try reconcileFullScopeGmailCredential(account: account, authorization: authorization)
        }
        try requirePortableAuthorization(authorization)
    }

    private static let knownGmailAccounts = ["oauth_tokens", "access_token", "refresh_token", "id_token",
                                            "access_token_expires_at", "scope_version"]
}
