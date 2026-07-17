import SwiftUI

// 3. TODO 자동 정렬 및 AI
struct IntelligenceDetailView: View {
    @Environment(\.appTutorialState) private var tutorial
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("pieroot.todo.onDeviceModelID") private var onDeviceModelID = "mlx-community/Qwen3.5-2B-MLX-4bit"
    
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var llmService: OnDeviceLLMService = .shared
    
    @State private var showDownloadConfirm = false
    @State private var geminiAPIKeyInput = ""
    
    private var selectedProvider: PersonaAIProvider {
        get {
            let raw: String = SettingsStore.shared.get("selectedAIProvider", defaultValue: PersonaAIProvider.foundationModels.rawValue)
            return PersonaAIProvider(rawValue: raw) ?? .foundationModels
        }
        nonmutating set {
            saveSetting(key: "selectedAIProvider", value: newValue.rawValue)
        }
    }
    
    private var selectedProviderBinding: Binding<PersonaAIProvider> {
        Binding(
            get: {
                let raw: String = SettingsStore.shared.get("selectedAIProvider", defaultValue: PersonaAIProvider.foundationModels.rawValue)
                return PersonaAIProvider(rawValue: raw) ?? .foundationModels
            },
            set: { newValue in
                saveSetting(key: "selectedAIProvider", value: newValue.rawValue)
            }
        )
    }
    
    private var selectedModelSizeMB: Int {
        OnDeviceLLMService.modelCatalog.first { $0.id == onDeviceModelID }?.sizeMB ?? 1400
    }
    
    private var isOnDeviceLLMCapable: Bool {
        llmService.isCapable
    }
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("AI 자동화", isOn: settingsBinding(key: "pieroot.todo.onDeviceLLMEnabled", defaultValue: false))
                    scopeBadge(for: "pieroot.todo.onDeviceLLMEnabled", iCloudSyncEnabled: iCloudSyncEnabled)
                }
            } header: {
                Label("AI 자동화", systemImage: "gearshape.2")
            } footer: {
                Text("앱 실행 시 자동으로 페르소나를 갱신합니다 (6시간 쿨다운). 이메일 분석·할 일 자동 등록은 아래 이메일 연동의 '메일 자동 분석' 토글로 별도 제어합니다. 수동 정렬(✦)·페르소나 생성은 이 설정과 상관없이 항상 동작합니다.")
            }
            
            Section {
                Picker("TODO 자동 정렬 AI", selection: selectedProviderBinding) {
                    ForEach(PersonaAIProvider.allCases) { p in
                        Label(p.displayName, systemImage: p.systemImage).tag(p)
                    }
                }
                .pickerStyle(.menu)
                scopeBadge(for: "selectedAIProvider", iCloudSyncEnabled: iCloudSyncEnabled)
                
                
                
                if selectedProvider == .onDevice && !llmService.isCapable {
                    Label("이 기기는 현재 온디바이스 AI 실행 기준을 충족하지 않아 다른 경로로 폴백될 수 있습니다.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if selectedProvider == .onDevice && !llmService.isModelCachedOnDisk {
                    Label("온디바이스 모델을 먼저 다운로드하세요 (아래 모델 관리 섹션)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if selectedProvider == .foundationModels {
                    if let reason = FoundationModelsAvailability.unavailableExplanation {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                
                Label("할 일 목록 화면 ✦ 버튼으로 AI 우선순위 정리 실행", systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Label("TODO 자동 정렬 AI", systemImage: "brain")
            } footer: {
                Text(intelligenceFooter)
            }
            
            if selectedProvider == .onDevice && isOnDeviceLLMCapable {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("모델")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(llmService.modelID.components(separatedBy: "/").last ?? llmService.modelID)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        llmModelStatusBadge
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        if llmService.isModelCachedOnDisk && !llmService.isModelLoaded {
                            Button {
                                Task { await llmService.loadModelIfNeeded() }
                            } label: {
                                Label("지금 로드", systemImage: "cpu.fill")
                            }
                        }
                        if llmService.isModelLoaded || llmService.isModelCachedOnDisk {
                            Button(role: .destructive) {
                                Task { await llmService.deleteDownloadedModel() }
                            } label: {
                                Label("모델 삭제 (약 \(selectedModelSizeMB / 100 * 100 / 1000).\((selectedModelSizeMB / 100) % 10)GB 확보)", systemImage: "trash")
                            }
                        }
                        if !llmService.isModelCachedOnDisk && !llmService.isLoading {
                            Button {
                                showDownloadConfirm = true
                            } label: {
                                Label("모델 다운로드", systemImage: "arrow.down.circle")
                            }
                        }
                    }
                    
                    Picker("모델", selection: $onDeviceModelID) {
                        ForEach(OnDeviceLLMService.availableModels) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: onDeviceModelID) { _, _ in
                        if llmService.isModelLoaded { llmService.unloadModel() }
                    }
                    .onAppear {
                        // 저장된 모델이 이 기기에서 허용되지 않으면(예: 6GB 기기인데 4B) 허용 모델로 교정.
                        let allowed = OnDeviceLLMService.availableModels
                        if !allowed.contains(where: { $0.id == onDeviceModelID }) {
                            onDeviceModelID = allowed.first?.id ?? OnDeviceLLMService.defaultModelID
                        }
                    }
                    
                    if llmService.isLoading {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: llmService.downloadProgress > 0 ? llmService.downloadProgress : nil)
                            if llmService.downloadProgress > 0 {
                                Text("\(Int(llmService.downloadProgress * 100))% 완료")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("초기화 중…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    
                    if llmService.downloadInterrupted {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                "다운로드가 중단됐습니다 (\(Int(llmService.downloadProgress * 100))% 완료)",
                                systemImage: "pause.circle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            HStack(spacing: 8) {
                                Button("다시 시도") {
                                    Task { await llmService.loadModelIfNeeded() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Button(role: .destructive) {
                                    Task { await llmService.deleteDownloadedModel() }
                                } label: {
                                    Text("부분 삭제")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    
                    if let err = llmService.loadError {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("다운로드 실패", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.red)
                            Text(err)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button("다시 시도") {
                                Task { await llmService.loadModelIfNeeded() }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                    
                    if !llmService.isLoading && !llmService.downloadInterrupted && !llmService.isModelCachedOnDisk {
                        if OnDeviceLLMService.isMLXAvailable {
                            Button {
                                showDownloadConfirm = true
                            } label: {
                                Label("모델 다운로드 (약 \(selectedModelSizeMB / 100 * 100 / 1000).\((selectedModelSizeMB / 100) % 10)GB)", systemImage: "arrow.down.circle")
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Xcode에서 패키지를 먼저 추가해야 합니다", systemImage: "exclamationmark.triangle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                                Text("File → Add Package Dependencies\n\(URL(string: "https://github.com/ml-explore/mlx-swift-lm")!.absoluteString)\nbranch: main → MLXLLM, MLXLMCommon 선택")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Label("온디바이스 모델 관리", systemImage: "square.and.arrow.down")
                } footer: {
                    Text("'Qwen AI' 선택 시 활성화됩니다. 최초 1회만 다운로드합니다. Wi-Fi 환경에서 진행을 권장합니다. 모델은 기기에만 저장되며 이메일 본문은 기기 밖으로 전송되지 않습니다.")
                }
                .confirmationDialog(
                    "모델 다운로드",
                    isPresented: $showDownloadConfirm,
                    titleVisibility: .visible
                ) {
                    Button("다운로드 (약 \(selectedModelSizeMB / 100 * 100 / 1000).\((selectedModelSizeMB / 100) % 10)GB)") {
                        Task { await llmService.loadModelIfNeeded() }
                    }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text("\(onDeviceModelID) 모델을 기기에 다운로드합니다. Wi-Fi 환경에서 진행을 권장하며, 모든 추론은 기기 내에서만 이루어집니다.")
                }
            }
            
            if selectedProvider == .gemini {
                Section {
                    SecureField("Gemini API Key", text: $geminiAPIKeyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    
                    Picker("모델", selection: settingsBinding(
                        key: "pieroot.todo.geminiModelID",
                        defaultValue: GeminiProviderService.defaultModelID
                    )) {
                        Text("gemini-2.0-flash").tag("gemini-2.0-flash")
                        Text("gemini-2.5-flash").tag("gemini-2.5-flash")
                    }
                    .pickerStyle(.menu)
                    scopeBadge(for: "pieroot.todo.geminiModelID", iCloudSyncEnabled: iCloudSyncEnabled)
                    
                    HStack {
                        Button("키 저장") {
                            GeminiProviderService.saveAPIKey(geminiAPIKeyInput)
                            geminiAPIKeyInput = GeminiProviderService.storedAPIKey ?? ""
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(geminiAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        
                        if GeminiProviderService.storedAPIKey != nil {
                            Button("키 삭제", role: .destructive) {
                                GeminiProviderService.deleteAPIKey()
                                geminiAPIKeyInput = ""
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Label("Gemini API", systemImage: "cloud")
                } footer: {
                    Text("Gemini 선택 시 TODO 제목·메모·마감·페르소나·캘린더 컨텍스트가 Google Gemini API로 전송됩니다. 이메일 원문 본문은 별도 동의 없이는 전송하지 않습니다.")
                }
            }
        }
        .navigationTitle("TODO 자동 정렬 및 AI")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            tutorial?.handleAIDetailClosed()
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if let tutorial, let hint = tutorial.hint(for: .aiDetail) {
                AppTutorialHintCard(hint: hint)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .task {
            let raw: String = SettingsStore.shared.get("selectedAIProvider", defaultValue: PersonaAIProvider.foundationModels.rawValue)
            if PersonaAIProvider(rawValue: raw) == nil {
                saveSetting(key: "selectedAIProvider", value: PersonaAIProvider.foundationModels.rawValue)
            }
            geminiAPIKeyInput = GeminiProviderService.storedAPIKey ?? ""

        }
    }
    
    private var intelligenceFooter: String {
        switch selectedProvider {
        case .foundationModels:
            return "Apple Foundation Models(온디바이스)가 할 일을 정렬합니다. 실패하면 휴리스틱으로 폴백합니다.\n\n\(credentialStorageHint)"
        case .onDevice:
            return "Qwen 온디바이스 모델이 우선 정렬하고, 실패하면 Gemini API(키 저장 시) → Apple Foundation Models → 휴리스틱 순으로 폴백합니다.\n\n\(credentialStorageHint)"
        case .gemini:
            return "Gemini API가 할 일을 정렬합니다. API 키가 없으면 Apple Foundation Models, 그 다음 Qwen/휴리스틱으로 폴백합니다.\n\n\(credentialStorageHint)"
        }
    }
    
    private var credentialStorageHint: String {
        if iCloudSyncEnabled {
            return "인증정보와 보안정보들은 사용자의 iCloud Keychain에 안전하게 저장됩니다."
        }
        return "인증정보와 보안정보들은 사용자의 Keychain에 안전하게 저장됩니다."
    }
    
    @ViewBuilder
    private var llmModelStatusBadge: some View {
        let (label, color): (String, Color) = {
            if llmService.isDeleting        { return ("삭제 중", .red) }
            if llmService.isModelLoaded     { return ("로드됨", .green) }
            if llmService.isLoading         { return ("다운로드 중", .blue) }
            if llmService.downloadInterrupted { return ("중단됨", .orange) }
            if llmService.isModelCachedOnDisk { return ("설치됨", .yellow) }
            return ("미설치", .gray)
        }()
        Text(label)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
    
    private func saveSetting<T>(key: String, value: T, onChange: ((T) -> Void)? = nil) {
        let isLocal = !iCloudSyncEnabled || SettingsStore.shared.isLocal(key: key)
        if isLocal {
            SettingsStore.shared.setLocal(key, value: value)
        } else {
            SettingsStore.shared.setGlobal(key, value: value)
        }
        onChange?(value)
    }
    
    private func settingsBinding<T>(key: String, defaultValue: T, onChange: ((T) -> Void)? = nil) -> Binding<T> {
        Binding(
            get: {
                SettingsStore.shared.get(key, defaultValue: defaultValue)
            },
            set: { newValue in
                saveSetting(key: key, value: newValue) { val in
                    onChange?(val)
                }
            }
        )
    }
    
}
