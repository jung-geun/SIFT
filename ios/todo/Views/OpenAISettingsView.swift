import SwiftUI

struct OpenAISettingsView: View {
    @ObservedObject private var connection = OpenAIConnection.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var regionalAvailability = OpenAIRegionalAvailability.shared
    @AppStorage(SettingsStore.betaOpenAIEnabledKey) private var providerEnabled = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var confirmDeleteConnections = false
    @State private var isDeletingConnections = false
    @State private var connectionCheckTask: Task<Void, Never>?
    @State private var connectionCheckID: UUID?
    @State private var verifiedModel: String?
    @State private var connectionCheckError: String?
    @AppStorage(RemovedProviderCleanup.failureKey) private var cleanupFailed = false

    var body: some View {
        Group {
            if regionalAvailability.isAvailable {
                availableContent
            } else {
                RegionalAnalysisUnavailableView()
            }
        }
        .onChange(of: regionalAvailability.isAvailable) { _, available in
            guard !available else { return }
            confirmDeleteConnections = false
            connectionTask?.cancel()
            resetConnectionCheck()
        }
    }

    private var availableContent: some View {
        Form {
            Section {
                Toggle(copy("openai.settings.enabled", fallback: "OpenAI 외부 분석 제공자 활성화"), isOn: Binding(
                    get: { providerEnabled },
                    set: { enabled in
                        providerEnabled = enabled
                        if !enabled { resetConnectionCheck() }
                        settings.setBetaProvider(.openAI, enabled: enabled)
                    }
                ))
                .accessibilityIdentifier("openai.enabled")
                Text(copy("openai.settings.models", fallback: "기초 분석: gpt-6-luna\n직접 누른 고급 재요청: gpt-6.1-sol"))
                    .font(.footnote.monospaced())
            } footer: {
                Text(copy("openai.settings.connectionNotice", fallback: "선택 사항입니다. ChatGPT Plus·Pro 한도와 승인된 앱 권한을 사용하며, 로그인은 데이터 전송 동의가 아닙니다. 로컬 개인 프로젝트·오픈소스·승인된 앱에서 제공되며 유료·원격 호스팅 배포에는 OpenAI 승인이 필요합니다. 모델과 한도는 OpenAI가 정합니다."))
            }

            Section {
                if let active = connection.activeProfile {
                    Label(active.email ?? copy("openai.account.connected", fallback: "연결된 ChatGPT 계정"), systemImage: "person.crop.circle.badge.checkmark")
                        .accessibilityIdentifier("openai.activeAccount")
                    Label(
                        connection.hasPlanPermission
                            ? copy("openai.account.planAuthorized", fallback: "ChatGPT 구독 사용 권한 있음")
                            : copy("openai.account.planUnauthorized", fallback: "구독 사용 권한 없음 · 다시 연결하세요"),
                        systemImage: connection.hasPlanPermission ? "checkmark.shield" : "exclamationmark.shield"
                    )
                    .font(.footnote)
                    if !connection.hasPlanPermission {
                        Button(copy("openai.account.authorizePlan", fallback: "ChatGPT 구독 사용 권한 승인")) {
                            resetConnectionCheck()
                            connectionTask?.cancel()
                            connectionTask = Task {
                                do {
                                    try await connection.enablePlanPermission()
                                    try Task.checkCancellation()
                                    guard regionalAvailability.isAvailable, connection.activeProfile != nil else { return }
                                    settings.setBetaProvider(.openAI, enabled: true)
                                } catch is CancellationError {
                                } catch {
                                    if !Task.isCancelled, regionalAvailability.isAvailable {
                                        errorMessage = OpenAIViewCopy.errorMessage(error)
                                    }
                                }
                            }
                        }
                        .disabled(connection.isSigningIn)
                    }
                }
                if connection.refreshOwnedElsewhere {
                    Text(OpenAIConnectionError.refreshOwnerRequired.errorDescription ?? "")
                        .font(.footnote).foregroundStyle(.secondary)
                    if connection.needsLocalReauthorization {
                        Button(copy("openai.account.reconnectHere", fallback: "이 기기에서 다시 연결")) { connect(newAccount: false) }
                            .disabled(connection.isSigningIn)
                            .accessibilityIdentifier("openai.reconnectHere")
                    }
                }
                ForEach(connection.profiles.filter { $0.id != connection.activeProfileID }) { profile in
                    Button {
                        resetConnectionCheck()
                        connectionTask?.cancel()
                        do { try connection.selectProfile(profile.id) }
                        catch OpenAIConnectionError.signInRequired {
                            // Selection remembers this registration while the current account stays active.
                            connect(newAccount: false)
                        }
                        catch { errorMessage = OpenAIViewCopy.errorMessage(error) }
                    } label: {
                        Text(profile.email ?? copy("openai.account.saved", fallback: "저장된 계정"))
                    }
                    .disabled(connection.isSigningIn)
                }
                if connection.isSigningIn {
                    ProgressView(copy("openai.account.signInProgress", fallback: "브라우저에서 로그인·권한 승인을 완료하세요"))
                    Button(copy("openai.account.cancelSignIn", fallback: "로그인 취소"), role: .cancel) {
                        connection.cancelSignIn()
                        connectionTask?.cancel()
                    }
                    .accessibilityIdentifier("openai.cancelSignIn")
                } else {
                    if connection.activeProfile == nil {
                        Button(copy("openai.account.continue", fallback: "ChatGPT로 계속하기")) { connect(newAccount: false) }
                            .accessibilityIdentifier("openai.signIn")
                    }
                    if !connection.profiles.isEmpty {
                        Button(copy("openai.account.add", fallback: "다른 계정 추가")) { connect(newAccount: true) }
                    }
                }
                if connection.activeProfile != nil {
                    Button(copy("openai.account.signOut", fallback: "연결 해제"), role: .destructive) {
                        resetConnectionCheck()
                        connectionTask?.cancel()
                        connectionTask = Task { await connection.signOut() }
                    }
                    .disabled(connection.isSigningIn)
                    .accessibilityIdentifier("openai.signOut")
                }
                if let status = connection.statusMessage {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                Link(copy("openai.account.manageUsage", fallback: "ChatGPT 사용량·앱 권한 관리"), destination: URL(string: "https://chatgpt.com/settings/usage")!)
            } header: {
                Text(copy("openai.account.section", fallback: "ChatGPT 계정"))
            } footer: {
                Text(copy("openai.settings.syncNotice", fallback: "앱의 iCloud 동기화와 iCloud 키체인을 켜면 같은 Apple 계정에서 연결을 복원할 수 있습니다. Apple의 동기화 완료 후 적용되며, 제공자 활성화와 전송 동의는 기기마다 설정합니다."))
            }

            OpenAIModelCatalogSection(connection: connection)

            Section {
                Button(copy("openai.connection.test", fallback: "구독 연결 테스트")) {
                    testConnection()
                }
                .disabled(!canTestConnection)
                .accessibilityIdentifier("openai.testConnection")
                if connection.activeProfile == nil {
                    Text(copy("openai.connection.requiresSignIn", fallback: "ChatGPT 계정을 먼저 연결하세요."))
                        .font(.footnote).foregroundStyle(.secondary)
                } else if !connection.hasPlanPermission {
                    Text(copy("openai.connection.requiresPlan", fallback: "연결된 계정의 구독 사용 권한을 먼저 승인하세요."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if connectionCheckID != nil {
                    ProgressView(copy("openai.connection.testProgress", fallback: "구독 연결을 확인하는 중…"))
                        .accessibilityIdentifier("openai.testConnectionProgress")
                }
                if let verifiedModel {
                    Text(String(format: copy("openai.connection.testSuccess", fallback: "%@ 모델로 구독 연결을 확인했습니다."), verifiedModel))
                        .font(.footnote)
                        .accessibilityIdentifier("openai.testConnectionResult")
                } else if let connectionCheckError {
                    Text(connectionCheckError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("openai.testConnectionResult")
                }
            } footer: {
                Text(copy("openai.connection.testExplanation", fallback: "테스트는 저장된 앱 데이터 대신 고정 메시지만 전송하며 구독 한도를 사용합니다. 제공자 활성화나 데이터별 전송 동의 없이 실행할 수 있습니다."))
            }

            ForEach(OpenAIDataScope.allCases, id: \.rawValue) { scope in
                OpenAIConsentSection(scope: scope)
            }
            Section(copy("openai.connections.deleteSection", fallback: "이 기기의 연결 기록 삭제")) {
                Button(copy("openai.connections.deleteAccounts", fallback: "모든 계정·토큰·연결 기록 삭제"), role: .destructive) {
                    confirmDeleteConnections = true
                }
                .accessibilityIdentifier("openai.deleteAll")
                if isDeletingConnections { ProgressView(copy("openai.connections.deleting", fallback: "연결 기록 삭제·원격 철회 확인 중…")) }
                if cleanupFailed {
                    Text(copy("openai.cleanup.failedNotice", fallback: "제거된 제공자의 비밀정보 삭제를 확인하지 못했습니다. 해당 제공자는 활성화되지 않습니다."))
                        .font(.footnote).foregroundStyle(.orange)
                    Button(copy("openai.cleanup.retry", fallback: "이전 비밀정보 삭제 다시 시도")) {
                        do { try RemovedProviderCleanup.run() }
                        catch { errorMessage = copy("openai.cleanup.error", fallback: "이전 제공자의 비밀정보를 안전하게 삭제하지 못했습니다. 다시 시도해 주세요.") }
                    }
                }
            }
        }
        .appFormStyle()
        .navigationTitle(copy("openai.title", fallback: "OpenAI · ChatGPT"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isDeletingConnections)
        .task {
            guard regionalAvailability.isAvailable else { return }
            connection.refreshCredentials()
        }
        .confirmationDialog(copy("openai.connections.deleteConfirmation", fallback: "이 기기의 모든 ChatGPT 연결 기록과 전송 동의를 지울까요?"), isPresented: $confirmDeleteConnections, titleVisibility: .visible) {
            Button(copy("openai.connections.deleteAll", fallback: "연결 기록 모두 삭제"), role: .destructive) {
                resetConnectionCheck()
                connectionTask?.cancel()
                connectionTask = Task {
                    isDeletingConnections = true
                    defer { isDeletingConnections = false }
                    settings.setBetaProvider(.openAI, enabled: false)
                    for scope in OpenAIDataScope.allCases { UserDefaults.standard.removeObject(forKey: OpenAIPrivacy.consentKey(for: scope)) }
                    do { try await connection.deleteAllLocalCredentials() }
                    catch { errorMessage = OpenAIViewCopy.errorMessage(error) }
                }
            }
        }
        .onDisappear {
            resetConnectionCheck()
            if connection.isSigningIn {
                connection.cancelSignIn()
                connectionTask?.cancel()
            }
        }
        .onChange(of: connection.sessionGeneration) { _, _ in
            resetConnectionCheck()
        }
        .onChange(of: providerEnabled) { _, enabled in
            if !enabled { resetConnectionCheck() }
        }
        .onChange(of: connection.isSigningIn) { _, isSigningIn in
            if isSigningIn { resetConnectionCheck() }
        }
        .alert(copy("openai.error.title", fallback: "연결 오류"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(copy("openai.action.ok", fallback: "확인"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func connect(newAccount: Bool) {
        guard regionalAvailability.isAvailable else { return }
        resetConnectionCheck()
        connectionTask?.cancel()
        connectionTask = Task {
            do {
                try await connection.signIn(newAccount: newAccount)
                try Task.checkCancellation()
                guard regionalAvailability.isAvailable, connection.activeProfile != nil else { return }
                settings.setBetaProvider(.openAI, enabled: true)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled, regionalAvailability.isAvailable {
                    errorMessage = OpenAIViewCopy.errorMessage(error)
                }
            }
        }
    }

    private var canTestConnection: Bool {
        regionalAvailability.isAvailable
            && connection.activeProfile != nil
            && connection.hasPlanPermission
            && !connection.needsLocalReauthorization
            && !connection.isSigningIn
            && !isDeletingConnections
            && connectionCheckID == nil
    }

    private func testConnection() {
        guard canTestConnection else { return }
        resetConnectionCheck()
        let checkID = UUID()
        let generation = connection.sessionGeneration
        connectionCheckID = checkID
        connectionCheckTask = Task { @MainActor in
            defer {
                if connectionCheckID == checkID {
                    connectionCheckID = nil
                    connectionCheckTask = nil
                }
            }
            do {
                let model = try await OpenAIProviderService().verifySubscriptionConnection()
                try Task.checkCancellation()
                guard connectionCheckID == checkID,
                      connection.sessionGeneration == generation else { return }
                verifiedModel = model
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled,
                      connectionCheckID == checkID,
                      connection.sessionGeneration == generation else { return }
                connectionCheckError = OpenAIViewCopy.connectionCheckErrorMessage(error)
            }
        }
    }

    private func resetConnectionCheck() {
        connectionCheckTask?.cancel()
        connectionCheckTask = nil
        connectionCheckID = nil
        verifiedModel = nil
        connectionCheckError = nil
        errorMessage = nil
    }

    private func copy(_ key: String, fallback: String) -> String {
        OpenAIViewCopy.copy(key, fallback: fallback)
    }
}

private struct OpenAIModelCatalogSection: View {
    @ObservedObject var connection: OpenAIConnection
    @State private var models: [OpenAIAvailableModel] = []
    @State private var loadedGeneration: UUID?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var revision = 0

    private struct RequestID: Hashable {
        let generation: UUID
        let revision: Int
    }

    var body: some View {
        if connection.activeProfile != nil, connection.hasPlanPermission, !connection.needsLocalReauthorization {
            Section {
                if isLoading || loadedGeneration != connection.sessionGeneration {
                    ProgressView(copy("openai.models.loading", "모델 목록 확인 중…"))
                } else if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.orange)
                } else if models.isEmpty {
                    Text(copy("openai.models.empty", "표시할 수 있는 모델이 없습니다."))
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(models) { model in
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                            Text(model.displayName)
                            if model.displayName != model.id {
                                Text(model.id).font(.footnote.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button(copy("openai.models.refresh", "모델 목록 새로고침")) { revision += 1 }
                    .disabled(isLoading || connection.isSigningIn)
                    .accessibilityIdentifier("openai.refreshModels")
            } header: {
                Text(copy("openai.models.section", "이 계정에서 제공하는 모델"))
                    .accessibilityIdentifier("openai.modelCatalog")
            } footer: {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                    Text(copy("openai.models.notice", "계정의 모델 목록만 조회합니다. 추론이나 저장된 앱 데이터 전송은 없으며, 목록이 모든 API 사용 권한을 뜻하지는 않습니다."))
                    Text(copy("openai.models.subscriptionCapabilities", AppLanguage.current == .english
                        ? "This subscription connection supports eligible Responses API requests, not audio/video input or transcription APIs such as speaker diarization."
                        : "이 구독 연결은 지원 대상 Responses API 요청에만 사용하며 음성·영상 입력과 화자 분리 등 전사 API는 지원하지 않습니다."))
                }
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            }
            .task(id: RequestID(generation: connection.sessionGeneration, revision: revision)) {
                await loadModels()
            }
        }
    }

    private func loadModels() async {
        let generation = connection.sessionGeneration
        loadedGeneration = generation
        models = []
        errorMessage = nil
        isLoading = true
        defer {
            if !Task.isCancelled, connection.sessionGeneration == generation { isLoading = false }
        }
        do {
            let available = try await OpenAIProviderService().availableModels()
            guard !Task.isCancelled, connection.sessionGeneration == generation else { return }
            models = available
        } catch {
            guard !Task.isCancelled, connection.sessionGeneration == generation else { return }
            errorMessage = OpenAIViewCopy.errorMessage(error)
        }
    }

    private func copy(_ key: String, _ fallback: String) -> String {
        OpenAIViewCopy.copy(key, fallback: fallback)
    }
}

struct OpenAIConsentSection: View {
    let scope: OpenAIDataScope
    @AppStorage private var consent: Bool
    @ObservedObject private var regionalAvailability = OpenAIRegionalAvailability.shared

    init(scope: OpenAIDataScope) {
        self.scope = scope
        _consent = AppStorage(wrappedValue: false, OpenAIPrivacy.consentKey(for: scope))
    }

    var body: some View {
        if regionalAvailability.isAvailable {
            Section {
                Toggle(title, isOn: $consent)
                    .accessibilityIdentifier("openai.consent.\(scope.rawValue)")
            } footer: {
                Text(explanation)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onChange(of: consent) { _, enabled in
                if !enabled { OpenAIRequestRegistry.shared.cancel(scope: scope) }
            }
        }
    }

    private var title: String {
        switch scope {
        case .tasks: copy("openai.consent.tasks.title", fallback: "할 일 정렬의 외부 분석 허용")
        case .email: copy("openai.consent.email.title", fallback: "직접 선택한 메일의 외부 분석 허용")
        case .routines: copy("openai.consent.routines.title", fallback: "루틴·행동 기록의 외부 분석 허용")
        case .persona: copy("openai.consent.persona.title", fallback: "페르소나의 외부 분석 허용")
        }
    }

    private var explanation: String {
        switch scope {
        case .tasks:
            copy("openai.consent.tasks.explanation", fallback: "일반 할 일의 제목·메모·마감·예상 시간과 캘린더의 가용 시간을 OpenAI로 보냅니다. 별도 캘린더 이벤트 컨텍스트는 제목 대신 Busy와 시간 구간만 포함하지만, 외부 캘린더에서 가져와 확정한 할 일의 제목·메모는 이 동의 범위에 포함됩니다. 메일·회의 출처 및 건강 기록에서 생성한 할 일은 자동 정렬에서 항상 제외하며, 페르소나는 별도 동의가 있을 때만 포함됩니다.")
        case .email:
            copy("openai.consent.email.explanation", fallback: "메일 상세에서 직접 외부 분석을 요청한 메일의 제목과 본문을 OpenAI로 보냅니다. 받은편지함 자동 수집·분석은 계속 기기 내에서 처리합니다. 원문·기존 로컬 요약은 덮어쓰지 않습니다.")
        case .routines:
            copy("openai.consent.routines.explanation", fallback: "직접 분석을 요청할 때 루틴 제목·주기·기록된 완료 시각·신뢰도 또는 결정론적 행동 통계를 OpenAI로 보냅니다. 완료 기록은 실제 활동 수행 증거가 아니며 건강 상태나 진단을 추론하지 않습니다. 확인·수정·할 일 생성은 직접 승인해야 합니다.")
        case .persona:
            copy("openai.consent.persona.explanation", fallback: "직접 분석을 요청하거나 동의한 할 일 정렬에서 저장된 페르소나 설명·선택 유형·결정론적 행동 근거를 OpenAI로 보냅니다. 결과는 미리보기이며 적용해야 저장됩니다. 메일·회의 원문은 포함하지 않습니다.")
        }
    }

    private func copy(_ key: String, fallback: String) -> String {
        OpenAIViewCopy.copy(key, fallback: fallback)
    }
}

struct RegionalAnalysisUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label {
                Text(AppLanguage.localized("analysis.regional.unavailable.title", defaultValue: "분석을 사용할 수 없습니다", language: .current))
            } icon: {
                Image(systemName: "globe")
            }
        } description: {
            Text(AppLanguage.localized(
                "analysis.regional.unavailable.message",
                defaultValue: "현재 App Store 국가 또는 지역에서는 외부 분석을 사용할 수 없습니다. 기기 내 기능은 계속 사용할 수 있습니다.",
                language: .current
            ))
        }
        .appScreenStyle()
        .navigationTitle(AppLanguage.localized("analysis.regional.navigationTitle", defaultValue: "분석", language: .current))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// View-owned localization for OpenAI settings and remote-analysis error presentation.
enum OpenAIViewCopy {
    static func copy(_ key: String, fallback: String) -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "OpenAI view copy.")
    }

    static func connectionCheckErrorMessage(_ error: Error) -> String {
        if (error as? OpenAIRequestError) == .invalidResponse {
            return copy("openai.connection.check.invalidResponse", fallback: AppLanguage.current == .english
                ? "OpenAI returned an invalid connection-check response. Inference access has not been verified. No stored app data was sent."
                : "OpenAI가 올바르지 않은 연결 확인 응답을 반환했습니다. 추론 사용 권한은 확인되지 않았습니다. 저장된 앱 데이터는 전송하지 않았습니다.")
        }
        return errorMessage(error)
    }

    static func errorMessage(_ error: Error) -> String {
        if let error = error as? OpenAIConnectionError { return error.errorDescription(language: .current) }
        if let error = error as? OpenAIRequestError { return error.errorDescription(language: .current) }
        return copy("openai.error.unknown", fallback: "OpenAI 작업을 완료하지 못했습니다. 다시 시도해 주세요.")
    }

}
