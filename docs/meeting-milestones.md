# Meeting Intelligence Milestones

Status date: 2026-10-13 (source-isolated documentation update; dated verification below remains separate).
Scope: iOS-first. Android remains deferred because it is unreleased.

## M1 — Capture integrity and local persistence

**Goal:** A foreground-started meeting produces protected local audio and a recoverable meeting record.

- [x] iOS 26 SpeechAnalyzer/SpeechTranscriber live captions.
- [x] Per-source unity-gain canonical 16 kHz mono PCM and separate FLAC parts; no microphone/app summing or capture gain normalization.
- [x] Protected local-only meeting SwiftData container; no CloudKit/Firebase meeting sync.
- [x] FLAC manifest model and logical sample ownership metadata.
- [x] Recording consent, withdrawal confirmation, and current-recording state.
- [x] Audio-session activation moved to a dedicated queue.
- [x] Journal each active child with its unique ID, parent ID, source identity and parent-relative start sample; write stopped audio/provisional-text recovery before transcript finalization. This is an active file journal, not a claim that a SwiftData `.recording` row is committed at Start.
- [x] Recover only the physically readable, contiguous owned-frame prefix of interrupted FLAC parts into parent/child records. Trim part overlap, stop at a partial/unreadable owned range, and never invent missing audio or transcript. Full hardware interruption/recovery durability remains unverified.
- [ ] Physical-device lock/background, route-change, interruption, low-storage, and thermal verification.
- [x] New captures have one parent and unique source child `MeetingRecord`s. Children own manifests, Apple/offline transcripts and Nemotron live/final timelines/IDs; the parent is a catalog/status aggregate, not mixed audio or a combined transcript. Existing completed records remain standalone without automatic conversion or reanalysis.
- [x] Child timelines start at source-relative zero. `audioTrackStartSample`/archive `sessionStartSample` separately preserve the parent-start offset at 16,000 samples/second; parent time = offset + child time. A later-approved source keeps its own identity rather than replacing another track's content.
- [x] Local audio import (2026-10-16): Files selection uses security-scoped, coordinated read access without microphone authorization or app server upload. System-decodable audio is converted with reused 4,096-frame buffers to 16 kHz mono FLAC, retaining the existing ten-minute owned parts, two-second overlap and six-hour limit. Import exclusively owns one UUID directory and removes only that directory on conversion, cancellation or save failure; the external source is unchanged. A saved standalone record carries basename-only `importedAudioFileName`, an empty validated base and `.importedAudio` provenance until Whisper succeeds. Missing-model/transcription failures retain the audio for retry; no automatic download or fabricated Apple transcript is produced. The 78:08 native conversion/playback smoke passed, and focused regression coverage passed for stereo resampling, long-file part ownership, cancellation, rejected input, save rollback and missing-model retention in `/tmp/sift-meeting-focused-20261016.xcresult` (that intermediate bundle also contains four task-capture UI failures, not an all-green result).
- [x] `/tmp/sift-meeting-native-v3-20261016.xcresult` passed real system Files selection of a generated 11-second English AIFF, FLAC conversion, installed pinned Whisper inference and saved timestamped text, including “Alice will send the report by Friday.” Imported provenance remained visible with no fabricated Apple original. This exercised the existing postprocessing rule fallback on Simulator, not AFM summaries, Nemotron speaker accuracy or physical-device model performance.
- Final cleaned-source regression evidence: `/tmp/sift-meeting-final-regressions-20261016.xcresult` passed 858 unit tests and nine UI cases (973 executions including parameters), zero failures/skips. This includes timestamp rejection/zero-duration-word boundaries, FLAC overlap preservation, import rollback/retention, measured progress, fine waveform seeking and existing separate-source playback/export. Disposable runtime drivers were removed; hardware/thermal/recognition-quality gates below remain open.

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
- [x] Duration-aware waveform resolution keeps ten peak bins per second (78:08 → 46,880 bins) with uniform time coverage instead of a fixed 180-bin full-recording view. Canvas visits only visible bins; fine drag commits a time-based seek on release, while a separate full-duration slider reaches distant sections. iOS 27 Simulator imported and played a generated 78:08 recording and showed distinct start/midpoint waveforms in `/tmp/sift-meeting-workflow-20261016.xcresult`; this is generated-audio navigation evidence, not long-recording model speed or physical-device performance.
- [ ] Verify real-device start/pause/resume/end playback; retain exact error stage/domain/code for failure diagnostics. *(코드는 stage/domain/code 유지 — 실기기 확인만 남음)*
- [x] Child detail owns replay, waveform, volume/EQ, original FLAC+manifest archive and overlap-free single-source WAV export. Group export is ZIP with root `meeting.json` (parent ID, child IDs, source labels/kinds, `sessionStartSample`, archive-relative manifests) and `tracks/<child>/audio/` containing untouched FLAC parts and `manifest.json`. There is no mixed group WAV/audio export.

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
- [x] Open a source child from the parent track list for replay/export, transcript retry, offline re-transcription, speaker retry and transcript/name/assignment editing. Each retains its Apple original, current baseline and own revisions; a failed child's finalization/ASR/speaker work does not discard successful siblings. Group status exposes child failure rather than fabricating combined success/text.
- [x] Saved-audio transcription reports queue/model loading, sample preparation, SDK-confirmed absolute recognition position, then validation/commit. Incremental chunk IDs are not treated as time. Estimates use the current recognition run only, require enough confirmed audio, grow during stalls rather than counting down fictitiously, and exclude model loading/speaker/proofread/summary work. Korean/English native status views were exercised with explicitly synthetic callback replay; a completed audio timestamp alone never marks a transcript durably saved.
- [x] Post-stop offline failures are presented as meeting-processing errors and distinguish preserved earlier text from audio awaiting its first transcript. The supplied iPhone report identifies `MeetingOfflineTranscriptionService.Failure.invalidTimestamps`, not a Nemotron failure; earlier Apple text can remain available after that failure. The report has no raw timings, stack or MetricKit payload, so its exact trigger and a thermal cause are not established.

**Exit evidence:** Every meeting has an inspectable status, transcript state, audio state, and retry/delete path.

## M4 — Accurate speaker diarization

**Goal:** 기기 내 녹음 중 임시 화자를 표시하고 종료 후 저장된 전체 음성으로 보정하되, 실기기 품질 검증 전에는 지원 완료로 간주하지 않는다.

- [x] `speakerIDs: [String]`로 미확정·단일·중첩 화자를 표현하고, Apple STT의 원문 timed run과 화자 타임라인을 별도로 유지한다. 근거가 없으면 `화자 미확정`으로 표시한다.
- [x] FluidAudio **v0.17.4 정확 버전 고정**, Nemotron 3 Core ML (`FluidInference/nemotron-3-diarization-coreml`, revision `25a90f97f254428d4b30374b76af9c74fdee8327`) 및 Community-1 FBank/WeSpeaker (`FluidInference/speaker-diarization-coreml`, revision `df2625ac79a7ac6b65ad868fee6d80f320da4232`) 연결. 전체 20개 파일의 크기·SHA-256 허용 목록을 검증한다(총 **217,397,979 bytes**; 실행 메모리 크기가 아님). 기존 Nemotron 단독 팩도 사용자가 명시적으로 업그레이드해야 하며, 검증된 기존 파일은 재사용한다.
- [x] 설정 → 베타 기능의 `pieroot.todo.beta.meetingDiarizationEnabled`는 기본 꺼짐·기기 로컬 전용(iCloud 비동기화)이다. 토글만으로 다운로드하지 않으며 사용자가 별도 설치 버튼을 누를 때만 Hugging Face에서 모델 파일을 내려받는다. 설치 후 추론은 오프라인이다.
- [x] canonical 16 kHz PCM에서 `fast32-split-w8a8` 라이브 worker로 분기해 임시 라벨을 갱신한다. 입력 대기는 최대 10초 분량으로 제한하고 초과·모델 실패 시 화자 처리만 중단한다. FLAC 저장과 Apple STT를 막거나 누락 구간을 임의 화자로 채우지 않는다.
- [x] 녹음·전사 원본을 먼저 저장한 뒤 `MeetingLogicalAudioCursor`로 FLAC part 중첩을 제거한 전체 논리 음성을 `c128-split-w8a8`로 스트리밍 재처리한다. 확정 화자 결과는 AI 전사 검수·요약 전에 반영한다.
- [x] timed run의 실제 시간과 화자 활동을 정렬한다. 커버리지 밖·순차 화자 경계가 불명확한 단어는 앞뒤 확정 화자의 라벨을 물려받지 않고 별도 미확정 turn으로 유지한다. 같은 시간의 활동이 충분히 겹칠 때만 복수 화자로 표시하며, 확인된 timed run 경계에서만 텍스트를 나눈다.
- [x] 라이브↔최종 ID 연결은 **같은 트랙**의 강한 음성 근거를 먼저 채택한 뒤 남은 화자에만 최대 시간 교집합의 일대일 매칭을 적용한다. 음성 비교는 코사인 0.75 이상·전체 후보 행/열 모두에서 마진 0.10 이상인 상호 최선만 채택하며, 모호한 후보를 이미 소비된 ID의 차선으로 승격하지 않는다. 유효하지만 불일치하는 음성은 시간 후보를 차단하고, 음성 근거가 없으면 기존 시간 기준을 유지한다. 트랙 내부 활성 화자는 최대 8명이며 수동 이름·배정은 유지한다. 임베딩은 트랙별 분석 중 메모리에만 두며 저장·동기화·트랙 간/회의 간 비교나 사람 연결에 사용하지 않는다.
- [x] **Auxiliary attribution:** The installed FBank/WeSpeaker embedding components are Core ML conversions from pyannote Community-1, used only to help live↔final ID attribution within one track. Nemotron still supplies live/final speaker activity, boundaries and overlap; this is not a replacement diarizer or a provider participant identity feed. Credit pyannote Community-1, the WeSpeaker contributors and FluidInference conversions under the supported artifacts' [CC BY 4.0 scope and NOTICE](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/df2625ac79a7ac6b65ad868fee6d80f320da4232/NOTICE.md) and [pinned provenance/model card](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/df2625ac79a7ac6b65ad868fee6d80f320da4232/README.md); do not extend that license statement to legacy artifacts or Nemotron.
- [x] **Worker isolation/resource scheduling:** Same-preset workers share immutable weights/read-only arrays only, not the mutable `Nemotron3Models` SDK wrapper, scratch `MLMultiArray`s, prediction options, frontend/cache, recurrent state or speaker IDs. Each worker constructs its own SDK models/state. The shared-weight prediction lock covers input packing, prediction and output readback, not just the call into Core ML. Final passes wait until every live track has released ownership, then run one at a time through the resource gate, with cancellation cleanup. Extra tracks mean extra ASR/diarization work and mutable state; weight reuse is not a measured speedup or a hardware capacity guarantee.

The following dated speaker workflow counts/native model runs predate the source-isolated capture cutover. They are retained evidence, not new multitrack tests or confirmation of hardware support for this work.

- [x] **화자 워크플로우 보정 (2026-10-13):** Nemotron의 라이브/최종 모델·preset은 유지한다. 각 화자의 깨끗한 단독 발화 전체에서 처음·중간·마지막의 2~3초 후보를 최대 3개 골라 시작부 편중을 줄인다. 다른 화자 활동·양끝 100 ms는 제외하고 무음이나 짧은 조각을 연결하지 않으며 긴 녹음의 모든 후보를 펼치지 않는다. 시간상 오매칭이 코사인 기준을 통과해도 더 강한 음성 근거가 우선하는 사례, 미처리 단어의 라벨 전파, 긴 발화의 처음 9초 편중을 수정 전·후 실행으로 확인했다. 집중 회귀 82개와 전체 단위 테스트 698개가 통과했다. 이는 한국어 DER 개선·iPhone 로딩/발열 개선 증거가 아니며 기존 완료 기록을 자동 재작성하지 않는다.
- [x] **현재 워크플로우 실제 실행 확인 (2026-10-13):** Mac 네이티브 실행에서 고정 Nemotron 라이브/최종 모델과 현재 activity tracker·분산 윈도우 선택·FLAC cursor·FBank/WeSpeaker 추출기·ID matcher를 연결했다. 공개 영어 두 화자의 서로 다른 네 발화(29.4초·470,400 samples)에서 양쪽 모두 2명·4개 구간을 반환했고, 선택한 라이브/최종 표본의 9개 고유 창을 실제 임베딩했다. 실제 음성 기반의 2개 ID 연결은 시간 겹침을 의도적으로 제거한 검증에서도 유지됐고 커버리지 밖 단어는 별도 미확정 turn이었다. 결과는 `/tmp/sift-speaker-workflow-20261012/real-runtime.json`이며 DER·실제 ASR·iPhone 성능 검증이 아니다. 별도 iOS 27 QA의 합성 한국어 전사 화면에서는 `민수 → 화자 미확정 → 민수`의 세 행과 가운데 단어 `하세요`의 독립 표시·이름 미전파를 실제 화면/접근성으로 확인했다. UI 스모크 `/tmp/sift-speaker-workflow-ui-20261013.xcresult` 1건 통과, 임시 fixture·UI 테스트·app 연결은 제거했다.
- [x] manifest·전사 내용/revision·작업 generation이 바뀌면 늦은 결과를 폐기한다. **저장된 음성의 화자 재처리** 실패/취소에는 음성·전사·이전 성공 화자 결과를 유지하고 다시 분석할 수 있다. 모델 대기·재생 중에도 중지할 수 있고 중단 상태가 저장된다. 녹음 도중 설정 변경은 다음 녹음부터 적용하며, 중단된 종료 후 처리는 앱 실행당 한 번 포그라운드에서 재개한다.
- [x] 녹음 UI에서 화자 모델 로딩·첫 분석 대기·실제 라이브 분석을 구분한다. 모델 로딩 시작/완료와 첫 prediction, 첫 화면 화자 라벨의 session/preset/sample lag를 원문 없이 로컬 진단 로그에 기록한다. iOS 27 시뮬레이터 pipeline 회귀 15개 통과; 실기기 화자 감지·속도 개선을 입증한 것은 아니다.
- [x] 회의 화면 진입 시 동일 live worker를 사전 준비해 녹음으로 handoff한다. 준비 중에도 FLAC/Apple 전사를 시작하며 모델 준비·첫 추론·첫 라벨을 별도 상태로 표시한다. session/preset별 첫 입력 샘플, 큐 high-water/eviction, 추론 및 표시 지연을 음성·원문 없이 로컬 로그에 기록한다. 시뮬레이터 회귀는 통과했으며 실제 회의 화면에서 cold/warm 사전 준비→녹음 handoff 및 첫 화면 화자 라벨 지연은 아직 측정하지 않았다. 별도 iPhone worker 스모크의 로딩 측정은 아래에 기록했다.
- [x] **Source-isolated OS capture:** Mac Catalyst admits up to four independently system-picker-approved targets plus a separate microphone; each approved source owns a unique child and unity-gain FLAC/STT/Nemotron path. iOS 27 iPhone admits one full-display selection plus microphone, not per-app or per-person selection. iOS 26.x and simulator expose microphone-only availability. Per-source gates, on/off, level/state and selection boundaries do not change the conference app's outgoing mute and cannot remove acoustic speaker re-entry. An app-output track can already contain multiple people mixed by that app. No direct Teams/Meet/Zoom/Discord receiver or unsupported provider toggle was implemented. Approval/reselection/revocation does not authorize another target under an existing source identity. Earlier Catalyst DEBUG `afplay` probe and single-display iPhone evidence below are not four-target or new grouped-capture hardware verification.
- [x] 사용자 수동 설치/삭제하는 revision·크기·SHA-256 고정 WhisperKit large-v3-turbo Core ML 모델을 추가했다(검증 대상 631,107,026 bytes). **각 자식 트랙**의 저장 FLAC overlap을 제거하고 bounded WAV로 오프라인 재전사한다. 해당 Apple 원문을 별도 보존하고 새 timed run/언어/provenance를 원자적으로 저장한 뒤 Nemotron 최종 보정·텍스트 검수 순서로 처리한다. 모델 미설치·실패·취소·오래된 결과에서는 그 트랙의 마지막 유효 원음/전사를 보존하고 다른 트랙 결과는 유지한다. 한국어 정확도 개선이나 다중 소스 실기기 추론 실행은 입증되지 않았다.
- [x] **Offline timestamp adapter correction (2026-10-13):** The supplied App Store 1.0.9 (4) Catalyst report contains one post-stop `MeetingOfflineTranscriptionService.Failure.invalidTimestamps`. This is the **Whisper offline adapter, not Nemotron**. There are no raw timings, transcript, stack or MetricKit payload, so the exact supplied event's trigger is unknown. The pinned [WhisperKit 1.1.0 revision](https://github.com/argmaxinc/WhisperKit/tree/1e2a163736dfa5a198e637ae44c114e1c6d5cc2d) retains zero-duration DTW words when there is no gap to expand them ([SegmentSeeker.swift, lines 561–604](https://github.com/argmaxinc/WhisperKit/blob/1e2a163736dfa5a198e637ae44c114e1c6d5cc2d/Sources/WhisperKit/Core/Text/SegmentSeeker.swift#L561-L604)). The adapter now keeps the full segment text but omits untrusted word runs instead of failing the replacement or inventing timing. Empty timestamp-only slices need no app interval; the SDK normally filters zero-duration segments when alignment weights exist ([TranscribeTask.swift, lines 196–218](https://github.com/argmaxinc/WhisperKit/blob/1e2a163736dfa5a198e637ae44c114e1c6d5cc2d/Sources/WhisperKit/Core/TranscribeTask.swift#L196-L218)), not evidence of nonempty zero-duration speech in final SDK output. Non-finite, negative, reversed and outside-decoder-window timings still fail, including after an unalignable word or on an empty slice. Only the bounded padded tail is clipped to saved samples; arbitrary finite ends are rejected and incremental SDK offsets remain absolute. Regression coverage was added, not executed here; no new build/lint/tests/formatters/native smoke evidence is claimed. FLAC export and Apple baseline ownership are unchanged. Integration checks remain `MeetingOfflineTranscriptionTests` on Catalyst/iOS and isolated saved-FLAC inference with the pinned model, silence/punctuation/short speech and a partial tail after 30 seconds: check complete text, absent runs for zero-duration words, bounded measured runs elsewhere, unchanged FLAC hashes and Apple raw text on success/failure/cancellation.
- [x] **단독 발화 임베딩과 입력 정규화 검증 (2026-10-11):** 2~3초 단독 발화 구간에서 WeSpeaker ResNet34 256차원 임베딩을 추출한다. 고정 10초 FBank 입력의 나머지를 0으로 채우면 전체 프레임 평균에 인위적인 무음이 포함되므로, 선택한 원음 구간을 반복해 입력을 채운다. LibriSpeech test-clean의 화자 6930·1320, 각기 다른 두 발화(합계 29.4초·선택 윈도우 7개)에서 기존 0 패딩의 후보 마진 0.042~0.049가 반복 입력 후 0.597~0.629로 바뀌었고, 기준 0.75/0.10을 그대로 두고 시간 겹침이 없는 두 ID를 2/2 연결했다. 이것은 해당 소규모 영어 샘플의 ID 연결 증거이지 일반적인 화자 분리 정확도가 아니다. 실제 Nemotron 라이브/최종 재생에서는 양쪽 모두 2명·4개 구간을 반환했고 시간 기준과 임베딩 보강의 ID 매핑도 같았으므로 DER 개선을 입증하지 않았다. Mac Catalyst의 7개 윈도우 처리 0.198초는 단일 측정이며 cold/warm·기기·발열 조건이 통제된 성능 비교나 실시간 보장이 아니다. 관련 결정적 회귀 84개와 실제 모델 스모크 1개가 통과했다. 한국어·잡음·중첩·짧은 발화의 품질과 실기기 장시간 성능은 별도 검증 대상이다.
- [x] **Foresight/EmbeddingGemma 용도 재확인:** 사용자가 제공한 [Foresight 공식 자료](https://developers.google.com/edge/foresight)는 EmbeddingGemma 2를 문서·이미지·음성의 의미 검색 및 로컬 RAG에 사용한다고 설명한다. 설치된 `/Applications/Foresight.app`의 안내도 같은 검색 흐름을 설명한다. [Google 문서](https://ai.google.dev/gemma/docs/embeddinggemma)상 EmbeddingGemma 1은 텍스트 임베딩, 2는 오디오를 포함한 멀티모달 임베딩이다. 따라서 모두 텍스트 전용이라고 판단하지 않는다. 다만 [2의 모델 카드](https://huggingface.co/google/embeddinggemma-2)는 오디오 검색/종합 벤치마크만 제시하고 화자 동일성 EER·회의 DER을 따로 제시하지 않으므로, 오디오 지원을 근거로 WeSpeaker보다 좋은 화자 모델이라고 결론 내리거나 교체하지 않는다. 현재 보강은 동일 트랙의 ID 연결용이며 발화 경계·중첩 감지는 Nemotron이 담당한다.
- [x] **추가 실제 모델·저장 스모크 (2026-10-11):** Mac Catalyst에서 첫 실제 임베딩 윈도우 처리 후 작업을 취소하여 `CancellationError`와 모델 lease 반환을 확인했다. 실제 음성에서 계산한 ID 연결을 별도 로컬 SwiftData DB에 반영하고 DB를 닫은 뒤 새 컨테이너로 다시 읽어 자동 화자 ID·사용자 이름·수동 구간 배정·완료 상태·모델 revision·원음 manifest가 유지됨을 확인했다. 전사 텍스트와 수동 이름은 검증용 입력이며 실제 ASR·UI 편집·앱 재실행 증거로 간주하지 않는다. 결과: `/tmp/sift-speaker-cancel-disk-sandbox-catalyst-20261011.xcresult`의 실제 모델 스모크 1건 통과. 처음에는 검증용 DB를 샌드박스 밖에 만들려다 권한 오류가 났으며 앱 권한 확대 없이 검증 경로를 샌드박스 내부로 수정했다.
- [x] **iPhone 실제 모델·취소·저장 스모크 (2026-10-11):** iPhone 18 Pro / iOS 27.0.1 (24A446)의 격리 앱 `pieroot.sift-todo.permissionsqa.todo`에서 동일 스모크를 새 프로세스로 두 번 실행해 모두 통과했다. 별도 Keychain 그룹·CloudKit entitlement 없음과 공개 음성/고정 모델 팩 전용 `Documents/SpeakerSmoke`를 사용했다. LibriSpeech 영어 두 화자의 서로 다른 발화 4개에서 시간 겹침 없는 ID 2개를 모두 연결했다. 첫 실제 임베딩 윈도우 뒤 취소하여 `CancellationError`와 lease 반환을 확인했고, 별도 SwiftData DB를 닫고 새 컨테이너로 다시 읽어 자동 ID·사용자 이름·수동 배정·완료 상태·모델 revision·원음 manifest 보존을 확인했다. 전사와 이름은 검증용 입력이므로 실제 ASR·UI 편집·앱 재실행 보존을 입증한 것은 아니다. Nemotron 라이브·최종 재생은 각각 2명·4개 구간, 전체 470,400 samples 처리 완료를 반환했으며 시간 기준/임베딩 보강의 ID 매핑이 같아 DER 개선 증거는 아니다. 원본 앱·회의·권한은 변경하지 않았다. 결과: `/tmp/sift-speaker-device-runtime-20261011-run1.xcresult`, `/tmp/sift-speaker-device-runtime-20261011-run2.xcresult`. 임시 소스는 일반 테스트에 복구하지 않고 기존 빌드된 `.xctestrun`으로 실행했다.
- [ ] **iPhone 반복 모델 로딩 지연 (2026-10-11):** 아래는 같은 고정 팩·연산 설정의 새 프로세스 두 번 실행 결과다. 지연은 `MeetingDiarizationWorker.loadModels()`의 `Nemotron3Models.load(..., computeUnits: .cpuAndNeuralEngine)` 구간에서 관찰됐고 두 번째에도 반복되어 최초 실행에만 생기는 비용이라고 판단하지 않는다. Core ML 컴파일·캐시·연산 배치 중 원인은 아직 분리하지 않았다. 첫 실행에는 병행 마이크 수집 로그도 있었으며, 두 번째에는 해당 로그 없이 지연이 반복됐다. 기기 열 상태·전역 캐시·테스트 호스트 비용을 통제하지 않았으므로 정식 cold/warm 벤치마크나 실시간 보장으로 사용하지 않는다. 기록된 취소 시간은 작업 시작부터의 시간이므로 취소 요청 이후 지연으로 인용하지 않는다.

  | 측정 구간 (초) | 첫 실행 | 두 번째 실행 |
  |---|---:|---:|
  | 임베딩 7개 윈도우 (로딩 포함) | 3.741 | 3.743 |
  | Nemotron live 모델 준비 | 114.303 | 113.800 |
  | Nemotron final 모델 준비 | 182.153 | 170.412 |
  | 29.4초 음성 live 재생 (로딩 포함) | 114.515 | 113.995 |
  | final 재생 + 임베딩 (로딩 포함) | 182.353 | 170.596 |
  | 전체 스모크 | 300.830 | 288.556 |

- [ ] **실기기 미검증:** 실제 iPhone/iPad 회의의 2인 이상 live 표시 지연 p95·장시간 처리 속도·발열, 캐시 조건을 통제한 cold/warm 로딩, 한국어·8인 코퍼스 DER/token 정확도. Teams/Discord/Zoom/Google Meet의 iPhone/iPad/Catalyst 실제 상대방 오디오·독립 음소거, lock/background, 라우트/인터럽트/권한 철회, 저장 음원과 Apple STT 일치 여부도 확인해야 한다. 이전 약 62초 실기기 QA에서는 복구 manifest 검증 오류로 저장 전 중단되었다. 시뮬레이터 회귀 통과를 실기기 지원으로 표시하지 않는다.
- [ ] 동일한 실제 사람 한국어/영어/혼합 회의 원음에서 Apple과 WhisperKit의 CER/WER·고유명사/숫자·무음 환각·word timing/화자 경계 및 30분 이상 peak memory/처리시간을 비교하고, 설치 후 비행기 모드 전체 경로를 확인한다.

### Provider media boundaries

These are conditional upstream API boundaries, **not implemented SIFT receivers or tested provider/hardware support**. The available capture path is OS-approved application/display output, with a separate mic; source tracks are not automatically participant tracks. No unsupported direct-provider UI toggle is offered.

| Platform | Primary-documented media boundary | Missing prerequisites / SIFT boundary |
|---|---|---|
| Teams | [Application-hosted media bots](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/calls-and-meetings/requirements-considerations-application-hosted-media-bots) require C#/.NET and Windows Server (production in Azure). [`ReceiveUnmixedMeetingAudio`](https://microsoftgraph.github.io/microsoft-graph-comms-samples/docs/bot_media/Microsoft.Skype.Bots.Media.AudioSocketSettings.html#Microsoft_Skype_Bots_Media_AudioSocketSettings_ReceiveUnmixedMeetingAudio) yields the **top four active speakers** at a time, not permanent streams for every participant. | Requires bot/app credentials, tenant admin consent/media permissions and applicable tenant recording/compliance policies. [`updateRecordingStatus`](https://learn.microsoft.com/en-us/graph/api/call-updaterecordingstatus?view=graph-rest-1.0) must succeed before persisting media or derived data. This is server-bot infrastructure, not a Catalyst/iPhone capture switch; none was implemented here. |
| Google Meet | The closed-enrollment Media API preview path requires approved access; [virtual streams](https://developers.google.com/workspace/meet/media-api/guides/virtual-streams) carry the **three loudest** sources through three static SSRCs. Sources can change; CSRC and participant/media metadata must map the true identity, not a fixed stream index. | Preview entitlement, [OAuth/restricted scopes and client requirements](https://developers.google.com/workspace/meet/media-api/guides/get-started), [admin/host settings and in-meeting consent](https://developers.google.com/workspace/meet/media-api/guides/overview) are required. Those prerequisites and a supported native SIFT iOS/Catalyst receiver are missing; a WebRTC/C++ example does not establish that native support. |
| Zoom | Native [macOS one-way audio callbacks](https://zoom.github.io/zoom-sdk-macos/protocol_zoom_s_d_k_audio_raw_data_delegate-p.html) and [iOS per-user raw audio delegates](https://marketplacefront.zoom.us/sdk/meeting/ios/protocol_mobile_r_t_c_audio_raw_data_delegate-p.html) are documented. | Requires Meeting SDK authentication/credentials, [server-side signature generation](https://developers.zoom.us/blog/troubleshooting-meeting-sdk-signature-validation/) and host-granted raw recording/streaming privileges ([macOS raw-data guide](https://developers.zoom.us/docs/meeting-sdk/macos/custom-ui/advanced-features/raw-data)). Native macOS/iOS SDK documentation is not Catalyst support: Catalyst is unsupported/unestablished for this integration. No credentials/signing service or Zoom receiver exists here. |
| OBS | [Application/desktop audio capture](https://obsproject.com/kb/macos-desktop-audio-capture-guide) separates **application output**, not the people already mixed inside it. | OBS recording tracks do not expose participant identity/PCM from Teams, Meet, Zoom or Discord. OBS is a capture reference, not an implemented SIFT provider receiver. |
| Discord | Stock [RPC commands/events](https://docs.discord.com/developers/topics/rpc) expose voice settings/state, **not participant PCM export**. [Social SDK voice callbacks](https://docs.discord.com/developers/game-development/how-to-add-proximity-voice-chat-to-your-game) belong to a separate [registered application/lobby integration](https://docs.discord.com/developers/discord-social-sdk/getting-started). | Social SDK lobby audio is not an export API for arbitrary stock Discord calls. The registration/auth/lobby receiver integration was not implemented here; OS-approved Discord app output remains the available path, with actual call capture unverified. |

**Supplied native model isolation smoke (2026-10-13):** `/tmp/sift-source-track-runtime-20261013/result.json` records a native Mac run with the pinned real models, production model pool/weights/activity tracker and separate mutable SDK diarizers. Source A used 283,680 samples (17.73 s), source B 186,720 samples (11.67 s). Both `fast32-split-w8a8` and `c128-split-w8a8` reported shared weights, disjoint speaker IDs, one speaker per source, three A intervals/two B intervals, zero maximum difference between interleaved and isolated replay for each source, and zero remaining borrowers. This is small-sample worker/weight-pool isolation and release evidence only: no real OS capture, ASR, parent/child UI, four-target hardware capacity, Korean quality, DER or speedup was exercised by that smoke.

**Latest integrated verification (2026-10-13):** `/tmp/sift-source-track-verified-regressions-20261013.xcresult` passed all 764 distinct unit tests (757 Swift Testing + 7 XCTest) and the two selected source-control/source-track UI tests, with zero failures; parameterized cases account for 850 total executions. These include failed-Apple-baseline recovery, queued edits/speaker metadata, grouped rollback/deletion and track-local audio lifecycle. `/tmp/sift-source-track-verified-catalyst-20261013.xcresult` built the latest QA Catalyst source successfully. This supersedes the intermediate failed integration runs; it does not merge the older speaker-workflow counts into this run.

The source-track UI regression used QA-only generated eight-second 220/440 Hz FLAC files and synthetic Korean transcripts, guarded by DEBUG, the exact QA bundle and the in-memory-store argument. Actual child navigation, source-only text, playback clock advance/pause and system ZIP sharing passed. The exercised ZIP was separately opened: both per-track manifests matched `meeting.json`, offsets were 0/32,000 samples, both FLAC files decoded to 128,000 mono 16 kHz frames, and exported/original SHA-256 matched for each. Attachments: `/tmp/sift-source-track-verified-ui-attachments-20261013/`. This is real persistence/playback/export of generated audio, not physical capture or ASR/diarization accuracy.

**Hardware gate remains open:** A QA-only Mac picker/capture probe was run with microphone off, then paused/revoked/stopped; the selected target did not remain demonstrably tied to the controlled source apps, so it is not a passing two-source audio-isolation, recovery or live-call result. Physical iPhone remained offline. A stable, explicitly approved two-source picker session and connected-device capture/recovery measurements are still required before claiming multitrack hardware support.

### Capture and offline ASR verification matrix (2026-09-28)

| Runtime | Verified in this change | Not established |
|---|---|---|
| iOS 27 iPhone simulator | Updated complete unit suite: 586 tests passed (589 runs); source UI gating regression passed; Korean meeting screen launch | ScreenCaptureKit hardware capture, model inference quality, human microphone input |
| iOS 27 iPad Pro 11-inch (M5) simulator | Updated source UI gating regression passed; earlier post-review unit runner stalled once during launch, while iPhone 27 full unit suite subsequently passed | Physical microphone/app capture and live/offline model-stage UI |
| iOS 26.5 iPhone simulator | Updated complete unit suite: 586 tests passed (589 runs); focused source/mixer, offline ASR and suspended-edit regressions: 60 tests passed (61 runs); app launch and microphone-only meeting surface | Physical recording, background/lock behavior |
| Physical iPhone 18 Pro / iOS 27 | Separately signed `pieroot.sift-todo.meetingqa` with its own local store: full-display picker starts capture; microphone/app independent toggles and app off→on passed again after the background fix. App-only Safari playback of a controlled synthesized English phrase continued while SIFT was backgrounded, saved 444,529 samples (27.783 s, mono 16 kHz FLAC), and Apple raw STT preserved repeated “The blue bicycle is parked beside the orange lighthouse” / “The meeting begins on Thursday at 9” segments. Original `pieroot.sift-todo` remained untouched. | Real human speech, conference apps and remote participants, lock/interruptions, offline models, diarization latency/accuracy and extended battery/thermal runs |
| Mac Catalyst on macOS 27 | Updated build and running meeting surface; app-only start reaches real system picker; cancelling selection returns to idle with Start enabled and no error sheet | Captured speech in canonical FLAC/STT, live/final model performance, actual conference calls |
| Saved-audio adapter | Deterministic 30-minute FLAC-to-WAV overlap-trimming test; UTF-16 word timing, rollback, deletion and stale-result tests | 30-minute Whisper inference peak memory, CER/WER or better-than-Apple accuracy |

| Actual remote speech capture | iPhone 27 | iPad 27 | Mac Catalyst |
|---|---|---|---|
| Microsoft Teams | Unverified | Unverified | Unverified |
| Discord | Unverified | Unverified | Unverified |
| Zoom | Unverified | Unverified | Unverified |
| Google Meet | Unverified | Unverified | Unverified |

One physical iPhone 18 Pro became available; the separately signed QA bundle has no CloudKit or original-app keychain entitlements. The QA scheme runs in Release, so `-ui-test-in-memory-store` did **not** activate the DEBUG-only in-memory SwiftData path: recordings and transcript were saved in the QA bundle's own local store, not the personal SIFT 1.0.8 app, which was neither replaced nor accessed. The second iPhone remained unavailable; no physical iPad or consenting remote call participant was available. The controlled Safari sample is synthesized speech, not human microphone or conference-call quality evidence. The thirty-minute adapter test uses deterministic PCM. Airplane-mode end-to-end validation remains open. Picker cancellation was reproduced and fixed in `MeetingView.startRecording`; the integrated Catalyst app returned normally, including after capture/postprocessing race corrections.

On iOS 27 the full-display system picker lists **SIFT as the receiving app**, not as the sole audio source; it does not offer per-app selection. The first app-only start failure came from rejecting valid sample PTS when `stream.synchronizationClock` was nil; accepting PTS within five seconds of host time fixed it, while unrelated clock domains still fail closed. A second physical failure appeared when SIFT left the foreground with microphone off: Safari's speech played, but only one app buffer reached the mixer. With the microphone engine active, over 1,200 app buffers arrived, isolating background suspension of the audio-only stream. Apple's [iOS ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios) registers a `.screen` output for full-display background capture; this app now registers a 64×64 output and immediately discards every frame, without storing any pixels. The repeat app-only Safari run passed with more than 20 app buffers, a finalized 27.783-second FLAC, manifest `totalSamples=444529`, and recognizable Apple STT phrases in the QA store. Separate source-toggle runs confirmed app off→on preserves the picker-approved microphone, and microphone off preserves app audio. This does **not** establish Teams/Discord/Zoom/Meet speech capture, human-speaker quality, lock behavior, or long-duration stability.

**Exit evidence:** 실제 iPhone에서 FLAC/STT 보존과 지연·발열 기준을 확인하고, 한국어·8인 및 중첩 음성 코퍼스의 DER/token 정확도와 라이브 p95를 측정한 뒤에만 M4를 완료로 판정한다.

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
