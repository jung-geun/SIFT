import SwiftUI

struct MeetingLanguagePicker: View {
    let title: String
    @Binding var selection: String
    let options: [MeetingLanguageOption]
    let identifier: String
    var automaticLanguageDetection: Binding<Bool>? = nil
    var automaticDetectionAvailable = true
    var savedAudioOnly = false

    var body: some View {
        NavigationLink {
            MeetingLanguagePickerDestination(selection: $selection, options: options,
                title: title, identifier: identifier,
                automaticLanguageDetection: automaticLanguageDetection,
                automaticDetectionAvailable: automaticDetectionAvailable, savedAudioOnly: savedAudioOnly)
        } label: {
            LabeledContent(title, value: automaticLanguageDetection?.wrappedValue == true
                ? MeetingLanguageCopy.automaticTitle
                : selection.isEmpty ? MeetingLanguageCopy.text("meeting.languages.choose", "Choose a language")
                : MeetingLanguageOption(id: selection).displayName(locale: AppLanguage.current.locale))
        }
        .accessibilityIdentifier(identifier)
    }

}

private struct MeetingLanguagePickerDestination: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    let options: [MeetingLanguageOption]
    let title: String
    let identifier: String
    let automaticLanguageDetection: Binding<Bool>?
    let automaticDetectionAvailable: Bool
    let savedAudioOnly: Bool
    @State private var search = ""

    var body: some View {
        List {
            MeetingAIAccuracyNotice()
            if let automaticLanguageDetection, automaticDetectionAvailable {
                Button {
                    automaticLanguageDetection.wrappedValue = true
                    dismiss()
                } label: {
                    HStack {
                        Text(MeetingLanguageCopy.automaticTitle)
                        Spacer()
                        if automaticLanguageDetection.wrappedValue { Image(systemName: "checkmark") }
                    }
                }
                .accessibilityIdentifier("\(identifier).automatic")
                .accessibilityAddTraits(automaticLanguageDetection.wrappedValue ? .isSelected : [])
                MeetingAutomaticLanguageNotice(savedAudioOnly: savedAudioOnly)
            }
            ForEach(filtered) { option in
                Button {
                    selection = option.id
                    automaticLanguageDetection?.wrappedValue = false
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.displayName(locale: AppLanguage.current.locale))
                                .foregroundStyle(.primary)
                            Text(option.id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isSelected(option) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                }
                .accessibilityIdentifier("\(identifier).option.\(option.id)")
                .accessibilityAddTraits(isSelected(option) ? .isSelected : [])
            }
            if options.isEmpty {
                Text(MeetingLanguageCopy.text("meeting.languages.unavailable", "No supported languages are available for this engine on this device."))
            }
        }
        .appListStyle()
        .navigationTitle(title)
        // Keep search in this destination on every platform so no navigation search
        // controller can remain attached after Back or language selection.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                Label(MeetingLanguageCopy.text("meeting.languages.search", "Search languages"), systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("\(identifier).search.title")
                TextField(MeetingLanguageCopy.text("meeting.languages.search", "Search languages"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("\(identifier).search")
            }
            .padding(.horizontal, AppTheme.Spacing.page)
            .padding(.vertical, AppTheme.Spacing.item)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, ignoresSafeAreaEdges: [])
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func isSelected(_ option: MeetingLanguageOption) -> Bool {
        automaticLanguageDetection?.wrappedValue != true && option.isEquivalent(to: selection)
    }

    private var filtered: [MeetingLanguageOption] {
        let inventory = MeetingLanguageOption.deduplicated(options, displayLocale: AppLanguage.current.locale)
        guard !search.isEmpty else { return inventory }
        return inventory.filter {
            $0.id.localizedCaseInsensitiveContains(search)
                || $0.displayName(locale: AppLanguage.current.locale).localizedCaseInsensitiveContains(search)
                || $0.englishName.localizedCaseInsensitiveContains(search)
                || Locale(identifier: $0.id).localizedString(forIdentifier: $0.id)?.localizedCaseInsensitiveContains(search) == true
        }
    }
}

struct MeetingAIAccuracyNotice: View {
    var body: some View {
        Label(MeetingLanguageCopy.text("meeting.languages.accuracy", "AI can make mistakes at any time. Transcripts, translations, summaries, speaker names and tasks may be inaccurate or incomplete. Choose automatic detection or a spoken language and choose a summary language, compare results with the original audio, and review before use."), systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("meeting.languages.accuracy")
    }
}

struct MeetingAutomaticLanguageNotice: View {
    var savedAudioOnly = false

    var body: some View {
        Text(savedAudioOnly
             ? MeetingLanguageCopy.text("meeting.languages.automaticSavedNotice", "Whisper estimates the language separately for each saved-audio window and each source. It cannot guarantee recognition of language switches within a window or overlapping voices.")
             : MeetingLanguageCopy.text("meeting.languages.automaticLiveNotice", "Whisper initially estimates the language from about 10 seconds of audio per source. Sources are detected separately. After recording stops, it detects the language again for each saved-audio window. It cannot guarantee recognition of language switches within a window or overlapping voices."))
            .font(.caption).foregroundStyle(.secondary)
    }
}

enum MeetingLanguageCopy {
    static func text(_ key: String, _ fallback: String) -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current,
            comment: "Explicit meeting engine language selection and AI accuracy disclosure.")
    }
    static var sourceTitle: String { text("meeting.languages.source", "Spoken language") }
    static var summaryTitle: String { text("meeting.languages.summary", "Summary language") }
    static var automaticTitle: String { text("meeting.languages.automatic", "Automatic detection") }
    static var automaticRequiresWhisper: String { text("meeting.languages.automaticRequiresWhisper", "To record with automatic detection, enable advanced Whisper transcription and install its model in Settings → Beta features. Your language selection is kept; no model is downloaded automatically.") }
}
