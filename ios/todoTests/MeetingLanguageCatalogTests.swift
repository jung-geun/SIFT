import Foundation
import Testing
import WhisperKit
@testable import todo

@Suite("Transcription language catalogs")
struct MeetingLanguageCatalogTests {
    private typealias Service = MeetingOfflineTranscriptionService

    // Independent snapshot of language tokens 50259...50358 in the pinned
    // openai/whisper-large-v3 tokenizer, not derived from the production catalog.
    private static let pinnedCodes = """
    en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su yue
    """.split(separator: " ").map(String.init)

    @Test("The full pinned large-v3 language set is available, deduplicated and named")
    func whisperCatalog() throws {
        let entries = MeetingLanguageCatalog.whisperLanguages(displayLocale: Locale(identifier: "en"))
        #expect(entries.count == 100)
        #expect(Set(entries.map(\.languageTag)) == Set(Self.pinnedCodes))
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(entries.allSatisfy { !$0.localizedName.isEmpty })
        for code in Self.pinnedCodes {
            #expect(try Service.languageCode(for: code) == code)
        }
        for (alias, code) in Constants.languages {
            #expect(try Service.languageCode(for: alias) == code)
        }
        #expect(entries == MeetingLanguageCatalog.whisperLanguages(displayLocale: Locale(identifier: "en")))
        let bengali = try #require(entries.first { $0.languageTag == "bn" })
        #expect(bengali.localizedName == Locale(identifier: "en").localizedString(forIdentifier: "bn"))
        let koreanEntries = MeetingLanguageCatalog.whisperLanguages(displayLocale: Locale(identifier: "ko"))
        #expect(koreanEntries.first { $0.languageTag == "bn" }?.localizedName
                == Locale(identifier: "ko").localizedString(forIdentifier: "bn"))
    }

    @Test("Formerly blocked languages and script/region tags carry exact engine codes into decoding")
    func languageRequests() throws {
        let tokenizer = LanguageTokenizer()
        for (tag, code) in [
            ("bn-BD", "bn"), ("bn-IN", "bn"), ("hi-IN", "hi"), ("ar-SA", "ar"),
            ("pt-BR", "pt"), ("ru-RU", "ru"), ("ta-IN", "ta"), ("te-IN", "te"),
            ("ur-PK", "ur"), ("vi-VN", "vi"), ("th-TH", "th"), ("sw-KE", "sw"),
            ("sr-Cyrl-RS", "sr"), ("sr-Latn-RS", "sr"), ("zh-Hans-CN", "zh"),
            ("zh-Hant-TW", "zh"), ("zh-HK", "zh"), ("yue-Hant-HK", "yue"),
            ("zh-yue-HK", "yue"), ("zh-cmn-Hans-CN", "zh"), ("cmn-TW", "zh"),
            ("jv-ID", "jw"), ("jw", "jw"), ("fil-PH", "tl"), ("nb-NO", "no"),
            ("nn-NO", "nn"), ("iw-IL", "he"), ("in-ID", "id"), ("ji", "yi"),
            ("  BN_bd  ", "bn"), ("es-419", "es"), ("en-001", "en")
        ] {
            let resolved = try Service.languageCode(for: tag)
            #expect(resolved == code)
            let options = try Service.decodingOptions(languageCode: resolved, tokenizer: tokenizer,
                                                       isMultilingual: true, logitsSize: 51_866)
            #expect(options.language == code)
            #expect(!options.detectLanguage)
            #expect(options.task == .transcribe)
        }
    }

    @Test("Unknown or malformed requests never fall back to English; nil still detects")
    func unsupportedRequests() throws {
        for tag in ["", "auto", "xx", "zz-ZZ", "not-a-language", "en--US", "en-US-garbage", "zh-unknown", "english-US", "<|en|>", "en-Fake", "en-Zzzz", "en-ZZ", "en-999"] {
            #expect(throws: Service.Failure.unsupportedLanguage) { try Service.languageCode(for: tag) }
        }
        #expect(try Service.languageCode(for: nil) == nil)
        let automatic = try Service.decodingOptions(languageCode: nil, tokenizer: LanguageTokenizer(),
                                                    isMultilingual: true, logitsSize: 51_866)
        #expect(automatic.language == nil)
        #expect(automatic.detectLanguage)
    }

    @Test("Actual decoder/tokenizer constraints reject missing, aliased, or out-of-vocabulary tokens")
    func modelConstraints() throws {
        for code in Self.pinnedCodes {
            let options = try Service.decodingOptions(languageCode: code, tokenizer: LanguageTokenizer(),
                                                       isMultilingual: true, logitsSize: 51_866)
            #expect(options.language == code)
        }
        #expect(throws: Service.Failure.unsupportedLanguage) {
            try Service.decodingOptions(languageCode: "bn", tokenizer: LanguageTokenizer(),
                                        isMultilingual: false, logitsSize: 51_864)
        }
        #expect(try Service.decodingOptions(languageCode: "en", tokenizer: nil,
                                            isMultilingual: false, logitsSize: 51_864).language == "en")
        let incomplete: [LanguageTokenizer?] = [nil, LanguageTokenizer(omitted: "bn"), LanguageTokenizer(aliasToEnglish: "bn")]
        for tokenizer in incomplete {
            #expect(throws: Service.Failure.unsupportedLanguage) {
                try Service.decodingOptions(languageCode: "bn", tokenizer: tokenizer,
                                            isMultilingual: true, logitsSize: 51_866)
            }
        }
        #expect(throws: Service.Failure.unsupportedLanguage) {
            try Service.decodingOptions(languageCode: "yue", tokenizer: LanguageTokenizer(),
                                        isMultilingual: true, logitsSize: 50_358)
        }
        #expect(throws: Service.Failure.unsupportedLanguage) {
            try Service.decodingOptions(languageCode: "xx", tokenizer: LanguageTokenizer(),
                                        isMultilingual: true, logitsSize: 51_866)
        }
    }

    @Test("Apple uses both runtime lists, preserves variants, and filters unsupported backends/assets")
    func appleCatalog() async {
        let locales: MeetingTranscriptionLocaleProvider = { backend in
            switch backend {
            case .speechTranscriber:
                ["en-US", "en-GB", "zh-Hans-CN", "sr-Cyrl-RS", "bn-BD", "fr-FR"].map(Locale.init(identifier:))
            case .dictationTranscriber:
                ["en_US", "ar-SA", "hi-IN", "zh-Hant-TW", "sr-Latn-RS", "bn-BD", "ca-ES-valencia", "pt-BR"].map(Locale.init(identifier:))
            }
        }
        let probe: MeetingTranscriptionCapabilityProbe = { backend, locale in
            let tag = locale.identifier(.bcp47)
            if tag == "fr-FR" { return .unavailable }
            if tag == "pt-BR" || (tag == "bn-BD" && backend == .speechTranscriber) { return .unsupportedAsset }
            return .supported(resolvedLocaleIdentifier: locale.identifier)
        }
        let entries = await MeetingLanguageCatalog.appleLanguages(displayLocale: Locale(identifier: "en"),
                                                                  localeProvider: locales, capabilityProbe: probe)
        // Foundation canonicalizes redundant Cyrl in Serbian before the runtime
        // provider returns Locale; non-default Latn remains a distinct option.
        #expect(Set(entries.map(\.languageTag)) == Set([
            "en-US", "en-GB", "zh-Hans-CN", "sr-RS", "bn-BD", "ar-SA", "hi-IN",
            "zh-Hant-TW", "sr-Latn-RS", "ca-ES-valencia"
        ]))
        #expect(entries.count == Set(entries.map(\.id)).count)
        #expect(entries.allSatisfy { !$0.localizedName.isEmpty })
        let reversed: MeetingTranscriptionLocaleProvider = { backend in Array((await locales(backend)).reversed()) }
        let reordered = await MeetingLanguageCatalog.appleLanguages(displayLocale: Locale(identifier: "en"),
                                                                    localeProvider: reversed, capabilityProbe: probe)
        #expect(entries == reordered)
        let unsupported = await MeetingLanguageCatalog.appleLanguages(localeProvider: locales,
                                                                       capabilityProbe: { _, _ in .unsupportedAsset })
        #expect(unsupported.isEmpty)
        let unavailable = await MeetingLanguageCatalog.appleLanguages(localeProvider: { _ in [] }, capabilityProbe: probe)
        #expect(unavailable.isEmpty)
    }

    @Test("System defaults use canonical exact IDs before compatible variants")
    func systemDefaultsPreferExactTags() {
        #expect(initialSelection(["ko-KR"], options: ["en-US", "ko", "ko-KR"]) == "ko-KR")
        #expect(initialSelection(["ko-KR"], options: ["en-US", "ko"]) == "ko")
        #expect(initialSelection(["en-GB"], options: ["en-US", "en-GB", "en"]) == "en-GB")
        #expect(initialSelection(["EN_gb"], options: ["en-US", "en-GB"]) == "en-GB")
        #expect(initialSelection(["en-GB"], options: ["en_US"]) == "en_US")
        // Preference order wins across languages; exactness ranks within a preference.
        #expect(initialSelection(["ko-KR", "en-GB"], options: ["en-GB", "ko"]) == "ko")
    }

    @Test("Base-language fallback is deterministic and never picks an unrelated first option")
    func systemDefaultsChooseCompatibleVariants() {
        #expect(initialSelection(["en"], options: ["ko-KR", "en-US"]) == "en-US")
        #expect(initialSelection(["xx-ZZ", "bn-BD"], options: ["en", "bn"]) == "bn")
        #expect(initialSelection(["xx-ZZ"], options: ["en", "ko"]).isEmpty)
        #expect(initialSelection([], options: ["en"]).isEmpty)
        #expect(initialSelection(["en"], options: []).isEmpty)
        #expect(initialSelection(["not-a-language", "en--US"], options: ["en"]).isEmpty)
    }

    @Test("Unavailable system regions use the language's likely region, not alphabetical order")
    func systemDefaultsPreferLikelyRegions() {
        let english = ["en-AU", "en-GB", "en-US"]
        #expect(initialSelection(["en-KR"], options: english) == "en-US")
        #expect(initialSelection(["en-KR"], options: Array(english.reversed())) == "en-US")
        #expect(initialSelection(["en-AU"], options: english) == "en-AU")
        #expect(initialSelection(["fr-KR"], options: ["fr-BE", "fr-CA", "fr-FR"]) == "fr-FR")
        #expect(initialSelection(["nl-KR"], options: ["nl-BE", "nl-NL"]) == "nl-NL")
        let inventory = MeetingLanguageOption.deduplicated(
            (english + ["fr-BE", "fr-FR", "nl-BE", "nl-NL"]).map { MeetingLanguageOption(id: $0) },
            preferredLanguages: ["ko-KR"]
        )
        #expect(Set(inventory.map(\.id)) == ["en-US", "fr-FR", "nl-NL"])
    }

    @Test("Chinese defaults preserve script distinctions and do not substitute Cantonese")
    func systemDefaultsPreserveChineseIdentity() {
        #expect(initialSelection(["zh-Hant"], options: ["zh-Hans", "yue"]).isEmpty)
        #expect(initialSelection(["zh-TW"], options: ["zh-CN", "yue"]).isEmpty)
        #expect(initialSelection(["zh-Hant"], options: ["zh-Hans-CN", "zh-Hant-TW", "yue"]) == "zh-Hant-TW")
        #expect(initialSelection(["zh-Hans"], options: ["zh-Hant-TW", "yue"]).isEmpty)
        // Whisper's script-neutral Mandarin code is not its distinct yue token.
        #expect(initialSelection(["zh-Hant-TW"], options: ["yue", "zh"]) == "zh")
        #expect(initialSelection(["yue-Hant-HK"], options: ["zh"]).isEmpty)
        #expect(initialSelection(["yue-Hant-HK"], options: ["zh", "yue"]) == "yue")
        #expect(initialSelection(["zh-yue-HK"], options: ["zh", "yue"]) == "yue")
        #expect(initialSelection(["cmn-TW"], options: ["zh-Hant", "yue"]) == "zh-Hant")
    }

    @Test("Defaults fill late inventories independently and preserve any nonempty selection")
    func systemDefaultsPreserveSelections() {
        let preferences = ["ko-KR"]
        let waiting = initialSelection(preferences, options: [])
        let spoken = initialSelection(preferences, options: ["ko-KR"], current: waiting)
        #expect(spoken == "ko-KR")
        #expect(initialSelection(preferences, options: ["en", "zh-Hans"]).isEmpty)
        #expect(initialSelection(preferences, options: ["ko"]) == "ko")
        #expect(initialSelection(["en-US"], options: ["en-US"], current: spoken) == "ko-KR")
        #expect(initialSelection(preferences, options: ["ko"], current: "fr-FR") == "fr-FR")
        #expect(initialSelection(preferences, options: [], current: "fr-FR") == "fr-FR")
    }

    @Test("System defaults ignore app-local language overrides when OS preferences exist")
    func systemLanguageDomainPrecedence() {
        let preferences = MeetingLanguageOption.preferredLanguages(global: ["ko-KR", "en-US"], fallback: ["fr-FR"])
        #expect(preferences == ["ko-KR", "en-US"])
        #expect(initialSelection(preferences, options: ["fr", "ko"]) == "ko")
        #expect(MeetingLanguageOption.preferredLanguages(global: nil, fallback: ["fr-FR"]) == ["fr-FR"])
        #expect(MeetingLanguageOption.preferredLanguages(global: [], fallback: ["fr-FR"]) == ["fr-FR"])
    }

    @Test("Bare, regional and provider aliases share one selectable language")
    func equivalentLanguageInventory() {
        let families = [
            ["ko", "ko-KR", "ko_KR"], ["en", "en-US", "en-GB"],
            ["jv", "jw", "jv-ID"], ["tl", "fil", "fil-PH"],
            ["no", "nb", "nb-NO"], ["he", "iw", "he-IL"],
            ["id", "in", "id-ID"], ["yi", "ji"],
            ["zh", "cmn", "zh-cmn-Hans-CN", "zh-Hans-CN"]
        ]
        for family in families {
            let options = family.map { MeetingLanguageOption(id: $0) }
            let inventory = MeetingLanguageOption.deduplicated(options, preferredLanguages: [family[0]])
            #expect(inventory.count == 1)
            #expect(family.allSatisfy { inventory.first?.isEquivalent(to: $0) == true })
            #expect(inventory == MeetingLanguageOption.deduplicated(Array(options.reversed()), preferredLanguages: [family[0]]))
        }
        let korean = MeetingLanguageOption.deduplicated(["ko", "ko-KR"].map { MeetingLanguageOption(id: $0) },
            preferredLanguages: ["ko-KR"])
        #expect(korean.map(\.id) == ["ko-KR"])
        // Matching aliases still returns the engine's exact ID, not a new tag.
        #expect(initialSelection(["jv-ID"], options: ["jw"]) == "jw")
        #expect(initialSelection(["fil-PH"], options: ["tl"]) == "tl")
        #expect(initialSelection(["nb-NO"], options: ["no"]) == "no")
    }

    @Test("Deduplication preserves meaningful scripts and distinct languages")
    func distinctLanguageInventory() {
        let options = ["zh", "zh-Hans-CN", "zh-Hant-TW", "yue-Hant-HK", "sr", "sr-Cyrl-RS", "sr-Latn-RS", "nb", "nn"]
            .map { MeetingLanguageOption(id: $0) }
        let inventory = MeetingLanguageOption.deduplicated(options, preferredLanguages: ["zh-Hant-TW", "sr-Latn-RS"])
        #expect(inventory.count == 7)
        #expect(inventory.contains { $0.id == "zh-Hant-TW" })
        #expect(inventory.contains { $0.id == "sr-Latn-RS" })
        for option in options {
            #expect(inventory.filter { $0.isEquivalent(to: option.id) }.count == 1)
        }
        #expect(!MeetingLanguageOption(id: "zh-Hant").isEquivalent(to: "zh-Hans"))
        #expect(!MeetingLanguageOption(id: "zh").isEquivalent(to: "yue"))
        #expect(!MeetingLanguageOption(id: "sr-Latn").isEquivalent(to: "sr-Cyrl"))
    }

    @Test("Unavailable Whisper adds no languages; installed Whisper merges equivalents")
    func sourceProviderInventory() {
        let apple = ["ko-KR", "en-US", "sr-Cyrl-RS", "sr-Latn-RS"].map { MeetingLanguageOption(id: $0) }
        let appleOnly = MeetingTranscriptionLanguages.options(apple: apple, whisperAvailable: false)
        #expect(appleOnly.count == apple.count)
        #expect(!appleOnly.contains { $0.isEquivalent(to: "bn") })
        #expect(MeetingTranscriptionLanguages.options(apple: [], whisperAvailable: false).isEmpty)
        let combined = MeetingTranscriptionLanguages.options(apple: apple, whisperAvailable: true)
        #expect(combined.filter { $0.isEquivalent(to: "ko") }.count == 1)
        #expect(combined.contains { $0.isEquivalent(to: "bn") })
        #expect(combined.contains { $0.isEquivalent(to: "sr-Cyrl") })
        #expect(combined.contains { $0.isEquivalent(to: "sr-Latn") })
        for option in combined {
            #expect(combined.filter { $0.isEquivalent(to: option.id) }.count == 1)
        }
    }

    private func initialSelection(_ preferences: [String], options: [String], current: String = "") -> String {
        MeetingLanguageOption.initialSelection(current: current, options: options.map { MeetingLanguageOption(id: $0) },
                                               preferredLanguages: preferences)
    }

    /// Token-only test double: no model loading, authorization or downloads.
    private struct LanguageTokenizer: WhisperTokenizer {
        var omitted: String? = nil
        var aliasToEnglish: String? = nil
        let specialTokens = SpecialTokens(
            endToken: 50_257, englishToken: 50_259, noSpeechToken: 50_363,
            noTimestampsToken: 50_364, specialTokenBegin: 50_257, startOfPreviousToken: 50_362,
            startOfTranscriptToken: 50_258, timeTokenBegin: 50_365,
            transcribeToken: 50_360, translateToken: 50_359, whitespaceToken: 220
        )
        var allLanguageTokens: Set<Int> {
            Set(MeetingLanguageCatalogTests.pinnedCodes.enumerated().compactMap { index, code in
                code == omitted ? nil : 50_259 + index
            })
        }
        func convertTokenToId(_ token: String) -> Int? {
            if let aliasToEnglish, token == "<|\(aliasToEnglish)|>" { return specialTokens.englishToken }
            guard let index = MeetingLanguageCatalogTests.pinnedCodes.firstIndex(where: { "<|\($0)|>" == token }),
                  MeetingLanguageCatalogTests.pinnedCodes[index] != omitted else { return nil }
            return 50_259 + index
        }
        func convertIdToToken(_ id: Int) -> String? {
            let index = id - 50_259
            guard MeetingLanguageCatalogTests.pinnedCodes.indices.contains(index) else { return nil }
            return "<|\(MeetingLanguageCatalogTests.pinnedCodes[index])|>"
        }
        func encode(text: String) -> [Int] { preconditionFailure("Token-only fixture") }
        func decode(tokens: [Int]) -> String { preconditionFailure("Token-only fixture") }
        func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
            preconditionFailure("Token-only fixture")
        }
    }
}
