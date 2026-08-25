import SwiftUI

struct BetaFeaturesView: View {
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var llmService: OnDeviceLLMService = .shared
    @AppStorage("pieroot.todo.onDeviceModelID") private var onDeviceModelID = OnDeviceLLMService.defaultModelID
    @State private var geminiAPIKeyInput = ""

    private var access: BetaProviderAccess { SettingsStore.betaProviderAccess() }

    private var enabledProviders: [PersonaAIProvider] {
        PersonaAIProvider.allCases.filter(access.isEnabled)
    }

    var body: some View {
        Form {
            Section {
                Text(copy(
                    "beta.warning",
                    korean: "베타 기능은 실험 중이며 일부 기기·언어·데이터에서 부정확하거나 동작하지 않을 수 있습니다. 필요한 provider만 직접 켜세요.",
                    english: "Beta features are experimental and may be inaccurate or unavailable for some devices, languages, or data. Enable only the providers you need."
                ))
                .font(.subheadline)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("beta.warning")
            }

            Section {
                providerToggle(
                    .foundationModels,
                    title: copy("beta.foundationModels.toggle", korean: "Apple Foundation Models (AFM)", english: "Apple Foundation Models (AFM)"),
                    identifier: "beta.foundationModels.toggle"
                )
                if access.foundationModelsEnabled, let explanation = FoundationModelsAvailability.unavailableExplanation {
                    Label(explanation, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                providerToggle(
                    .onDevice,
                    title: copy("beta.onDevice.toggle", korean: "다운로드 온디바이스 모델", english: "Downloaded on-device model"),
                    identifier: "beta.onDevice.toggle"
                )
                if access.onDeviceEnabled {
                    OnDeviceModelManagementSection(
                        llmService: llmService,
                        modelID: $onDeviceModelID
                    )
                }

                providerToggle(
                    .gemini,
                    title: copy("beta.gemini.toggle", korean: "Gemini 연결", english: "Gemini connection"),
                    identifier: "beta.gemini.toggle"
                )
                if access.geminiEnabled {
                    geminiSettings
                }
            } header: {
                Text(copy("beta.providers.section", korean: "베타 provider", english: "Beta providers"))
            } footer: {
                Text(copy(
                    "beta.providers.footer",
                    korean: "각 provider는 TODO 우선순위, 이메일 분석, 회의 분석에 사용될 수 있습니다. Gemini 메일 본문 전송은 이메일 설정의 별도 동의가 필요합니다.",
                    english: "Each provider may be used for TODO prioritization, email analysis, and meeting analysis. Sending email bodies to Gemini still requires separate consent in Email settings."
                ))
            }

            if enabledProviders.count > 1 {
                Section {
                    Picker(
                        copy("beta.providerPicker", korean: "사용할 베타 provider", english: "Beta provider to use"),
                        selection: selectedProviderBinding
                    ) {
                        ForEach(enabledProviders) { provider in
                            Label(provider.displayName, systemImage: provider.systemImage).tag(provider)
                        }
                    }
                    .accessibilityIdentifier("beta.providerPicker")
                }
            }

            Section {
                Toggle(
                    copy("beta.voiceProcessing.toggle", korean: "음성 노이즈 감소", english: "Voice noise reduction"),
                    isOn: Binding(
                        get: { access.meetingVoiceProcessingEnabled },
                        set: { enabled in
                            SettingsStore.shared.meetingVoiceProcessingEnabled = enabled
                        }
                    )
                )
                .accessibilityIdentifier("beta.voiceProcessing.toggle")

                if access.foundationModelsEnabled || access.onDeviceEnabled {
                    Toggle(
                        copy("beta.autoRefine.toggle", korean: "전사 자동 교정", english: "Automatically refine transcripts"),
                        isOn: Binding(
                            get: { settingsStore.meetingAutoRefineEnabled },
                            set: { settingsStore.meetingAutoRefineEnabled = $0 }
                        )
                    )
                }
            } header: {
                Text(copy("beta.meeting.section", korean: "회의 베타 기능", english: "Meeting beta features"))
            }
        }
        .navigationTitle(copy("beta.title", korean: "베타 기능", english: "Beta Features"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            settingsStore.migrateLegacyBetaSelectedProviderIfNeeded()
            settingsStore.normalizeBetaSelectedProvider()
            geminiAPIKeyInput = GeminiProviderService.storedAPIKey ?? ""
        }
    }

    @ViewBuilder
    private func providerToggle(_ provider: BetaProvider, title: String, identifier: String) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { SettingsStore.betaProviderEnabled(provider) },
                set: { SettingsStore.shared.setBetaProvider(provider, enabled: $0) }
            )
        )
        .accessibilityIdentifier(identifier)
    }

    private var selectedProviderBinding: Binding<PersonaAIProvider> {
        Binding(
            get: { SettingsStore.betaSelectedProvider() ?? enabledProviders[0] },
            set: { SettingsStore.shared.setBetaSelectedProvider($0) }
        )
    }

    @ViewBuilder
    private var geminiSettings: some View {
        SecureField(copy("beta.gemini.apiKey", korean: "Gemini API 키", english: "Gemini API Key"), text: $geminiAPIKeyInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

        Picker(copy("beta.model.label", korean: "모델", english: "Model"), selection: Binding(
            get: { SettingsStore.shared.get("pieroot.todo.geminiModelID", defaultValue: GeminiProviderService.defaultModelID) },
            set: { SettingsStore.shared.set("pieroot.todo.geminiModelID", value: $0) }
        )) {
            Text("gemini-2.0-flash").tag("gemini-2.0-flash")
            Text("gemini-2.5-flash").tag("gemini-2.5-flash")
        }

        HStack {
            Button(copy("beta.gemini.saveKey", korean: "키 저장", english: "Save key")) {
                GeminiProviderService.saveAPIKey(geminiAPIKeyInput)
                geminiAPIKeyInput = GeminiProviderService.storedAPIKey ?? ""
            }
            .disabled(geminiAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if GeminiProviderService.storedAPIKey != nil {
                Button(copy("beta.gemini.deleteKey", korean: "키 삭제", english: "Delete key"), role: .destructive) {
                    GeminiProviderService.deleteAPIKey()
                    geminiAPIKeyInput = ""
                }
            }
        }

        Text(copy(
            "beta.gemini.warning",
            korean: "Gemini를 사용하면 TODO 제목·메모·마감·페르소나·캘린더 컨텍스트가 외부 서비스로 전송될 수 있습니다. 이메일 원문 본문은 별도 동의 없이는 전송하지 않습니다.",
            english: "Using Gemini may send TODO titles, notes, due dates, persona, and calendar context to an external service. Email bodies are never sent without separate consent."
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func copy(_ key: String, korean: String, english: String) -> String {
        AppLanguage.localized(
            key,
            defaultValue: AppLanguage.current == .english ? english : korean,
            language: .current,
            comment: "Beta feature settings copy."
        )
    }
}

struct OnDeviceModelManagementSection: View {
    @ObservedObject var llmService: OnDeviceLLMService
    @Binding var modelID: String

    private var supported: Bool {
        OnDeviceModelSupportState(
            isCapable: llmService.isCapable,
            availableModelCount: OnDeviceLLMService.availableModels.count
        ) == .available
    }

    var body: some View {
        if supported {
            Picker(copy("beta.model.label", korean: "모델", english: "Model"), selection: $modelID) {
                ForEach(OnDeviceLLMService.availableModels) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .onChange(of: modelID) { _, _ in
                if llmService.isModelLoaded { llmService.unloadModel() }
            }

            HStack {
                if llmService.isModelCachedOnDisk {
                    Label(copy("beta.model.downloaded", korean: "다운로드됨", english: "Downloaded"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button(copy("beta.model.delete", korean: "삭제", english: "Delete"), role: .destructive) {
                        Task { await llmService.deleteDownloadedModel() }
                    }
                } else {
                    Button(copy("beta.model.download", korean: "모델 다운로드", english: "Download model")) {
                        Task { await llmService.loadModelIfNeeded(use: .modelManagement) }
                    }
                    .disabled(llmService.isLoading)
                }
            }
        } else {
            Label(copy("beta.model.unsupported", korean: "이 기기는 다운로드 온디바이스 모델을 지원하지 않습니다.", english: "This device does not support downloaded on-device models."), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("intelligence.onDevice.unsupported")
        }
    }

    private func copy(_ key: String, korean: String, english: String) -> String {
        AppLanguage.localized(
            key,
            defaultValue: AppLanguage.current == .english ? english : korean,
            language: .current,
            comment: "On-device beta model management copy."
        )
    }
}
