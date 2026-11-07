import SwiftUI
import SwiftData


private struct MailConnectionValidation: Sendable {
    let isAuthenticated: Bool
    let hasStoredCredential: Bool
    let failureMessage: String?
}

// 4. 이메일 연동
struct EmailDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appTutorialState) private var tutorial
    @AppStorage("pieroot.todo.lastEmailFetchDate") private var lastEmailFetchTimestamp: Double = 0

    @State private var isGmailAuthenticated = false
    @State private var isConnectingGmail = false
    @State private var isOutlookAuthenticated = false
    @State private var isConnectingOutlook = false
    @State private var isValidatingGmail = false
    @State private var isValidatingOutlook = false
    @State private var gmailConnectionFailure: String?
    @State private var outlookConnectionFailure: String?
    @State private var fetchingProviders: Set<MailProvider> = []
    @State private var imapEmail = ""
    @State private var imapPassword = ""
    @State private var outlookEmail = ""
    @State private var outlookPassword = ""
    @State private var showGmailConnection = false
    @State private var showOutlookConnection = false
    @State private var hasGmailStoredCredential = false
    @State private var hasOutlookStoredCredential = false
    @State private var showBackgroundWarning = false
    @State private var backgroundWarningAccount = ""
    @State private var isUpdatingBackgroundAccess = false
    @State private var credentialAction: CredentialAction?
    @State private var showCredentialApproval = false

    private struct CredentialAction {
        let account: String
        let purpose: String
        let operation: @MainActor () async throws -> Void
    }
    @State private var showOutlookHelp = false
    @AppStorage("pieroot.todo.imap.account") private var imapAccount = ""
    @AppStorage("pieroot.todo.imap.backgroundEnabled") private var imapBackgroundEnabled = false
    @AppStorage("pieroot.todo.outlook.account") private var outlookAccount = ""
    @AppStorage("pieroot.todo.outlook.backgroundEnabled") private var outlookBackgroundEnabled = false
    @State private var lastFetchMessage: String?
    @State private var showEmailPeriod = false
    @State private var suppressedSendersList: [String] = []
    @State private var errorMessage: String?
    @State private var showError = false

    init() {
        let localAccess = MailboxCachedProviderAccess.current()
        _hasGmailStoredCredential = State(
            initialValue: localAccess.isLocallyConfigured(.gmail)
        )
        _hasOutlookStoredCredential = State(
            initialValue: localAccess.isLocallyConfigured(.outlook)
        )
        _isValidatingGmail = State(initialValue: localAccess.isLocallyConfigured(.gmail))
        _isValidatingOutlook = State(initialValue: localAccess.isLocallyConfigured(.outlook))
    }

    private var isAnyMailAuthenticated: Bool {
        isGmailAuthenticated || isOutlookAuthenticated
    }

    private static func validateGmailSession(
        account: String,
        backgroundEnabled: Bool
    ) async -> MailConnectionValidation {
        guard !account.isEmpty else {
            return MailConnectionValidation(isAuthenticated: false, hasStoredCredential: false, failureMessage: nil)
        }
        do {
            try await GmailIMAPService.shared.validateConnection(
                email: account,
                backgroundEnabled: backgroundEnabled
            )
            MailCredentialApprovalCenter.shared.resolveMailApproval(provider: .gmail, namespace: account)
            return MailConnectionValidation(isAuthenticated: true, hasStoredCredential: true, failureMessage: nil)
        } catch {
            if error as? KeychainStoreError == .authenticationRequired {
                MailCredentialApprovalCenter.shared.requireMailApproval(provider: .gmail, namespace: account)
            }
            return MailConnectionValidation(
                isAuthenticated: false,
                hasStoredCredential: MailCredentialFailurePolicy.hasStoredCredential(after: error),
                failureMessage: mailErrorMessage(error)
            )
        }
    }

    private static func validateOutlookSession(
        account: String,
        backgroundEnabled: Bool
    ) async -> MailConnectionValidation {
        guard !account.isEmpty else {
            return MailConnectionValidation(isAuthenticated: false, hasStoredCredential: false, failureMessage: nil)
        }
        do {
            try await OutlookIMAPService.shared.validateConnection(
                email: account,
                backgroundEnabled: backgroundEnabled
            )
            MailCredentialApprovalCenter.shared.resolveMailApproval(provider: .outlook, namespace: account)
            return MailConnectionValidation(isAuthenticated: true, hasStoredCredential: true, failureMessage: nil)
        } catch {
            if error as? KeychainStoreError == .authenticationRequired {
                MailCredentialApprovalCenter.shared.requireMailApproval(provider: .outlook, namespace: account)
            }
            return MailConnectionValidation(
                isAuthenticated: false,
                hasStoredCredential: MailCredentialFailurePolicy.hasStoredCredential(after: error),
                failureMessage: mailErrorMessage(error)
            )
        }
    }


    private var emailLookbackDaysBinding: Binding<Int> {
        Binding(
            get: {
                EmailAnalysisLookbackPolicy.storedLookbackDays()
            },
            set: { newValue in
                EmailAnalysisLookbackPolicy.saveLookbackDays(newValue)
            }
        )
    }

    private var emailLookbackDays: Int {
        emailLookbackDaysBinding.wrappedValue
    }


    var body: some View {
        Form {
            Section {
                accountRow(
                    title: "Gmail IMAP",
                    connected: isGmailAuthenticated,
                    isValidating: isValidatingGmail,
                    icon: "envelope.circle.fill",
                    tint: .green,
                    onFetch: { Task { await fetchEmailsNow(for: .gmail) } },
                    onSignOut: signOutGmail
                )

                if IMAPCredentialStore.isCredentialRejected(for: imapAccount) {
                    Label(
                        GmailIMAPError.credentialRejected.errorDescription(language: .current),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                }

                if !isGmailAuthenticated && !isValidatingGmail {
                    if hasGmailStoredCredential {
                        storedCredentialRetryPanel(
                            provider: "Gmail",
                            isConnecting: isConnectingGmail,
                            failureMessage: gmailConnectionFailure,
                            retry: { Task { await reconnectGmail() } },
                            replace: { hasGmailStoredCredential = false }
                        )
                    } else {
                        DisclosureGroup(isExpanded: $showGmailConnection) {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("Gmail 이메일 주소", text: $imapEmail)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.emailAddress)
                                SecureField("Google App Password", text: $imapPassword)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                Text("일반 Google 비밀번호가 아닌 App Password를 입력하세요. 저장 후 앱에서는 다시 표시하거나 복사할 수 없습니다.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Toggle("자동 백그라운드 메일 불러오기", isOn: Binding(
                                    get: { imapBackgroundEnabled },
                                    set: { enabled in
                                        if enabled {
                                            backgroundWarningAccount = imapAccount
                                            showBackgroundWarning = true
                                        } else {
                                            imapBackgroundEnabled = false
                                        }
                                    }
                                ))
                                .disabled(isUpdatingBackgroundAccess)
                                Button {
                                    Task { await connectGmail() }
                                } label: {
                                    if isConnectingGmail {
                                        HStack(spacing: 8) {
                                            ProgressView().controlSize(.small)
                                            Text("연결 중…")
                                        }
                                    } else {
                                        Label("Gmail IMAP 연결", systemImage: "plus.circle")
                                    }
                                }
                                .disabled(isConnectingGmail || imapEmail.isEmpty || imapPassword.isEmpty)
                            }
                        } label: {
                            Text("Gmail IMAP 연결")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { showGmailConnection.toggle() }
                        }
                    }
                }

                accountRow(
                    title: "Outlook IMAP",
                    titleKey: "mail.account.outlook",
                    connected: isOutlookAuthenticated,
                    isValidating: isValidatingOutlook,
                    icon: "envelope.circle.fill",
                    tint: .blue,
                    onFetch: { Task { await fetchEmailsNow(for: .outlook) } },
                    onSignOut: signOutOutlook
                )

                if !isOutlookAuthenticated && !isValidatingOutlook {
                    if hasOutlookStoredCredential {
                        storedCredentialRetryPanel(
                            provider: "Outlook",
                            isConnecting: isConnectingOutlook,
                            failureMessage: outlookConnectionFailure,
                            retry: { Task { await reconnectOutlook() } },
                            replace: { hasOutlookStoredCredential = false }
                        )
                    } else {
                        DisclosureGroup(isExpanded: $showOutlookConnection) {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField(
                                    AppLanguage.localized(
                                        "mail.connection.outlook.emailPlaceholder",
                                        defaultValue: "Outlook 이메일 주소",
                                        language: .current,
                                        comment: "Outlook email field placeholder"
                                    ),
                                    text: $outlookEmail
                                )
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.emailAddress)
                                SecureField(
                                    AppLanguage.localized(
                                        "mail.connection.outlook.passwordPlaceholder",
                                        defaultValue: "Outlook App Password",
                                        language: .current,
                                        comment: "Outlook password field placeholder"
                                    ),
                                    text: $outlookPassword
                                )
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                Text(
                                    AppLanguage.localized(
                                        "mail.connection.outlook.legacyNotice",
                                        defaultValue: "Outlook IMAP may require an App Password and can be unavailable for some account policies.",
                                        language: .current,
                                        comment: "Outlook legacy connection notice"
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Button {
                                    showOutlookHelp = true
                                } label: {
                                    Label(
                                        AppLanguage.localized(
                                            "mail.connection.outlook.helpButton",
                                            defaultValue: "설정 가이드 보기",
                                            language: .current,
                                            comment: "Outlook setup help button"
                                        ),
                                        systemImage: "questionmark.circle"
                                    )
                                    .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(AppTheme.accent)

                                Button {
                                    Task { await connectOutlook() }
                                } label: {
                                    if isConnectingOutlook {
                                        HStack(spacing: 8) {
                                            ProgressView().controlSize(.small)
                                            Text(AppLanguage.localized(
                                                "연결 중…",
                                                defaultValue: "Connecting…",
                                                language: .current,
                                                comment: "Outlook IMAP connection progress."
                                            ))
                                        }
                                    } else {
                                        Label(
                                            AppLanguage.localized(
                                                "Outlook IMAP 연결",
                                                defaultValue: "Connect Outlook IMAP",
                                                language: .current,
                                                comment: "Outlook IMAP connection action."
                                            ),
                                            systemImage: "plus.circle"
                                        )
                                    }
                                }
                                .disabled(isConnectingOutlook || outlookEmail.isEmpty || outlookPassword.isEmpty)
                            }
                        } label: {
                            Text("Outlook IMAP 연결")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { showOutlookConnection.toggle() }
                        }
                    }
                }

                if isAnyMailAuthenticated {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("메일 자동 분석", isOn: settingsBinding(key: "pieroot.todo.emailAutoAnalysisEnabled", defaultValue: true))
                    }
                }

                if isAnyMailAuthenticated {
                    DisclosureGroup(isExpanded: $showEmailPeriod) {

                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppLanguage.localized(
                                "mail.background.cacheExplanation",
                                defaultValue: "목록과 전체 본문은 분석 설정과 별개로 주기적으로 저장합니다. 백그라운드 수집과 분석은 허용한 계정에만 적용되며 iOS가 실행 시각을 결정합니다.",
                                language: .current
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Stepper(
                                "메일 분석 기간: \(emailLookbackDays)일",
                                value: emailLookbackDaysBinding,
                                in: EmailAnalysisLookbackPolicy.lookbackRange
                            )
                            Text(
                                String(
                                    format: AppLanguage.localized(
                                        "mail.lookback.scope",
                                        defaultValue: "Independent of Inbox display period; automatic To-Do/calendar analysis is limited to the latest %lld days.",
                                        language: .current,
                                        comment: "Email analysis lookback explanation."
                                    ),
                                    locale: AppLanguage.current.locale,
                                    Int64(emailLookbackDays)
                                )
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack {
                            Label("동기화 설정", systemImage: "gear")
                            Spacer()
                            if lastEmailFetchTimestamp > 0 {
                                Text(Date(timeIntervalSince1970: lastEmailFetchTimestamp), style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let msg = lastFetchMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("이메일 연동", systemImage: "envelope")
            } footer: {
                if isGmailAuthenticated {
                    Text(AppLanguage.localized("mail.connection.automaticFooter", defaultValue: "'메일 자동 분석'을 켜면 연결된 Gmail을 분석해 할 일 후보를 자동으로 정리합니다. 실행 시각은 기기 상태나 네트워크 상황에 따라 달라질 수 있습니다.", language: .current, comment: "Gmail automatic analysis settings explanation."))
                }
            }

            if isGmailAuthenticated && !suppressedSendersList.isEmpty {
                Section {
                    ForEach(suppressedSendersList, id: \.self) { sender in
                        HStack {
                            Label(sender, systemImage: "bell.slash")
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            Button("해제") {
                                EmailLearningStore.shared.unsuppress(sender)
                                suppressedSendersList = EmailLearningStore.shared.suppressedSenders()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } header: {
                    Label("자동 숨긴 발신자", systemImage: "eye.slash")
                } footer: {
                    Text("같은 발신자의 이메일을 2회 이상 삭제하면 자동으로 숨겨집니다. 해제하면 이후 메일이 다시 분류됩니다.")
                }
            }
        }
        .appFormStyle()
        .navigationTitle("이메일 연동")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let gmailAccount = imapAccount
            let storedOutlookAccount = outlookAccount
            let gmailBackgroundEnabled = imapBackgroundEnabled
            let outlookBackgroundEnabled = outlookBackgroundEnabled
            let localAccess = MailboxCachedProviderAccess.current()

            imapEmail = gmailAccount
            outlookEmail = storedOutlookAccount
            hasGmailStoredCredential = localAccess.isLocallyConfigured(.gmail)
            hasOutlookStoredCredential = localAccess.isLocallyConfigured(.outlook)
            isValidatingGmail = !gmailAccount.isEmpty
            isValidatingOutlook = !storedOutlookAccount.isEmpty

            async let gmailValidation = Self.validateGmailSession(
                account: gmailAccount,
                backgroundEnabled: gmailBackgroundEnabled
            )
            async let outlookValidation = Self.validateOutlookSession(
                account: storedOutlookAccount,
                backgroundEnabled: outlookBackgroundEnabled
            )
            let (gmail, outlook) = await (gmailValidation, outlookValidation)
            guard !Task.isCancelled else { return }

            isGmailAuthenticated = gmail.isAuthenticated
            hasGmailStoredCredential = gmail.hasStoredCredential
            gmailConnectionFailure = gmail.failureMessage
            isValidatingGmail = false
            isOutlookAuthenticated = outlook.isAuthenticated
            hasOutlookStoredCredential = outlook.hasStoredCredential
            outlookConnectionFailure = outlook.failureMessage
            isValidatingOutlook = false
            suppressedSendersList = EmailLearningStore.shared.suppressedSenders()
        }
        .sheet(isPresented: $showOutlookHelp) {
            SupportSafariView(url: URL(string: "https://sift.pieroot.xyz/email-setup.html#outlook")!)
        }
        .onDisappear {
            tutorial?.handleEmailDetailClosed()
            credentialAction = nil
            showCredentialApproval = false
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let tutorial {
                AppTutorialTipHost(tutorial: tutorial, screen: .emailDetail)
            }
        }
        .alert(Self.credentialText("mail.credential.background.title", "백그라운드 메일 접근 승인"), isPresented: $showBackgroundWarning) {
            Button(Self.credentialText("mail.credential.background.allow", "위험을 이해하고 인증 허용")) {
                let account = backgroundWarningAccount
                Task { await enableBackgroundAccess(for: account) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(backgroundWarningAccount.isEmpty ? imapEmail : backgroundWarningAccount)
            Text(Self.backgroundAccessPurpose)
        }
        .alert(Self.credentialText("credentialApproval.title", "인증 사용 승인"), isPresented: $showCredentialApproval, presenting: credentialAction) { action in
            Button(Self.credentialText("credentialApproval.allow", "허용하고 계속")) {
                Task {
                    do {
                        try await KeychainStore.withApprovedAuthentication(purpose: action.purpose) {
                            try await action.operation()
                        }
                    } catch {
                        errorMessage = mailErrorMessage(error)
                        showError = true
                    }
                    credentialAction = nil
                }
            }
            Button(Self.credentialText("credentialApproval.later", "나중에"), role: .cancel) {
                credentialAction = nil
            }
        } message: { action in
            Text(action.account)
            Text(action.purpose)
            Text(Self.credentialText("mail.credential.explicitExplanation", "허용한 경우에만 이 작업을 위해 Touch ID, Face ID 또는 시스템 암호 확인을 시작할 수 있습니다. 취소하면 재시도하지 않습니다."))
        }
        .alert("오류", isPresented: $showError, presenting: errorMessage) { _ in
            Button("확인", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    @ViewBuilder
    private func accountRow(
        title: String,
        titleKey: String = "mail.account.gmail",
        connected: Bool,
        isValidating: Bool,
        icon: String,
        tint: Color,
        onFetch: @escaping () -> Void,
        onSignOut: @escaping () -> Void
    ) -> some View {
        let localizedTitle = AppLanguage.localized(titleKey, defaultValue: title, language: .current, comment: "Mail account label.")
        let connection = isValidating
            ? AppLanguage.localized(
                "mail.authentication.checking",
                defaultValue: "연결·메일 조회 확인 중…",
                language: .current,
                comment: "Checking the IMAP connection and inbox message access."
            )
            : AppLanguage.localized(
                connected ? "mail.account.connected" : "mail.account.disconnected",
                defaultValue: connected ? "연결됨" : "미연결",
                language: .current,
                comment: "Mail account connection state."
            )
        HStack {
            Label(localizedTitle, systemImage: icon)
                .symbolRenderingMode(.monochrome)
            Spacer()
            if isValidating {
                ProgressView().controlSize(.small)
            }
            Text(connection)
                .font(.subheadline)
                .foregroundStyle(connected ? tint : .secondary)
        }
        .contextMenu {
            if connected {
                Button(action: onFetch) {
                    Label("지금 메일 확인", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive, action: onSignOut) {
                    Label("연결 해제", systemImage: "minus.circle")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if connected {
                Button(action: onFetch) {
                    Label("메일 확인", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if connected {
                Button(role: .destructive, action: onSignOut) {
                    Label("연결 해제", systemImage: "minus.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func storedCredentialRetryPanel(
        provider: String,
        isConnecting: Bool,
        failureMessage: String?,
        retry: @escaping () -> Void,
        replace: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let failureMessage {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
            }
            Text(String(format: AppLanguage.localized(
                "mail.connection.savedPasswordRetained",
                defaultValue: "저장된 %@ App Password가 있습니다. 마지막 연결 시도는 실패했지만 비밀번호는 삭제되지 않았습니다.",
                language: .current, comment: "Failed connection retains the provider's saved password. %@ is the provider name."
            ), provider))
            .font(.caption)
            .foregroundStyle(.secondary)

            Button(action: retry) {
                if isConnecting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(AppLanguage.localized("연결 중…", defaultValue: "Connecting…", language: .current))
                    }
                } else {
                    Label(AppLanguage.localized("mail.connection.retry", defaultValue: "Retry connection", language: .current, comment: "Retry with the saved mail password."), systemImage: "arrow.clockwise")
                }
            }
            .disabled(isConnecting)

            Button(AppLanguage.localized("mail.connection.replacePassword", defaultValue: "Replace App Password", language: .current, comment: "Replace the saved mail app password."), action: replace)
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
        }
    }


    private func saveSetting<T>(key: String, value: T, onChange: ((T) -> Void)? = nil) {
        SettingsStore.shared.set(key, value: value)
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



    private static func credentialText(_ key: String, _ fallback: String) -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "Explicit mail credential action approval.")
    }

    private static var backgroundAccessPurpose: String {
        credentialText("mail.credential.background.purpose", "Gmail 앱 비밀번호의 백그라운드 접근을 허용합니다. 이미 저장된 비밀번호가 있으면 키체인에서 읽어 접근 정책을 변경합니다. 허용하면 Touch ID, Face ID 또는 시스템 암호 확인이 표시될 수 있습니다. 이후에는 기기가 잠겨도 이 기기에서 앱 비밀번호를 사용할 수 있어 분실·탈옥·앱 침해 위험이 증가할 수 있습니다.")
    }

    private func enableBackgroundAccess(for account: String) async {
        guard account == imapAccount, !isUpdatingBackgroundAccess else { return }
        isUpdatingBackgroundAccess = true
        defer { isUpdatingBackgroundAccess = false }
        do {
            if !account.isEmpty {
                try await KeychainStore.withApprovedAuthentication(purpose: Self.backgroundAccessPurpose) {
                    guard account == imapAccount else { throw CancellationError() }
                    try IMAPCredentialStore.migrateAccess(for: account, toBackground: true)
                }
            }
            guard account == imapAccount else { throw CancellationError() }
            // An empty account configures the subsequent new connection only;
            // there is no stored credential whose ACL could be migrated yet.
            imapBackgroundEnabled = true
        } catch {
            errorMessage = mailErrorMessage(error)
            showError = true
        }
    }

    private func selectedAccount(for provider: MailProvider) -> String {
        provider == .gmail ? imapAccount : outlookAccount
    }

    private func requiresCredentialApproval(_ error: any Error) -> Bool {
        if let keychain = error as? KeychainStoreError { return keychain == .authenticationRequired }
        if let deletion = error as? IMAPCredentialDeletionError {
            return [deletion.portableError, deletion.localError].compactMap { $0 }.contains { requiresCredentialApproval($0) }
        }
        if let rollback = error as? IMAPCredentialRollbackError {
            return requiresCredentialApproval(rollback.operationError) || requiresCredentialApproval(rollback.rollbackError)
        }
        return false
    }

    private func handleCredentialFailure(
        _ error: any Error, provider: MailProvider, account: String, purpose: String,
        retry: @escaping @MainActor () async throws -> Void
    ) {
        guard requiresCredentialApproval(error), selectedAccount(for: provider) == account else {
            errorMessage = mailErrorMessage(error)
            showError = true
            return
        }
        credentialAction = CredentialAction(account: account, purpose: purpose) {
            guard selectedAccount(for: provider) == account else { throw CancellationError() }
            try await retry()
        }
        showCredentialApproval = true
    }

    private func signOutGmail() { signOutMail(.gmail) }
    private func signOutOutlook() { signOutMail(.outlook) }

    private func signOutMail(_ provider: MailProvider) {
        let account = selectedAccount(for: provider)
        Task {
            do {
                try await disconnectMail(provider, account: account)
            } catch {
                handleCredentialFailure(
                    error, provider: provider, account: account,
                    purpose: Self.credentialText("mail.credential.disconnectPurpose", "이 계정의 메일 연결을 해제하고 저장된 앱 비밀번호 및 관련 연결 정보를 삭제하기 위해 키체인 접근을 승인합니다. 이미 요청한 연결 해제만 다시 시도하며 다른 계정은 변경하지 않습니다.")
                ) { try await disconnectMail(provider, account: account) }
            }
        }
    }

    private func disconnectMail(_ provider: MailProvider, account: String) async throws {
        guard !account.isEmpty, selectedAccount(for: provider) == account else { throw CancellationError() }
        switch provider {
        case .gmail: await GmailIMAPService.shared.disconnect()
        case .outlook: await OutlookIMAPService.shared.disconnect()
        }
        guard selectedAccount(for: provider) == account else { throw CancellationError() }
        switch provider {
        case .gmail:
            try IMAPCredentialStore.delete(for: account)
            MailboxIncrementalSyncCoordinator.shared.forgetCursor(for: .gmail, rawAccount: account)
            UserDefaults.standard.removeObject(forKey: "pieroot.todo.gmailIMAP.ingestionCursor.\(account.lowercased())")
            imapAccount = ""
            imapEmail = ""
            imapPassword = ""
            isGmailAuthenticated = false
            hasGmailStoredCredential = false
            NotificationCenter.default.post(name: .gmailAuthChanged, object: false)
        case .outlook:
            try OutlookIMAPCredentialStore.delete(for: account)
            MailboxIncrementalSyncCoordinator.shared.forgetCursor(for: .outlook, rawAccount: account)
            outlookAccount = ""
            outlookEmail = ""
            outlookPassword = ""
            isOutlookAuthenticated = false
            hasOutlookStoredCredential = false
            NotificationCenter.default.post(name: Notification.Name("pieroot.todo.outlookAuthChanged"), object: false)
        }
    }

    private func reconnectOutlook() async { await reconnectMail(.outlook) }
    private func reconnectGmail() async { await reconnectMail(.gmail) }

    private func reconnectMail(_ provider: MailProvider) async {
        let account = selectedAccount(for: provider)
        do {
            try await validateExplicitMailConnection(provider, account: account)
        } catch {
            switch provider {
            case .gmail:
                isGmailAuthenticated = false
                hasGmailStoredCredential = MailCredentialFailurePolicy.hasStoredCredential(after: error)
                gmailConnectionFailure = mailErrorMessage(error)
            case .outlook:
                isOutlookAuthenticated = false
                hasOutlookStoredCredential = MailCredentialFailurePolicy.hasStoredCredential(after: error)
                outlookConnectionFailure = mailErrorMessage(error)
            }
            handleCredentialFailure(
                error, provider: provider, account: account,
                purpose: Self.credentialText("credentialApproval.mailPurpose", "저장된 메일 앱 비밀번호를 키체인에서 읽어 이 계정의 메일 연결을 복구합니다. 비밀번호는 화면이나 알림에 표시하지 않습니다.")
            ) { try await validateExplicitMailConnection(provider, account: account) }
        }
    }

    private func validateExplicitMailConnection(_ provider: MailProvider, account: String) async throws {
        guard !account.isEmpty, selectedAccount(for: provider) == account else { throw CancellationError() }
        if provider == .gmail { isConnectingGmail = true } else { isConnectingOutlook = true }
        defer {
            if provider == .gmail { isConnectingGmail = false } else { isConnectingOutlook = false }
        }
        switch provider {
        case .gmail:
            try await GmailIMAPService.shared.validateConnection(email: account, backgroundEnabled: imapBackgroundEnabled)
        case .outlook:
            try await OutlookIMAPService.shared.validateConnection(email: account, backgroundEnabled: outlookBackgroundEnabled)
        }
        guard selectedAccount(for: provider) == account else { throw CancellationError() }
        MailCredentialApprovalCenter.shared.resolveMailApproval(provider: provider, namespace: account)
        switch provider {
        case .gmail:
            isGmailAuthenticated = true
            hasGmailStoredCredential = true
            gmailConnectionFailure = nil
            NotificationCenter.default.post(name: .gmailAuthChanged, object: true)
        case .outlook:
            isOutlookAuthenticated = true
            hasOutlookStoredCredential = true
            outlookConnectionFailure = nil
            NotificationCenter.default.post(name: Notification.Name("pieroot.todo.outlookAuthChanged"), object: true)
        }
    }

    private func connectOutlook() async { await connectMail(.outlook) }
    private func connectGmail() async { await connectMail(.gmail) }

    private func connectMail(_ provider: MailProvider) async {
        let email = provider == .gmail ? imapEmail : outlookEmail
        let password = provider == .gmail ? imapPassword : outlookPassword
        let selected = selectedAccount(for: provider)
        let background = provider == .gmail ? imapBackgroundEnabled : outlookBackgroundEnabled
        do {
            try await submitMailConnection(provider, email: email, password: password, selected: selected, background: background)
        } catch {
            guard requiresCredentialApproval(error), selectedAccount(for: provider) == selected else {
                errorMessage = mailErrorMessage(error)
                showError = true
                return
            }
            credentialAction = CredentialAction(
                account: email,
                purpose: Self.credentialText("mail.credential.connectPurpose", "입력한 앱 비밀번호로 이 계정의 메일 연결을 확인하고 키체인에 저장합니다. 기존 비밀번호를 교체해야 하는 경우 해당 계정의 보호된 저장 정보에 접근합니다. 화면에서 요청한 연결·저장만 다시 시도하며 다른 계정은 변경하지 않습니다.")
            ) {
                try await submitMailConnection(provider, email: email, password: password, selected: selected, background: background)
            }
            showCredentialApproval = true
        }
    }

    private func submitMailConnection(
        _ provider: MailProvider, email: String, password: String, selected: String, background: Bool
    ) async throws {
        func requireReviewedInput() throws {
            let currentEmail = provider == .gmail ? imapEmail : outlookEmail
            let currentPassword = provider == .gmail ? imapPassword : outlookPassword
            let currentBackground = provider == .gmail ? imapBackgroundEnabled : outlookBackgroundEnabled
            guard selectedAccount(for: provider) == selected, currentEmail == email,
                  currentPassword == password, currentBackground == background else { throw CancellationError() }
        }
        try requireReviewedInput()
        if provider == .gmail { isConnectingGmail = true } else { isConnectingOutlook = true }
        defer {
            if provider == .gmail { isConnectingGmail = false } else { isConnectingOutlook = false }
        }
        switch provider {
        case .gmail:
            try await GmailIMAPService.shared.authenticateAndSave(email: email, appPassword: password, backgroundEnabled: background)
        case .outlook:
            try await OutlookIMAPService.shared.authenticateAndSave(email: email, appPassword: password, backgroundEnabled: background)
        }
        try requireReviewedInput()
        switch provider {
        case .gmail:
            imapAccount = IMAPCredentialStore.canonicalAccount(email) ?? email
            imapPassword = ""
            isGmailAuthenticated = true
            hasGmailStoredCredential = true
            NotificationCenter.default.post(name: .gmailAuthChanged, object: true)
        case .outlook:
            outlookAccount = OutlookIMAPCredentialStore.canonicalAccount(email) ?? email
            outlookPassword = ""
            isOutlookAuthenticated = true
            hasOutlookStoredCredential = true
            NotificationCenter.default.post(name: Notification.Name("pieroot.todo.outlookAuthChanged"), object: true)
        }
        lastFetchMessage = String(format: AppLanguage.localized("mail.connection.connectedProvider", defaultValue: "%@ connected", language: .current, comment: "Successful mail provider connection. %@ is Gmail IMAP or Outlook IMAP."), provider == .gmail ? "Gmail IMAP" : "Outlook IMAP")
    }

    nonisolated static func fetchStatusMessage(
        todoCount: Int,
        eventCount: Int,
        failures: [String],
        language: AppLanguage
    ) -> String {
        var parts: [String] = []
        if todoCount > 0 {
            parts.append(AppLanguage.localizedCount("mail.fetch.todoCount", count: todoCount, defaultValue: language == .english ? "%lld To-Dos" : "할 일 %lld개", language: language, comment: "Count of extracted to-dos."))
        }
        if eventCount > 0 {
            parts.append(AppLanguage.localizedCount("mail.fetch.eventCount", count: eventCount, defaultValue: language == .english ? "%lld Events" : "일정 %lld개", language: language, comment: "Count of extracted events."))
        }
        if !failures.isEmpty {
            parts.append(failures.joined(separator: "; "))
        }
        guard !parts.isEmpty else {
            return AppLanguage.localized("mail.fetch.none", defaultValue: language == .english ? "No New Items" : "새 항목 없음", language: language, comment: "No extracted mail items.")
        }
        return parts.joined(separator: ", ") + " " + AppLanguage.localized("mail.fetch.extracted", defaultValue: language == .english ? "extracted" : "추출됨", language: language, comment: "Extracted mail items suffix.")
    }

    private func fetchEmailsNow(for provider: MailProvider) async {
        guard fetchingProviders.insert(provider).inserted else { return }
        defer { fetchingProviders.remove(provider) }

        let account = selectedAccount(for: provider)
        var todoCount = 0
        let eventCount = 0
        var failures: [String] = []
        var didSucceed = false

        switch provider {
        case .gmail:
            if isGmailAuthenticated {
                let synced = await MailboxIncrementalSyncCoordinator.shared.sync(provider: .gmail)
                guard !Task.isCancelled, selectedAccount(for: provider) == account else { return }
                todoCount = await EmailAutomationOrchestrator.shared.analyzeNow(provider: .gmail, namespace: account)
                guard !Task.isCancelled, selectedAccount(for: provider) == account else { return }
                didSucceed = synced
                if !synced {
                    failures.append(AppLanguage.localized("오류", defaultValue: "오류", language: .current, comment: "Error"))
                }
            }
            if didSucceed {
                lastEmailFetchTimestamp = Date().timeIntervalSince1970
            }
            lastFetchMessage = Self.fetchStatusMessage(
                todoCount: todoCount,
                eventCount: eventCount,
                failures: failures,
                language: AppLanguage.current
            )
        case .outlook:
            if isOutlookAuthenticated {
                let ok = await MailboxIncrementalSyncCoordinator.shared.sync(provider: .outlook)
                guard !Task.isCancelled, selectedAccount(for: provider) == account else { return }
                _ = await EmailAutomationOrchestrator.shared.analyzeNow(provider: .outlook, namespace: account)
                guard !Task.isCancelled, selectedAccount(for: provider) == account else { return }
                if ok {
                    didSucceed = true
                    lastEmailFetchTimestamp = Date().timeIntervalSince1970
                    lastFetchMessage = AppLanguage.localized(
                        "mail.fetch.outlookSuccess",
                        defaultValue: "Outlook 받은편지함 동기화 완료",
                        language: AppLanguage.current,
                        comment: "Outlook sync success message."
                    )
                } else {
                    lastFetchMessage = AppLanguage.localized(
                        "mail.fetch.outlookFailed",
                        defaultValue: "Outlook 받은편지함 동기화 실패",
                        language: AppLanguage.current,
                        comment: "Outlook sync failure message."
                    )
                }
            }
        }
    }
}
