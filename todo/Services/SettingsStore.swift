import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    
    private let local = UserDefaults.standard
    private let global = NSUbiquitousKeyValueStore.default
    
    private init() {
        // iCloud 변경 사항 알림 구독
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(globalStoreDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: global
        )
        global.synchronize()
    }
    
    @objc private func globalStoreDidChange(_ notification: Notification) {
        let syncableKeys = [
            "pieroot.todo.onDeviceLLMEnabled",
            "selectedAIProvider",
            "pieroot.todo.emailAutoAnalysisEnabled",
            "pieroot.todo.emailRefreshHour",
            "pieroot.todo.emailLookbackDays",
            "pieroot.todo.calendarAutoRegister",
            "pieroot.todo.calendarCompletionAction",
            "pieroot.todo.suppressedSenders",
            "pieroot.todo.dismissedMessageIDs",
            "pieroot.todo.senderDeletionCounts",
            "pieroot.todo.memorySummary",
            "pieroot.todo.memoryInsights",
            "pieroot.todo.memoryDate",
            "pieroot.todo.memoryFastTags",
            "pieroot.todo.memoryOverdueRate",
            "pieroot.todo.memoryProductiveHour"
        ]

        let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        
        if reason == NSUbiquitousKeyValueStoreInitialSyncChange || reason == NSUbiquitousKeyValueStoreAccountChange {
            print("[SettingsStore] iCloud 초기 동기화 또는 계정 변경 감지: 전체 키 동기화 진행")
            for key in syncableKeys {
                if !isLocal(key: key) {
                    if let value = global.object(forKey: key) {
                        local.set(value, forKey: key)
                    } else {
                        local.removeObject(forKey: key)
                    }
                }
            }
        } else if let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] {
            print("[SettingsStore] iCloud 일부 키 변경 감지: \(keys)")
            for key in keys {
                if !isLocal(key: key) {
                    if let value = global.object(forKey: key) {
                        local.set(value, forKey: key)
                    } else {
                        local.removeObject(forKey: key)
                    }
                }
            }
        }
        objectWillChange.send()
    }
    
    /// 특정 키가 이 장비에서 로컬 설정을 사용하는지 여부
    func isLocal(key: String) -> Bool {
        local.bool(forKey: "\(key).isLocal")
    }
    
    /// 특정 키의 로컬 모드 여부를 저장
    func setLocal(key: String, isLocal: Bool) {
        local.set(isLocal, forKey: "\(key).isLocal")
        objectWillChange.send()
    }
    
    /// 설정값 조회 (로컬 모드이면 UserDefaults, 아니면 iCloud -> 로컬 캐시 -> 기본값 순으로 폴백)
    func get<T>(_ key: String, defaultValue: T) -> T {
        if isLocal(key: key) {
            return local.object(forKey: key) as? T ?? defaultValue
        } else {
            return global.object(forKey: key) as? T ?? local.object(forKey: key) as? T ?? defaultValue
        }
    }
    
    /// 설정값 글로벌(iCloud) 저장 (로컬 모드 해제 및 iCloud 동기화 후 UserDefaults 로컬 캐싱)
    func setGlobal<T>(_ key: String, value: T) {
        local.set(false, forKey: "\(key).isLocal")
        
        if let val = value as? Bool {
            global.set(val, forKey: key)
        } else if let val = value as? Int {
            global.set(val, forKey: key)
        } else if let val = value as? Double {
            global.set(val, forKey: key)
        } else if let val = value as? String {
            global.set(val, forKey: key)
        } else {
            global.set(value, forKey: key)
        }
        global.synchronize()
        
        // 오프라인 대비 로컬 캐싱
        local.set(value, forKey: key)
        objectWillChange.send()
    }
    
    /// 설정값 로컬(이 기기 전용) 저장 (로컬 모드 설정 및 UserDefaults 단독 저장)
    func setLocal<T>(_ key: String, value: T) {
        local.set(true, forKey: "\(key).isLocal")
        local.set(value, forKey: key)
        objectWillChange.send()
    }
    
    /// 설정값 저장 (iCloud 활성화 여부 및 개별 로컬 설정에 따라 자동 결정)
    func set<T>(_ key: String, value: T) {
        let useICloud = local.bool(forKey: "pieroot.todo.iCloudSyncEnabled")
        if useICloud && !isLocal(key: key) {
            setGlobal(key, value: value)
        } else {
            setLocal(key, value: value)
        }
    }
    
    /// 그동안 로컬 UserDefaults에만 저장되어 있던 설정들을 iCloud로 모두 업로드합니다.
    func uploadLocalSettingsToCloud() {
        let syncableKeys = [
            "pieroot.todo.onDeviceLLMEnabled",
            "selectedAIProvider",
            "pieroot.todo.emailAutoAnalysisEnabled",
            "pieroot.todo.emailRefreshHour",
            "pieroot.todo.emailLookbackDays",
            "pieroot.todo.calendarAutoRegister",
            "pieroot.todo.calendarCompletionAction",
            "pieroot.todo.suppressedSenders",
            "pieroot.todo.dismissedMessageIDs",
            "pieroot.todo.senderDeletionCounts",
            "pieroot.todo.memorySummary",
            "pieroot.todo.memoryInsights",
            "pieroot.todo.memoryDate",
            "pieroot.todo.memoryFastTags",
            "pieroot.todo.memoryOverdueRate",
            "pieroot.todo.memoryProductiveHour"
        ]
        
        for key in syncableKeys {
            // 로컬 모드가 아닌 경우에만 클라우드에 업로드
            if !isLocal(key: key) {
                if let localValue = local.object(forKey: key) {
                    setGlobal(key, value: localValue)
                }
            }
        }
        global.synchronize()
    }
}

