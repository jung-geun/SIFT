import Foundation
import Security
import OSLog

/// 앱의 모든 민감 정보(Gmail 토큰 등 보안정보) Keychain 접근을 단일화.
///
/// **정책 요약:**
/// - 동기화 가능 여부: 앱 iCloud 토글(`pieroot.todo.iCloudSyncEnabled`)에 연동.
///   ON → `synchronizable=true` (iCloud Keychain, E2E 암호화, 같은 Apple ID 기기 동기화)
///   OFF → `synchronizable=false` (ThisDeviceOnly, 완전 로컬)
/// - 접근성: 배경 BGTask 메인 스레드에서 토큰을 읽을 수 있도록
///   `AfterFirstUnlock` 계열 사용 (기본값 `WhenUnlocked` 대신).
/// - 마이그레이션: 동기화 상태 변경 중에도 기존 데이터를 항상 찾을 수 있도록
///   `get`과 `delete`는 `kSecAttrSynchronizableAny`를 사용.
/// - 저장 전: 동기화/비동기화 잔존 항목 모두 삭제(정책 혼선 차단).
enum KeychainStore {
    private static let logger = Logger(subsystem: "pieroot.todo", category: "KeychainStore")

    // MARK: - 동기화 정책

    private static let iCloudSyncKey = "pieroot.todo.iCloudSyncEnabled"

    private static var shouldSync: Bool {
        UserDefaults.standard.bool(forKey: iCloudSyncKey)
    }

    /// 동기화 정책에 따른 접근성 클래스.
    /// synchronizable 항목은 ThisDeviceOnly 플래그와 함께 사용할 수 없음.
    private static func accessibility(sync: Bool) -> CFString {
        sync ? kSecAttrAccessibleAfterFirstUnlock
             : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    // MARK: - CRUD

    /// 저장 (현재 동기화 정책 적용). 기존 항목 상태 무관하게 먼저 삭제.
    static func set(service: String, account: String? = nil, value: String) {
        logger.debug("Setting keychain item: service=\(service), account=\(account ?? "nil")")
        guard let data = value.data(using: .utf8) else { return }
        let sync = shouldSync
        deleteAny(service: service, account: account)       // 잔존 항목 정리
        
        var attrs: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrSynchronizable as String: sync ? kCFBooleanTrue! : kCFBooleanFalse!,
            kSecAttrAccessible as String:     accessibility(sync: sync),
            kSecValueData as String:          data
        ]
        if let account { attrs[kSecAttrAccount as String] = account }
        
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Failed to add keychain item: status \(status)")
        }
    }

    /// 동기화 상태 무관하게 조회(SynchronizableAny)하여 전환 중에도 항상 찾음.
    static func get(service: String, account: String? = nil) -> String? {
        logger.debug("Getting keychain item: service=\(service), account=\(account ?? "nil")")
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
        
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Failed to get keychain item: status \(status)")
        }
        return nil
    }

    /// 삭제 — 동기화/비동기화 항목 모두 제거.
    static func deleteAny(service: String, account: String? = nil) {
        logger.debug("Deleting keychain item: service=\(service), account=\(account ?? "nil")")
        var query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        if let account { query[kSecAttrAccount as String] = account }
        
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Failed to delete keychain item: status \(status)")
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
            (service: "pieroot.todo.gmail", account: "access_token"),
            (service: "pieroot.todo.gmail", account: "refresh_token")
        ]
    }
}
