# Meeting Intelligence Milestones

Status date: 2026-07-13
Scope: iOS-first. Android remains deferred because it is unreleased.

## M1 — Capture integrity and local persistence

**Goal:** A foreground-started meeting produces protected local audio and a recoverable meeting record.

- [x] iOS 26 SpeechAnalyzer/SpeechTranscriber live captions.
- [x] Canonical 16 kHz mono PCM path and FLAC part writer foundation.
- [x] Protected local-only meeting SwiftData container; no CloudKit/Firebase meeting sync.
- [x] FLAC manifest model and logical sample ownership metadata.
- [x] Recording consent, withdrawal confirmation, and current-recording state.
- [x] Audio-session activation moved to a dedicated queue.
- [ ] Create/persist `.recording` MeetingRecord at Start; checkpoint active manifest/part recovery during capture.
- [ ] Complete FLAC recovery from interrupted open part and reconcile it into a visible recoverable meeting.
- [ ] Physical-device lock/background, route-change, interruption, low-storage, and thermal verification.

**Exit evidence:** Capture survives expected interruption paths, raw parts and manifest are inspectable locally, and no completed meeting is lost before transcript finalization.

## M2 — Original audio playback, volume, and waveform

**Goal:** Users can verify what was captured with correct, overlap-free audio playback and an intelligible waveform.

- [x] Logical part timeline with overlap trim rules.
- [x] Playback route activation and mono PCM graph setup.
- [x] Volume control (0–100%) and bounded EQ gain (0–12 dB).
- [x] FLAC reader/writer round-trip test.
- [x] Waveform generation from logical PCM peaks, p95 normalization, silence floor, and Canvas renderer.
- [x] Rendered-sample-based waveform playhead progress publication.
- [x] Replace full-meeting PCM scheduling with a bounded 2–3-buffer streaming scheduler (`MeetingPlaybackStreamScheduler`, logical-cursor 기반, `.dataConsumed` refill, 자연 종료 이벤트).
- [x] Add waveform task cancellation and manifest-keyed waveform cache.
- [ ] Verify real-device start/pause/resume/end playback; retain exact error stage/domain/code for failure diagnostics. *(코드는 stage/domain/code 유지 — 실기기 확인만 남음)*
- [x] Add original download/export: source FLAC parts plus manifest archive, and separately an overlap-free convenience export (`MeetingAudioExporter`: zip 아카이브 + 단일 WAV).

**Exit evidence:** A 6-hour meeting plays without runaway memory use, pause/resume preserves position, waveform/playhead match audio, and source archive export is recoverable.

## M3 — Transcript finalization and meeting detail

**Goal:** A recorded meeting becomes a usable local record.

- [x] Time-indexed provisional transcript entries with start/end timestamps.
- [x] Timestamped transcript detail screen.
- [x] Meeting list navigation to detail.
- [x] Finalization progress stages and explicit failure state.
- [x] Persist `MeetingCaptureArtifact` immediately after FLAC close, before potentially slow Speech finalization (`stopCapture()`/`finalizeTranscript()` 분리, 레코드 선저장).
- [x] Distinguish final transcript success from recoverable transcript-finalization timeout/failure (`MeetingStatus.transcriptFinalizationFailed`, 180초 타임아웃).
- [x] Add explicit retry/finalize action that preserves raw audio and provisional transcript (`MeetingTranscriptRetryService`: 저장된 FLAC에서 온디바이스 재전사).
- [x] Add manual transcript segment edit/split/merge/rename, revision invalidation, and stale-draft rejection tests (`MeetingTranscriptEditor` → `MeetingRevisionEditor` 위임, `MeetingTranscriptEditorTests`).

**Exit evidence:** Every meeting has an inspectable status, transcript state, audio state, and retry/delete path.

## M4 — Accurate speaker diarization

**Goal:** Show stable speaker labels only after a whole-recording diarization result exists.

- [x] `speakerIDs: [String]` contract supports no speaker, single speaker, and overlap.
- [x] Live UI accurately displays `화자 미확정` rather than inventing labels.
- [ ] Pin FluidAudio 0.12.1 and implement whole-session local diarization.
- [ ] Align diarization time ranges to finalized transcript segments.
- [ ] Persist stable labels; add rename/merge/split edits without transcript revision changes.
- [ ] Add consent-gated local known-speaker enrollment; never sync or upload embeddings.
- [ ] Corpus/bake-off evaluation across Korean/English/noise/overlap/speaker counts.

**Exit evidence:** Detail screen shows stable `화자 1`, `화자 2`, and multi-speaker overlap only after validated local diarization completes.

## M5 — On-demand transcript analysis

**Goal:** A user can explicitly analyze a saved transcript into a complete meeting summary and reviewable action candidates.

- [x] Detail-screen `전사문 분석` button and deterministic explicit-action fallback.
- [x] Fallback drafts retain source segment IDs and require user review.
- [ ] Implement local AFM/downloaded-Qwen analysis producing full `ProviderMeetingExtraction`: title, summary, decisions, unresolved questions, action drafts.
- [ ] Validate source IDs, finite confidence, and schema; derive canonical action IDs locally.
- [ ] Make deterministic extractor a documented fallback only, not the primary analyzer.
- [ ] Persist analysis progress/failure/retry state without deleting transcript/audio.
- [ ] Add `다시 정리` for dissatisfied/failed analysis using saved transcript/audio manifest.

**Exit evidence:** A user can see summary, decisions, unanswered questions, and grounded action candidates, then rerun analysis without rerecording.

## M6 — Persona relevance and confirmed task import

**Goal:** Persona context highlights relevance but never creates hallucinated tasks.

- [ ] Inject the main app ModelContext separately from the meeting-local ModelContext.
- [ ] Fetch Persona read-only; calculate local-only draft relevance metadata keyed by draft ID.
- [ ] Show relevance/reason as UI context only.
- [ ] Show selectable action draft candidates with source timestamp/provenance.
- [ ] Confirm selected drafts through `MeetingTodoImporter.confirm` into main Todo storage.
- [ ] Create only review-triage meeting Todos; no auto-schedule, reminder, or AI-sort inclusion.
- [ ] Test replay idempotency, stale revision rejection, and confirmed-Todo preservation after meeting deletion.

**Exit evidence:** Persona-relevant commitments are highlighted; only explicitly confirmed, source-grounded candidates become review Todos.

## M7 — Verification, privacy, and release readiness

**Goal:** Ship only after behavior, privacy, and operational boundaries are proven.

- [ ] Add automated tests for playback multi-part overlap, waveform normalization/progress, artifact persistence/recovery, analysis schema/fallback/retry, and Todo import.
- [ ] Run focused iOS tests and physical-device capture/playback/thermal scenarios.
- [ ] Remove noisy Keychain token lookup logs from production paths.
- [ ] Keep PointerUI and CloudKit background-task logs classified as unrelated system/container noise unless app behavior proves otherwise.
- [ ] Update README, docs/index, privacy policy, changes log, third-party notices, and App Store Audio Data disclosure.
- [ ] Independent review of iOS diff before completion.

**Exit evidence:** Focused tests pass, physical-device evidence exists, privacy disclosures match actual storage/processing, and independent review has no unresolved blockers.
