import Foundation
import UIKit
import Darwin
import os
import OSLog

nonisolated struct DiagnosticSource: Codable, Equatable, Sendable {
    let file: String
    let line: Int
    let function: String
}

nonisolated struct DiagnosticErrorFrame: Codable, Equatable, Sendable {
    let relation: String
    let domain: String
    let code: Int
    let type: String?
    let localizedDescription: String
    let failureReason: String?
    let userInfoKeys: [String]
}

nonisolated struct DiagnosticLocaleInfo: Codable, Equatable, Sendable {
    let identifier: String
    let languageCode: String?
    let regionCode: String?
    let scriptCode: String?
    let calendarIdentifier: String
    let timeZoneIdentifier: String
    let timeZoneOffsetSeconds: Int
    let uses24HourClock: Bool
}

nonisolated struct DiagnosticRuntimeState: Codable, Equatable, Sendable {
    let appVersion: String
    let build: String
    let systemVersion: String
    let operatingSystemBuild: String?
    let appState: String
    let processUptimeSeconds: Double
    let thermalState: String
    let isLowPowerModeEnabled: Bool
    let memoryFootprintBytes: UInt64?
    let availableDiskBytes: Int64?
    /// Locale at the error timestamp. Region is derived from this locale; no
    /// physical location or device name is collected.
    let locale: DiagnosticLocaleInfo?
}

nonisolated struct DiagnosticAppInfo: Codable, Equatable, Sendable {
    let version: String
    let build: String
    let bundleIdentifier: String
    let installSource: String
    let appLanguage: String
    let selectedAIProvider: String
    let processUptimeSeconds: Double
}

nonisolated struct DiagnosticDeviceInfo: Codable, Equatable, Sendable {
    let modelIdentifier: String
    let systemName: String
    let systemVersion: String
    let operatingSystemBuild: String?
    let idiom: String
    let isiOSAppOnMac: Bool
    let isMacCatalystApp: Bool
    let physicalMemoryBytes: UInt64
    let activeProcessorCount: Int
    let totalDiskBytes: Int?
    let availableDiskBytes: Int64?
    let screen: String?
    let localeIdentifier: String
    let preferredLanguages: [String]
    let timeZoneIdentifier: String
    let locale: DiagnosticLocaleInfo
    let thermalState: String
    let isLowPowerModeEnabled: Bool
    let systemUptimeSeconds: Double
    let bootEpoch: Double?
}

nonisolated struct DiagnosticLogEntry: Codable, Equatable, Sendable {
    let date: Date
    let category: String
    let level: String
    let message: String
}

nonisolated struct DiagnosticFailure: CustomNSError, LocalizedError, Sendable {
    let code: Int
    let reason: String

    static var errorDomain: String { "todo.DiagnosticFailure" }
    var errorCode: Int { code }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: reason] }
    var errorDescription: String? { reason }
}

nonisolated enum DiagnosticRedaction {
    private static let maxMetricPayloadDepth = 24
    private static let maxMetricArrayItems = 80
    private static let maxMetricDictionaryEntries = 160

    nonisolated static func text(_ value: String, limit: Int = 300) -> String {
        let withoutPaths = value.replacingOccurrences(
            of: #"(?:\\?/)(?:private|var|Users)(?:\\?/)[^"\s]+"#,
            with: "<redacted-path>",
            options: .regularExpression
        )
        let redacted = withoutPaths.replacingOccurrences(
            of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
            with: "<redacted-email>",
            options: .regularExpression
        )
        guard redacted.count > limit else { return redacted }
        return String(redacted.prefix(limit)) + "…"
    }

    nonisolated static func metricPayload(_ payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return text(payload, limit: 2_000)
        }
        let redacted = redactMetricValue(object, depth: 0)
        guard JSONSerialization.isValidJSONObject(redacted),
              let encoded = try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys]),
              let result = String(data: encoded, encoding: .utf8)
        else {
            return text(payload, limit: 2_000)
        }
        return result
    }

    nonisolated private static func redactMetricValue(_ value: Any, depth: Int) -> Any {
        guard depth < maxMetricPayloadDepth else {
            return "<truncated-depth>"
        }

        switch value {
        case let string as String:
            return text(string, limit: 2_000)
        case let array as [Any]:
            var redacted = array.prefix(maxMetricArrayItems).map {
                redactMetricValue($0, depth: depth + 1)
            }
            if array.count > maxMetricArrayItems {
                redacted.append("<truncated-\(array.count - maxMetricArrayItems)-items>")
            }
            return redacted
        case let dictionary as [String: Any]:
            var redacted: [String: Any] = [:]
            redacted.reserveCapacity(min(dictionary.count, maxMetricDictionaryEntries + 1))
            for key in dictionary.keys.sorted().prefix(maxMetricDictionaryEntries) {
                guard let value = dictionary[key] else { continue }
                redacted[key] = redactMetricValue(value, depth: depth + 1)
            }
            if dictionary.count > maxMetricDictionaryEntries {
                redacted["_truncatedEntries"] = dictionary.count - maxMetricDictionaryEntries
            }
            return redacted
        default:
            return value
        }
    }
}

nonisolated enum DiagnosticErrorChain {
    nonisolated static func frames(for error: Error) -> (root: DiagnosticErrorFrame, underlying: [DiagnosticErrorFrame]) {
        let root = frame(for: error, relation: "root")
        var queue: [(error: Error, relation: String, depth: Int)] = candidates(for: error, depth: 0)
        var index = 0
        var underlying: [DiagnosticErrorFrame] = []

        while index < queue.count, underlying.count < 7 {
            let next = queue[index]
            index += 1
            underlying.append(frame(for: next.error, relation: next.relation))
            guard next.depth < 3 else { continue }
            queue.append(contentsOf: candidates(for: next.error, depth: next.depth))
        }
        return (root, underlying)
    }

    nonisolated private static func frame(for error: Error, relation: String) -> DiagnosticErrorFrame {
        let nsError = error as NSError
        return DiagnosticErrorFrame(
            relation: relation,
            domain: nsError.domain,
            code: nsError.code,
            type: String(reflecting: type(of: error)),
            localizedDescription: DiagnosticRedaction.text(nsError.localizedDescription),
            failureReason: nsError.localizedFailureReason.map { DiagnosticRedaction.text($0) },
            userInfoKeys: nsError.userInfo.keys.sorted()
        )
    }

    nonisolated private static func candidates(for error: Error, depth: Int) -> [(error: Error, relation: String, depth: Int)] {
        let userInfo = (error as NSError).userInfo
        var result: [(error: Error, relation: String, depth: Int)] = []

        if let underlying = userInfo[NSUnderlyingErrorKey] as? Error {
            result.append((underlying, "underlying", depth + 1))
        }
        if let multiple = userInfo[NSMultipleUnderlyingErrorsKey] as? [Any] {
            result.append(contentsOf: multiple.compactMap { $0 as? Error }.prefix(3).map {
                ($0, "multiple", depth + 1)
            })
        }

        for key in userInfo.keys.sorted() where key != NSUnderlyingErrorKey && key != NSMultipleUnderlyingErrorsKey {
            let errors = errorsContained(in: userInfo[key]).prefix(3)
            result.append(contentsOf: errors.map { ($0, "userInfo.\(key)", depth + 1) })
        }
        return result
    }

    nonisolated private static func errorsContained(in value: Any?) -> [Error] {
        guard let value else { return [] }
        if let error = value as? Error { return [error] }
        if let values = value as? [Any] {
            return values.flatMap(errorsContained(in:))
        }
        if let values = value as? [AnyHashable: Any] {
            return values.values.flatMap(errorsContained(in:))
        }
        return []
    }
}

enum DiagnosticEnvironment {
    nonisolated static let processStart = Date()
    nonisolated static let appStateBox = OSAllocatedUnfairLock(initialState: "unknown")

    nonisolated static func setAppState(_ value: String) {
        appStateBox.withLock { $0 = value }
    }

    nonisolated static func currentAppState() -> String {
        appStateBox.withLock { $0 }
    }

    nonisolated static func runtimeState() -> DiagnosticRuntimeState {
        let version = bundleVersion()
        return DiagnosticRuntimeState(
            appVersion: version.version,
            build: version.build,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            operatingSystemBuild: operatingSystemBuild(),
            appState: currentAppState(),
            processUptimeSeconds: Date().timeIntervalSince(processStart),
            thermalState: thermalStateName(ProcessInfo.processInfo.thermalState),
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            memoryFootprintBytes: memoryFootprintBytes(),
            availableDiskBytes: availableDiskBytes(),
            locale: localeInfo()
        )
    }

    nonisolated static func modelIdentifier() -> String {
        if let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulatorModel.isEmpty {
            return simulatorModel
        }
        var info = utsname()
        uname(&info)
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    nonisolated static func installSource() -> String {
        #if targetEnvironment(simulator)
        return "simulator"
        #elseif DEBUG
        return "development"
        #else
        switch Bundle.main.appStoreReceiptURL?.lastPathComponent {
        case "sandboxReceipt": return "testFlight"
        case "receipt": return "appStore"
        default: return "unknown"
        }
        #endif
    }

    nonisolated static func memoryFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
    }

    nonisolated static func availableDiskBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
    }

    nonisolated static func totalDiskBytes() -> Int? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey])
        return values?.volumeTotalCapacity
    }

    /// Boot time is sampled only for the optional, locally reviewed bug report.
    nonisolated private static func currentBootEpoch() -> TimeInterval? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 else {
            return nil
        }
        return TimeInterval(bootTime.tv_sec) + TimeInterval(bootTime.tv_usec) / 1_000_000
    }

    nonisolated static func appInfo() -> DiagnosticAppInfo {
        let version = bundleVersion()
        return DiagnosticAppInfo(
            version: version.version,
            build: version.build,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            installSource: installSource(),
            appLanguage: AppLanguage.current.rawValue,
            selectedAIProvider: SettingsStore.selectedProvider().rawValue,
            processUptimeSeconds: Date().timeIntervalSince(processStart)
        )
    }

    @MainActor
    static func deviceInfo() -> DiagnosticDeviceInfo {
        let device = UIDevice.current
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let screen = scene.map { "\($0.screen.bounds.width)x\($0.screen.bounds.height)@\($0.screen.scale)x" }
        let locale = localeInfo()
        return DiagnosticDeviceInfo(
            modelIdentifier: modelIdentifier(),
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            operatingSystemBuild: operatingSystemBuild(),
            idiom: idiomName(device.userInterfaceIdiom),
            isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac,
            isMacCatalystApp: ProcessInfo.processInfo.isMacCatalystApp,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            totalDiskBytes: totalDiskBytes(),
            availableDiskBytes: availableDiskBytes(),
            screen: screen,
            localeIdentifier: locale.identifier,
            preferredLanguages: Array(Locale.preferredLanguages.prefix(3)),
            timeZoneIdentifier: locale.timeZoneIdentifier,
            locale: locale,
            thermalState: thermalStateName(ProcessInfo.processInfo.thermalState),
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            systemUptimeSeconds: ProcessInfo.processInfo.systemUptime,
            bootEpoch: currentBootEpoch()
        )
    }

    nonisolated static func localeInfo() -> DiagnosticLocaleInfo {
        let locale = Locale.current
        let timeZone = TimeZone.current
        let hourTemplate = DateFormatter.dateFormat(
            fromTemplate: "j",
            options: 0,
            locale: locale
        ) ?? ""
        return DiagnosticLocaleInfo(
            identifier: locale.identifier,
            languageCode: locale.language.languageCode?.identifier,
            regionCode: locale.region?.identifier,
            scriptCode: locale.language.script?.identifier,
            calendarIdentifier: String(describing: locale.calendar.identifier),
            timeZoneIdentifier: timeZone.identifier,
            timeZoneOffsetSeconds: timeZone.secondsFromGMT(),
            uses24HourClock: hourTemplate.contains("H") || hourTemplate.contains("k")
        )
    }

    nonisolated static func operatingSystemBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &value, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: value)
    }

    nonisolated static func settingsSnapshot(_ defaults: UserDefaults = .standard) -> [String: Bool] {
        let gmailAccount = defaults.string(forKey: "pieroot.todo.imap.account") ?? ""
        let outlookAccount = defaults.string(forKey: "pieroot.todo.outlook.account") ?? ""

        return [
            "iCloudSyncEnabled": defaults.bool(forKey: "pieroot.todo.iCloudSyncEnabled"),
            "emailAutoAnalysisEnabled": defaults.bool(forKey: "pieroot.todo.emailAutoAnalysisEnabled"),
            "imapBackgroundEnabled": defaults.bool(forKey: "pieroot.todo.imap.backgroundEnabled"),
            "outlookBackgroundEnabled": defaults.bool(forKey: "pieroot.todo.outlook.backgroundEnabled"),
            "calendarAutoRegister": defaults.bool(forKey: "pieroot.todo.calendarAutoRegister"),
            "onDeviceLLMEnabled": defaults.bool(forKey: "pieroot.todo.onDeviceLLMEnabled"),
            "betaFeaturesEnabled": defaults.bool(forKey: "pieroot.todo.betaFeaturesEnabled"),
            "betaFoundationModelsEnabled": defaults.bool(forKey: "pieroot.todo.beta.foundationModelsEnabled"),
            "betaOnDeviceModelEnabled": defaults.bool(forKey: "pieroot.todo.beta.onDeviceModelEnabled"),
            "betaOpenAIEnabled": defaults.bool(forKey: SettingsStore.betaOpenAIEnabledKey),
            "betaMeetingVoiceProcessingEnabled": defaults.bool(forKey: "pieroot.todo.beta.meetingVoiceProcessingEnabled"),
            "meetingVoiceProcessingEnabled": defaults.bool(forKey: "pieroot.todo.meetingVoiceProcessingEnabled"),
            "meetingAutoRefineEnabled": defaults.bool(forKey: "pieroot.todo.meetingAutoRefineEnabled"),
            "hasOnboarded": defaults.bool(forKey: "pieroot.todo.hasOnboarded"),
            "hasCompletedTutorial": defaults.bool(forKey: "pieroot.todo.hasCompletedTutorial"),
            "gmailAccountLinked": !gmailAccount.isEmpty,
            "gmailCredentialStored": IMAPCredentialStore.hasCredential(for: gmailAccount),
            "gmailCredentialRejected": IMAPCredentialStore.isCredentialRejected(for: gmailAccount),
            "outlookAccountLinked": !outlookAccount.isEmpty,
            "outlookCredentialStored": OutlookIMAPCredentialStore.hasCredential(for: outlookAccount)
        ]
    }

    nonisolated private static func bundleVersion() -> (version: String, build: String) {
        (
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        )
    }

    nonisolated private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    @MainActor
    private static func idiomName(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone: return "phone"
        case .pad: return "pad"
        case .mac: return "mac"
        case .vision: return "vision"
        default: return "other"
        }
    }
}

enum DiagnosticLogTail {
    private struct Candidate {
        let date: Date
        let category: String
        let level: String
        let message: String
    }

    nonisolated static func recent(maxEntries: Int = 300, lookback: TimeInterval = 1_800) -> [DiagnosticLogEntry] {
        guard maxEntries > 0 else { return [] }
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-lookback))
            let predicate = NSPredicate(format: "subsystem == %@", "pieroot.todo")
            var retained = Array<Candidate?>(repeating: nil, count: maxEntries)
            var next = 0
            var count = 0

            for case let entry as OSLogEntryLog in try store.getEntries(at: position, matching: predicate) {
                guard entry.level == .error || entry.level == .fault else { continue }
                retained[next] = Candidate(
                    date: entry.date,
                    category: entry.category,
                    level: entry.level == .fault ? "fault" : "error",
                    message: entry.composedMessage
                )
                next = (next + 1) % maxEntries
                count = min(count + 1, maxEntries)
            }

            return (0..<count).compactMap { offset in
                let index = count == maxEntries ? (next + offset) % maxEntries : offset
                guard let entry = retained[index] else { return nil }
                return DiagnosticLogEntry(
                    date: entry.date,
                    category: entry.category,
                    level: entry.level,
                    message: DiagnosticRedaction.text(entry.message, limit: 500)
                )
            }
        } catch {
            return []
        }
    }
}
