---
layout: default
locale: en
lang: en
page_key: privacy
permalink: /en/privacy-policy.html
title: Privacy policy
description: How SIFT collects, uses, stores, transmits, and deletes information, and the choices available to you.
---

# Privacy policy

**App name**: SIFT: To-Do List  
**Operator**: jung-geun (independent developer)  
**Contact**: pieroot.02@gmail.com  
**Scheduled effective date**: November 12, 2026 (this revision announced: November 4, 2026; earlier revision scheduled for: November 9, 2026; previous effective date: October 27, 2026; initial effective date: July 31, 2026)

---

SIFT values your personal information. This policy clearly explains what information the app collects, uses, and stores, and how it does so.

**Full iCloud storage is a separate choice.** In versions that provide this feature, the full-storage paths below are used only after you review and consent to the expanded scope, including email bodies and meeting recordings. Existing consent to a narrower scope, or simply continuing to use the app, does not expand that scope.

**Notice of the October 27, 2026 revision**: Google AdMob advertising and consent management for iOS and iPadOS versions that provide ads (Section 1-11), connections to health and workout records (Section 1-10), and full app data storage in iCloud (Section 2) were added. This revision was announced on October 20, 2026 and takes effect on October 27. App versions providing those features will also be distributed only after the effective date.

**Notice of the revision scheduled for November 9, 2026**: This revision reflects transmission of transcripts and source labels for GPT re-summarization following explicit meeting-sharing consent and a direct request (Section 1-5); optional Mac meeting activity detection and output-source recording, audio downloads to user-selected files, and deletion of entire meetings (Section 1-7); and per-account on-device usage displays (Section 1-9). This revision is announced on November 1, 2026, and apps containing these changes will be publicly released on or after November 9, 2026, following a notice period of at least 7 days. Existing consent or continued use does not expand the transmission scope of the previous policy. External meeting requests require separate consent on each device.

**Release-date correction — November 4, 2026**: The public App Store record shows that 1.0.14 was released on November 2, 2026, contrary to the notice above promising release on or after November 9. This correction does not mean the notice period was met or retroactively expand existing consent.

**Notice of the revision scheduled for November 12, 2026**: On November 4, 2026, we newly announce periodic storage of email lists and complete bodies and background collection for accounts permitted on each device (Section 1-3), task proposals based only on required actions identified in complete bodies (Section 1-5), and on-device retention of original versions before sync-conflict resolution and user-selected restoration (Sections 2 and 5). We will allow at least 7 days after actual publication. Version 1.0.15 will be submitted for manual release and will not be released before November 12, 2026 at 00:00 KST. Existing separate consent boundaries for external transmission, full iCloud storage, and background access remain unchanged.

---

## 1. Information collected and purposes

### 1-1. Information entered directly

| Information | Purpose |
|------|------|
| Task titles, notes, deadlines, tags, and priorities | Task management |
| Persona types and descriptions | Personalizing AI priorities |

### 1-2. Automatically generated or collected information

| Information | How it is collected | Purpose |
|------|-----------|------|
| Audit events (creation, completion, and deletion times and sources) | Recorded automatically when tasks are processed | Behavioral pattern analysis |
| Behavioral pattern analysis results (completion time periods and statistics by tag) | On-device calculations and optional requests for OpenAI explanations | Behavioral explanations for user review and reference for prioritization |
| App settings (AI provider selection, email and calendar options, etc.) | Saving settings | Operating features |

### 1-3. Email integration (Gmail and Outlook; optional, enabled after explicit user consent)

- **Information and permissions**: Inbox message subjects, senders, snippets, and bodies. Gmail OAuth connections request the `gmail.modify` permission and can reflect user actions to view messages, mark them as read, and move them to the trash on Gmail's servers. Gmail and Outlook IMAP connections use the account's app password.
- **Purpose**: On-device summarization and organization of full email bodies, task suggestions based on Needs Review/Action items, and saving after user review.
- **Storage location**: Authoritative copies of original messages and analyses are kept in a separate on-device store. If you explicitly consent to the full iCloud storage scope, copies are replicated to the CloudKit private database for the same Apple account. Automatic email analysis takes place on the device; OpenAI requests for selected messages are subject to the separate consent in Section 1-5 below.
- **Credentials**: OAuth tokens and IMAP app passwords are stored in Keychain and used for authentication with the relevant provider. They can be restored through iCloud Keychain after full-storage consent and account verification. Device-specific access controls and background permissions for operational secrets, and slot pointers, are not transferred to a new device.
- **Communication with mail servers**: The app connects to Google LLC's Gmail REST API (`gmail.googleapis.com`) or TLS IMAP (`imap.gmail.com:993`), or Microsoft's Outlook TLS IMAP (`outlook.office365.com:993`), to retrieve email and reflect user-initiated actions to mark messages as read or move them to the trash.
- **Periodic on-device storage**: Message lists and full bodies may be saved periodically, independently of the automatic email analysis setting. Background fetching applies only to accounts you have approved on this device, and iOS determines when it actually runs. Incomplete or previously partial bodies are not used as evidence for task suggestions until the full body has been checked again.
- **External visual resources in HTML email**: Opening HTML email may automatically load HTTPS images, styles, and fonts. Those external hosts may record the viewing time and the device's IP address. JavaScript, forms, frames, media, and HTTP resources are blocked.

### 1-4. Calendar integration (optional, enabled after system permission is granted)

- **Information**: Calendar events (EventKit, read and write).
- **Purpose**: Adding eligible tasks to a selected system calendar only when you explicitly request it or separately consent to automatic registration, and importing calendar events as tasks. Automatic registration is off by default, and health (`health:`) sources are excluded. Target accounts are connected through the device's system calendar settings; no separate OAuth connection is added.
- **Processing location**: The on-device system calendar framework (EventKit). Separate calendar event context sent to OpenAI masks titles as `Busy` and includes only start and end times. However, tasks imported from external calendars and confirmed as active fall within the scope of general task-sharing consent, so their titles and notes may be transmitted.

### 1-5. Task prioritization and optional external analysis

- The default AI is Apple Intelligence. Only on devices whose hardware is unsupported may you explicitly allow the beta local language model alternative and use a model you install yourself. An inactive state or model preparation on a supported device is not treated as consent to use another model. If no model is available, on-device rules are used. Independently of an explicit choice of an external provider for task sorting, default meeting, persona, and behavioral analysis takes place on the device. GPT reanalysis of personas and behavior can be requested directly only with a connected account, separate activation, and sharing consent.
- **App Store country restrictions**: ChatGPT/OpenAI screens, authentication, model retrieval, connection tests, and analysis requests are blocked when StoreKit identifies the mainland China storefront (`CHN`) or when country information is unavailable. The app observes storefront changes and checks again when it becomes active. A transition to a blocked state stops ongoing requests and prevents late results from being applied. Country information is used only in memory to determine availability; it is not saved as a customer profile or used for advertising or tracking. Changing the language does not lift this restriction.
- **OpenAI analysis requests involving app data**: Provider activation, an official ChatGPT connection, subscription usage entitlement, and separate consent for each data category are all required. General task titles, notes, deadlines, and available time; selected email subjects and bodies; summaries of routine evidence derived from completion records; persona and behavioral explanations; and meeting transcripts for which you directly request re-summarization are used only within the relevant consent scope. Persona consent is checked even when persona context is included in task sorting. Meeting consent is a device-specific setting separate from consent for other data and is not enabled merely by connecting an account or restoring from iCloud.
- **Subscription connection test**: When you explicitly request it in settings, only a short, fixed test message is sent to OpenAI to check model availability and response completion. It does not use stored app data or task, email, routine, or persona-sharing consent. The connected account must have subscription usage entitlement, but the test can run even if the external analysis provider is off, and it may consume part of the subscription's usage allowance. It does not authorize activation of, or consent to, analysis of actual app data.
- **Models**: Basic requests use `gpt-6-luna`. Explicit advanced repeat requests for important email content, routines, and persona/behavioral explanations use `gpt-6.1-sol`. A model unavailable to the account is not automatically replaced with another model.
- **Account model list**: The connected account's OAuth token is used to retrieve the model list and display names and model IDs. This lookup does not perform inference or transmit stored app data, and it does not guarantee access to other APIs.
- **Per-account local usage**: Input, output, and cached input token counts provided in completed responses, response ID deduplication records, and the aggregation start date are stored on this device. A SHA-256 hash of the subject is used to distinguish accounts; original text, email addresses, and authentication tokens are not stored in the metrics. Cached input is a subset of input tokens. Missing figures are not estimated. These figures are not account-wide usage, usage in other apps, monthly usage, charges, or remaining allowances. They are not synced with iCloud and remain after an ordinary disconnection, but are erased when all connection records are deleted. Subscription plans that cannot be established through the public connection contract are not guessed.
- **Automatic email processing**: Available Apple Intelligence analyzes the full body. If it fails or is unsupported, on-device rules may display a factual summary only. Tasks are suggested only from Needs Review/Action items in a successful body analysis; if such items are absent or cannot be confirmed, tasks are not invented from the subject or summary. Tasks originating from email or meetings are excluded from automatic external sorting. OpenAI analysis of a selected email's body takes place only after email-sharing consent and when you directly press the relevant request button.
- **Meeting and calendar boundaries**: Automatic meeting summaries, transcription, and speaker analysis take place on the device. Only after separate meeting-sharing consent and when you directly choose **Summarize again with ChatGPT → Send and summarize again** does the app send the selected meeting's transcript, summary language, format, and writing instructions to OpenAI. For meetings with multiple sources, all sources must be ready, and source names and speaker labels may be included. Original audio, other meetings, the personal vocabulary, and previous summaries are not sent. Titles and notes in separate calendar event context are not sent, but titles and notes of tasks imported from external calendars and confirmed by you are subject to general task-sharing consent.
- **Responses and cancellation**: Requests use the public Responses API with `store:false` and `stream:true`, and only completed responses are used. For meetings, only successful results with verified transcript grounding replace saved summaries and review candidates; original audio, transcripts, and already registered tasks are not changed. Provider-side retention and data use follow OpenAI policies; zero retention is not guaranteed. Withdrawing consent, disabling the provider, changing accounts, or signing out cancels related ongoing requests and blocks late responses from being applied. Changes to original text or summary settings, or deletion during processing, also block application. Incomplete, failed, or canceled responses preserve the existing results.
- **Distinction from developer console tracing**: This is a developer diagnostic feature absent from distribution builds. Debug/Debug-QA records starts, HTTP status, failure stages, and error types without bodies. Actual OpenAI request JSON and received response/error bodies are printed to the console only when a developer explicitly enables **Full request/response log (Debug)** on the meeting re-summarization screen or sets `PIEROOT_LLM_DEBUG=1`. The screen toggle is not saved or synced and is off by default. Request content, including selected transcripts or emails, may be included and must not be made public. Authentication headers, cookies, and URL queries are not logged, and direct reflections of the access token used in the request are redacted. The app does not put this output in separate files, iCloud, the diagnostic store in Section 1-6, or error reports, and does not transmit it automatically. Console records retained by development tools must be managed and deleted separately by the developer.

### 1-6. User-consented error diagnostics (optional)

- **Information**: Error occurrence time and repetition count; source file, line number, and function; error domain, code, type, and message (file paths and email addresses removed, limited to 300 characters) and underlying error chains; app version and build, operating system version and build, app execution state, feature settings, language, country/region derived from device language settings, time zone, UTC offset, calendar, and 24-hour clock setting at the time of the error; device model identifier, memory, storage space, screen size, processor count, language, region, and time zone when the report is prepared; recent app error logs (up to 300 entries, 30 minutes); and crash, hang, or memory termination diagnostics Apple may provide later. Country/region is derived from device language settings, not actual location.
- **Excluded information**: Actual location or GPS location, device name, voice recordings, transcripts, tasks, email bodies, subjects or addresses, personas, account identifiers, and authentication tokens.
- **Consent and storage**: Only if you explicitly allow it in the app is a limited number of records kept in on-device local storage with file protection and exclusion from backups. They are deleted immediately if you withdraw consent or delete local diagnostic logs.
- **Transmission and prior review**: The app does not automatically transmit diagnostic logs over the network. The on-device review screen shows the full prepared report, actual disk capacity, system uptime, boot time, and snapshots from each error occurrence. In versions supporting in-app feedback, the same report is sent over HTTPS to SIFT's private inbox only if you include it in an error report and explicitly approve final submission. Neither mail app configuration nor signing in to a service account is required. Related local diagnostics are marked as processed only after the server confirms receipt. Local diagnostics remain if you cancel review or transmission fails. Email/share-sheet submission in earlier versions sends to recipients you select and is not automatic intake.
- **Apple system diagnostics**: MetricKit/App Store Connect diagnostics may be delayed or unavailable depending on Apple and device settings, and do not capture every forced termination.

#### In-app error reports and feature suggestions

- **Submitted information and purpose**: The type, title, and description you write; app version, build, platform, OS version, and selected language; and a random submission ID to prevent duplicate intake are used to investigate errors and improve features. The prepared diagnostic report described above is attached only when you separately choose to include it with an error report. Diagnostics are not attached to feature suggestions.
- **User choice**: Upload occurs only when you review the input and attachment information and submit it yourself. No account connection, email connection, or contact details are required, and stored tasks, email, audio, health records, and credentials are not automatically attached. Do not enter personal information, passwords, or original email text in free-text fields.
- **Processing and access**: Cloudflare Workers processes requests, which are stored in a private D1 inbox. Only the Operator can view, classify, and delete them after authentication. They are not published as public GitHub issues. Receipt numbers confirm submission only; no public lookup or individual reply service is provided.
- **Retention**: Submissions, attached diagnostics, and operational notes are excluded from queries after 30 days from receipt and deleted by a daily scheduled job. In normal operation, there may be a gap of up to 24 hours between expiration and the next scheduled job; provider outages may delay deletion further. The Operator may delete them earlier. D1's free-plan point-in-time recovery history may retain pre-deletion data for up to 7 days, and it is not publicly accessible through the operational inbox. Deleting local logs or the app does not immediately delete submissions already sent. Provide the receipt number when requesting deletion.
- **Abuse prevention and network information**: Cloudflare processes network information, including IP addresses, when handling transmissions. SIFT submission records do not store original IP addresses or persistent device identifiers. Only network rate-limit keys generated using HMAC with a daily secret key are retained, for up to 2 days. Submission bodies, diagnostics, and administrator secret keys are not written to application logs. Not requiring a login does not mean complete anonymity from the network provider.
- **Service limits**: Transmission may fail when free-service, daily submission, body size, or storage limits are reached, or when the network is disconnected. The app does not show success without server confirmation of receipt, and keeps the composition screen open so you can try again.

### 1-7. Meeting recording, app audio, speaker separation, and offline re-transcription (optional)

- **Processed information and platform boundaries**: The app processes selected microphone audio; app/screen output approved through the system sharing picker (which may include other participants' speech or sounds from other apps); per-source transcripts; speaker time segments; user names/assignments; on/off states; and selection boundaries. The Mac Catalyst path supports up to 4 individually approved targets and a separate microphone; the iOS 27 iPhone path supports a single full-screen selection and microphone. iPhone cannot select individual apps or people, and app audio is unavailable on iOS 26.x or the simulator. This description of the paths does not mean that call capture has been verified with actual meeting apps/devices. Screen **video and images are not saved**. Check consent to record third-party conversations and local rules. Direct provider receivers have not been implemented; provider API conditions and platform boundaries are separate.
- **Meeting activity detection (Mac, optional)**: If you enable meeting detection, the app checks permitted apps' processes, app identifiers, display names, and input/output audio activity in device memory to show expiring recording suggestions. Detection does not collect browser websites, meeting content, or audio, and does not itself start recording. Detection and target-app selections are device-specific and are not enabled through sync. Starting recording yourself and obtaining necessary system permissions and participant consent are separate requirements.
- **Independent source controls**: You control recording separately for the microphone and approved targets. SIFT does not change another meeting app's outgoing mute state, listening device, or volume. Sources are saved as individual FLAC files at unity gain; the parent record does not store a mixed file or combined transcript. Full playback and the cross-source conversation timeline align saved sources to a common time and combine them read-only on the device, without replacing originals or sending them to an additional server. Because speaker audio picked up again by the microphone cannot be removed, headphones are recommended. Failure in one track is isolated so that it does not affect another track's original audio or transcript. Capture of actual call audio from a particular app is not guaranteed.
- **Model installation and processing**: Only when you press install in Settings → Meetings does the app download fixed public files from Hugging Face and verify their size and SHA-256. Nemotron is the default speaker-separation implementation, and its use is a separate choice. Models are not installed automatically even when use is enabled, and a choice to disable use is preserved. Whisper is used only for optional beta re-transcription after recording ends, and may require additional power and time. Automatic language mode also saves only original audio during recording, then detects the language and transcribes after recording ends. Installation requests do not include meeting audio, transcripts, or speaker information. Nemotron live/final speaker analysis and WhisperKit re-transcription of saved audio take place on the device. The pyannote Community-1-based FBank/WeSpeaker is an auxiliary extractor for linking IDs within a track and does not replace Nemotron. [CC BY 4.0 scope and pyannote/WeSpeaker/FluidInference attribution](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/df2625ac79a7ac6b65ad868fee6d80f320da4232/NOTICE.md) are retained. Embeddings exist only in memory during per-track analysis; they are not stored or synced and do not link people across tracks or meetings. Only immutable weights are shared; mutable models/state are isolated per worker, and final passes run sequentially after all live tracks have ended.
- **Originals, storage, and recovery**: New recordings are stored locally as a parent record and per-source child records with unique IDs. The app retains each child's 16 kHz mono FLAC and manifest; Apple original text; offline/reviewed transcripts; Nemotron live/final speaker IDs and names/assignments; source status and selections; and start offsets relative to the parent. Track times start at 0 when the source begins. Active/finalization journals recover the readable continuous audio prefix after an interruption; they do not fabricate missing audio or transcripts. Existing completed records remain independent records. Per-track playback, editing, reprocessing, and export, as well as full original ZIP export (`meeting.json`, FLAC files and `manifest.json` under `tracks/<child>/audio/`), run at your choice. When sharing externally, audio and source information may be delivered to your selected recipients. After full iCloud storage consent, meeting records, original audio, and recovery information are also replicated to the same Apple account. They are excluded from Firebase snapshots and are not sent to external AI services for re-transcription or speaker analysis. Original text and audio samples are not written to diagnostic logs.
- **Local file import**: Audio you choose through the system file picker is opened read-only, converted into on-device meeting audio, and saved. The original file and its location are not changed, and only the file's base name is retained in the record. Importing itself does not request microphone permission, model downloads, or server uploads. If the file provider downloads the original, that provider's policies apply. Local audio remains available for retry even if a model is not installed or transcription fails; deleting the meeting removes the app's copy.
- **Explicit audio downloads and deletion**: You can export a selected source's original ZIP or WAV, or an original ZIP of all sources, through the system save dialog. On Mac, the app receives read/write access only to the destination file you select for that save. It does not request full-disk access or access to arbitrary folders. Imported originals remain read-only. When you confirm deletion of a meeting record, all its sources, transcripts, summaries, in-app original audio, and recovery materials are deleted together. Already registered tasks and downloaded copies you saved externally remain.

### 1-8. Routine and schedule suggestions based on completion records (optional)

- When you turn on on-device learning and explicitly run analysis, completed manual tasks from the last 90 days are grouped by the same normalized title. Completion evidence from at least 3 days is required. Email, meeting, external-calendar, pending-registration, and deleted items are excluded.
- Completion checkmarks do not establish the actual time or duration of an activity, medication use, or health status. The app shows the evidence count, period, frequency, preferred time, and uncertainty, and suggests tasks only from routines you have reviewed and edited.
- Accept/reject/snooze actions, checks for duplicates against existing items, approved schedules, and task IDs are recorded in a protected local file. The app checks available time, actual deadlines, app schedules, and conflicts with calendars it has permission to access. Start dates and deadlines are saved only after you approve a time interval. New notifications and calendar export are separate choices.
- Turning off learning stops learning and suggestions. Deleting all removes routines, evidence, and feedback. Already approved tasks must be deleted separately.

### 1-9. ChatGPT connection information (optional)

- The official SIWC public-client flow manages account identity, registration ID, device-specific host ID, granted scopes, expiration times, and OAuth tokens. If you consent to full iCloud storage and verify the current Apple account, registrations and tokens are synced through iCloud Keychain and restored on other full-storage installations using the same account. Existing device-only connections are also replicated in accordance with this policy, while the receiving device retains its own unique host ID. Installations with iCloud disabled and local-only builds do not download or upload cloud connections. Provider activation and data-transmission consent are configured separately on each device.
- Signing out deletes tokens and attempts remote revocation, but retains registration for reconnection. Deleting all connection records deletes registrations, host IDs, and credentials. Completion of remote revocation is not guaranteed if the network fails. You can manage app permissions in ChatGPT settings.
- Apple determines when iCloud Keychain actually propagates changes. The app rereads connections when becoming active and before requests, but does not guarantee immediate propagation or offline restoration. The refresh-ownership indicator for rotating tokens is synced with the credentials, and refresh runs only on the installation that approved the connection. Other devices can use tokens before expiration. After expiration, you must open SIFT on the original device and wait for refresh and sync, or explicitly reconnect on the current device. Device-specific quarantine of a failed token is separate from signing out or deleting a shared connection, and valid tokens that arrive late are accepted. Explicit remote revocation of a shared session may affect the same connection on other devices.
- If propagation is interrupted after a local login is saved, the device records pending-publication metadata and a baseline hash, not the secret itself. If there is a conflict with changes from another device, both the local and shared versions are preserved and the sync status reports it; the local login is not automatically reverted to an earlier value. This operational metadata is not restored as another device's settings.
- The [official scope](https://developers.openai.com/siwc/token-sharing-open-source) covers open-source, locally hosted apps. Paid or remotely hosted distribution requires separate OpenAI approval. Entitlements and usage limits apply by plan, account, and model.

### 1-10. Connections to actual health and workout records (optional)

- **Scope and permissions**: Only for categories you explicitly connect in settings, the app reads up to the last 90 days of workout or medication records from HealthKit. Each category is connected independently. Write access, clinical records, and background delivery permissions are not requested. Medication uses actual dose-taking (`taken`) events on iOS 26 or later and medication names for user display; doses, units, prescription schedules, and adherence are not collected or inferred. Reading health records is unsupported on Mac Catalyst, so the connection is disabled. Completion of a permission request does not prove that reading was allowed, and empty results are not used to determine whether permission was denied.
- **Local processing and approval**: Source apps are unapproved by default. Candidates are generated using at least 4 days of records from approved sources and frequency/time consistency of 80% or more. You must review and confirm the title, frequency, time, reference date, and time zone before activation. Multiple medications or sources are not combined, and multiple daily dose-taking events are not interpreted as a once-daily prescription. The app does not provide medical advice, changes to prescriptions/dosages, or advice about missed or additional doses.
- **Storage**: Limited projections of original records, source approvals, candidates, generation consent, and deduplication markers are stored in device-only storage with file protection and backup exclusion, and are not transmitted to CloudKit, Firebase, or OpenAI. Generated health-source tasks are also excluded from automatic OpenAI analysis, general behavioral/persona evidence, completion-check learning, automatic calendar registration, and automatic notification assignment.
- **Task generation and synchronization**: Separate consent for automatic generation is required in addition to source approval and routine confirmation. Because generated task titles and schedules may also reveal health information, they are excluded from full iCloud storage under [Apple policy](https://developer.apple.com/app-store/review/guidelines/#health-and-health-research). They are included in encrypted Firebase snapshots that you explicitly run, and this boundary is disclosed before generation consent. Only the next future occurrence is created; past occurrences are not generated retroactively. Calendar export and notifications directly chosen for an individual task are separate user actions.
- **Stopping and deleting**: Disconnecting a category stops reading and deletes its local evidence and source approvals. Clearing records removes all connections, generation consents, originals, and candidates, but retains existing tasks and nonclinical deduplication markers. Only a full reset clears the markers, with confirmation that existing tasks may remain and be generated again. The app does not modify HealthKit originals or revoke OS read permissions.


### 1-11. Google AdMob advertising and consent management (only in versions that provide ads)

- **Scope and advertising settings**: The following applies when advertising is actually provided in iOS and iPadOS versions that support it. It does not mean this processing occurs in previously distributed versions without advertising or in the Mac app. The app requests non-personalized ads from the Google Mobile Ads SDK (AdMob). It does not display the ATT (App Tracking Transparency) prompt or request access to IDFA (the advertising identifier), and publisher first-party ID is disabled.
- **Consent and ad requests**: Before requesting ads, the app checks and updates consent status through Google UMP (User Messaging Platform) and displays required consent forms. Ads are requested only if UMP consent status permits them. Where privacy options must be provided, you can reopen that screen in app settings to change your choices. Non-personalized requests do not replace this consent process.
- **Information the SDK may process and purposes**: According to Google's [iOS SDK data disclosure guidance](https://developers.google.com/admob/ios/privacy/data-disclosure), the SDK may process IP addresses and approximate location inferred from them; app and device identifiers; interactions such as ad impressions, views, and clicks; crash logs; and diagnostic/performance information such as app launch time, hangs, and energy use. Not requesting IDFA permission and disabling publisher first-party ID do not eliminate all processing of other app- or developer-scoped device identifiers or network information. The SDK's privacy declarations include data that may be linked to users or used for tracking, so non-personalized requests and the absence of an ATT request do not exclude all tracking. This information may be used to serve ads, prevent fraud and abuse, measure and analyze ad effectiveness, and improve SDK performance.
- **App content and health information boundaries**: Task, email, calendar, health record, audio/transcript, and persona content is not transmitted for ad targeting. HealthKit data and derived information, including health-source tasks generated from it, are not used for advertising or passed to the advertising SDK or UMP. The prohibition on using Gmail data for advertising or third-party marketing remains as set out in Section 4 below.
- **Distinction from SIFT error diagnostics**: Automatic diagnostic/performance processing by the advertising SDK is separate from the optional SIFT error reports and local diagnostic logs in Section 1-6. Even if you disable SIFT error diagnostic consent or do not submit a report, the SDK's own diagnostic/performance information may be processed in accordance with advertising consent status and Google policies.
- **Processing, retention, and related policies**: Non-personalized advertising does not mean complete anonymity or no data collection or retention. Actual processing depends on your UMP choices, applicable consent status, and Google policies. For Google's retention and deletion standards, see the [Google Privacy Policy](https://policies.google.com/privacy) and [information on Google's use of data from sites and apps using its services](https://policies.google.com/technologies/partner-sites). Changing advertising consent or deleting the app's local data alone does not immediately delete information Google has already processed.

---

## 2. Information storage locations

| Storage | Information stored |
|--------|-----------|
| On-device local storage (SwiftData) | Authoritative copies of tasks, personas, audit/behavioral data, and analysis records. Retained locally regardless of sync settings |
| Separate on-device email store | Authoritative copies of Gmail and Outlook originals, metadata, and analysis results. Replicated to CloudKit after full-storage consent |
| On-device meeting store and audio files | Parent/per-source meetings, FLAC, manifests, Apple/offline/reviewed transcripts, speakers, names, edits, and recovery information. Replicated to CloudKit after full-storage consent; excluded from Firebase; speaker embeddings are not stored |
| Protected on-device routine file | Authoritative routines, evidence, accept/reject/snooze actions, and approved schedules. Replicated as individual records under full storage; original file excluded from device backups |
| Protected on-device health-record file and health-source tasks | Local projections of HealthKit originals, source approvals, candidates, generation consent, deduplication markers, and generated tasks — excluded from iCloud. Originals and candidates also excluded from Firebase and backups |
| Apple CloudKit private database — when full storage is selected | General app data above, personal vocabulary, learning sources, settings, model selections, and permission history. Excludes health information, model installation files, and authentication secrets; restored permission/pending-action history is not applied as active approval or automatic execution |
| iCloud Key-Value Store — reading older-version values | Migration path for importing some historical settings into local authoritative copies. New transmission of all settings uses the CloudKit path |
| Device Keychain | Local copies of email and ChatGPT credentials, device-specific access controls and host ID, and learning identity key |
| iCloud Keychain — after full-storage consent and account verification | Restoration copies of email OAuth credentials and IMAP app passwords, ChatGPT registrations and OAuth credentials, and the personalized learning identity key. Device-specific OS permissions and access controls are not transferred |
| Device UserDefaults | App settings and device-specific operational state. Consent/account verification, collection cursors, deletion protection, and pending-publication receipts are not applied as another device's active state |
| On-device local diagnostic store (optional) | Consented error times, source files, line numbers, functions, codes, types, and messages; snapshots of OS, language/region, execution state, and settings at error time; device specifications and language/region settings when the report is prepared; recent app error logs; and limited Apple system diagnostics — excluded from iCloud and backups |
| Cloudflare D1 private inbox (only when explicitly submitted by the user) | Error reports, feature suggestions, app environment information, selected diagnostic attachments, and operational processing status/notes — no account or email connection required |

**Sync boundaries**: Full-storage consent includes email and meeting originals, routines and feedback, personalized learning, and settings, but is not consent to send content to OpenAI. HealthKit information, health-source tasks, OS permissions, device-specific host IDs, and model installation files are excluded. Saved permission history is kept separately and is not executed as permissions or pending email actions on the receiving device. Authentication secrets are not included in ordinary settings, CloudKit bodies, or Firebase snapshots. Disabling full storage stops subsequent replication but does not delete local data or data on other devices. Actual propagation depends on completion of Apple's transfer; local saving is not labeled as completed iCloud storage.

---

## 3. Third-party processing and international data transfers

SIFT uses the services below, and some data may be transferred to overseas servers in the process.

| Processor | Transfer countries | Information transferred | Purpose | Related policy |
|--------|-----------|-----------|------|-----------|
| Apple Inc. | United States and other countries | General app data, original emails, original meeting audio/transcripts, routines, vocabulary, settings, and iCloud Keychain credentials covered by consent to expanded full storage; health information excluded | Storage and restoration across devices using the same Apple account | [Apple Privacy Policy](https://www.apple.com/legal/privacy/) |
| Google LLC | United States and other countries | Gmail retrieval and read/trash change requests, and OAuth/IMAP authentication | Email integration | [Google Privacy Policy](https://policies.google.com/privacy) |
| Google LLC — AdMob and UMP (versions with advertising) | United States and other countries | Advertising consent choices and status; IP and approximate inferred location; app and device identifiers; interactions including ad impressions and clicks; SDK diagnostics and performance information | Advertising consent management, serving non-personalized ads, fraud prevention, measurement, and performance improvement | [Google Privacy Policy](https://policies.google.com/privacy), [data use on partner sites and apps](https://policies.google.com/technologies/partner-sites), [iOS SDK data disclosure guidance](https://developers.google.com/admob/ios/privacy/data-disclosure) |
| Microsoft Corporation | United States and other countries | Outlook IMAP authentication, email retrieval, and user-initiated read/trash change requests | Optional Outlook email integration | [Microsoft Privacy Statement](https://privacy.microsoft.com/privacystatement) |
| OpenAI | United States and other countries | Official login and account/registration information; tasks, email, routines, persona/behavioral explanations, meeting transcripts, and selected summary settings separately consented to and requested | Optional ChatGPT connection and analysis | [OpenAI Privacy Policy](https://openai.com/policies/privacy-policy/) |
| Cloudflare, Inc. | United States and other countries | User-approved error reports, feature suggestions, optional diagnostic attachments, and network information needed for transmission | Private feedback intake, storage, and abuse prevention | [Cloudflare Privacy Policy](https://www.cloudflare.com/privacypolicy/) |

---

## 4. Google API Services User Data Policy (Limited Use)

SIFT's use of information received from Google APIs and transfer of that information to other apps or services complies with the **[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy)**, including its Limited Use requirements.

Specifically:
- Gmail data is used in the app to assess task candidates, summarize messages, and extract tasks. Automatic analysis and sorting of email-source tasks take place on the device. After email-sharing consent, you can directly request OpenAI analysis of a selected message.
- It is not used for advertising or third-party marketing.
- It is not used to train AI models.

---

## 5. Information retention and destruction

| Information | Retention period | Destruction method |
|------|-----------|-----------|
| App data such as tasks and personas | Until app deletion or explicit user deletion | Delete device data / delete iCloud container |
| Email messages | Until the user deletes them from app data | Local deletion; deletion records synced when full storage is used |
| Meeting recordings, transcripts, and speaker information | Until the user deletes the meeting record | Delete local models and original audio/recovery materials; deletion records synced when full storage is used |
| Email OAuth tokens and IMAP app passwords | Until the relevant connection is disconnected | Delete local Keychain data and prevent reappearance; revoke sharing allowed under the current account; revocation of the provider's app password itself must be performed separately with the provider |
| Routines, evidence, and feedback | Until deleted by the user | Local deletion; individual deletion records synced when full storage is used. Already approved tasks require separate deletion |
| OpenAI credentials / registration and host ID for reconnection | Credentials deleted on sign-out; reconnection records retained until all are deleted | Delete local/synced connection information in Keychain and attempt remote revocation; host ID is device-only |
| iCloud data | Until deleted and synced in the app, or deleted in app-specific storage under the Apple account | To stop replication, turn off full storage in the app; delete remote materials separately through OS iCloud storage management. Turning it off alone does not delete remote materials |
| Local app data | Until app deletion or explicit user deletion | Delete from device storage |
| User-consented local diagnostic logs | Until consent is withdrawn or the user deletes them in the app | Delete the on-device local diagnostic store |
| Submitted error reports, feature suggestions, diagnostic attachments, and operational notes | 30 days after receipt; the Operator may delete earlier | Scheduled deletion from the private inbox (may be delayed by provider outages or delayed scheduled jobs) |
| Daily HMAC network rate-limit keys | Up to 2 days | Scheduled deletion |
| Google AdMob/UMP advertising and consent information (versions with advertising) | Purpose-specific retention standards under UMP choices, applicable consent status, and Google policies | Google policy deletion and rights-exercise procedures apply. Deleting app-local data or changing consent does not guarantee immediate deletion of information retained by Google |

---

## 6. User rights and how to exercise them

You can exercise your rights at any time as follows.

- **Delete tasks and personas**: Delete them directly in the app.
- **Delete meeting records**: Delete local models, recordings, transcripts, speakers, and recovery materials from meeting records in the app; deletion records are synced when full storage is used.
- **Disconnect email integration**: Settings → Email integration → Disconnect. This deletes device credentials and performs permitted shared revocation; it is separate from deleting stored original messages and revoking provider permissions.
- **Delete routines or stop learning**: Settings → Routines and suggestions → Turn off learning, or delete all routines, evidence, and feedback.
- **Withdraw OpenAI consent or delete the connection**: Settings → AI → OpenAI · ChatGPT → Turn off consent for each data category, sign out, or delete all connection records.
- **Revoke calendar permission**: iOS Settings → Privacy → Calendars → Disable SIFT.
- **Stop iCloud replication**: Settings → iCloud sync → Turn off full storage. This does not delete data on the current device, other devices, or data already uploaded.
- **Delete all data**: Clear materials in the app or delete the app to remove local materials. Delete iCloud materials separately through synced deletion or OS Apple account → iCloud → Manage storage.
- **Request deletion of submitted feedback**: Provide the receipt number to the contact below so it can be located and deleted from the private inbox. This is separate from deleting app-local data.
- **Advertising privacy choices (versions with advertising)**: Where UMP requires privacy options to be provided, open the relevant screen in app settings to change your consent choices. Access, deletion, and other rights concerning information Google processes follow the [rights guidance in Google's Privacy Policy](https://policies.google.com/privacy), separate from deleting SIFT local data or error diagnostics.

Contact **pieroot.02@gmail.com** to request access, correction, deletion, or suspension of processing, and we will act without delay.

---

## 7. Data security

- Email OAuth credentials, Gmail/Outlook IMAP app passwords, ChatGPT registrations/tokens, and learning identity keys are stored in Keychain. They are replicated through iCloud Keychain after full-storage consent and verification of the current Apple account. Device host IDs and access controls for operational secrets are device-only. Raw tokens and passwords are not written to UserDefaults, ordinary settings sync, or diagnostic logs.
- Authoritative copies of original emails, meetings, and routines remain in protected local storage and are replicated to iCloud only after consent to the expanded scope. OpenAI transmission is subject to the separate consent and direct-request requirements in Section 1-5 above. Diagnostic reports do not contain message bodies, routine evidence, or authentication tokens.
- iCloud data uses Apple's encryption infrastructure (encryption in transit and at rest).
- The app does not use non-exempt encryption (`ITSAppUsesNonExemptEncryption = NO`).

---

## 8. Children's privacy

This app is not intended for children under 14 and does not intentionally collect children's personal information. If we become aware that a child's information has been collected, we delete it immediately.

---

## 9. Changes to this policy

Changes to this policy will be announced through app update notes or an in-app notice at least 7 days in advance. Changes expanding the scope of storage or transmission, such as email or recordings, do not treat existing consent or continued use as new consent. They apply only after you review the expanded scope and explicitly choose it on each device.

---

## 10. Contact

For questions, complaints, or reports about this privacy policy, please contact:

- **Email**: pieroot.02@gmail.com
- **Response time**: Within 5 business days

---

*Last updated: November 4, 2026 — this additional revision is scheduled for November 12, 2026, separately from the revision announced November 1 and scheduled for November 9 and the previously effective policy.*
