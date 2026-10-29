import SwiftUI

struct AISettingsView: View {
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var regionalAvailability = OpenAIRegionalAvailability.shared
    @ObservedObject private var connection = OpenAIConnection.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var connectionTask: Task<Void, Never>?
    @State private var connectionError: String?

    var body: some View {
        Form {

            Section {
                LabeledContent("Apple Intelligence") {
                    Text(FoundationModelsAvailability.isAvailable
                         ? copy("ai.apple.available", korean: "사용 가능", english: "Available")
                         : copy("ai.apple.unavailable", korean: "사용 불가", english: "Unavailable"))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("ai.apple.status")
            } footer: {
                Text(copy("ai.apple.default", korean: "기본 AI이며 기기에서 처리합니다. 사용할 수 없으면 규칙으로 처리합니다. 미지원 기기의 다운로드 모델 대체 기능은 베타 설정에서 선택할 수 있습니다.", english: "The default AI processes on device. When unavailable, rules apply. Devices without support can opt into downloaded-model fallback in Beta settings."))
            }

            if regionalAvailability.isAvailable {
                Section {
                    chatGPTConnectionControl
                } header: {
                    Text(copy("ai.chatGPT.optional", korean: "ChatGPT · 선택 사항", english: "ChatGPT · Optional"))
                } footer: {
                    Text(copy("ai.chatGPT.consent", korean: "계정을 연결해도 데이터별 전송 동의 없이는 앱 데이터를 보내지 않습니다. 고급 모델은 직접 재요청할 때만 사용합니다.", english: "Connecting an account does not send app data without consent for each data scope. Advanced models are used only when you explicitly request them."))
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
    let allowsModelUse: Bool
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
        if supported && !FoundationModelsAvailability.isDeviceEligible {
            let installed = installedOptions
            if allowsModelUse && !installed.isEmpty {
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
                } else if !llmService.isModelCachedOnDisk(for: downloadModelID) {
                    Button(copy("beta.model.download", korean: "모델 다운로드", english: "Download model")) {
                        Task { await llmService.installModel(id: downloadModelID) }
                    }
                    .disabled(llmService.isDeleting || !allowsModelUse)
                    .accessibilityIdentifier("beta.model.localDownload")
                }
            }
            .onAppear {
                downloadModelID = OnDeviceLLMService.availableModels.contains(where: { $0.id == modelID })
                    ? modelID : OnDeviceLLMService.defaultModelID
            }
            if let error = llmService.loadError { Text(error).font(.footnote).foregroundStyle(.red) }
        } else {
            if !FoundationModelsAvailability.isDeviceEligible {
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
        ForEach(llmService.installedModels) { model in
            ModelManagementRow {
                Text(model.displayName)
            } actions: {
                Button(copy("beta.model.delete", korean: "삭제", english: "Delete"), role: .destructive) {
                    Task { await llmService.deleteDownloadedModel(id: model.id) }
                }
                .disabled(llmService.isLoading || llmService.isDeleting)
                .accessibilityIdentifier("beta.model.localDelete")
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
