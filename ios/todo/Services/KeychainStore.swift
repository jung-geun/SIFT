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
}

enum DeviceOnlyCredentialAccess: Sendable {
    case foregroundUserPresence
    case backgroundAfterFirstUnlock
}

nonisolated enum KeychainStore {
    private static let logger = Logger(subsystem: "pieroot.todo", category: "KeychainStore")

    #if DEBUG
    nonisolated private static let testStoreLock = NSLock()
    nonisolated(unsafe) private static var testStore: [String: String] = [:]
    nonisolated(unsafe) private static var testDataStore: [String: Data] = [:]
    nonisolated(unsafe) private static var testWriteFailures: [String: OSStatus] = [:]

    nonisolated static func setWriteFailureForTesting(service: String, status: OSStatus?) {
        testStoreLock.lock()
        testWriteFailures[service] = status
        testStoreLock.unlock()
    }

    /// Explicit test seam. Unit-test hosts provide XCTestConfigurationFilePath;
    /// UI tests opt in through SIFT_UI_TESTING. Production always uses
    /// Security.framework.
    nonisolated private static var usesTestStore: Bool {
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
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            if let status = testWriteFailures[service] { throw KeychainStoreError.security(status) }
            testStore[testKey(service: service, account: account)] = value
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
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainStoreError.security(status) }
        let item = query.merging(attributes) { _, new in new }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retry = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard retry == errSecSuccess else { throw KeychainStoreError.security(retry) }
        } else if addStatus != errSecSuccess {
            throw KeychainStoreError.security(addStatus)
        }
    }

    private static func record(_ error: Error, operation: String) {
        DiagnosticRecorder.shared.record(error: error, component: "security.keychain", operation: operation)
        logger.error("Keychain \(operation) failed")
    }

    /// 동기화 상태 무관하게 조회(SynchronizableAny)하여 전환 중에도 항상 찾음.
    static func get(service: String, account: String? = nil) -> String? {
        do { return try getChecked(service: service, account: account) }
        catch { record(error, operation: "get"); return nil }
    }

    static func getChecked(service: String, account: String? = nil) throws -> String? {
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            return testStore[testKey(service: service, account: account)]
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
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
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
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            if let account {
                testStore.removeValue(forKey: testKey(service: service, account: account))
                testDataStore.removeValue(forKey: testKey(service: service, account: account))
            } else {
                let prefix = "\(service)\u{1F}"
                testStore = testStore.filter { !$0.key.hasPrefix(prefix) }
                testDataStore = testDataStore.filter { !$0.key.hasPrefix(prefix) }
            }
            testStoreLock.unlock()
            return
        }
        #endif
        var query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        if let account { query[kSecAttrAccount as String] = account }
        
        let status = SecItemDelete(query as CFDictionary)
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
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            if let status = testWriteFailures[service] { throw KeychainStoreError.security(status) }
            testDataStore[testKey(service: service, account: account)] = data
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
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
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
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.security(status) }
        guard let data = result as? Data else { throw KeychainStoreError.security(errSecDecode) }
        return data
    }

    /// Checks for a device-only item without reading secret bytes or presenting
    /// a Keychain authentication prompt.
    nonisolated static func hasDeviceOnlyItem(service: String, account: String) -> Bool {
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            defer { testStoreLock.unlock() }
            return testDataStore[testKey(service: service, account: account)] != nil
        }
        #endif
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    nonisolated static func deleteDeviceOnly(service: String, account: String) throws {
        #if DEBUG
        if usesTestStore {
            testStoreLock.lock()
            testDataStore.removeValue(forKey: testKey(service: service, account: account))
            testStoreLock.unlock()
            return
        }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.security(status)
        }
    }

    // MARK: - 동기화 정책 마이그레이션

    /// 동기화 토글 변경 시 호출: 알려진 모든 시크릿을 현재 정책으로 재저장.
    /// - ON 전환: synchronizable=true로 승격 → iCloud Keychain 동기화 시작.
    /// - OFF 전환: ThisDeviceOnly로 강등 + 원격 삭제 signal
    ///   → 다른 기기에서 해당 항목이 삭제됨.
    ///
    /// **호출 시점:** UserDefaults에 새 값이 반영된 직후 호출해야 
    /// `shouldSync`가 올바른 값을 읽어 재저장함.
    static func applySyncPolicy() {
        logger.info("Applying keychain sync policy migration")
        for item in knownSecretItems() {
            if let value = get(service: item.service, account: item.account) {
                set(service: item.service, account: item.account, value: value)
            }
        }
    }

    /// 정책 재적용 대상 시크릿 목록.
    private static func knownSecretItems() -> [(service: String, account: String?)] {
        [
            (service: "pieroot.todo.gmail", account: "oauth_tokens"),
            (service: "pieroot.todo.gmail", account: "access_token"),
            (service: "pieroot.todo.gmail", account: "refresh_token"),
            (service: "pieroot.todo.gmail", account: "id_token"),
            (service: "pieroot.todo.gmail", account: "access_token_expires_at"),
            (service: "pieroot.todo.gmail", account: "scope_version")
        ]
    }
}
