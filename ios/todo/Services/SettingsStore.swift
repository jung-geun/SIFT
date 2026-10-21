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

    /// Only expanded, account-bound consent authorizes portable credentials.
    nonisolated static var isICloudSyncEnabled: Bool { UserCloudSyncPolicy.isEnabled }
    static let betaFeaturesKey = "pieroot.todo.betaFeaturesEnabled"
    nonisolated static let betaOpenAIEnabledKey = "pieroot.todo.beta.openAIEnabled"
    nonisolated static let betaMeetingVoiceProcessingEnabledKey = "pieroot.todo.beta.meetingVoiceProcessingEnabled"
    nonisolated static let betaMeetingDiarizationEnabledKey = "pieroot.todo.beta.meetingDiarizationEnabled"
    nonisolated static let betaLayaEnabledKey = "pieroot.todo.beta.layaEnabled"
    nonisolated static let betaMeetingAdvancedTranscriptionEnabledKey = "pieroot.todo.beta.meetingAdvancedTranscriptionEnabled"
    nonisolated static let betaSelectedProviderKey = "pieroot.todo.beta.selectedProvider"
    nonisolated static let betaLegacySelectionMigratedKey = "pieroot.todo.beta.legacySelectionMigrated.v1"

    nonisolated static func betaProviderEnabled(_ provider: BetaProvider) -> Bool {
        if provider == .openAI, !OpenAIRegionalAvailability.allowsRequests { return false }
        let key: String
        switch provider {
        case .foundationModels, .onDevice: return true
        case .openAI: key = betaOpenAIEnabledKey
        case .laya: key = betaLayaEnabledKey
        }
        let defaults = UserDefaults.standard
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

    static func betaProviderReadiness() -> BetaProviderReadiness {
        let localModel = OnDeviceLLMService.shared
        let laya = LayaDecisionService.shared
        let connection = OpenAIConnection.shared
        let modelID = localModel.modelID
        let memoryGiB = OnDeviceLLMService.physicalMemoryGiB
        return BetaProviderReadiness(
            foundationModelsAvailable: FoundationModelsAvailability.isAvailable,
            onDeviceModelUsable: localModel.isCapable && !localModel.isDeleting
                && OnDeviceLLMService.modelCatalog.contains { $0.id == modelID && memoryGiB >= $0.minMemoryGiB }
                && (localModel.loadedModelIdentifier == modelID || localModel.isModelCachedOnDisk),
            openAIAccountConnected: connection.activeProfile != nil,
            openAIPlanPermitted: connection.hasPlanPermission && !connection.needsLocalReauthorization,
            layaModelUsable: laya.isCapable && laya.isModelInstalled && !laya.isLoading && !laya.isDeleting
        )
    }

    /// Stored selection is portable intent; runtime selection requires local readiness.
    static func betaSelectedProvider() -> PersonaAIProvider? {
        let selected = UserDefaults.standard.string(forKey: betaSelectedProviderKey)
            .flatMap(PersonaAIProvider.init(rawValue:))
        return betaProviderReadiness().normalizedSelection(selected, access: betaProviderAccess())
    }

    func setBetaProvider(_ provider: BetaProviderOptIn, enabled: Bool) {
        guard provider != .openAI || !enabled || OpenAIRegionalAvailability.allowsRequests else { return }
        let key: String
        switch provider {
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
            guard Self.betaProviderAccess().isEnabled(provider),
                  Self.betaProviderReadiness().isReady(provider) else { return }
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
            if existingValidProvider == nil {
                setBetaSelectedProvider(.foundationModels)
            }
            defaults.set(true, forKey: Self.betaLegacySelectionMigratedKey)
        }
    }

    func normalizeBetaSelectedProvider() {
        // Unavailable or regionally blocked providers remain saved intent, not
        // an effective selection. Do not overwrite another device's preference.
        if let raw = local.string(forKey: Self.betaSelectedProviderKey),
           PersonaAIProvider(rawValue: raw) != nil {
            return
        }
        setBetaSelectedProvider(Self.betaSelectedProvider())
    }
    #if DEBUG
    func resetBetaFeaturesForUITest() {
        [
            Self.betaOpenAIEnabledKey,
            Self.betaMeetingVoiceProcessingEnabledKey,
            Self.meetingAutoRefineKey,
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

    #endif


    /// Processing stays on device; the preference is included in full storage.
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

    /// Full storage includes this preference, not the device's model installation.
    /// Enabling it alone does not install or download a model.
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

    /// Opt-in for saved-audio Whisper transcription after Apple live results are
    /// persisted. Full storage carries the choice, never the model files.
    var meetingAdvancedTranscriptionEnabled: Bool {
        get { local.bool(forKey: Self.betaMeetingAdvancedTranscriptionEnabledKey) }
        set {
            local.set(newValue, forKey: Self.betaMeetingAdvancedTranscriptionEnabledKey)
            objectWillChange.send()
        }
    }

    nonisolated static let meetingAutoRefineKey = "pieroot.todo.meetingAutoRefineEnabled"

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

    private init() {}

    nonisolated static func selectedProvider() -> PersonaAIProvider {
        let raw = UserDefaults.standard.string(forKey: "selectedAIProvider")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = raw.flatMap(PersonaAIProvider.init(rawValue:)) ?? .foundationModels
        return provider == .openAI && !OpenAIRegionalAvailability.allowsRequests
            ? .foundationModels : provider
    }

    nonisolated static func emailAnalysisLookbackDays() -> Int {
        let raw = (UserDefaults.standard.object(forKey: EmailAnalysisLookbackPolicy.lookbackSettingKey) as? NSNumber)?.intValue
            ?? EmailAnalysisLookbackPolicy.defaultLookbackDays
        return EmailAnalysisLookbackPolicy.normalizedLookbackDays(raw)
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


    func migrateLegacyMemoryKeysIntoSwiftDataIfNeeded() {
        let receiptKey = "pieroot.todo.storage.legacyMemoryImported.v1"
        guard !local.bool(forKey: receiptKey) else { return }
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

            local.set(true, forKey: receiptKey)
            cleanupLocalLegacyMemoryKeys()
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


    /// All settings commit locally first; the full-data mirror captures the same
    /// canonical values. There is no per-setting cloud allowlist or opt-out.
    func get<T>(_ key: String, defaultValue: T) -> T {
        local.object(forKey: key) as? T ?? defaultValue
    }

    func set<T>(_ key: String, value: T) {
        local.set(value, forKey: key)
        objectWillChange.send()
    }

    func adoptFullCloudPolicy() {
        let receiptKey = "pieroot.todo.storage.legacySettingsImported.v1"
        if !local.bool(forKey: receiptKey), let previous = global?.dictionaryRepresentation, !previous.isEmpty {
            for (key, value) in previous where CloudPreferenceStore.isUserPreference(key)
                && !CloudPreferenceStore.requiresLocalConfirmation(key) && local.object(forKey: key) == nil {
                local.set(value, forKey: key)
            }
            local.set(true, forKey: receiptKey)
        }
        // Earlier writes while offline created sticky per-setting local overrides.
        // Full sync is one policy: these overrides must not silently omit data.
        for key in local.dictionaryRepresentation().keys where key.hasSuffix(".isLocal") {
            local.removeObject(forKey: key)
        }
        objectWillChange.send()
    }

    func didRestoreFullCloudPreferences() {
        normalizeBetaSelectedProvider()
        objectWillChange.send()
        NotificationCenter.default.post(name: AppLanguage.didChangeNotification, object: nil)
    }
}
