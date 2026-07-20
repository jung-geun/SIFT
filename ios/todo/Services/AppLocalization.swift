import Foundation

nonisolated struct AppLanguage: RawRepresentable, Hashable, Identifiable, Sendable {
    let rawValue: String

    static let korean = AppLanguage(rawValue: "ko")
    static let english = AppLanguage(rawValue: "en")
    /// Add a language here only after its catalogs and domain/AI output
    /// translations are complete. This prevents a partial `.lproj` from
    /// silently producing Korean fallback content.
    static let supportedIdentifiers = ["ko", "en"]
    static let userOverrideKey = "pieroot.todo.appLanguageOverride"
    static let didChangeNotification = Notification.Name("pieroot.todo.appLanguageDidChange")

    var id: String { rawValue }

    static var current: AppLanguage {
        resolve(
            preferredLocalizations: Bundle.main.preferredLocalizations,
            userOverride: UserDefaults.standard.string(forKey: userOverrideKey)
        )
    }

    static var supported: [AppLanguage] {
        let current = current
        return supportedIdentifiers
            .map(AppLanguage.init(rawValue:))
            .sorted { lhs, rhs in
                if lhs == current { return true }
                if rhs == current { return false }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    static var userOverride: AppLanguage? {
        guard let raw = UserDefaults.standard.string(forKey: userOverrideKey),
              let language = supported.first(where: { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame })
        else { return nil }
        return language
    }

    static func setUserOverride(_ language: AppLanguage?) {
        if let language {
            UserDefaults.standard.set(language.rawValue, forKey: userOverrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userOverrideKey)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func resolve(
        preferredLocalizations: [String],
        userOverride: String? = nil
    ) -> AppLanguage {
        let supported = availableIdentifiers()
        if let override = userOverride.flatMap({ matchingIdentifier($0, in: supported) }) {
            return AppLanguage(rawValue: override)
        }
        for preferred in preferredLocalizations {
            if let match = matchingIdentifier(preferred, in: supported) {
                return AppLanguage(rawValue: match)
            }
        }
        return korean
    }

    static func resolve(languageTag: String) -> AppLanguage {
        let supported = availableIdentifiers()
        if let match = matchingIdentifier(languageTag, in: supported) {
            return AppLanguage(rawValue: match)
        }
        return korean
    }

    var displayName: String {
        let locale = Locale(identifier: rawValue)
        return locale.localizedString(forLanguageCode: rawValue) ?? rawValue
    }

    var locale: Locale {
        let selected = Locale(identifier: rawValue)
        guard selected.region == nil,
              let region = Locale.autoupdatingCurrent.region
        else { return selected }
        return Locale(identifier: "\(rawValue)_\(region.identifier)")
    }

    var outputLanguageName: String {
        Locale(identifier: rawValue).localizedString(forLanguageCode: rawValue) ?? rawValue
    }

    private static func availableIdentifiers() -> [String] {
        supportedIdentifiers
    }

    private static func matchingIdentifier(_ raw: String, in available: [String]) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = available.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact
        }
        guard let languageCode = Locale(identifier: trimmed).language.languageCode?.identifier
                ?? trimmed.split(separator: "-").first.map(String.init)
        else { return nil }
        return available.first {
            let candidate = Locale(identifier: $0).language.languageCode?.identifier ?? ""
            return candidate.caseInsensitiveCompare(languageCode) == .orderedSame
        }
    }
}

private final class AppLocalizationBundleMarker: NSObject {}

extension AppLanguage {
    nonisolated static func localized(
        _ key: String,
        defaultValue: String,
        language: AppLanguage,
        table: String = "Localizable",
        comment: String = ""
    ) -> String {
        let hostBundle = Bundle(for: AppLocalizationBundleMarker.self)
        for identifier in language.bundleCandidates {
            guard let path = hostBundle.path(forResource: identifier, ofType: "lproj"),
                  let languageBundle = Bundle(path: path)
            else { continue }
            let value = languageBundle.localizedString(forKey: key, value: nil, table: table)
            if value != key { return value }
        }
        let value = hostBundle.localizedString(forKey: key, value: nil, table: table)
        return value == key ? defaultValue : value
    }

    nonisolated static func localizedCount(
        _ key: String,
        count: Int,
        defaultValue: String,
        language: AppLanguage,
        table: String = "Localizable",
        comment: String = ""
    ) -> String {
        let format = localized(
            key,
            defaultValue: defaultValue,
            language: language,
            table: table,
            comment: comment
        )
        return String.localizedStringWithFormat(format, Int64(count))
    }

    private var bundleCandidates: [String] {
        let languageCode = Locale(identifier: rawValue).language.languageCode?.identifier
        var candidates = [rawValue]
        if let languageCode, languageCode != rawValue {
            candidates.append(languageCode)
        }
        if rawValue != AppLanguage.english.rawValue {
            candidates.append(AppLanguage.english.rawValue)
        }
        return candidates
    }
}
