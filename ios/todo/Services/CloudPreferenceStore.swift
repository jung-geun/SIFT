import CoreFoundation
import Foundation

/// Lossless property-list values. JSON's sorted keys make repeated snapshots stable,
/// including dictionaries, dates and binary journals that UserDefaults supports.
nonisolated indirect enum CloudPreferenceValue: Codable, Equatable, Sendable {
    case string(String), integer(Int64), number(Double), boolean(Bool)
    case data(Data), date(Date), array([CloudPreferenceValue]), dictionary([String: CloudPreferenceValue])

    init(_ value: Any) throws {
        switch value {
        case let value as String: self = .string(value)
        case let value as Data: self = .data(value)
        case let value as Date: self = .date(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .boolean(value.boolValue) }
            else if ["d", "f"].contains(String(cString: value.objCType)) { self = .number(value.doubleValue) }
            else { self = .integer(value.int64Value) }
        case let value as [Any]: self = .array(try value.map(Self.init))
        case let value as [String: Any]: self = .dictionary(try value.mapValues(Self.init))
        default: throw CloudPreferenceError.unsupportedValue
        }
    }

    var value: Any {
        switch self {
        case .string(let value): value
        case .integer(let value): NSNumber(value: value)
        case .number(let value): NSNumber(value: value)
        case .boolean(let value): value
        case .data(let value): value
        case .date(let value): value
        case .array(let value): value.map(\.value)
        case .dictionary(let value): value.mapValues(\.value)
        }
    }
}

nonisolated enum CloudPreferenceError: Error {
    case unsupportedValue, invalidKey, changedDuringSync
}

nonisolated enum CloudPreferenceStore {
    static let prefix = "preference/"
    static let restoredPrefix = "pieroot.todo.restoredDevicePreference."
    static let historyPrefix = "permission-history/"

    static func isPreferenceKey(_ key: String) -> Bool { key.hasPrefix(prefix) || key.hasPrefix(historyPrefix) }

    static func installationID(defaults: UserDefaults = .standard) -> String {
        let key = "pieroot.todo.cloudSync.installationID"
        if let id = defaults.string(forKey: key), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }

    /// Internal progress, keychain pointers, transient capability state and local
    /// health data are not user preferences. Do not transfer another installation's
    /// safety tombstones or pretend its OS permissions exist on this installation.
    static func isUserPreference(_ key: String) -> Bool {
        if key == "selectedAIProvider" { return true }
        guard key.hasPrefix("pieroot.todo."), !key.hasSuffix(".isLocal") else { return false }
        let excludedPrefixes = [
            "pieroot.todo.health.", "pieroot.todo.unexpectedTermination.",
            "pieroot.todo.iCloud", "pieroot.todo.cloudSync.",
            "pieroot.todo.storage.", "pieroot.todo.testCloud.",
            "pieroot.todo.restoredDevicePreference.",
            "pieroot.todo.imap.activeSlot.", "pieroot.todo.imap.rejectedCredential.",
            "pieroot.todo.outlook.imap.activeSlot.", "pieroot.todo.outlook.imap.rejectedCredential.",
            "pieroot.todo.imap.explicitlyDeleted.", "pieroot.todo.imap.portableReceipt.",
            "pieroot.todo.outlook.imap.explicitlyDeleted.", "pieroot.todo.outlook.imap.portableReceipt.",
            "pieroot.todo.openai.signedOut", "pieroot.todo.openai.credentialsDeleted",
            "pieroot.todo.openai.rejectedCredential", "pieroot.todo.openai.device",
            "pieroot.todo.gmail.revoked.v1.",
            "pieroot.todo.gmail.historyID.", "pieroot.todo.gmailIMAP.ingestionCursor.",
            "pieroot.todo.mailbox.updateCursor.",
            "pieroot.todo.memory", "pieroot.todo.removedProvider"
        ]
        guard !excludedPrefixes.contains(where: key.hasPrefix) else { return false }
        return ![
            "pieroot.todo.lastEmailFetchDate", "pieroot.todo.lastLLMAutomationDate",
            "pieroot.todo.imap.pendingPublications.v1", "pieroot.todo.outlook.imap.pendingPublications.v1",
            "pieroot.todo.lastCalendarImportDate", "pieroot.todo.beta.legacySelectionMigrated.v1",
            "pieroot.todo.taskAnalysisCalendarIDs",
            "pieroot.todo.meeting.sourceLanguageTag", "pieroot.todo.meeting.summaryLanguageTag",
            "pieroot.todo.meeting.automaticLanguageDetection"
        ].contains(key)
    }

    /// Consent history and device identifiers are saved in full, but restoring
    /// history is not a new authorization to send data, replay mailbox operations,
    /// or grant background credential access on a different device.
    static func requiresLocalConfirmation(_ key: String) -> Bool {
        key.hasPrefix("pieroot.todo.openai.consent.")
            || key == SettingsStore.betaOpenAIEnabledKey
            || key == "pieroot.todo.imap.backgroundEnabled"
            || key == "pieroot.todo.outlook.backgroundEnabled"
            || key.hasPrefix("pieroot.todo.mailbox.pending")
            || key == "pieroot.todo.defaultCalendarID"
            || key == "pieroot.todo.disabledCalendarIDs"
            || key == "pieroot.todo.emailEventMapping"
            || key == DiagnosticReportService.collectionEnabledKey
            || key == "pieroot.todo.hasReviewedPermissions"
    }

    static func capture(defaults: UserDefaults = .standard) throws -> [String: Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let owner = installationID(defaults: defaults)
        let stored = defaults.dictionaryRepresentation()
        var result = [String: Data]()
        for (key, value) in stored where isUserPreference(key) {
            let recordKey = requiresLocalConfirmation(key) ? historyPrefix + owner + "/" + key : prefix + key
            result[recordKey] = try encoder.encode(CloudPreferenceValue(value))
        }
        // Retain foreign permission/outbox history without replaying it or
        // overwriting another device's consent with this device's default false.
        for (key, value) in stored where key.hasPrefix(restoredPrefix) {
            let suffix = String(key.dropFirst(restoredPrefix.count))
            let parts = suffix.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] != owner, UUID(uuidString: parts[0]) != nil,
                  isUserPreference(parts[1]), requiresLocalConfirmation(parts[1]) else { continue }
            result[historyPrefix + suffix] = try encoder.encode(CloudPreferenceValue(value))
        }
        return result
    }

    /// Verify the captured value at the mutation boundary, not before awaiting
    /// audio reads. A newer local language/model choice must survive this pass.
    static func apply(key: String, payload: Data?, expectedDigest: String?, defaults: UserDefaults = .standard) throws {
        let (name, destination) = try validateSnapshot(key: key, expectedDigest: expectedDigest, defaults: defaults)
        let value = try payload.map { try JSONDecoder().decode(CloudPreferenceValue.self, from: $0).value }
        if let value { defaults.set(value, forKey: destination) }
        else { defaults.removeObject(forKey: destination) }
        if !requiresLocalConfirmation(name) { defaults.removeObject(forKey: name + ".isLocal") }
    }

    @discardableResult
    static func validateSnapshot(key: String, expectedDigest: String?, defaults: UserDefaults = .standard) throws -> (String, String) {
        let result = try destination(for: key)
        // Permission history restores only into inert metadata, never the live
        // preference that produced an originating installation's snapshot.
        if key.hasPrefix(prefix) {
            let current = try encodedValue(defaults.object(forKey: result.destination))
            guard current.map(CloudFileStore.digest) == expectedDigest else { throw CloudPreferenceError.changedDuringSync }
        }
        return result
    }

    private static func encodedValue(_ value: Any?) throws -> Data? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(CloudPreferenceValue(value))
    }

    private static func destination(for key: String) throws -> (name: String, destination: String) {
        let destination: String
        let name: String
        if key.hasPrefix(historyPrefix) {
            let suffix = String(key.dropFirst(historyPrefix.count))
            let parts = suffix.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, UUID(uuidString: parts[0]) != nil,
                  isUserPreference(parts[1]), requiresLocalConfirmation(parts[1]) else { throw CloudPreferenceError.invalidKey }
            name = parts[1]
            destination = restoredPrefix + suffix
        } else {
            guard key.hasPrefix(prefix) else { throw CloudPreferenceError.invalidKey }
            name = String(key.dropFirst(prefix.count))
            guard isUserPreference(name), !requiresLocalConfirmation(name) else { throw CloudPreferenceError.invalidKey }
            destination = name
        }
        return (name, destination)
    }
}
