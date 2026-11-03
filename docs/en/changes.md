---
layout: default
locale: en
lang: en
page_key: changes
permalink: /en/changes.html
title: What's new
description: New features, improvements, and fixes in each version of SIFT.
---

# What's new

<a id="version-1-0-15"></a>
## 1.0.15

### To-do and email lists

- Mac to-do and email rows no longer show persistent disclosure arrows. Hovering reveals a trailing More menu; clicking the row opens details, while More or right-click opens actions only.
- On iPhone and iPad, task details use standard form rows for Complete and Delete instead of large filled buttons. Delete uses the standard destructive color, and Add Tag has a lighter presentation.

### Calendar

- The iPhone and iPad calendar now shows both the year and month in the upper-left corner, updating to match the month you scroll to. You can identify the correct year and month across year-end and New Year transitions, too.
- Month headings within the calendar now also show the year, making it easier to distinguish the same month in different years.

- Week view shows two or three days at a time on iPhone and narrow iPad layouts; wide iPad layouts can show all seven days.
- Dates scroll horizontally with native momentum. Rightward date swipes no longer navigate back; the Back button remains available.
- All-day events and events lasting at least a day appear as one continuous bar instead of repeated daily chips. Date headers, time columns, and bars scroll together while time labels stay pinned. Timed events shorter than a day remain in each day's timetable even when they cross midnight.

### Mail

- Tasks are suggested only from **Needs Review/Action** items in an analysis of the full message body. If there are no such items, the email subject or summary is not turned into a task; you can save a task you enter manually instead.
- Save multiple action items from one email separately, with duplicate prevention for the same item even after you edit its title. Calendar events you add manually are also kept separate for each task, while references to the original email are preserved.
- Disconnected IMAP sessions reconnect on the next retrieval, and a failure to mark a message as read no longer prevents its body from being received. Read and trash actions are not performed through another account's connection.
- Message lists and full bodies are saved on the device when the app becomes active and periodically. The cache is maintained even with AI analysis off; background fetching applies only to accounts you have approved, and iOS determines when it runs.
- Balanced the spacing above and below email summary cards and improved the action-item selection screen so long item names can be read.
- Fetch complete text and display HTML without large attachments, preserving actions at the end of messages. A device's connection failure no longer erases valid synced summaries, and deletion undo retains email action provenance and duplicate prevention.

### Settings and sync

- On the **Sync conflicts** screen, you can compare each item's versions and differing content, then choose and apply the version you want. Items that change during comparison must be checked again, while other items without conflicts continue to sync.
- Original versions are kept on your device before conflict resolution. You can compare and restore them again under **Saved versions**. Your selected version is used to consolidate duplicates of the same item.
- Advertising privacy form errors now distinguish app configuration problems, network errors/timeouts, and failures to provide a form, with guidance on how to resolve them. Google-side configuration problems are not presented as errors that a simple retry can fix.
- Improved iCloud restoration of older tasks. New email action tasks cannot be read by 1.0.14 and can stop its sync, so update every iPhone, iPad, and Mac sharing the same iCloud account.

<a id="version-1-0-14-13"></a>
## 1.0.14 (13)

### Meetings

- An **Add task** button appears beside summary sentences classified as tasks. It adds the sentence you reviewed directly to the review queue, without a separate candidate list or another summary to create a task title, while preserving original-source verification and duplicate prevention.
- In **Summarize again**, you can directly choose Apple Intelligence, GPT-6.1 Sol, or GPT-6 Luna. GPT is used only with a connected account and per-device consent to transmit meeting data. Previous results are preserved on errors or cancellation.
- Fixed format selection and instruction editing so they remain available even when custom summary instructions are empty.
- Split long-meeting processing by Apple Intelligence into stages and improved output-language selection and original-source grounding verification.
- Consecutive transcript segments from the same speaker, and undetected segments bordered by the same speaker, are grouped into paragraphs. Manual separation, source changes, and actual overlapping speech are retained, without changing original speaker assignments.
- Organized multiple summary evidence buttons into location links and an evidence menu.
- After confirmation, you can delete **an entire meeting and its audio sources, transcripts, summaries, and original audio**. Already registered tasks and files saved externally remain.
- Save an individual source's original ZIP/WAV or an original ZIP of all sources through Files on iPhone/iPad or the save dialog on Mac. Files from multiple sources and their start offsets are preserved separately.
- Added Finder file drag and drop, a paste button, and ⌘V to Mac audio import. Original files are not modified.
- Meeting recovery now saves child and membership changes before clearing recovery records. If saving fails, existing transcripts, original audio, and recovery records are preserved.
- Existing summaries remain when only summary output settings change. Task registration also remains available for summaries whose original grounding can be confirmed unchanged; registration is blocked if the actual evidence changes or cannot be verified.
- Improved Mac meeting activity detection and per-app output capture. The selected app's executable and process ownership are checked, and capture stops for reselection if the target changes. Per-app Safari capture using shared WebKit helpers is not supported.

### Settings, accounts, and sync

- Removed unverifiable plan tiers and an unnecessary model list from the AI account screen, focusing it on connection status, connection tests, transmission consent, and usage.
- Fixed the ChatGPT JSON request format and completed-response handling. The app shows per-account input, output, cached input tokens, and response counts observed on this device; these are not account-wide usage or remaining allowances.
- Fixed unchanged account connection records repeatedly scheduling full sync.
- Improved compatibility and recovery for iCloud deletion records. Duplicate identifiers with different content are not arbitrarily overwritten; only the affected items are held back while other changes continue to sync.
- Reduced duplicate explanations and empty items in meeting, AI, and beta settings. Model rows and selected values are less likely to be clipped on small screens or with large text.
- Expanded the touch areas of the iPad persona reset and generate buttons.
- Added an **Advertising consent and privacy** entry in iPhone and iPad settings. It checks Google's consent status again and does not treat form errors as completed consent. Mac remains excluded from advertising.

<a id="version-1-0-13-12"></a>
## 1.0.13 (12)

- Automatic sync checks protected connection information without an authentication prompt. Separate authorization actions explain the authentication purpose, current group, cancellation, and waiting state.
- Small sync changes are saved in bounded batches to reduce disk writes and CloudKit export requests. Original content, revision IDs, restart after intermediate failures, and cancellation handling are preserved.
- Meeting system-audio errors retain the failure stage and SDK code, with guidance on Mac capture permissions. Errors are not lost if diagnostic collection is enabled later.
- Diagnostic review, drafts, and submission IDs are retained after canceling report composition or a failed submission. Diagnostics are marked as delivered only after actual successful receipt.

<a id="version-1-0-12-11"></a>
## 1.0.12 (11)

- Improved mobile calendar month display density, year/day/multi-day views, continuous scrolling, pinch gestures, navigation to today, and narrow iPad layouts.
- On the Mac calendar, click or drag empty time to create an event, drag an event edge to adjust its time, and right-click to edit or delete it.
- Direct event edits and deletions preserve existing task links, completion records, recurring events, and time-zone boundaries. Deleted events are better protected against being recreated by automatic registration.
- Added actual input waveforms, Live Activity on iPhone/iPad, and a Mac menu bar recording indicator. Live transcription uses Apple's default model; optional Whisper is used only for processing after recording ends.
- Improved the distinction between transcription failures during recording and original-audio saving failures, and checks for whether Apple transcription supports the actual input format.
- Mac audio import now uses read permission for user-selected files and a native open panel. Audio is saved and played locally without modifying the original.
- Reorganized settings around the roles of AI, meetings, tasks, and routines. Actual Apple Intelligence readiness is distinguished from consent to use an alternative local model. External analysis runs only with a connection, a supported region, and individual sharing consent.
- Removed email sync success popups and added a blue dot for new emails you have not opened yet.
- Pinned task search and filters, and enabled task creation by double-clicking or double-tapping empty space.
- New task drafts are retained when switching Duo screens, and the save button is less likely to cover input areas on small screens.
- Improved Mac task buttons, editing, contrast, calendar event viewing, and scrolling.

<a id="version-1-0-11-10"></a>
## 1.0.11 (10)

- Moved the iPhone/iPad task banner from the bottom of the screen to a fixed area below the categories.
- Placed Mac language search at the top of the selection screen and fixed the search field remaining after returning to the previous screen.
- Moved the Mac calendar sidebar button to the top toolbar and fixed duplicate weeks between consecutive months.
- Fixed events disappearing because of linked tasks and excessive space above a day's events.
- Added metadata to task drag previews and unified model installation, cancellation, and deletion controls.
- Reorganized the meeting conversation timeline around speakers, times, and text, reducing repeated headings and spacing for the same speaker.
- Fixed time-scale and positioning errors in daily events, and improved the large-screen task editor and clickable areas of Gmail/Outlook connection rows.
- Improved Mac continuous-calendar scrolling and window resizing, and removed unnecessary week-selection borders.

<a id="version-1-0-11-9"></a>
## 1.0.11 (9)

- Task settings now manage deadline notifications, AI for priority sorting, and rules. Titles and notes can be edited on the Mac board.
- You can choose which calendars to use for task analysis. Deselecting a calendar only stops new imports and updates to unapproved suggestions; approved tasks remain.
- Separated AI account connections and transmission consent from local model installation, cancellation, and deletion. Opening a screen alone does not download a model.
- Expanded optional iCloud storage to include email, meetings, routines, vocabulary, and settings. Connection information uses iCloud Keychain; health information, OS permissions, and downloaded models are excluded.
- Full meeting audio and the conversation timeline play in alignment with the sources' common time, and the app remembers the last selected audio and summary languages.
- You can review and approve routine suggestion evidence and schedules. Health and workout records on supported iOS devices connect through separate permissions and consent.
- You can review and submit feedback and selected diagnostics without signing in. Success is shown only after an actual receipt number is received.
- Improved playback settings, waveforms, the task board, the tutorial, and the Mac monthly calendar display.
- Fixed Mac inactive-toolbar crashes, unnecessary Metal initialization when models are unused, and FLAC saving/playback issues for short meetings.
- Pending-registration items are excluded from bulk AI sorting, notifications, and automatic calendar registration.

{% include release-history.html %}
