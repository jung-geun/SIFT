import SwiftUI

struct PersonaSettingsView: View {
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTutorialState) private var tutorial
    @EnvironmentObject private var appUpdate: AppUpdateService
    @State private var languageOverrideRaw = AppLanguage.userOverride?.rawValue ?? ""
    @State private var selectedAppLanguage = AppLanguage.current
    @State private var showsAdvancedSettings = false
    var body: some View {
        ScrollViewReader { scrollProxy in
        AppTutorialObserving {
        Form {
            Section {
                NavigationLink(destination: TodoSettingsView()) {
                    Label(copy("settings.todo.title", fallback: "할 일"), systemImage: "checklist")
                        .labelStyle(SettingsRowLabelStyle())
                        .appTutorialGlow(tutorial?.currentStep == .permissions || tutorial?.currentStep == .priorityRules)
                }
                .accessibilityIdentifier("settings.todoRow")
                .appTutorialAnchor(screen: .settings, steps: [.permissions, .priorityRules])
                .id("tutorial.todoSettings")
                NavigationLink(destination: EmailDetailView()) {
                    Label("이메일 연동", systemImage: "envelope")
                        .labelStyle(SettingsRowLabelStyle())
                        .appTutorialGlow(tutorial?.currentStep == .emailOptional)
                }
                .appTutorialAnchor(screen: .settings, steps: [.emailOptional])
                .id("tutorial.emailSettings")
                NavigationLink(destination: CalendarDetailView()) {
                    Label("캘린더 설정", systemImage: "calendar")
                        .labelStyle(SettingsRowLabelStyle())
                }
                .accessibilityIdentifier("settings.calendarRow")
                NavigationLink(destination: ICloudSyncDetailView()) {
                    Label("iCloud 동기화", systemImage: "icloud")
                        .labelStyle(SettingsRowLabelStyle())
                }
                .accessibilityIdentifier("settings.syncRow")
                NavigationLink(destination: RoutineDetailView()) {
                    Label(copy("routines.title", fallback: "루틴 학습·추천"), systemImage: "repeat")
                        .labelStyle(SettingsRowLabelStyle())
                }
                .accessibilityIdentifier("settings.routinesRow")
                if !HealthHistoryReader.availableCategories.isEmpty || HealthRoutineStore.shared.hasLocalData {
                NavigationLink(destination: HealthHistorySettingsView()) {
                    Label(copy("settings.health.title", fallback: "건강·운동 기록"), systemImage: "heart.text.square")
                        .labelStyle(SettingsRowLabelStyle())
                }
                .accessibilityIdentifier("settings.healthRow")
                }
                NavigationLink(destination: AISettingsView()) {
                    Label(copy("settings.ai.title", fallback: "AI"), systemImage: "sparkles")
                        .labelStyle(SettingsRowLabelStyle())
                }
                .accessibilityIdentifier("settings.aiRow")
                NavigationLink(destination: BetaFeaturesSettingsView()) {
                    Label(copy("settings.beta.title", fallback: "베타 기능"), systemImage: "flask")
                        .labelStyle(SettingsRowLabelStyle())
                }
                .accessibilityIdentifier("settings.betaRow")
            }
            Section {
                NavigationLink(destination: AppInfoDetailView()) {
                    HStack {
                        Label("앱 정보", systemImage: "info.circle")
                            .labelStyle(SettingsRowLabelStyle())
                        Spacer()
                        if appUpdate.hasUpdate {
                            Text("업데이트 가능")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("settings.appInfoRow")
                Picker(
                    copy("settings.language.label", fallback: "앱 언어"),
                    selection: $languageOverrideRaw
                ) {
                    Text(copy("settings.language.system", fallback: "시스템 언어"))
                        .tag("")
                    ForEach(AppLanguage.supported) { language in
                        Text(language.displayName)
                            .tag(language.rawValue)
                    }
                }
                .onChange(of: languageOverrideRaw) { _, rawValue in
                    let language = AppLanguage.supported.first { $0.rawValue == rawValue }
                    AppLanguage.setUserOverride(language)
                }
                .accessibilityIdentifier("settings.languagePicker")
            }
            #if !targetEnvironment(macCatalyst)
            AdMobPrivacyOptionsRow()
            #endif
            Section {
                DisclosureGroup(isExpanded: $showsAdvancedSettings) {
                    NavigationLink(destination: PersonaDetailView()) {
                        Label("나의 페르소나", systemImage: "person.circle")
                            .labelStyle(SettingsRowLabelStyle())
                            .appTutorialGlow(tutorial?.currentStep == .persona)
                    }
                    .appTutorialAnchor(screen: .settings, steps: [.persona], above: true)
                    .id("tutorial.personaSettings")
                    NavigationLink(destination: MemoryDetailView()) {
                        Label("행동 패턴 분석", systemImage: "brain.head.profile")
                            .labelStyle(SettingsRowLabelStyle())
                    }
                    NavigationLink(destination: VocabularyDetailView()) {
                        Label("사용자 단어장", systemImage: "text.book.closed")
                            .labelStyle(SettingsRowLabelStyle())
                    }
                    .accessibilityIdentifier("settings.vocabularyRow")
                } label: {
                    Label(copy("settings.advanced", fallback: "고급 설정"), systemImage: "slider.horizontal.3")
                        .labelStyle(SettingsRowLabelStyle())
                        .accessibilityIdentifier("settings.advanced")
                }
            }

        }
        .appFormStyle()
        .environment(\.locale, selectedAppLanguage.locale)
        .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { _ in
            selectedAppLanguage = AppLanguage.current
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let tutorial {
                AppTutorialTipHost(tutorial: tutorial, screen: .settings)
            }
        }
        .navigationTitle(copy("settings.title", fallback: "설정"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(copy("action.close", fallback: "닫기")) {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }
                    .accessibilityIdentifier("settings.closeButton")
            }
        }
        #if !targetEnvironment(macCatalyst)
        .task {
            // Privacy choices remain accessible even when placement access disables ads.
            // This explicit Settings-entry refresh never starts GMA or a startup form.
            AdMobConsentManager.shared.refreshPrivacyOptionsRequirement()
        }
        #endif
        .task(id: tutorial?.currentStep) {
            revealTutorialSettings()
            let target: String?
            switch tutorial?.currentStep {
            case .persona: target = "tutorial.personaSettings"
            case .priorityRules, .permissions: target = "tutorial.todoSettings"
            case .emailOptional: target = "tutorial.emailSettings"
            default: target = nil
            }
            guard let target else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            scrollProxy.scrollTo(target, anchor: .center)
        }
        }
        }
    }

    private func copy(_ key: String, fallback: String) -> String {
        AppLanguage.localized(
            key,
            defaultValue: fallback,
            language: selectedAppLanguage,
            comment: "Settings localization copy."
        )
    }

    private func revealTutorialSettings() {
        if tutorial?.currentStep == .persona {
            showsAdvancedSettings = true
        }
    }
}

struct BetaFeaturesSettingsView: View {
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var llmService = OnDeviceLLMService.shared
    @ObservedObject private var layaService = LayaDecisionService.shared
    @ObservedObject private var speakerModel = MeetingDiarizationModelController.shared
    @ObservedObject private var whisperModel = MeetingWhisperModelController.shared
    @AppStorage("pieroot.todo.onDeviceModelID") private var onDeviceModelID = OnDeviceLLMService.defaultModelID
    @State private var language = AppLanguage.current

    var body: some View {
        Form {
            Section {
                Text(copy(
                    "ai.models.notice",
                    korean: "다운로드 모델은 아래 버튼으로 직접 설치합니다. 기능을 켜기만 해서는 다운로드되지 않습니다. 실험적 모델의 결과는 원본과 함께 확인하세요.",
                    english: "Install downloaded models explicitly using the buttons below. Turning a feature on does not download its model. Check experimental model results against the source."
                ))
                .font(.subheadline)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("ai.models.notice")
            }
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
                    korean: "기기에서 Apple 음성 처리로 에코와 잡음을 줄입니다. 기본값은 꺼짐이며, 끄면 원본 입력으로 녹음합니다.",
                    english: "Uses Apple voice processing on device to reduce echo and noise. Off by default; when off, recordings use the original input."
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
                    korean: "기본으로 켜져 있으며 녹음 완료·재전사 후 기기에서 전사의 오인식과 오탈자를 교정합니다. 사용 가능한 Apple Intelligence를 먼저 사용하며, 끄면 자동 교정을 건너뜁니다.",
                    english: "On by default. After recording or retranscription, corrects recognition errors and typos on device, using Apple Intelligence first when available. Turn off to skip automatic correction."
                ))
            }

            if SettingsStore.betaProviderAccess().layaEnabled || layaService.isModelInstalled || layaService.isLoading {
                Section {
                    LayaModelManagementSection(service: layaService, isEnabled: SettingsStore.betaProviderAccess().layaEnabled)
                } header: {
                    Text(copy("beta.laya.toggle", korean: "Laya 결정 모델 (메일 후보·우선순위)", english: "Laya decisions (email candidates and priority)"))
                }
            }

            Section {
                OnDeviceModelManagementSection(llmService: llmService, modelID: $onDeviceModelID)
            } header: {
                Text(copy("ai.localModels.section", korean: "다운로드 로컬 모델", english: "Downloaded local models"))
            } footer: {
                Text(copy(
                    "beta.localModels.description",
                    korean: "설치할 모델을 선택한 뒤 다운로드 버튼을 눌러 직접 설치하세요. 모델 선택만으로는 다운로드되지 않으며, 분석은 기기 안에서 처리합니다.",
                    english: "Choose a model, then tap Download to install it explicitly. Choosing a model does not download it; analysis runs on device."
                ))
            }
            Section {
                Toggle(
                    copy("beta.diarization.toggle", korean: "회의 화자 구분 (Nemotron)", english: "Meeting speaker diarization (Nemotron)"),
                    isOn: Binding(
                        get: { settingsStore.meetingDiarizationEnabled },
                        set: { settingsStore.meetingDiarizationEnabled = $0 }
                    )
                )
                .accessibilityIdentifier("beta.meetingDiarization.toggle")

                if settingsStore.meetingDiarizationEnabled || speakerModel.hasRemovableModels || speakerModel.isInstalling {
                    speakerModelManagement
                }

                Toggle(
                    copy("beta.whisper.auto", korean: "녹음 후 오프라인 고급 전사", english: "Offline transcription after recording"),
                    isOn: Binding(
                        get: { settingsStore.meetingAdvancedTranscriptionEnabled },
                        set: { settingsStore.meetingAdvancedTranscriptionEnabled = $0 }
                    )
                )
                .accessibilityIdentifier("beta.whisper.auto")

                if settingsStore.meetingAdvancedTranscriptionEnabled || whisperModel.isInstalled || whisperModel.isInstalling {
                    whisperModelManagement
                }
            } header: {
                Text(copy("ai.meeting.section", korean: "회의 음성 모델", english: "Meeting speech models"))
            }
        }
        .appFormStyle()
        .navigationTitle(copy("settings.beta.title", korean: "베타 기능", english: "Beta features"))
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
        Text(copy(
            "beta.diarization.warning",
            korean: "화자 구분은 실험적 기능이며 한국어·8인 회의 품질이나 이번 모델 추가의 품질 개선은 아직 검증되지 않았습니다. Nemotron은 계속 녹음 중 임시 화자 구분과 종료 후 각 트랙의 저장된 음성에 대한 최종 분석을 모두 담당합니다. pyannote/WeSpeaker Community-1 음성 임베딩은 보조 수단으로, 혼자 말한 구간을 이용해 같은 트랙의 이전·최종 화자 ID만 비교하며 Nemotron을 대체하지 않습니다. 충분한 단독 발화가 없으면 음성 비교를 생략합니다. 임베딩은 해당 트랙을 분석하는 동안 기기 메모리에만 유지되며 저장·동기화하거나 다른 트랙·회의의 화자를 연결하는 데 사용하지 않습니다. 트랙당 최대 8명입니다. 켜기만 해서는 다운로드되지 않으며 설치 버튼으로 전체 팩(약 218 MB)을 설치해야 합니다. 기존 Nemotron 단독 설치도 직접 업그레이드해야 하며 검증된 Nemotron 파일은 다시 내려받지 않습니다. 설치할 때만 Hugging Face에서 공개 모델을 내려받습니다. 음성·전사·화자 분석은 기기에서 처리합니다. 전체 iCloud 저장에 동의하면 저장된 녹음·전사와 이 설정이 동기화되지만 모델은 기기마다 설치해야 합니다. 녹음 중 변경은 다음 녹음부터 적용됩니다.",
            english: "Speaker diarization is experimental; quality for Korean and 8-person meetings and any quality improvement from this addition are not yet verified. Nemotron remains responsible for both live provisional speaker diarization and final analysis of each track's saved audio when you stop. pyannote/WeSpeaker Community-1 voice embeddings are auxiliary: solo speech is used only to compare prior and final speaker IDs within the same track, not to replace Nemotron. Voice comparison is skipped when there is not enough solo speech. Embeddings stay only in device memory during analysis of that track; they are not saved, synced or used to link speakers across tracks or meetings. Up to 8 speakers per track. Turning this on downloads nothing: explicitly install the complete pack (about 218 MB) using the install button. Existing Nemotron-only installs also require an explicit upgrade; verified Nemotron files are reused without downloading them again. Only installation downloads public models from Hugging Face. Audio, transcript and speaker analysis runs on device. Full iCloud storage consent can sync saved recordings, transcripts and this setting, but model files must be installed on each device. Changes during recording apply to the next recording."
        ))
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.orange)
        .accessibilityIdentifier("beta.diarization.warning")

        Link(copy(
            "beta.diarization.attribution",
            korean: "같은 트랙의 화자 ID 비교용 보조 임베딩 · 수정된 Core ML 변환: pyannote · WeSpeaker · BUT Speech@FIT · Fluid Inference (CC BY 4.0; 제작자·변경 사항은 NOTICE 참조)",
            english: "Auxiliary same-track speaker-ID embeddings · modified Core ML conversions: pyannote · WeSpeaker · BUT Speech@FIT · Fluid Inference (CC BY 4.0; creators and changes in NOTICE)"
        ), destination: URL(string: "https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/df2625ac79a7ac6b65ad868fee6d80f320da4232/NOTICE.md")!)
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("beta.diarization.attribution")

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
        Text(copy(
            "beta.whisper.warning",
            korean: "Whisper large-v3-turbo Core ML 모델(약 631 MB)을 직접 설치해야 합니다. 설치할 때만 공개 모델 파일을 내려받고, 녹음·전사 내용은 기기에서만 처리합니다. 종료 후 Apple 실시간 전사를 보존한 채 저장 음성을 다시 전사합니다. 모델이 없거나 실패하면 기존 음성과 Apple 전사는 유지됩니다. 한국어·혼합 언어의 품질 향상은 아직 검증되지 않았습니다.",
            english: "Install the Whisper large-v3-turbo Core ML model (about 631 MB) manually. Only public model files are downloaded; your audio and transcript are processed on device. After recording, saved audio is transcribed while the original Apple live transcript is retained. If the model is missing or fails, existing audio and Apple text remain. Accuracy gains for Korean and mixed languages are not yet verified."
        ))
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.orange)
        .accessibilityIdentifier("beta.whisper.warning")

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
            comment: "Beta settings copy."
        )
    }
}
