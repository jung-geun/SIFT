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
6. `AppLanguage.supportedIdentifiers` is an explicit UI allow-list. A UI locale is not selectable merely because a partial `.lproj` exists; it is added only after user-facing catalogs are translated. Meeting source and summary language capabilities are separate from this list.

The shipped selections are Korean (`ko`), English (`en`), Spanish (`es`), Japanese (`ja`), Simplified Chinese (`zh-Hans`), French (`fr`), Italian (`it`), and German (`de`). Picker names are stable native names, independent of the current app language.

Preference resolution accepts case-insensitive regional aliases and underscores (for example `es-MX`, `fr_CA`, and `de-CH`). Chinese `zh`, `zh-CN`, and `zh-SG` select Simplified Chinese; an explicit `Hans` script takes precedence over region. Traditional Chinese (`zh-Hant`, or an unqualified `zh-TW`/`zh-HK`/`zh-MO`) is not a UI selection and preference resolution continues to the next system preference. `supportedLanguage(for:)` returns `nil` outside the UI language contract instead of silently treating content as Korean. Only exhausted app preference resolution falls back to Korean.

Formatting uses the selected language and script with the device region, retaining regional date/time conventions. Bundle lookup tries the exact identifier, then its language code, then English; it never adds Korean as a resource fallback for a non-Korean selection.

`speechLanguageTag` supplies `ko-KR`, `en-US`, `es-ES`, `ja-JP`, `zh-CN`, `fr-FR`, `it-IT`, or `de-DE` to speech consumers. These identifiers do not guarantee backend support: the existing runtime capability checks must reject unavailable recognizers, models, or languages. `outputLanguageName` is an English machine-instruction name (including “Simplified Chinese”), not a localized picker label.

## Translation rules

- Use stable semantic keys such as `settings.language.label`; do not use translated sentences as new keys.
- Add complete values for all eight shipped locales for every reachable key, including keys used through custom localization helpers that Xcode does not automatically extract.
- Keep source-language comments specific enough for translators to understand subject, audience, and interpolation order.
- Use String Catalog plural variations (`one`, `other`, and any language-specific categories) for counts. Never write `item(s)`, concatenate plural suffixes, or branch on `count == 1` in UI code.
- Use `String(localized:)`, catalog-backed `AppLanguage.localized`, or `AppLanguage.localizedCount` for user-facing copy. Do not expose `Error.localizedDescription` directly; map errors to an app-owned key and log private diagnostics separately.
- Use `Locale`/`DateFormatter`/`NumberFormatter`/`RelativeDateTimeFormatter` from the selected language for dates, numbers, times, and relative units. Never assemble locale-sensitive dates manually.
- Machine prompts are not UI resources. Prompt builders receive an explicit output language; source email/transcript content, IDs, and factual quotations remain unchanged. Meeting prompts receive required `sourceLanguageTag` and `summaryLanguageTag` strings, retaining the exact selected output locale for every generated natural-language field (including decisions, questions, and action notes). Do not infer output language from prompt prose, UI language, or source-script detection.
- Manual meeting processing uses persisted `MeetingRecord.languageTag`. Automatic mode is a separate `automaticLanguageDetection` flag; it never stores `auto` as a locale or overwrites manual/summary preferences. `processingSourceLanguageTag` uses supported detected speech evidence for one language, `mul` for mixed speech, and `und` for absent/invalid evidence. Unknown/mixed/nonlinguistic meta-tags cannot gain provider support through locale fallback. The independent `summaryLanguageTag` selects generated summary output; its empty legacy default retains the saved source preference, never the UI locale. Suspended AI work checks mode and exact detected evidence before committing.
- New recording/import drafts default spoken and summary choices independently from `Locale.preferredLanguages` within their supported inventories; nonempty choices survive refresh. Spoken-language pickers also offer explicit automatic detection, while summary pickers never do. Automatic recording requires enabled, installed Whisper. Its first roughly ten-second source-local estimate selects supported Apple live transcription and replays the captured prefix; short stops use available audio. Automatic saved-audio decoding redetects per window and preserves raw files on failure. Import/retry may retain automatic mode before model installation. Recovery/sync preserve the separate flag, with missing legacy fields defaulting to manual `false`. Changing a record affects its next request, not its existing text.
- Catalog-backed AI accuracy warnings appear in capture/import, language selection and summary surfaces: transcripts, translations, summaries, names and tasks can be wrong or incomplete at any time. Review against original audio before use. All eight UI locales contain these notices; this does not certify recognition or generation quality in every selectable content language.
- Routine UI renders uncertainty from structured sample count, distinct completion days, and confidence, using catalog plural resources and the existing prediction-confidence threshold. Persisted uncertainty prose and feedback action raw values remain unchanged; views localize the display labels and error messages without changing service contracts.

## Domain language capabilities

- `MeetingLanguageCatalog.appleLanguages(displayLocale:)` unions the runtime `SpeechTranscriber.supportedLocales` and `DictationTranscriber.supportedLocales` lists, retains full BCP-47 script/region variants, deduplicates by tag, and sorts localized names with a tag tie-breaker. Listing checks backend availability and asset `.unsupported` states without permissions, asset installation/reservation, or session creation. Downloadable-but-not-installed locales remain selectable; actual session setup retains its existing runtime gates and never switches to an online recognizer. Sources: Apple's [SpeechTranscriber supportedLocales](https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales) and [DictationTranscriber supportedLocales](https://developer.apple.com/documentation/speech/dictationtranscriber/supportedlocales).
- `MeetingLanguageCatalog.whisperLanguages(displayLocale:)` exposes all 100 unique codes in [pinned WhisperKit 1.1.0 Constants.languages](https://github.com/argmaxinc/WhisperKit/blob/1e2a163736dfa5a198e637ae44c114e1c6d5cc2d/Sources/WhisperKit/Core/Models.swift), backed by [the pinned large-v3 tokenizer](https://huggingface.co/openai/whisper-large-v3/blob/06f233fe06e710322aca913c1bc4249a0d71fce1/tokenizer_config.json), independently of app translations. Requests resolve supported base/script/region tags and upstream name aliases to exact decoder codes, including BCP-47 `jv` → Whisper `jw`, `fil` → `tl`, `nb` → `no`, `cmn` → `zh`, and explicit `zh-yue` → `yue`. `zh-Hans`, `zh-Hant`, and `zh-HK` all request `zh`; a Traditional script or Hong Kong region alone never implies Cantonese. Whisper cannot force a script/region within a language token. Unknown/malformed requests fail rather than defaulting to English, and loaded decoder/tokenizer constraints are checked before decoding. Explicit automatic mode passes `nil` rather than a UI or manual locale; summary-language choices never pass that mode. Single-language output retains the exact verified language-token code (including `zh`, `yue`, and legacy `jw`) without an `AppLanguage` round-trip; mixed/silent output has no single detected language tag. Catalog coverage is not a claim of measured recognition quality.
- Pinned Whisper results can report the final silent window's language rather than earlier speech. Actual speech language is taken only from an exact SOT `50258` followed by a verified tokenizer language token and inherited within that result's same-seek window. Empty/silent/padding-only results contribute no language. A task-local SDK window adapter uses actual `seek + segmentSize` to exclude valid decoder padding before chunk offsets; malformed, mismatched or numerically corrupt timings remain rejected. These boundaries do not certify recognition accuracy or separate overlapping voices.
- Meeting AI post-processing accepts content language tags outside `AppLanguage`. Apple checks both source and requested output against `SystemLanguageModel.default.supportsLocale` immediately before generation; the selection catalog also incorporates runtime `supportedLanguages`. Unsupported input/output or an unavailable model cannot produce an English substitute. Proofreading uses the source-language tag and preserves each segment's original language and facts, including mixed-language speech; it is not translation.
- `MeetingSummaryLanguages` documents coverage for each selectable local checkpoint: default MiniCPM5-1B is limited to documented English/Simplified Chinese; Qwen3.5 2B/4B have a broad enumerated subset of their advertised 201-language coverage, based on the published Qwen 119-language table. This is not a claim of measured fluency or an exhaustive 201-language inventory. Unknown custom models have no inferred language coverage. See [MiniCPM5 model card](https://huggingface.co/openbmb/MiniCPM5-1B), [Qwen3.5 model card](https://huggingface.co/Qwen/Qwen3.5-2B), and [Qwen language inventory](https://qwenlm.github.io/blog/qwen3/#key-features).
- Rule fallback returns distinguishable `sourceExcerpts`, not a translated/generated summary, and retains the real routing failure reason. Its title/summary are source excerpts; stale generated decisions/questions are removed. The deterministic action extractor recognizes Korean/English source request/commitment patterns only, without claiming other-language grammar. Consent and local-only routing remain mandatory; meetings never route to OpenAI.
- Deterministic email deadline/calendar-invitation recognition and rule-priority keyword dictionaries retain their Korean/English source grammar. New app languages do not imply new parser grammar; unrecognized mail retains original subject/body excerpts, and rule fallback does not manufacture facts. Generated labels, fallback reasons, and recognized invitation summaries are still catalog-localized in the selected app language.
- Apple Foundation Models retains its framework, OS, device, Apple Intelligence, and Siri-language availability gates. Locale support is queried through Apple's [fallback-aware supportsLocale API](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/supportslocale(_:)); neither the UI allow-list nor a hardcoded Apple-language list can grant support. No hardware/fluency result is inferred from catalog or prompt coverage. POSIX locales remain intentional for wire-date parsing, machine serialization, and stable search/identity normalization rather than presentation.

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
