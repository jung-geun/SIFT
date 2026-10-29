import Combine
import Foundation

/// User intent is device-local and shared by recording, import and detail pickers.
/// Catalog resolution is read-only: temporary provider/model limits must not
/// replace the user's saved language or automatic-transcription mode.
@MainActor
final class MeetingLanguagePreferences: ObservableObject {
    static let shared = MeetingLanguagePreferences()

    @Published private(set) var sourceLanguageTag: String
    @Published private(set) var summaryLanguageTag: String
    @Published private(set) var automaticLanguageDetection: Bool

    private let defaults: UserDefaults
    private static let sourceKey = "pieroot.todo.meeting.sourceLanguageTag"
    private static let summaryKey = "pieroot.todo.meeting.summaryLanguageTag"
    private static let automaticKey = "pieroot.todo.meeting.automaticLanguageDetection"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sourceLanguageTag = defaults.string(forKey: Self.sourceKey) ?? ""
        summaryLanguageTag = defaults.string(forKey: Self.summaryKey) ?? ""
        automaticLanguageDetection = defaults.bool(forKey: Self.automaticKey)
    }

    // Call only from explicit picker actions, never from view/catalog lifecycle.
    func selectSource(_ tag: String) {
        defaults.set(tag, forKey: Self.sourceKey)
        sourceLanguageTag = tag
        selectAutomaticDetection(false)
    }

    func selectSummary(_ tag: String) {
        defaults.set(tag, forKey: Self.summaryKey)
        summaryLanguageTag = tag
    }

    func selectAutomaticDetection(_ enabled: Bool) {
        // Automatic selection applies to each saved track after Stop. It must
        // never overwrite the last manual language or invent a live language.
        defaults.set(enabled, forKey: Self.automaticKey)
        automaticLanguageDetection = enabled
    }

    func sourceSelection(
        options: [MeetingLanguageOption],
        preferredLanguages: [String] = MeetingLanguageOption.systemPreferredLanguages
    ) -> String {
        Self.selection(saved: sourceLanguageTag, options: options, preferredLanguages: preferredLanguages)
    }

    func summarySelection(
        options: [MeetingLanguageOption],
        preferredLanguages: [String] = MeetingLanguageOption.systemPreferredLanguages
    ) -> String {
        Self.selection(saved: summaryLanguageTag, options: options, preferredLanguages: preferredLanguages)
    }

    private static func selection(
        saved: String, options: [MeetingLanguageOption], preferredLanguages: [String]
    ) -> String {
        if !saved.isEmpty {
            if options.contains(where: { $0.id == saved }) { return saved }
            let compatible = MeetingLanguageOption.initialSelection(
                current: "", options: options, preferredLanguages: [saved])
            if !compatible.isEmpty { return compatible }
        }
        // No unrelated first-option/Korean/English default. An empty result asks
        // the user to choose when no system preference is supported.
        return MeetingLanguageOption.initialSelection(
            current: "", options: options, preferredLanguages: preferredLanguages)
    }
}
