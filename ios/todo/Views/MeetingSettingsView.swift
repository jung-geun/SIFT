import SwiftUI
struct MeetingSettingsView: View {
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var speakerModel = MeetingDiarizationModelController.shared
    @ObservedObject private var whisperModel = MeetingWhisperModelController.shared
    @State private var language = AppLanguage.current
    #if targetEnvironment(macCatalyst)
    @ObservedObject private var detection = MeetingDetectionCoordinator.shared
    #endif

    var body: some View {
        Form {
            #if targetEnvironment(macCatalyst)
            if detection.isSupported {
                Section {
                    Toggle(copy("meeting.detection.enabled", korean: "회의 녹음 제안", english: "Suggest meeting recordings"),
                           isOn: Binding(get: { detection.isEnabled }, set: { detection.setEnabled($0) }))
                        .accessibilityIdentifier("meeting.detection.enabled")
                    if detection.isEnabled {
                        DisclosureGroup(copy("meeting.detection.apps", korean: "제안을 허용할 앱", english: "Allowed applications")) {
                            ForEach(MeetingDetectionCoordinator.applications, id: \.id) { app in
                                Toggle(app.browser ? app.name + " · " + copy("meeting.detection.possibleBrowser", korean: "브라우저 통화 가능성", english: "Possible browser call") : app.name,
                                       isOn: Binding(get: { detection.isAllowed(app.id) },
                                                     set: { detection.setAllowed($0, bundleID: app.id) }))
                            }
                        }
                    }
                    if detection.monitoringUnavailable {
                        Text(copy("meeting.detection.unavailable", korean: "오디오 활동 메타데이터를 확인할 수 없습니다. 녹음은 회의 화면에서 직접 시작할 수 있습니다.", english: "Audio activity metadata is unavailable. You can still start recording from Meeting."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    DisclosureGroup(copy("action.details", korean: "세부사항", english: "Details")) {
                        Text(copy("meeting.detection.description", korean: "Mac에서 선택한 앱의 입력·출력 오디오 활동 메타데이터만 기기에서 확인합니다. 감지 중에는 마이크나 오디오를 녹음하지 않습니다. 안정적인 활동이 감지되면 30초 동안 제안하며, 시작을 눌러 권한과 녹음 설정을 확인해야 합니다. 브라우저의 사이트나 실제 회의 여부는 알 수 없습니다. 이 설정은 이 Mac에만 저장됩니다.", english: "On this Mac, checks only input/output audio activity metadata for allowed apps. Detection never records the microphone or audio. Stable activity shows a suggestion for 30 seconds; choose Start to review permissions and recording setup. Browser websites and actual meeting activity are unknown. This preference stays on this Mac."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            #endif
            Section {
                Toggle(
                    copy("beta.voiceProcessing.toggle", korean: "음성 노이즈 감소", english: "Voice noise reduction"),
                    isOn: Binding(
                        get: { settingsStore.meetingVoiceProcessingEnabled },
                        set: { settingsStore.meetingVoiceProcessingEnabled = $0 }
                    )
                )
                .accessibilityIdentifier("beta.voiceProcessing.toggle")
            } footer: {
                Text(copy(
                    "beta.voiceProcessing.description",
                    korean: "Apple 음성 처리로 에코와 잡음을 줄입니다. 끄면 원본 입력으로 녹음합니다. 변경은 다음 녹음부터 적용됩니다.",
                    english: "Reduces echo and noise with Apple voice processing. Turn off to record the original input. Changes apply to the next recording."
                ))
            }

            Section {
                Toggle(
                    copy("beta.autoRefine.toggle", korean: "전사 자동 교정", english: "Automatically refine transcripts"),
                    isOn: Binding(
                        get: { settingsStore.meetingAutoRefineEnabled },
                        set: { settingsStore.meetingAutoRefineEnabled = $0 }
                    )
                )
                .accessibilityIdentifier("beta.autoRefine.toggle")
            } footer: {
                Text(copy(
                    "beta.autoRefine.description",
                    korean: "녹음·재전사 후 기기에서 오인식과 오탈자를 교정합니다. Apple Intelligence를 기본으로 사용합니다.",
                    english: "Corrects recognition errors and typos on device after recording or retranscription. Apple Intelligence is the default."
                ))
            }

            Section {
                Toggle(
                    copy("meeting.diarization.toggle", korean: "화자 구분 · Nemotron", english: "Speaker separation · Nemotron"),
                    isOn: Binding(
                        get: { settingsStore.meetingDiarizationEnabled },
                        set: { settingsStore.meetingDiarizationEnabled = $0 }
                    )
                )
                .accessibilityIdentifier("beta.meetingDiarization.toggle")

                if settingsStore.meetingDiarizationEnabled || speakerModel.hasRemovableModels || speakerModel.isInstalling {
                    speakerModelManagement
                }
                speakerModelDetails
            }

            Section {

                Toggle(
                    copy("meeting.whisper.toggle", korean: "녹음 후 고급 전사 · 베타", english: "Advanced transcription after recording · Beta"),
                    isOn: Binding(
                        get: { settingsStore.meetingAdvancedTranscriptionEnabled },
                        set: { settingsStore.meetingAdvancedTranscriptionEnabled = $0 }
                    )
                )
                .accessibilityIdentifier("beta.whisper.auto")

                if settingsStore.meetingAdvancedTranscriptionEnabled || whisperModel.isInstalled || whisperModel.isInstalling {
                    whisperModelManagement
                }
                whisperModelDetails
            }
        }
        .appFormStyle()
        .navigationTitle(copy("settings.meeting.title", korean: "회의", english: "Meeting"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.locale, language.locale)
        .task {
            await speakerModel.refresh()
            await whisperModel.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { _ in
            language = AppLanguage.current
        }
    }

    private var speakerModelDetails: some View {
        DisclosureGroup(copy("meeting.diarization.details", korean: "모델 정보·제한", english: "Model details and limits")) {
            Text(copy(
                "meeting.diarization.summary",
                korean: "기기에서 화자를 구분합니다. 끄면 모델 처리를 생략해 배터리 사용을 줄입니다. 약 218 MB 모델 팩은 직접 설치해야 하며, 변경은 다음 녹음부터 적용됩니다.",
                english: "Separates speakers on device. Turn off to skip model processing and reduce battery use. Install the ~218 MB model pack manually; changes apply to the next recording."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)

            Text(copy(
                "meeting.diarization.limits",
                korean: "트랙당 최대 8명이며 한국어·다인 회의의 정확도는 검증되지 않았습니다. Nemotron은 녹음 중 임시 구분과 종료 후 최종 분석을 담당합니다. 보조 pyannote/WeSpeaker 임베딩은 충분한 단독 발화가 있을 때 같은 트랙의 화자 ID만 비교하며, 분석 중 메모리에만 유지됩니다. 저장·동기화하거나 다른 트랙·회의의 화자를 연결하지 않습니다. 설치 시에만 Hugging Face에서 공개 모델을 내려받고, 음성 분석은 기기에서 처리합니다. 전체 iCloud 저장에 동의하면 녹음·전사·설정이 동기화되지만 모델은 기기마다 설치해야 합니다. 기존 Nemotron 단독 설치는 직접 업그레이드해야 하며 검증된 파일은 재사용합니다.",
                english: "Up to 8 speakers per track; accuracy for Korean and group meetings is unverified. Nemotron provides provisional live separation and final analysis after recording. Auxiliary pyannote/WeSpeaker embeddings compare speaker IDs only within the same track when enough solo speech is available. They remain only in memory during analysis, are not saved or synced, and never link speakers across tracks or meetings. Only installation downloads public models from Hugging Face; audio analysis runs on device. Full iCloud storage consent syncs recordings, transcripts and settings, but models need installation on each device. Older Nemotron-only installs require a manual upgrade; verified files are reused."
            ))
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("beta.diarization.warning")

            Link(copy(
                "beta.diarization.attribution",
                korean: "같은 트랙의 화자 ID 비교용 보조 임베딩 · 수정된 Core ML 변환: pyannote · WeSpeaker · BUT Speech@FIT · Fluid Inference (CC BY 4.0; 제작자·변경 사항은 NOTICE 참조)",
                english: "Auxiliary same-track speaker-ID embeddings · modified Core ML conversions: pyannote · WeSpeaker · BUT Speech@FIT · Fluid Inference (CC BY 4.0; creators and changes in NOTICE)"
            ), destination: URL(string: "https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/df2625ac79a7ac6b65ad868fee6d80f320da4232/NOTICE.md")!)
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("beta.diarization.attribution")
        }
    }

    private var whisperModelDetails: some View {
        DisclosureGroup(copy("meeting.diarization.details", korean: "모델 정보·제한", english: "Model details and limits")) {
            Text(copy(
                "meeting.whisper.summary",
                korean: "녹음 종료 후 더 큰 Whisper 모델로 저장 음성을 다시 전사합니다. 배터리와 시간이 더 필요합니다. 약 631 MB 모델은 직접 설치해야 하며 Apple 실시간 전사는 그대로 유지됩니다.",
                english: "After you stop, a larger Whisper model retranscribes saved audio. This uses more battery and time. Install the ~631 MB model manually; Apple live transcription is retained."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)

            Text(copy(
                "meeting.settings.liveTranscription",
                korean: "실시간 전사는 Apple의 기기 내 음성 인식을 사용합니다.",
                english: "Live transcription uses Apple’s on-device speech recognition."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)

            Text(copy(
                "beta.whisper.warning",
                korean: "Whisper large-v3-turbo를 사용합니다. 설치 시에만 공개 모델 파일을 내려받고 음성·전사는 기기에서 처리합니다. 모델이 없거나 실패해도 원본 음성과 Apple 전사는 유지됩니다. 한국어·혼합 언어의 품질 향상은 검증되지 않았습니다.",
                english: "Uses Whisper large-v3-turbo. Only installation downloads public model files; audio and text stay on device. Missing models or failures leave the original audio and Apple transcript intact. Accuracy gains for Korean and mixed languages are unverified."
            ))
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("beta.whisper.warning")
        }
    }

    @ViewBuilder
    private var speakerModelManagement: some View {

        ModelManagementRow {
            Group {
                if speakerModel.isInstalling {
                    ProgressView(
                        copy("beta.diarization.installing", korean: "화자 모델 팩 재사용·다운로드·검증 및 로드 중…", english: "Reusing, downloading, verifying and loading the speaker model pack…"),
                        value: speakerModel.progress
                    )
                } else if speakerModel.isInstalled {
                    Label(copy("beta.diarization.installed", korean: "전체 화자 모델 팩 설치됨 (약 218 MB)", english: "Complete speaker model pack installed (about 218 MB)"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text(copy("beta.diarization.notInstalled", korean: "전체 화자 모델 팩이 필요합니다. 기존 Nemotron 단독 설치도 업그레이드해야 합니다.", english: "The complete speaker model pack is required. Existing Nemotron-only installs also need an upgrade."))
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("meeting.diarization.state")
        } actions: {
            VStack(alignment: .trailing, spacing: AppTheme.Spacing.compact) {
                if speakerModel.isInstalling {
                    Button(copy("beta.diarization.cancel", korean: "설치 취소", english: "Cancel installation"), role: .cancel) {
                        speakerModel.cancelInstall()
                    }
                } else {
                    if speakerModel.hasRemovableModels {
                        Button(copy("beta.diarization.delete", korean: "화자 모델 삭제", english: "Delete speaker model"), role: .destructive) {
                            Task { await speakerModel.delete() }
                        }
                        .disabled(speakerModel.isDeleting)
                        .accessibilityIdentifier("beta.diarization.delete")
                    }
                    if settingsStore.meetingDiarizationEnabled && !speakerModel.isInstalled {
                        // Installation is user-initiated only, never triggered by the toggle or view lifecycle.
                        Button(copy("beta.diarization.download", korean: "화자 모델 팩 설치 또는 업그레이드 (약 218 MB)", english: "Install or upgrade speaker model pack (about 218 MB)")) {
                            speakerModel.install()
                        }
                        .disabled(speakerModel.isDeleting)
                        .accessibilityIdentifier("meeting.diarization.download")
                    }
                }
            }
        }

        if let errorMessage = speakerModel.errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("beta.diarization.error")
        }
    }
    @ViewBuilder
    private var whisperModelManagement: some View {

        ModelManagementRow {
            Group {
                if whisperModel.isInstalling {
                    ProgressView(
                        copy("beta.whisper.installing", korean: "음성 모델 다운로드 및 검증 중…", english: "Downloading and verifying the transcription model…"),
                        value: whisperModel.progress
                    )
                } else if whisperModel.isInstalled {
                    Label(copy("beta.whisper.installed", korean: "음성 모델 설치됨 (약 631 MB)", english: "Transcription model installed (about 631 MB)"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text(copy("beta.whisper.notInstalled", korean: "고급 전사 모델이 설치되지 않았습니다. Apple 실시간 전사는 계속 사용할 수 있습니다.", english: "The transcription model is not installed. Apple live transcription remains available."))
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("beta.whisper.state")
        } actions: {
            if whisperModel.isInstalling {
                Button(copy("beta.whisper.cancel", korean: "다운로드 취소", english: "Cancel download"), role: .cancel) {
                    whisperModel.cancelInstall()
                }
                .accessibilityIdentifier("beta.whisper.cancel")
            } else if whisperModel.isInstalled {
                Button(copy("beta.whisper.delete", korean: "음성 모델 삭제", english: "Delete transcription model"), role: .destructive) {
                    Task { await whisperModel.delete() }
                }
                .disabled(whisperModel.isDeleting)
                .accessibilityIdentifier("beta.whisper.delete")
            } else if settingsStore.meetingAdvancedTranscriptionEnabled {
                Button(copy("beta.whisper.download", korean: "음성 모델 다운로드 (약 631 MB)", english: "Download transcription model (about 631 MB)")) {
                    whisperModel.install()
                }
                .disabled(whisperModel.isDeleting)
                .accessibilityIdentifier("beta.whisper.download")
            }
        }

        if let error = whisperModel.errorMessage {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("beta.whisper.error")
        }
    }
    private func copy(_ key: String, korean: String, english: String) -> String {
        AppLanguage.localized(
            key,
            defaultValue: language == .english ? english : korean,
            language: language,
            comment: "Meeting settings copy."
        )
    }
}
