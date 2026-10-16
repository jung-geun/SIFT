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

The shipped selections are Korean (`ko`), English (`en`), Spanish (`es`), Japanese (`ja`), Simplified Chinese (`zh-Hans`), French (`fr`), Italian (`it`), and German (`de`). Picker names are stable native names, independent of the current app language.

Preference resolution accepts case-insensitive regional aliases and underscores (for example `es-MX`, `fr_CA`, and `de-CH`). Chinese `zh`, `zh-CN`, and `zh-SG` select Simplified Chinese; an explicit `Hans` script takes precedence over region. Traditional Chinese (`zh-Hant`, or an unqualified `zh-TW`/`zh-HK`/`zh-MO`) is unsupported and preference resolution continues to the next system preference. `supportedLanguage(for:)` returns `nil` for unsupported domain languages instead of silently treating them as Korean. Only exhausted app preference resolution falls back to Korean.

Formatting uses the selected language and script with the device region, retaining regional date/time conventions. Bundle lookup tries the exact identifier, then its language code, then English; it never adds Korean as a resource fallback for a non-Korean selection.

`speechLanguageTag` supplies `ko-KR`, `en-US`, `es-ES`, `ja-JP`, `zh-CN`, `fr-FR`, `it-IT`, or `de-DE` to speech consumers. These identifiers do not guarantee backend support: the existing runtime capability checks must reject unavailable recognizers, models, or languages. `outputLanguageName` is an English machine-instruction name (including “Simplified Chinese”), not a localized picker label.

## Translation rules

- Use stable semantic keys such as `settings.language.label`; do not use translated sentences as new keys.
- Add complete values for all eight shipped locales for every reachable key, including keys used through custom localization helpers that Xcode does not automatically extract.
- Keep source-language comments specific enough for translators to understand subject, audience, and interpolation order.
- Use String Catalog plural variations (`one`, `other`, and any language-specific categories) for counts. Never write `item(s)`, concatenate plural suffixes, or branch on `count == 1` in UI code.
- Use `String(localized:)`, catalog-backed `AppLanguage.localized`, or `AppLanguage.localizedCount` for user-facing copy. Do not expose `Error.localizedDescription` directly; map errors to an app-owned key and log private diagnostics separately.
- Use `Locale`/`DateFormatter`/`NumberFormatter`/`RelativeDateTimeFormatter` from the selected language for dates, numbers, times, and relative units. Never assemble locale-sensitive dates manually.
- Machine prompts are not UI resources. Prompt builders receive an explicit output language and require every generated natural-language field to use `outputLanguageName`; source email/transcript content, IDs, and factual quotations remain unchanged. Do not infer output language from prompt prose or source-script detection.
- Meeting processing uses the persisted `MeetingRecord.languageTag` for transcription, proofreading, and summary language. Meeting screen chrome, status, errors, and accessibility text use `AppLanguage.current`.
- Routine UI renders uncertainty from structured sample count, distinct completion days, and confidence, using catalog plural resources and the existing prediction-confidence threshold. Persisted uncertainty prose and feedback action raw values remain unchanged; views localize the display labels and error messages without changing service contracts.

## Domain language capabilities

- Apple live/retry speech selection still probes `SpeechTranscriber` and `DictationTranscriber` for a supported locale and model assets at runtime. A translated app selection does not bypass a rejection, asset installation failure, unavailable hardware, or OS restriction.
- Saved-audio Whisper transcription uses the pinned multilingual large-v3 graph and tokenizer. Explicit shipped language tags and regional aliases map to their language token (`zh-Hans` maps to Whisper `zh`); `nil` retains automatic detection. Unsupported tags, including Traditional Chinese selections, are rejected rather than substituted with Korean. Whisper's `zh` detection does not distinguish Chinese scripts. A detected language outside the app allow-list remains its SDK identifier; it is not relabeled as a supported app language.
- Meeting AI post-processing rejects a stored language tag outside the supported language contract instead of generating Korean summaries for it. Proofreading preserves transcript language and source facts; it is not translation. Action-import provenance labels use the app language while retaining the source draft title, notes, assignee, and stable IDs.
- The deterministic meeting action extractor recognizes Korean and English source request/commitment patterns only. App localization does not extend its grammar to six additional languages: unmatched source text remains available in the transcript, without fabricated action drafts. Model-backed analysis has explicit selected-language output instructions but is still subject to provider/runtime availability.
- Deterministic email deadline/calendar-invitation recognition and rule-priority keyword dictionaries retain their Korean/English source grammar. New app languages do not imply new parser grammar; unrecognized mail retains original subject/body excerpts, and rule fallback does not manufacture facts. Generated labels, fallback reasons, and recognized invitation summaries are still catalog-localized in the selected app language.
- Apple Foundation Models retains its framework, OS, device, Apple Intelligence, and Siri-language availability gates. An explicit output-language requirement is not a claim of provider availability or measured generation quality in that language; no hardware/fluency result is inferred from catalog or prompt coverage. POSIX locales remain intentional for wire-date parsing, machine serialization, and stable search/identity normalization rather than presentation.

## Adding a language

For any additional language:

1. Add complete translations to `Localizable.xcstrings` and `InfoPlist.xcstrings`, including plural categories required by that language.
2. Add its canonical identifier, native picker name, speech tag, and English output-language name to `AppLanguage`, and update the project's `knownRegions`.
3. Audit every direct binary language branch in models, errors, prompts, and services. Replace generated/display prose with catalog keys or language-aware formatters; existing default-value branches inside catalog lookups may remain. Preserve raw identifiers, stored source prose, and source-language parser vocabulary.
4. Check transcription provider capabilities independently before exposing the locale for meeting content. App UI support is not a claim of backend/model language support.
5. Add behavior tests for alias/script resolution, unsupported languages, override/reset, selected-locale formatting, count-unit boundaries, and source/identity preservation. Inspect prompt output-language requirements separately; remove wording-only snapshots rather than repinning translated sentences.
6. Verify the language picker, system fallback, explicit override, and reset-to-system behavior on a simulator whose system language differs from the selected app language.

A partially translated language stays out of the allow-list. This is deliberate: showing a mixture of the new language and Korean is worse than retaining the previous supported language.

## Verification checklist

```sh
python3 -m json.tool ios/todo/Localizable.xcstrings >/dev/null
xcrun xcstringstool compile ios/todo/Localizable.xcstrings --output-directory /tmp/sift-localizable --language ko --language en --language es --language ja --language zh-Hans --language fr --language it --language de --dry-run
xcrun xcstringstool compile ios/todo/InfoPlist.xcstrings --output-directory /tmp/sift-infoplist --language ko --language en --language es --language ja --language zh-Hans --language fr --language it --language de --dry-run
xcodebuild test -project ios/todo.xcodeproj -scheme todo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' \
  -only-testing:todoTests/LocalizationRuntimeTests \
  -parallel-testing-enabled NO
```

Reviewers must inspect both the catalog diff and the runtime call sites. A passing catalog compile alone does not prove that dynamic strings, plural behavior, AI output, or locale formatting are correct.
