import SwiftUI

struct OpenAISettingsView: View {
    @ObservedObject private var connection = OpenAIConnection.shared
    @ObservedObject private var settings = SettingsStore.shared
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
        Form {
            Section {
                Toggle(copy("openai.settings.enabled", fallback: "OpenAI 외부 분석 제공자 활성화"), isOn: Binding(
                    get: { SettingsStore.betaProviderEnabled(.openAI) },
                    set: { enabled in
                        if !enabled { resetConnectionCheck() }
                        settings.setBetaProvider(.openAI, enabled: enabled)
                        if enabled { settings.setBetaSelectedProvider(.openAI) }
                    }
                ))
                .accessibilityIdentifier("openai.enabled")
                Text(copy("openai.settings.optionalNotice", fallback: "OpenAI 연결은 선택 사항입니다. ChatGPT Plus·Pro의 사용 가능한 한도와 승인된 앱 권한을 사용합니다. 로그인만으로 데이터 전송에 동의한 것으로 처리하지 않습니다."))
                    .font(.caption)
                Text(copy("openai.settings.models", fallback: "기초 분석: gpt-6-luna\n직접 누른 고급 재요청: gpt-6.1-sol"))
                    .font(.caption.monospaced())
                Text(copy("openai.settings.subscriptionNotice", fallback: "이 구독 연결은 로컬 개인 프로젝트·오픈소스 및 승인된 앱에 제공됩니다. 유료·원격 호스팅 배포에는 OpenAI 승인이 필요합니다. 계정별 모델 제공 여부와 한도는 OpenAI가 결정합니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(copy("openai.account.section", fallback: "ChatGPT 계정")) {
                if let active = connection.activeProfile {
                    Label(active.email ?? active.clientID, systemImage: "person.crop.circle")
                        .accessibilityIdentifier("openai.activeAccount")
                    Label(
                        connection.hasPlanPermission
                            ? copy("openai.account.planAuthorized", fallback: "ChatGPT 구독 사용 권한 있음")
                            : copy("openai.account.planUnauthorized", fallback: "구독 사용 권한 없음 · 다시 연결하세요"),
                        systemImage: connection.hasPlanPermission ? "checkmark.shield" : "exclamationmark.shield"
                    )
                    .font(.caption)
                    if !connection.hasPlanPermission {
                        Button(copy("openai.account.authorizePlan", fallback: "ChatGPT 구독 사용 권한 승인")) {
                            resetConnectionCheck()
                            connectionTask?.cancel()
                            connectionTask = Task {
                                do { try await connection.enablePlanPermission() }
                                catch { if !Task.isCancelled { errorMessage = OpenAIViewCopy.errorMessage(error) } }
                            }
                        }
                        .disabled(connection.isSigningIn)
                    }
                }
                ForEach(connection.profiles) { profile in
                    Button {
                        resetConnectionCheck()
                        connectionTask?.cancel()
                        do { try connection.selectProfile(profile.id) }
                        catch { errorMessage = OpenAIViewCopy.errorMessage(error) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(profile.email ?? copy("openai.account.saved", fallback: "저장된 계정"))
                                Text(profile.clientID).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if profile.id == connection.activeProfileID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(connection.isSigningIn)
                }
                if connection.isSigningIn {
                    ProgressView(copy("openai.account.signInProgress", fallback: "브라우저에서 로그인·권한 승인을 완료하세요"))
                    Button(copy("openai.account.cancelSignIn", fallback: "로그인 취소"), role: .cancel) {
                        connection.cancelSignIn()
                        connectionTask?.cancel()
                    }
                } else {
                    Button(copy("openai.account.continue", fallback: "ChatGPT로 계속하기")) { connect(newAccount: false) }
                        .accessibilityIdentifier("openai.signIn")
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
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Link(copy("openai.account.manageUsage", fallback: "ChatGPT 사용량·앱 권한 관리"), destination: URL(string: "https://chatgpt.com/settings/usage")!)
            }

            Section {
                Button(copy("openai.connection.test", fallback: "구독 연결 테스트")) {
                    testConnection()
                }
                .disabled(!canTestConnection)
                .accessibilityIdentifier("openai.testConnection")
                if connectionCheckID != nil {
                    ProgressView(copy("openai.connection.testProgress", fallback: "구독 연결을 확인하는 중…"))
                        .accessibilityIdentifier("openai.testConnectionProgress")
                }
                if let verifiedModel {
                    Text(String(format: copy("openai.connection.testSuccess", fallback: "%@ 모델로 구독 연결을 확인했습니다."), verifiedModel))
                        .font(.caption)
                        .accessibilityIdentifier("openai.testConnectionResult")
                } else if let connectionCheckError {
                    Text(connectionCheckError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("openai.testConnectionResult")
                }
            } footer: {
                Text(copy("openai.connection.testExplanation", fallback: "짧고 고정된 테스트 메시지만 전송하며, 저장된 앱 데이터는 보내지 않습니다. 할 일·메일·루틴·페르소나 전송 동의 없이 테스트할 수 있습니다. 구독 사용 한도를 일부 사용할 수 있습니다."))
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
                        .font(.caption).foregroundStyle(.orange)
                    Button(copy("openai.cleanup.retry", fallback: "이전 비밀정보 삭제 다시 시도")) {
                        do { try RemovedProviderCleanup.run() }
                        catch { errorMessage = copy("openai.cleanup.error", fallback: "이전 제공자의 비밀정보를 안전하게 삭제하지 못했습니다. 다시 시도해 주세요.") }
                    }
                }
            }
        }
        .navigationTitle(copy("openai.title", fallback: "OpenAI · ChatGPT"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isDeletingConnections)
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
        .onChange(of: SettingsStore.betaProviderEnabled(.openAI)) { _, enabled in
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
        resetConnectionCheck()
        connectionTask?.cancel()
        connectionTask = Task {
            do { try await connection.signIn(newAccount: newAccount) }
            catch is CancellationError { }
            catch { errorMessage = OpenAIViewCopy.errorMessage(error) }
        }
    }

    private var canTestConnection: Bool {
        SettingsStore.betaProviderEnabled(.openAI)
            && connection.activeProfile != nil
            && connection.hasPlanPermission
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
                      connection.sessionGeneration == generation,
                      SettingsStore.betaProviderEnabled(.openAI) else { return }
                verifiedModel = model
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled,
                      connectionCheckID == checkID,
                      connection.sessionGeneration == generation,
                      SettingsStore.betaProviderEnabled(.openAI) else { return }
                connectionCheckError = OpenAIViewCopy.errorMessage(error)
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

struct OpenAIConsentSection: View {
    let scope: OpenAIDataScope
    @AppStorage private var consent: Bool

    init(scope: OpenAIDataScope) {
        self.scope = scope
        _consent = AppStorage(wrappedValue: false, OpenAIPrivacy.consentKey(for: scope))
    }

    var body: some View {
        Section {
            Toggle(title, isOn: $consent)
                .accessibilityIdentifier("openai.consent.\(scope.rawValue)")
        } footer: {
            Text(explanation)
        }
        .onChange(of: consent) { _, enabled in
            if !enabled { OpenAIRequestRegistry.shared.cancel(scope: scope) }
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
            copy("openai.consent.tasks.explanation", fallback: "일반 할 일의 제목·메모·마감·예상 시간과 캘린더의 가용 시간을 OpenAI로 보냅니다. 별도 캘린더 이벤트 컨텍스트는 제목 대신 Busy와 시간 구간만 포함하지만, 외부 캘린더에서 가져와 확정한 할 일의 제목·메모는 이 동의 범위에 포함됩니다. 메일·회의 출처 할 일은 자동 정렬에서 항상 제외하며, 페르소나는 별도 동의가 있을 때만 포함됩니다.")
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

/// View-owned localization for OpenAI settings and remote-analysis error presentation.
enum OpenAIViewCopy {
    static func copy(_ key: String, fallback: String) -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "OpenAI view copy.")
    }

    static func errorMessage(_ error: Error) -> String {
        if let error = error as? OpenAIConnectionError { return error.errorDescription(language: .current) }
        if let error = error as? OpenAIRequestError { return error.errorDescription(language: .current) }
        return copy("openai.error.unknown", fallback: "OpenAI 작업을 완료하지 못했습니다. 다시 시도해 주세요.")
    }

}
