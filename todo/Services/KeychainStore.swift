import Foundation
import Security

/// 앱의 모든 민감 정보(Gmail 토큰, AI API 키) Keychain 접근을 단일화.
///
/// **정책 요약:**
/// - 동기화 가능 여부: 앱 iCloud 토글(`pieroot.todo.iCloudSyncEnabled`)에 연동.
///   ON → `synchronizable=true` (iCloud Keychain, E2E 암호화, 사용자 기기 전용)
///   OFF → `synchronizable=false` (ThisDeviceOnly, 완전 로컬)
/// - 접근성: 배경 BGTask 메일 새로고침이 잠금 상태에서 토큰을 읽어야 하므로
///   `AfterFirstUnlock` 계열 사용 (기본값 `WhenUnlocked` 대신).
/// - 읽기: `SynchronizableAny`로 조회하여 동기화 상태 변경 중에도 항상 찾음.
/// - 저장 전: 동기화/비동기화 잔존 항목 모두 삭제(정책 혼선 차단).
enum KeychainStore {

    // MARK: - 동기화 정책

    private static let iCloudSyncKey = "pieroot.todo.iCloudSyncEnabled"

    private static var shouldSync: Bool {
        UserDefaults.standard.bool(forKey: iCloudSyncKey)
    }

    /// 동기화 정책에 맞는 접근성 클래스.
    /// synchronizable 항목은 ThisDeviceOnly를 사용할 수 없으므로 분기.
    private static func accessibility(sync: Bool) -> CFString {
        sync ? kSecAttrAccessibleAfterFirstUnlock
             : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    // MARK: - CRUD

    /// 저장 (현재 동기화 정책 적용). 기존 항목은 상태 무관하게 먼저 삭제.
    static func set(service: String, account: String? = nil, value: String) {
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
        SecItemAdd(attrs as CFDictionary, nil)
    }

    /// 읽기 — 동기화 상태 무관하게 조회(SynchronizableAny)하여 전환 중에도 항상 찾음.
    static func get(service: String, account: String? = nil) -> String? {
        var query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 삭제 — 동기화/비동기화 항목 모두 제거.
    static func deleteAny(service: String, account: String? = nil) {
        var query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        if let account { query[kSecAttrAccount as String] = account }
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - 동기화 정책 마이그레이션

    /// 동기화 토글 변경 시 호출: 알려진 모든 시크릿을 현재 정책으로 재저장.
    /// - ON 전환: synchronizable=true로 승격 → iCloud Keychain 동기화 시작.
    /// - OFF 전환: ThisDeviceOnly로 강등 + 이전 synchronizable 항목 삭제 전파
    ///   → 다른 기기의 iCloud Keychain에서 해당 항목이 회수됨.
    ///
    /// **호출 시점:** `@AppStorage`/`UserDefaults`에 새 값이 반영된 직후 호출해야
    /// `shouldSync`가 올바른 값을 읽음.
    static func applySyncPolicy() {
        for item in knownSecretItems() {
            if let value = get(service: item.service, account: item.account) {
                set(service: item.service, account: item.account, value: value)
            }
        }
    }

    /// 정책 재적용 대상 시크릿 인벤토리.
    private static func knownSecretItems() -> [(service: String, account: String?)] {
        var items: [(service: String, account: String?)] = [
            (service: "pieroot.todo.gmail", account: "access_token"),
            (service: "pieroot.todo.gmail", account: "refresh_token")
        ]
        for p in PersonaAIProvider.allCases where p.requiresAPIKey {
            items.append((service: p.keychainKey, account: nil))
        }
        return items
    }
}
