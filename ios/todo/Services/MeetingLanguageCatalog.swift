import Foundation
import Speech
import WhisperKit

/// Transcription languages are engine capabilities, not app translation languages.
nonisolated enum MeetingLanguageCatalog {
    struct Language: Identifiable, Equatable, Sendable {
        /// Apple: full runtime BCP-47 locale. Whisper: exact decoder language code.
        let languageTag: String
        let localizedName: String
        var id: String { languageTag }
    }

    // Source: WhisperKit 1.1.0, revision 1e2a163736dfa5a198e637ae44c114e1c6d5cc2d,
    // Sources/WhisperKit/Core/Models.swift, Constants.languages/languageCodes.
    // All 100 codes have language tokens in the pinned large-v3 tokenizer:
    // https://huggingface.co/openai/whisper-large-v3/blob/06f233fe06e710322aca913c1bc4249a0d71fce1/tokenizer_config.json
    // The loader verifies these tokens against the actual local tokenizer/model.
    static let whisperLanguageCodes = Constants.languageCodes

    static func whisperLanguages(displayLocale: Locale = .current) -> [Language] {
        languages(tags: whisperLanguageCodes, displayLocale: displayLocale)
    }

    /// Language names/aliases come from the pinned SDK. Only known language tags
    /// and well-formed script/region suffixes are accepted. In particular,
    /// Traditional Chinese is still `zh`, not Cantonese; only explicit yue is yue.
    static func whisperLanguageCode(for tag: String) -> String? {
        let value = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let code = Constants.languages[value] { return code }
        guard let parts = tagParts(value, allowVariants: false) else { return nil }
        var code = parts[0]
        if code == "zh", parts.count > 1, ["yue", "cmn"].contains(parts[1]) {
            code = parts[1]
        }
        // BCP-47/ISO aliases for Whisper's legacy jw/tl/no spellings, plus
        // deprecated ISO codes. Never canonicalize a decoder code through ICU:
        // it would turn jw into jv, which has no Whisper language token.
        switch code {
        case "jv": code = "jw"
        case "fil": code = "tl"
        case "nb": code = "no"
        case "iw": code = "he"
        case "in": code = "id"
        case "ji": code = "yi"
        case "cmn": code = "zh"
        default: break
        }
        return whisperLanguageCodes.contains(code) ? code : nil
    }

    /// Runtime support, not installedLocales: downloadable languages remain
    /// selectable. These APIs and the capability probe only read availability
    /// and AssetInventory.status; no authorization, reservation, installation,
    /// session creation, or online recognizer is started by listing languages.
    /// Sources: developer.apple.com/documentation/speech/{speechtranscriber,
    /// dictationtranscriber}/supportedlocales
    static func appleLanguages(
        displayLocale: Locale = .current,
        localeProvider: MeetingTranscriptionLocaleProvider = DefaultMeetingTranscriptionSessionFactory.liveSupportedLocales,
        capabilityProbe: MeetingTranscriptionCapabilityProbe = DefaultMeetingTranscriptionSessionFactory.liveLanguageCapabilityProbe
    ) async -> [Language] {
        var tags = Set<String>()
        for backend in [MeetingTranscriptionBackend.speechTranscriber, .dictationTranscriber] {
            let locales = await localeProvider(backend)
            for locale in locales {
                if case .supported(let identifier) = await capabilityProbe(backend, locale) {
                    // Keep the full resolved locale, not just its base language.
                    tags.insert(Locale(identifier: identifier).identifier(.bcp47))
                }
            }
        }
        return languages(tags: tags, displayLocale: displayLocale)
    }

    /// A locale identifier must name a language; never let Locale's permissive
    /// parser reinterpret arbitrary input as the user's default language.
    static func isLanguageTag(_ tag: String) -> Bool { tagParts(tag) != nil }

    private static func tagParts(_ tag: String, allowVariants: Bool = true) -> [String]? {
        let parts = tag.replacingOccurrences(of: "_", with: "-").lowercased()
            .split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        func letters(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { (97...122).contains($0) }
        }
        func digits(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
        }
        guard let base = parts.first, (2...3).contains(base.count), letters(base) else { return nil }
        var index = 1
        // The Chinese macrolanguage's explicit extlang must not be mistaken for
        // a region or silently collapsed to Mandarin.
        if base == "zh", index < parts.count, ["yue", "cmn"].contains(parts[index]) { index += 1 }
        if index < parts.count, parts[index].count == 4, letters(parts[index]) {
            let script = Locale.Script(parts[index].capitalized)
            guard script.isISOScript, script != .unknown else { return nil }
            index += 1
        }
        if index < parts.count,
           (parts[index].count == 2 && letters(parts[index])) || (parts[index].count == 3 && digits(parts[index])) {
            let region = Locale.Region(parts[index].uppercased())
            guard region.category != nil, region != .unknown else { return nil }
            index += 1
        }
        guard allowVariants || index == parts.count else { return nil }
        var variants = Set<String>()
        while index < parts.count {
            let variant = parts[index]
            guard ((5...8).contains(variant.count) || (variant.count == 4 && digits(String(variant.prefix(1))))),
                  variant.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }),
                  variants.insert(variant).inserted else { return nil }
            index += 1
        }
        return parts
    }

    private static func languages(tags: Set<String>, displayLocale: Locale) -> [Language] {
        tags.map { tag in
            Language(languageTag: tag, localizedName: displayLocale.localizedString(forIdentifier: tag) ?? tag)
        }.sorted { lhs, rhs in
            let order = lhs.localizedName.compare(rhs.localizedName, options: [.caseInsensitive, .diacriticInsensitive],
                                                 locale: displayLocale)
            return order == .orderedSame ? lhs.languageTag < rhs.languageTag : order == .orderedAscending
        }
    }
}
