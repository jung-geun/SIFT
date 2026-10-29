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
                NavigationLink(destination: MeetingSettingsView()) {
                    Label(copy("settings.meeting.title", fallback: "회의"), systemImage: "waveform")
                        .labelStyle(SettingsRowLabelStyle())
                }
                .accessibilityIdentifier("settings.meetingRow")
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
    @AppStorage("pieroot.todo.onDeviceModelID") private var onDeviceModelID = OnDeviceLLMService.defaultModelID
    @State private var language = AppLanguage.current

    private var localModelUseAllowed: Bool {
        !FoundationModelsAvailability.isDeviceEligible && settingsStore.localModelFallbackEnabled
    }

    var body: some View {
        Form {
            Section {
                if !FoundationModelsAvailability.isDeviceEligible {
                    Toggle(copy("beta.localFallback.toggle", korean: "다운로드 모델로 대체", english: "Use a downloaded model as fallback"), isOn: Binding(
                        get: { settingsStore.localModelFallbackEnabled },
                        set: { settingsStore.localModelFallbackEnabled = $0 }
                    ))
                    .accessibilityIdentifier("beta.localFallback.toggle")
                }
                OnDeviceModelManagementSection(llmService: llmService, modelID: $onDeviceModelID, allowsModelUse: localModelUseAllowed)
            } header: {
                Text(copy("beta.localFallback.section", korean: "로컬 AI 대체 · 베타", english: "Local AI fallback · Beta"))
            } footer: {
                if FoundationModelsAvailability.isDeviceEligible {
                    Text(copy("beta.localFallback.supported", korean: "이 기기는 Apple Intelligence를 지원하므로 다운로드 모델을 대체 AI로 사용하지 않습니다. 설치된 모델은 삭제할 수 있습니다.", english: "This device supports Apple Intelligence, so downloaded models are not used as fallback AI. Installed models can still be deleted."))
                } else {
                    Text(copy("beta.localFallback.description", korean: "Apple Intelligence 미지원 기기에서만 선택할 수 있습니다. 모델은 직접 설치해야 하며 켜거나 선택하는 것만으로 다운로드되지 않습니다. 기기에서 처리하며 배터리 사용이 늘 수 있습니다.", english: "Optional only on devices without Apple Intelligence support. Install a model manually; enabling or selecting one downloads nothing. Processing stays on device and may use more battery."))
                }
            }

            if !FoundationModelsAvailability.isDeviceEligible || layaService.isModelInstalled || layaService.isLoading {
                Section {
                    if !FoundationModelsAvailability.isDeviceEligible {
                        Toggle(copy("beta.laya.toggle", korean: "Laya 결정 모델 (메일 후보·우선순위)", english: "Laya decisions (email candidates and priority)"), isOn: Binding(
                            get: { SettingsStore.betaProviderAccess().layaEnabled },
                            set: { settingsStore.setBetaProvider(.laya, enabled: $0) }
                        ))
                        .disabled(!localModelUseAllowed)
                        .accessibilityIdentifier("beta.laya.toggle")
                    }
                    if SettingsStore.betaProviderAccess().layaEnabled || layaService.isModelInstalled || layaService.isLoading {
                        LayaModelManagementSection(service: layaService, isEnabled: SettingsStore.betaProviderAccess().layaEnabled)
                    }
                } header: {
                    Text(copy("beta.laya.section", korean: "Laya · 베타", english: "Laya · Beta"))
                } footer: {
                    Text(copy("beta.laya.note", korean: "약 483 MB 모델을 직접 설치해야 하며 기기에서 처리합니다. 우선순위 품질 기준은 미달, 메일 판단 정확도는 미검증입니다. 원본을 확인하고 직접 저장하세요. 설치하지 않으면 규칙으로 처리합니다.", english: "Manually install the ~483 MB model for on-device processing. Priority quality missed its gate; email accuracy is unverified. Check the source and save explicitly. Without the model, rules apply."))
                }
            }
        }
        .appFormStyle()
        .navigationTitle(copy("settings.beta.title", korean: "베타 기능", english: "Beta features"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.locale, language.locale)
        .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { _ in
            language = AppLanguage.current
        }
    }

    private func copy(_ key: String, korean: String, english: String) -> String {
        AppLanguage.localized(key, defaultValue: language == .english ? english : korean, language: language, comment: "Beta settings copy.")
    }
}
