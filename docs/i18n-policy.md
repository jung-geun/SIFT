# SIFT i18n policy

## Scope

The app UI is localized independently from user/source content. Translation values live in the workspace String Catalogs:

- `ios/todo/Localizable.xcstrings` — UI, accessibility, errors, and plural resources.
- `ios/todo/InfoPlist.xcstrings` — permission prompts and the display name.

Persisted raw identifiers, provider IDs, meeting transcript text, email content, calendar titles, and user vocabulary are never translated in storage.

## Language selection contract

1. The default is the app's system preference (`Bundle.main.preferredLocalizations`).
2. A user selection is a local, device-only override at `pieroot.todo.appLanguageOverride`.
3. Selecting **System Language** removes the override.
4. `AppLanguage.current` resolves the override first, then the system preference, then Korean as the final safe fallback.
5. The root scene applies `AppLanguage.current.locale` through SwiftUI's `\.locale` environment. A language-change notification refreshes the root without destroying tab or navigation state.
6. `AppLanguage.supportedIdentifiers` is an explicit allow-list. A locale is not selectable merely because a partial `.lproj` exists; it is added only after all user-facing catalogs and domain/AI output paths are translated.

Language names in the picker are generated from `Locale`, so a future locale can display its native language name without hard-coded English-only labels. Bundle lookup tries the exact BCP-47 identifier, then its language code, then English.

## Translation rules

- Use stable semantic keys such as `settings.language.label`; do not use translated sentences as new keys.
- Add both `ko` and `en` values for every reachable key in the current release.
- Keep source-language comments specific enough for translators to understand subject, audience, and interpolation order.
- Use String Catalog plural variations (`one`, `other`, and any language-specific categories) for counts. Never write `item(s)`, concatenate plural suffixes, or branch on `count == 1` in UI code.
- Use `String(localized:)`, catalog-backed `AppLanguage.localized`, or `AppLanguage.localizedCount` for user-facing copy. Do not expose `Error.localizedDescription` directly; map errors to an app-owned key and log private diagnostics separately.
- Use `Locale`/`DateFormatter`/`NumberFormatter`/`RelativeDateTimeFormatter` from the selected language for dates, numbers, times, and relative units. Never assemble locale-sensitive dates manually.
- Machine prompts are not UI resources. Prompt builders receive an explicit output language and use the selected language's name; source email/transcript content remains unchanged.
- Meeting processing uses the persisted `MeetingRecord.languageTag` for transcription, proofreading, and summary language. Meeting screen chrome, status, errors, and accessibility text use `AppLanguage.current`.

## Adding a language

For a new language, for example Japanese (`ja`):

1. Add the language to `Localizable.xcstrings` and `InfoPlist.xcstrings` with complete translations, including plural categories required by that language.
2. Add `ja` to `AppLanguage.supportedIdentifiers` only after catalog compilation succeeds.
3. Audit every `language == .english ? … : Korean` fallback in models, errors, prompts, and services. Replace binary branches with catalog keys or language-aware formatters.
4. Add the locale to meeting/transcription provider capability checks before exposing it for meeting content.
5. Add exact runtime assertions for representative UI strings, singular/plural counts, dates, numbers, and error messages.
6. Verify the language picker, system fallback, explicit override, and reset-to-system behavior on a simulator whose system language differs from the selected app language.

A partially translated language stays out of the allow-list. This is deliberate: showing a mixture of the new language and Korean is worse than retaining the previous supported language.

## Verification checklist

```sh
python3 -m json.tool ios/todo/Localizable.xcstrings >/dev/null
xcrun xcstringstool compile ios/todo/Localizable.xcstrings --output-directory /tmp/sift-localizable --language ko --language en --dry-run
xcrun xcstringstool compile ios/todo/InfoPlist.xcstrings --output-directory /tmp/sift-infoplist --language ko --language en --dry-run
xcodebuild test -project ios/todo.xcodeproj -scheme todo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' \
  -only-testing:todoTests/LocalizationRuntimeTests \
  -parallel-testing-enabled NO
```

Reviewers must inspect both the catalog diff and the runtime call sites. A passing catalog compile alone does not prove that dynamic strings, plural behavior, AI output, or locale formatting are correct.
