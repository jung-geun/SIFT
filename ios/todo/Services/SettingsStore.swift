import Foundation
import Combine
import SwiftData

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// Build capability, independent of the user's persisted sync preference.
    #if SIFT_LOCAL_ONLY
    nonisolated static let supportsICloud = false
    #else
    nonisolated static let supportsICloud = true
    #endif

    /// Effective sync policy for cloud operations and synchronizable credentials.
    /// Keep the raw preference intact so local-only builds retain store selection.
    nonisolated static var isICloudSyncEnabled: Bool {
        supportsICloud && UserDefaults.standard.bool(forKey: "pieroot.todo.iCloudSyncEnabled")
    }
    static let syncableKeys: [String] = [
        "pieroot.todo.onDeviceLLMEnabled",
        "selectedAIProvider",
        "pieroot.todo.emailAutoAnalysisEnabled",
        "pieroot.todo.emailRefreshHour",
        EmailAnalysisLookbackPolicy.lookbackSettingKey,
        "pieroot.todo.calendarAutoRegister",
        "pieroot.todo.calendarCompletionAction",
        "pieroot.todo.suppressedSenders",
        "pieroot.todo.dismissedMessageIDs",
        "pieroot.todo.analyzedMessageIDs",
        "pieroot.todo.senderDeletionCounts",
        "pieroot.todo.betaFeaturesEnabled",
        "pieroot.todo.meetingVoiceProcessingEnabled",
        "pieroot.todo.meetingAutoRefineEnabled"
    ]

    static let betaFeaturesKey = "pieroot.todo.betaFeaturesEnabled"
    nonisolated static let betaFoundationModelsEnabledKey = "pieroot.todo.beta.foundationModelsEnabled"
    nonisolated static let betaOnDeviceModelEnabledKey = "pieroot.todo.beta.onDeviceModelEnabled"
    nonisolated static let betaOpenAIEnabledKey = "pieroot.todo.beta.openAIEnabled"
    nonisolated static let betaMeetingVoiceProcessingEnabledKey = "pieroot.todo.beta.meetingVoiceProcessingEnabled"
    nonisolated static let betaMeetingDiarizationEnabledKey = "pieroot.todo.beta.meetingDiarizationEnabled"
    nonisolated static let betaLayaEnabledKey = "pieroot.todo.beta.layaEnabled"
    nonisolated static let betaMeetingAdvancedTranscriptionEnabledKey = "pieroot.todo.beta.meetingAdvancedTranscriptionEnabled"
    nonisolated static let betaSelectedProviderKey = "pieroot.todo.beta.selectedProvider"
    nonisolated static let betaLegacySelectionMigratedKey = "pieroot.todo.beta.legacySelectionMigrated.v1"

    nonisolated static func betaProviderEnabled(_ provider: BetaProvider) -> Bool {
        let key: String
        switch provider {
        case .foundationModels: key = betaFoundationModelsEnabledKey
        case .onDevice: key = betaOnDeviceModelEnabledKey
        case .openAI: key = betaOpenAIEnabledKey
        case .laya: key = betaLayaEnabledKey
        }
        let defaults = UserDefaults.standard
        if provider == .foundationModels, defaults.object(forKey: key) == nil {
            return true
        }
        return defaults.bool(forKey: key)
    }

    nonisolated static func betaProviderAccess() -> BetaProviderAccess {
        BetaProviderAccess(
            foundationModelsEnabled: betaProviderEnabled(.foundationModels),
            onDeviceEnabled: betaProviderEnabled(.onDevice),
            openAIEnabled: betaProviderEnabled(.openAI),
            layaEnabled: betaProviderEnabled(.laya),
            meetingVoiceProcessingEnabled: UserDefaults.standard.bool(
                forKey: betaMeetingVoiceProcessingEnabledKey
            )
        )
    }

    nonisolated static func betaSelectedProvider() -> PersonaAIProvider? {
        if let raw = UserDefaults.standard.string(forKey: betaSelectedProviderKey),
           let provider = PersonaAIProvider(rawValue: raw) {
            return provider
        }
        return betaProviderEnabled(.foundationModels) ? .foundationModels : nil
    }

    func setBetaProvider(_ provider: BetaProvider, enabled: Bool) {
        let key: String
        switch provider {
        case .foundationModels: key = Self.betaFoundationModelsEnabledKey
        case .onDevice: key = Self.betaOnDeviceModelEnabledKey
        case .openAI: key = Self.betaOpenAIEnabledKey
        case .laya: key = Self.betaLayaEnabledKey
        }
        local.set(enabled, forKey: key)
        if provider == .openAI, !enabled {
            OpenAIRequestRegistry.shared.cancel(generation: OpenAIConnection.shared.sessionGeneration)
        }
        normalizeBetaSelectedProvider()
        objectWillChange.send()
    }

    func setBetaSelectedProvider(_ provider: PersonaAIProvider?) {
        if let provider {
            local.set(provider.rawValue, forKey: Self.betaSelectedProviderKey)
        } else {
            local.removeObject(forKey: Self.betaSelectedProviderKey)
        }
        objectWillChange.send()
    }

    func migrateLegacyBetaSelectedProviderIfNeeded() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.betaLegacySelectionMigratedKey) {
            let raw = defaults.string(forKey: Self.betaSelectedProviderKey)
            let existingValidProvider = raw.flatMap(PersonaAIProvider.init(rawValue:))
            if existingValidProvider == nil && Self.betaProviderEnabled(.foundationModels) {
                setBetaSelectedProvider(.foundationModels)
            }
            defaults.set(true, forKey: Self.betaLegacySelectionMigratedKey)
        }
    }

    func normalizeBetaSelectedProvider() {
        let access = Self.betaProviderAccess()
        if let selected = Self.betaSelectedProvider(), access.isEnabled(selected) {
            return
        }

        let preferred = [PersonaAIProvider.foundationModels, .onDevice, .openAI, .laya]
            .first(where: access.isEnabled)
        setBetaSelectedProvider(preferred)
    }
    #if DEBUG
    func resetBetaFeaturesForUITest() {
        [
            Self.betaFoundationModelsEnabledKey,
            Self.betaOnDeviceModelEnabledKey,
            Self.betaOpenAIEnabledKey,
            Self.betaMeetingVoiceProcessingEnabledKey,
            Self.betaMeetingDiarizationEnabledKey,
            Self.betaMeetingAdvancedTranscriptionEnabledKey,
            Self.betaLayaEnabledKey,
            Self.betaSelectedProviderKey,
            Self.betaLegacySelectionMigratedKey
        ].forEach(local.removeObject(forKey:))
        objectWillChange.send()
    }

    func seedLegacyAISettingsForUITest() {
        local.set(true, forKey: Self.betaFeaturesKey)
        local.set(true, forKey: "pieroot.todo.onDeviceLLMEnabled")
        local.set("gemini", forKey: "selectedAIProvider")
        objectWillChange.send()
    }
    #endif

    #if DEBUG
    nonisolated private static var isTestProcess: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    nonisolated static func setTestCloudValue(_ value: Any?, forKey key: String) {
        let testKey = "pieroot.todo.testCloud.\(key)"
        if let value {
            UserDefaults.standard.set(value, forKey: testKey)
        } else {
            UserDefaults.standard.removeObject(forKey: testKey)
        }
    }

    nonisolated private static func testCloudValue(forKey key: String) -> Any? {
        UserDefaults.standard.object(forKey: "pieroot.todo.testCloud.\(key)")
    }
    #endif

    /// Unlocks opt-in features that are still being validated. Default off.
    var betaFeaturesEnabled: Bool {
        get { get(Self.betaFeaturesKey, defaultValue: false) }
        set { set(Self.betaFeaturesKey, value: newValue) }
    }

    /// Legacy key retained only so existing stored settings can be migrated or inspected.
    static let meetingVoiceProcessingKey = "pieroot.todo.meetingVoiceProcessingEnabled"

    /// On-device voice processing is a device-local beta opt-in.
    var meetingVoiceProcessingEnabled: Bool {
        get { Self.betaProviderAccess().meetingVoiceProcessingEnabled }
        set {
            local.set(newValue, forKey: Self.betaMeetingVoiceProcessingEnabledKey)
            objectWillChange.send()
        }
    }

    var effectiveMeetingVoiceProcessingEnabled: Bool {
        Self.betaProviderAccess().meetingVoiceProcessingEnabled
    }

    /// Device-local speaker diarization opt-in. Default off; never synced to iCloud.
    /// Enabling this setting does not install or download a model.
    var meetingDiarizationEnabled: Bool {
        get { local.bool(forKey: Self.betaMeetingDiarizationEnabledKey) }
        set {
            local.set(newValue, forKey: Self.betaMeetingDiarizationEnabledKey)
            objectWillChange.send()
        }
    }

    /// Permission to use diarization, independent of AI provider selection.
    /// Callers must also require an installed local speaker model before processing.
    var effectiveMeetingDiarizationEnabled: Bool {
        meetingDiarizationEnabled
    }

    /// Device-local opt-in for saved-audio Whisper transcription after Apple
    /// live results are persisted. Installing a model does not enable it.
    var meetingAdvancedTranscriptionEnabled: Bool {
        get { local.bool(forKey: Self.betaMeetingAdvancedTranscriptionEnabledKey) }
        set {
            local.set(newValue, forKey: Self.betaMeetingAdvancedTranscriptionEnabledKey)
            objectWillChange.send()
        }
    }

    static let meetingAutoRefineKey = "pieroot.todo.meetingAutoRefineEnabled"

    /// After a recording finalizes or is re-transcribed, run the AFM transcript
    /// correction pass automatically (typo/keyword patching → better summary).
    /// Default on; when off, correction only runs from the manual button.
    var meetingAutoRefineEnabled: Bool {
        get { get(Self.meetingAutoRefineKey, defaultValue: true) }
        set { set(Self.meetingAutoRefineKey, value: newValue) }
    }

    static let legacyMemoryKeys = [
        "pieroot.todo.memorySummary",
        "pieroot.todo.memoryInsights",
        "pieroot.todo.memoryDate",
        "pieroot.todo.memoryFastTags",
        "pieroot.todo.memoryOverdueRate",
        "pieroot.todo.memoryProductiveHour"
    ]

    private let local = UserDefaults.standard
    private let global: NSUbiquitousKeyValueStore? = {
        guard SettingsStore.supportsICloud else { return nil }
        #if DEBUG
        if SettingsStore.isTestProcess { return nil }
        #endif
        return .default
    }()

    private init() {
        guard let global else { return }
        // iCloud 변경 사항 알림 구독
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(globalStoreDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: global
        )
        global.synchronize()
    }

    nonisolated static func selectedProvider() -> PersonaAIProvider {
        let key = "selectedAIProvider"
        let local = UserDefaults.standard
        let defaultValue = PersonaAIProvider.foundationModels.rawValue
        let normalize: (String?) -> String = { raw in
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? defaultValue : trimmed
        }

        if !supportsICloud || local.bool(forKey: "\(key).isLocal") {
            return PersonaAIProvider(rawValue: normalize(local.string(forKey: key))) ?? .foundationModels
        }

        #if DEBUG
        let cloudValue: String?
        if isTestProcess {
            cloudValue = testCloudValue(forKey: key) as? String
        } else {
            cloudValue = NSUbiquitousKeyValueStore.default.string(forKey: key)
        }
        #else
        let cloudValue = NSUbiquitousKeyValueStore.default.string(forKey: key)
        #endif
        let raw = normalize(cloudValue ?? local.string(forKey: key))
        return PersonaAIProvider(rawValue: raw) ?? .foundationModels
    }

    nonisolated static func emailAnalysisLookbackDays() -> Int {
        let key = EmailAnalysisLookbackPolicy.lookbackSettingKey
        let local = UserDefaults.standard
        let rawValue: Int

        if !supportsICloud || local.bool(forKey: "\(key).isLocal") {
            rawValue = (local.object(forKey: key) as? NSNumber)?.intValue
                ?? EmailAnalysisLookbackPolicy.defaultLookbackDays
        } else {
            #if DEBUG
            let cloudValue = isTestProcess ? testCloudValue(forKey: key) : NSUbiquitousKeyValueStore.default.object(forKey: key)
            #else
            let cloudValue = NSUbiquitousKeyValueStore.default.object(forKey: key)
            #endif
            rawValue = (cloudValue as? NSNumber)?.intValue
                ?? (local.object(forKey: key) as? NSNumber)?.intValue
                ?? EmailAnalysisLookbackPolicy.defaultLookbackDays
        }
        return EmailAnalysisLookbackPolicy.normalizedLookbackDays(rawValue)
    }

    static func legacyMemoryAnalysis(from valueForKey: (String) -> Any?) -> MemoryAnalysis? {
        let summary = stringValue(valueForKey("pieroot.todo.memorySummary"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let insights = stringArrayValue(valueForKey("pieroot.todo.memoryInsights"))
        let fastTags = stringArrayValue(valueForKey("pieroot.todo.memoryFastTags"))

        guard !summary.isEmpty || !insights.isEmpty else {
            return nil
        }

        let createdAt = dateValue(valueForKey("pieroot.todo.memoryDate")) ?? Date()
        let overdueRate = min(max(doubleValue(valueForKey("pieroot.todo.memoryOverdueRate")) ?? 0, 0), 1)
        let productiveHour = hourValue(valueForKey("pieroot.todo.memoryProductiveHour"))

        let analysis = MemoryAnalysis(
            summary: summary,
            insights: insights,
            fastTags: fastTags,
            overdueRate: overdueRate,
            productiveHour: productiveHour,
            recordTitle: AppLanguage.localized("memory.legacy.title", defaultValue: "Previous Behavior Pattern Analysis", language: AppLanguage.current),
            accessScopeSummary: AppLanguage.localized("memory.legacy.scope", defaultValue: "Migrated from legacy settings storage", language: AppLanguage.current),
            processorDescription: AppLanguage.localized("memory.legacy.processor", defaultValue: "Legacy Storage", language: AppLanguage.current)
        )
        analysis.createdAt = createdAt
        return analysis
    }

    private static func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        return ""
    }

    private static func stringArrayValue(_ value: Any?) -> [String] {
        let rawItems: [String]
        if let values = value as? [String] {
            rawItems = values
        } else if let values = value as? NSArray {
            rawItems = values.compactMap { $0 as? String }
        } else {
            let raw = stringValue(value)
            rawItems = raw.isEmpty ? [] : raw.components(separatedBy: .newlines)
        }
        return rawItems
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let value = value as? Date { return value }
        if let value = value as? TimeInterval { return Date(timeIntervalSince1970: value) }
        if let value = value as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue) }
        let raw = stringValue(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) {
            return Date(timeIntervalSince1970: seconds)
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        let raw = stringValue(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : Double(raw)
    }

    private static func hourValue(_ value: Any?) -> Int? {
        guard let raw = doubleValue(value) else { return nil }
        let hour = Int(raw)
        return (0...23).contains(hour) ? hour : nil
    }

    @objc private func globalStoreDidChange(_ notification: Notification) {
        guard let global else { return }
        let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int

        migrateLegacyMemoryKeysIntoSwiftDataIfNeeded()

        if reason == NSUbiquitousKeyValueStoreInitialSyncChange || reason == NSUbiquitousKeyValueStoreAccountChange {
            print("[SettingsStore] iCloud 초기 동기화 또는 계정 변경 감지: 전체 키 동기화 진행")
            for key in Self.syncableKeys {
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
            let changedKeys = Set(keys)
            for key in Self.syncableKeys where changedKeys.contains(key) {
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

    func migrateLegacyMemoryKeysIntoSwiftDataIfNeeded() {
        global?.synchronize()
        guard let legacyAnalysis = Self.legacyMemoryAnalysis(from: { key in
            self.global?.object(forKey: key) ?? self.local.object(forKey: key)
        }) else {
            cleanupLocalLegacyMemoryKeys()
            MemoryService.shared.invalidateCache()
            return
        }

        do {
            let context = ModelContext(AppDataContainer.shared.container)
            let descriptor = FetchDescriptor<MemoryAnalysis>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let existing = try context.fetch(descriptor)
            let alreadyMigrated = existing.contains { analysis in
                analysis.summary == legacyAnalysis.summary
                    && abs(analysis.createdAt.timeIntervalSince(legacyAnalysis.createdAt)) <= 1
            }

            if !alreadyMigrated {
                context.insert(legacyAnalysis)
                try context.save()
            }

            cleanupAllLegacyMemoryKeys()
            global?.synchronize()
            MemoryService.shared.invalidateCache()
        } catch {
            print("[SettingsStore] 레거시 행동 패턴 분석 이전 실패: \(error)")
        }
    }

    private func cleanupLocalLegacyMemoryKeys() {
        for key in Self.legacyMemoryKeys {
            local.removeObject(forKey: key)
            local.removeObject(forKey: "\(key).isLocal")
        }
    }

    private func cleanupAllLegacyMemoryKeys() {
        cleanupLocalLegacyMemoryKeys()
        for key in Self.legacyMemoryKeys {
            global?.removeObject(forKey: key)
        }
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
            return global?.object(forKey: key) as? T ?? local.object(forKey: key) as? T ?? defaultValue
        }
    }

    /// 설정값 글로벌(iCloud) 저장. 미지원 빌드에서는 로컬 저장으로 전환한다.
    func setGlobal<T>(_ key: String, value: T) {
        guard Self.supportsICloud else {
            setLocal(key, value: value)
            return
        }
        local.set(false, forKey: "\(key).isLocal")

        if let val = value as? Bool {
            global?.set(val, forKey: key)
        } else if let val = value as? Int {
            global?.set(val, forKey: key)
        } else if let val = value as? Double {
            global?.set(val, forKey: key)
        } else if let val = value as? String {
            global?.set(val, forKey: key)
        } else {
            global?.set(value, forKey: key)
        }
        global?.synchronize()

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
        if Self.isICloudSyncEnabled && !isLocal(key: key) {
            setGlobal(key, value: value)
        } else {
            setLocal(key, value: value)
        }
    }

    /// 그동안 로컬 UserDefaults에만 저장되어 있던 설정들을 iCloud로 모두 업로드합니다.
    func uploadLocalSettingsToCloud() {
        guard Self.supportsICloud else { return }
        for key in Self.syncableKeys {
            // 로컬 모드가 아닌 경우에만 클라우드에 업로드
            if !isLocal(key: key) {
                if let localValue = local.object(forKey: key) {
                    setGlobal(key, value: localValue)
                }
            }
        }
        global?.synchronize()
    }
}
