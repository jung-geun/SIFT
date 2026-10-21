import SwiftUI

struct AISettingsView: View {
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var regionalAvailability = OpenAIRegionalAvailability.shared
    @ObservedObject private var connection = OpenAIConnection.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var connectionTask: Task<Void, Never>?
    @State private var connectionError: String?

    private var access: BetaProviderAccess { SettingsStore.betaProviderAccess() }

    var body: some View {
        Form {

            Section {

                if regionalAvailability.isAvailable {
                    chatGPTConnectionControl
                }

                Toggle(
                    copy("beta.laya.toggle", korean: "Laya 결정 모델 (메일 후보·우선순위)", english: "Laya decisions (email candidates and priority)"),
                    isOn: Binding(
                        get: { access.layaEnabled },
                        set: { settingsStore.setBetaProvider(.laya, enabled: $0) }
                    )
                )
                .accessibilityIdentifier("beta.laya.toggle")
                if access.layaEnabled {
                    Text(copy(
                        "beta.laya.note",
                        korean: "Laya는 메일을 할 일 후보로 추천하고 TODO 우선순위·처리 시각을 판단합니다. 약 483 MB 다국어 모델을 직접 설치해야 하며 분석은 기기 안에서 수행합니다. 우선순위 품질 기준은 미달, 메일 판단 정확도는 미검증입니다. 원본 확인 후 직접 저장하세요. 미설치 시 기존 날짜 규칙을 사용합니다.",
                        english: "Laya suggests email to-do candidates and decides task priority and processing time. Install its ~483 MB multilingual model manually; Laya performs analysis on device. Priority quality missed its gate, and email-classification accuracy is unverified. Review the source and save explicitly. Without the model, the existing date rules apply."
                    ))
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text(copy("ai.providers.section", korean: "AI 제공자 · 모델", english: "AI providers and models"))
            } footer: {
                if regionalAvailability.isAvailable {
                    Text(copy(
                        "ai.providers.footer.local",
                        korean: "자동 메일 후보·요약은 기기 내에서 처리합니다. 직접 ChatGPT에 로그인하면 외부 분석 제공자가 활성화되지만, 앱 데이터는 계정 권한과 데이터별 전송 동의가 모두 있어야 전송합니다. 고급 모델은 직접 재요청할 때만 사용합니다.",
                        english: "Automatic email candidates and summaries are processed on device. Signing in to ChatGPT enables the external provider, but app data is sent only with account permission and consent for each data scope. The advanced model is used only on an explicit re-request."
                    ))
                } else {
                    Text(copy(
                        "beta.providers.footer.onDevice",
                        korean: "자동 메일 후보·요약은 기기 내에서 처리합니다.",
                        english: "Automatic email candidates and summaries are processed on device."
                    ))
                }
            }

        }
        .appFormStyle()
        .navigationTitle(copy("settings.ai.title", korean: "AI", english: "AI"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if regionalAvailability.isAvailable { connection.refreshCredentials() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if regionalAvailability.isAvailable { connection.refreshCredentials() }
            }
        }
        .onChange(of: regionalAvailability.isAvailable) { _, available in
            if available {
                connection.refreshCredentials()
            } else {
                connectionError = nil
                cancelConnection()
            }
        }
        .onDisappear { cancelConnection() }
        .alert(copy("openai.error.title", korean: "연결 오류", english: "Connection error"), isPresented: Binding(
            get: { connectionError != nil },
            set: { if !$0 { connectionError = nil } }
        )) {
            Button(copy("openai.action.ok", korean: "확인", english: "OK"), role: .cancel) { connectionError = nil }
        } message: {
            Text(connectionError ?? "")
        }
    }
    @ViewBuilder
    private var chatGPTConnectionControl: some View {
        if connection.isSigningIn || connectionTask != nil {
            ProgressView(copy("openai.account.signInProgress", korean: "브라우저에서 로그인·권한 승인을 완료하세요", english: "Complete sign-in and authorization in your browser"))
                .accessibilityIdentifier("openai.signInProgress")
            Button(copy("openai.account.cancelSignIn", korean: "로그인 취소", english: "Cancel sign-in"), role: .cancel) {
                cancelConnection()
            }
            .accessibilityIdentifier("openai.cancelSignIn")
        } else if connection.activeProfile != nil {
            NavigationLink(destination: OpenAISettingsView()) {
                Label(copy("openai.title", korean: "OpenAI · ChatGPT", english: "OpenAI · ChatGPT"), systemImage: "person.crop.circle.badge.checkmark")
            }
            .accessibilityIdentifier("settings.openAIRow")
        } else {
            Button(copy("openai.account.continue", korean: "ChatGPT로 계속하기", english: "Continue with ChatGPT")) {
                connectChatGPT()
            }
            .accessibilityIdentifier("openai.signIn")
        }
    }

    private func connectChatGPT() {
        guard regionalAvailability.isAvailable, connectionTask == nil, !connection.isSigningIn else { return }
        connectionError = nil
        connectionTask = Task {
            defer { connectionTask = nil }
            do {
                try await connection.signIn(newAccount: false)
                try Task.checkCancellation()
                guard regionalAvailability.isAvailable, connection.activeProfile != nil else { return }
                settingsStore.setBetaProvider(.openAI, enabled: true)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled, regionalAvailability.isAvailable {
                    connectionError = OpenAIViewCopy.errorMessage(error)
                }
            }
        }
    }

    private func cancelConnection() {
        guard connectionTask != nil || connection.isSigningIn else { return }
        connection.cancelSignIn()
        connectionTask?.cancel()
    }




    private func copy(_ key: String, korean: String, english: String) -> String {
        AppLanguage.localized(
            key,
            defaultValue: AppLanguage.current == .english ? english : korean,
            language: .current,
            comment: "AI settings copy."
        )
    }
}


/// Model state and actions share one full-width settings row in every install state.
struct ModelManagementRow<Status: View, Actions: View>: View {
    let status: Status
    let actions: Actions

    init(@ViewBuilder status: () -> Status, @ViewBuilder actions: () -> Actions) {
        self.status = status()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
            status
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .frame(maxWidth: .infinity, alignment: .trailing)
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
        .fixedSize(horizontal: false, vertical: true)
        .lineLimit(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AppTheme.Spacing.compact)
    }
}

struct LayaModelManagementSection: View {
    @ObservedObject var service: LayaDecisionService
    let isEnabled: Bool
    @State private var downloadTask: Task<Void, Never>?

    var body: some View {
        ModelManagementRow {
            if service.isLoading || downloadTask != nil {
                ProgressView(value: service.downloadProgress)
            } else if service.isModelInstalled {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                    Label(copy("beta.model.downloaded", korean: "다운로드됨", english: "Downloaded"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(ByteCountFormatter.string(fromByteCount: service.installedSizeBytes, countStyle: .file))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if isEnabled && !service.isCapable {
                Label(copy("beta.laya.unsupported", korean: "이 기기는 Laya 모델을 실행할 수 없습니다.", english: "This device cannot run the Laya model."), systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.orange)
            } else if isEnabled {
                Text(copy("intelligence.model.notInstalled", korean: "설치되지 않음", english: "Not Installed"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } actions: {
            if service.isLoading || downloadTask != nil {
                Button(copy("beta.model.cancel", korean: "다운로드 취소", english: "Cancel download"), role: .cancel) {
                    downloadTask?.cancel()
                }
                .accessibilityIdentifier("beta.laya.cancelDownload")
            } else if service.isModelInstalled {
                Button(copy("beta.model.delete", korean: "삭제", english: "Delete"), role: .destructive) {
                    Task { await service.deleteDownloadedModel() }
                }
                .disabled(service.isLoading || service.isDeleting)
                .accessibilityIdentifier("beta.laya.delete")
            } else if isEnabled && service.isCapable {
                Button(copy("beta.model.download", korean: "모델 다운로드", english: "Download model")) {
                    downloadTask = Task {
                        defer { downloadTask = nil }
                        await service.loadModelIfNeeded(use: .layaModelManagement)
                    }
                }
                .disabled(service.isDeleting)
                .accessibilityIdentifier("beta.laya.download")
            }
        }
        if !service.isLoading && downloadTask == nil && !service.isModelInstalled && isEnabled {
            if let loadError = service.loadError {
                Text(loadError).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func copy(_ key: String, korean: String, english: String) -> String {
        AppLanguage.localized(
            key,
            defaultValue: AppLanguage.current == .english ? english : korean,
            language: .current,
            comment: "Laya beta model management copy."
        )
    }
}

struct OnDeviceModelManagementSection: View {
    @ObservedObject var llmService: OnDeviceLLMService
    @Binding var modelID: String
    @State private var downloadModelID = OnDeviceLLMService.defaultModelID

    private var installedOptions: [OnDeviceLLMService.ModelOption] {
        OnDeviceLLMService.availableModels.filter { llmService.isModelCachedOnDisk(for: $0.id) }
    }

    private var supported: Bool {
        OnDeviceModelSupportState(
            isCapable: llmService.isCapable,
            availableModelCount: OnDeviceLLMService.availableModels.count
        ) == .available
    }

    var body: some View {
        if supported {
            let installed = installedOptions
            if !installed.isEmpty {
                Picker(copy("beta.model.active", korean: "사용할 로컬 모델", english: "Local model to use"), selection: Binding<String?>(
                    get: { installed.contains(where: { $0.id == modelID }) ? modelID : nil },
                    set: { selected in
                        guard let selected, installed.contains(where: { $0.id == selected }) else { return }
                        if llmService.loadedModelIdentifier != selected { llmService.unloadModel() }
                        modelID = selected
                        SettingsStore.shared.normalizeBetaSelectedProvider()
                    }
                )) {
                    if !installed.contains(where: { $0.id == modelID }) {
                        Text(copy("beta.model.noneInstalled", korean: "설치된 모델을 선택하세요", english: "Choose an installed model"))
                            .tag(Optional<String>.none)
                    }
                    ForEach(installed) { model in Text(model.displayName).tag(Optional(model.id)) }
                }
                .pickerStyle(.menu)
                .controlSize(.regular)
                .accessibilityIdentifier("beta.model.installedPicker")
                .disabled(llmService.isLoading || llmService.isDeleting)
            }
            Picker(copy("beta.model.downloadTarget", korean: "설치할 로컬 모델", english: "Local model to install"), selection: $downloadModelID) {
                ForEach(OnDeviceLLMService.availableModels) { model in Text(model.displayName).tag(model.id) }
            }
            .pickerStyle(.menu)
            .controlSize(.regular)
            .disabled(llmService.isLoading || llmService.isDeleting)
            .accessibilityIdentifier("beta.model.downloadPicker")
            ModelManagementRow {
                if llmService.isLoading {
                    ProgressView(value: llmService.downloadProgress)
                } else if llmService.isModelCachedOnDisk(for: downloadModelID) {
                    Label(copy("beta.model.downloaded", korean: "다운로드됨", english: "Downloaded"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text(copy("intelligence.model.notInstalled", korean: "설치되지 않음", english: "Not Installed"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } actions: {
                if llmService.isLoading {
                    Button(copy("beta.model.cancel", korean: "다운로드 취소", english: "Cancel download"), role: .cancel) {
                        llmService.unloadModel(reason: .manual)
                    }
                    .accessibilityIdentifier("beta.model.localCancelDownload")
                } else if llmService.isModelCachedOnDisk(for: downloadModelID) {
                    Button(copy("beta.model.delete", korean: "삭제", english: "Delete"), role: .destructive) {
                        Task { await llmService.deleteDownloadedModel(id: downloadModelID) }
                    }
                    .disabled(llmService.isLoading || llmService.isDeleting)
                    .accessibilityIdentifier("beta.model.localDelete")
                } else {
                    Button(copy("beta.model.download", korean: "모델 다운로드", english: "Download model")) {
                        Task { await llmService.installModel(id: downloadModelID) }
                    }
                    .disabled(llmService.isDeleting)
                    .accessibilityIdentifier("beta.model.localDownload")
                }
            }
            .onAppear {
                downloadModelID = OnDeviceLLMService.availableModels.contains(where: { $0.id == modelID })
                    ? modelID : OnDeviceLLMService.defaultModelID
            }
            if let error = llmService.loadError { Text(error).font(.footnote).foregroundStyle(.red) }
        } else {
            ModelManagementRow {
                Label(copy("beta.model.unsupported", korean: "이 기기는 다운로드 온디바이스 모델을 지원하지 않습니다.", english: "This device does not support downloaded on-device models."), systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("intelligence.onDevice.unsupported")
            } actions: {
                EmptyView()
            }
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
