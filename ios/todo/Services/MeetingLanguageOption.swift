import Foundation
import CoreFoundation

/// Presentation of an engine language code; never resolves through AppLanguage.
nonisolated struct MeetingLanguageOption: Identifiable, Hashable, Sendable {
    let id: String

    func displayName(locale: Locale) -> String {
        locale.localizedString(forIdentifier: id) ?? id
    }

    var englishName: String { displayName(locale: Locale(identifier: "en")) }

    /// Read the OS domain directly: Locale.preferredLanguages also observes
    /// per-app/launch-argument AppleLanguages and is not a system-language source.
    static var systemPreferredLanguages: [String] {
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString,
            kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        return preferredLanguages(global: global, fallback: Locale.preferredLanguages)
    }

    static func preferredLanguages(global: [String]?, fallback: [String]) -> [String] {
        let languages = global?.filter { MeetingLanguageCatalog.isLanguageTag($0) } ?? []
        return languages.isEmpty ? fallback : languages
    }

    /// Equivalence is language + likely script, not spelling, region or provider.
    /// Keep real engine IDs so a displayed choice remains runnable. In particular
    /// zh-Hans/zh-Hant and sr-Cyrl/sr-Latn must never collapse into one another.
    func isEquivalent(to other: String) -> Bool {
        guard let lhs = DefaultLanguageTag(id), let rhs = DefaultLanguageTag(other) else { return false }
        return lhs.identity == rhs.identity
    }

    static func deduplicated(
        _ options: [MeetingLanguageOption],
        preferredLanguages: [String] = systemPreferredLanguages,
        displayLocale: Locale = .current
    ) -> [MeetingLanguageOption] {
        var groups: [String: [MeetingLanguageOption]] = [:]
        for option in options {
            guard let tag = DefaultLanguageTag(option.id) else { continue }
            groups[tag.identity, default: []].append(option)
        }
        return groups.compactMap { identity, group in
            var matched = initialSelection(current: "", options: group, preferredLanguages: preferredLanguages)
            if matched.isEmpty {
                matched = initialSelection(current: "", options: group, preferredLanguages: [identity])
            }
            return group.first { $0.id == matched } ?? group.min { $0.id < $1.id }
        }.sorted {
            let order = $0.displayName(locale: displayLocale).compare($1.displayName(locale: displayLocale),
                options: [.caseInsensitive, .diacriticInsensitive], locale: displayLocale)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// Defaults are content-language choices, independent of the app's UI locale.
    /// Return the original engine ID, and never replace a choice already made.
    static func initialSelection(
        current: String,
        options: [MeetingLanguageOption],
        preferredLanguages: [String] = systemPreferredLanguages
    ) -> String {
        guard current.isEmpty else { return current }
        let candidates: [(id: String, tag: DefaultLanguageTag)] = options.compactMap { option in
            guard let tag = DefaultLanguageTag(option.id) else { return nil }
            return (option.id, tag)
        }
        for preference in preferredLanguages {
            guard let preferred = DefaultLanguageTag(preference) else { continue }
            // An unsupported country (en-KR) must not make en-AU win by spelling.
            let likely = Locale.Language(identifier: preferred.identity).maximalIdentifier
            let likelyRegion = Locale(identifier: likely).region?.identifier
            var best: (id: String, canonical: String, rank: Int)?
            for candidate in candidates {
                let tag = candidate.tag
                guard tag.language == preferred.language else { continue }
                let rank: Int
                if tag.canonical == preferred.canonical {
                    rank = 16
                } else {
                    // A bare engine code (notably Whisper's zh) is script-neutral.
                    // Region-bearing tags use their likely script, so zh-TW cannot
                    // fall back to zh-CN. Cantonese has a separate language code.
                    if let script = preferred.script, let supportedScript = tag.script,
                       script != supportedScript { continue }
                    rank = (preferred.region != nil && tag.region == preferred.region ? 8 : 0)
                        + (preferred.script != nil && tag.script == preferred.script ? 4 : 0)
                        + (tag.isLanguageOnly ? 2 : 0)
                        + (likelyRegion != nil && tag.region == likelyRegion ? 1 : 0)
                }
                if let previous = best {
                    guard rank > previous.rank || (rank == previous.rank
                        && (tag.canonical < previous.canonical
                            || (tag.canonical == previous.canonical && candidate.id < previous.id))) else { continue }
                }
                best = (candidate.id, tag.canonical, rank)
            }
            if let best { return best.id }
        }
        return ""
    }

    private struct DefaultLanguageTag {
        let canonical: String
        let language: String
        let script: String?
        let region: String?
        let isLanguageOnly: Bool
        let identity: String

        init?(_ id: String) {
            guard MeetingLanguageCatalog.isLanguageTag(id) else { return nil }
            var parts = id.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
            // Match the catalog's explicit Chinese extlang conventions, not a
            // Chinese macrolanguage fallback that could merge Mandarin and yue.
            if parts[0] == "zh", parts.count > 1, ["cmn", "yue"].contains(parts[1]) { parts.removeFirst() }
            if parts[0] == "cmn" { parts[0] = "zh" }
            switch parts[0] {
            case "jw": parts[0] = "jv"
            case "tl": parts[0] = "fil"
            case "no": parts[0] = "nb"
            case "iw": parts[0] = "he"
            case "in": parts[0] = "id"
            case "ji": parts[0] = "yi"
            default: break
            }
            let locale = Locale(identifier: parts.joined(separator: "-"))
            guard let code = locale.language.languageCode?.identifier else { return nil }
            canonical = locale.identifier(.bcp47).lowercased()
            language = code
            isLanguageOnly = parts.count == 1
            script = isLanguageOnly ? nil : locale.language.script?.identifier
            region = locale.region?.identifier
            identity = "\(code)-\(locale.language.script?.identifier ?? "")"
        }
    }
}

nonisolated enum MeetingTranscriptionLanguages {
    static let whisper: [MeetingLanguageOption] =
        MeetingLanguageCatalog.whisperLanguages().map { MeetingLanguageOption(id: $0.languageTag) }

    static func apple() async -> [MeetingLanguageOption] {
        await MeetingLanguageCatalog.appleLanguages().map { MeetingLanguageOption(id: $0.languageTag) }
    }

    /// Apple locales may be installable under the existing explicit asset opt-in.
    /// Whisper contributes only when its actual model is installed and enabled.
    static func options(apple: [MeetingLanguageOption], whisperAvailable: Bool) -> [MeetingLanguageOption] {
        MeetingLanguageOption.deduplicated(apple + (whisperAvailable ? whisper : []),
            displayLocale: AppLanguage.current.locale)
    }

    static func supportsApple(_ tag: String) async -> Bool {
        guard MeetingLanguageCatalog.isLanguageTag(tag) else { return false }
        for backend in [MeetingTranscriptionBackend.speechTranscriber, .dictationTranscriber] {
            if case .supported = await DefaultMeetingTranscriptionSessionFactory.liveCapabilityProbe(backend, Locale(identifier: tag)) {
                return true
            }
        }
        return false
    }
}

extension MeetingSummaryLanguages {
    @MainActor static var available: [MeetingLanguageOption] {
        supported.map { MeetingLanguageOption(id: $0.id) }.sorted {
            $0.displayName(locale: AppLanguage.current.locale).localizedStandardCompare($1.displayName(locale: AppLanguage.current.locale)) == .orderedAscending
        }
    }
}
