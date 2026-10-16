import Foundation

nonisolated struct AppLanguage: RawRepresentable, Hashable, Identifiable, Sendable {
    let rawValue: String

    static let korean = AppLanguage(rawValue: "ko")
    static let english = AppLanguage(rawValue: "en")
    static let spanish = AppLanguage(rawValue: "es")
    static let japanese = AppLanguage(rawValue: "ja")
    static let simplifiedChinese = AppLanguage(rawValue: "zh-Hans")
    static let french = AppLanguage(rawValue: "fr")
    static let italian = AppLanguage(rawValue: "it")
    static let german = AppLanguage(rawValue: "de")
    /// Add a language here only after its catalogs and domain/AI output
    /// translations are complete. This prevents a partial `.lproj` from
    /// silently producing Korean fallback content.
    static let supportedIdentifiers = ["ko", "en", "es", "ja", "zh-Hans", "fr", "it", "de"]
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
                if lhs == rhs { return false }
                if lhs == current { return true }
                if rhs == current { return false }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    static var userOverride: AppLanguage? {
        guard let raw = UserDefaults.standard.string(forKey: userOverrideKey) else { return nil }
        return supportedLanguage(for: raw)
    }

    static func setUserOverride(_ language: AppLanguage?) {
        if let language = language.flatMap({ supportedLanguage(for: $0.rawValue) }) {
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
        supportedLanguage(for: languageTag) ?? korean
    }

    /// Unlike app preference resolution, domain capability checks must not
    /// silently turn an unsupported content language into Korean.
    static func supportedLanguage(for languageTag: String) -> AppLanguage? {
        matchingIdentifier(languageTag, in: supportedIdentifiers).map(AppLanguage.init(rawValue:))
    }

    var displayName: String {
        switch self {
        case .korean: "한국어"
        case .english: "English"
        case .spanish: "Español"
        case .japanese: "日本語"
        case .simplifiedChinese: "简体中文"
        case .french: "Français"
        case .italian: "Italiano"
        case .german: "Deutsch"
        default: Locale(identifier: rawValue).localizedString(forIdentifier: rawValue) ?? rawValue
        }
    }

    var locale: Locale {
        let selected = Locale(identifier: rawValue)
        guard selected.region == nil,
              let region = Locale.autoupdatingCurrent.region
        else { return selected }
        return Locale(identifier: "\(rawValue)_\(region.identifier)")
    }

    /// Stable English language names for machine instructions, not picker labels.
    var outputLanguageName: String {
        switch self {
        case .korean: "Korean"
        case .english: "English"
        case .spanish: "Spanish"
        case .japanese: "Japanese"
        case .simplifiedChinese: "Simplified Chinese"
        case .french: "French"
        case .italian: "Italian"
        case .german: "German"
        default: Locale(identifier: "en").localizedString(forIdentifier: rawValue) ?? rawValue
        }
    }

    var speechLanguageTag: String {
        switch self {
        case .korean: "ko-KR"
        case .english: "en-US"
        case .spanish: "es-ES"
        case .japanese: "ja-JP"
        case .simplifiedChinese: "zh-CN"
        case .french: "fr-FR"
        case .italian: "it-IT"
        case .german: "de-DE"
        default: rawValue
        }
    }

    private static func availableIdentifiers() -> [String] {
        supportedIdentifiers
    }

    private static func matchingIdentifier(_ raw: String, in available: [String]) -> String? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }
        let parts = normalized.split(separator: "-").map { $0.lowercased() }
        guard let language = parts.first else { return nil }
        if language == "zh" {
            // Explicit script wins over region. Traditional Chinese is not a
            // supported translation; never label it as Simplified Chinese.
            let script = parts.count > 1 && parts[1].count == 4 ? parts[1] : nil
            if let script, script != "hans" { return nil }
            let regionIndex = script == nil ? 1 : 2
            let region = parts.count > regionIndex ? parts[regionIndex] : nil
            if script == nil && region.map({ ["tw", "hk", "mo"].contains($0) }) == true {
                return nil
            }
            return available.first { $0 == "zh-Hans" }
        }
        return available.first { $0.caseInsensitiveCompare(language) == .orderedSame }
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
        // `Bundle.localizedString(forKey:value:table:)` returns the key
        // itself when no translation exists *only if `value` is nil or
        // empty*. Passing a distinct sentinel here (instead of comparing the
        // result against `key`) is required: some catalog entries use the
        // Korean source string as both the key and its own "ko" translation
        // (e.g. "녹음 시작"), which made `value != key` misfire and silently
        // fall through to the next language candidate (English) even though
        // the correct Korean translation was found.
        for identifier in language.bundleCandidates {
            guard let path = hostBundle.path(forResource: identifier, ofType: "lproj"),
                  let languageBundle = Bundle(path: path)
            else { continue }
            let missingSentinel = "\u{0}__missing__\(table)__\(key)__"
            let value = languageBundle.localizedString(forKey: key, value: missingSentinel, table: table)
            if value != missingSentinel { return value }
        }
        return defaultValue
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
        return String(format: format, locale: language.locale, Int64(count))
    }

    nonisolated private var bundleCandidates: [String] {
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
