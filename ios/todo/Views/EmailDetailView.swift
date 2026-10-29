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
    @State private var isFetchingEmails = false
    @State private var imapEmail = ""
    @State private var imapPassword = ""
    @State private var outlookEmail = ""
    @State private var outlookPassword = ""
    @State private var showGmailConnection = false
    @State private var showOutlookConnection = false
    @State private var hasGmailStoredCredential = false
    @State private var hasOutlookStoredCredential = false
    @State private var showBackgroundWarning = false
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
            return MailConnectionValidation(isAuthenticated: true, hasStoredCredential: true, failureMessage: nil)
        } catch {
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
            return MailConnectionValidation(isAuthenticated: true, hasStoredCredential: true, failureMessage: nil)
        } catch {
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

    private var emailRefreshHour: Int {
        get { SettingsStore.shared.get("pieroot.todo.emailRefreshHour", defaultValue: 7) }
        nonmutating set { saveSetting(key: "pieroot.todo.emailRefreshHour", value: newValue) }
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

                if !isGmailAuthenticated {
                    if isValidatingGmail {
                        storedCredentialValidationPanel()
                    } else if hasGmailStoredCredential {
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
                                            showBackgroundWarning = true
                                        } else {
                                            imapBackgroundEnabled = false
                                        }
                                    }
                                ))
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

                if !isOutlookAuthenticated {
                    if isValidatingOutlook {
                        storedCredentialValidationPanel()
                    } else if hasOutlookStoredCredential {
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

                if isGmailAuthenticated {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("메일 자동 분석", isOn: settingsBinding(key: "pieroot.todo.emailAutoAnalysisEnabled", defaultValue: true))
                    }
                }

                if isAnyMailAuthenticated {
                    DisclosureGroup(isExpanded: $showEmailPeriod) {

                        VStack(alignment: .leading, spacing: 4) {
                            Picker("자동 동기화 시각", selection: settingsBinding(key: "pieroot.todo.emailRefreshHour", defaultValue: 7) { _ in
                                scheduleEmailRefresh()
                            }) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(Self.hourLabel(h)).tag(h)
                                }
                            }
                            .pickerStyle(.menu)
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
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let tutorial {
                AppTutorialTipHost(tutorial: tutorial, screen: .emailDetail)
            }
        }
        .alert("백그라운드 메일 불러오기", isPresented: $showBackgroundWarning) {
            Button("위험을 이해하고 활성화") {
                imapBackgroundEnabled = true
                if !imapAccount.isEmpty {
                    Task { try? IMAPCredentialStore.migrateAccess(for: imapAccount, toBackground: true) }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("기기가 잠긴 뒤에도 이 기기에서 App Password를 사용할 수 있습니다. 분실·탈옥·앱 침해 위험이 증가할 수 있습니다.")
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

    private func storedCredentialValidationPanel() -> some View {
        return HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(AppLanguage.localized(
                "mail.authentication.checking",
                defaultValue: "연결·메일 조회 확인 중…",
                language: .current,
                comment: "Checking the IMAP connection and inbox message access."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
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

    private static func hourLabel(_ h: Int) -> String {
        switch h {
        case 0:
            return AppLanguage.localized("mail.hour.midnight", defaultValue: "자정 00:00", language: .current, comment: "Mail refresh hour.")
        case 12:
            return AppLanguage.localized("mail.hour.noon", defaultValue: "정오 12:00", language: .current, comment: "Mail refresh hour.")
        default:
            let formatter = DateFormatter()
            formatter.locale = AppLanguage.current.locale
            formatter.setLocalizedDateFormatFromTemplate("j")
            let calendar = Calendar(identifier: .gregorian)
            let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: h))!
            let clock = String(format: "%02d:00", h)
            return "\(formatter.string(from: date)) (\(clock))"
        }
    }


    private func signOutGmail() {
        Task {
            await GmailIMAPService.shared.disconnect()
            do {
                let targetAccount = imapAccount
                try IMAPCredentialStore.delete(for: targetAccount)
                MailboxIncrementalSyncCoordinator.shared.forgetCursor(for: .gmail, rawAccount: targetAccount)
                GmailIMAPIngestionCursorStore().clearCursor(for: targetAccount)
                imapAccount = ""
                imapEmail = ""
                isGmailAuthenticated = false
                hasGmailStoredCredential = false
                NotificationCenter.default.post(name: .gmailAuthChanged, object: false)
                imapPassword = ""
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }


    private func signOutOutlook() {
        Task {
            await OutlookIMAPService.shared.disconnect()
            do {
                let targetAccount = outlookAccount
                try OutlookIMAPCredentialStore.delete(for: targetAccount)
                MailboxIncrementalSyncCoordinator.shared.forgetCursor(for: .outlook, rawAccount: targetAccount)
                outlookAccount = ""
                outlookEmail = ""
                isOutlookAuthenticated = false
                hasOutlookStoredCredential = false
                NotificationCenter.default.post(name: Notification.Name("pieroot.todo.outlookAuthChanged"), object: false)
                outlookPassword = ""
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func reconnectOutlook() async {
        isConnectingOutlook = true
        defer { isConnectingOutlook = false }
        do {
            try await OutlookIMAPService.shared.validateConnection(
                email: outlookAccount,
                backgroundEnabled: outlookBackgroundEnabled
            )
            isOutlookAuthenticated = true
            hasOutlookStoredCredential = true
            outlookConnectionFailure = nil
            NotificationCenter.default.post(name: Notification.Name("pieroot.todo.outlookAuthChanged"), object: true)
        } catch {
            isOutlookAuthenticated = false
            hasOutlookStoredCredential = MailCredentialFailurePolicy.hasStoredCredential(after: error)
            outlookConnectionFailure = mailErrorMessage(error)
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func reconnectGmail() async {
        isConnectingGmail = true
        defer { isConnectingGmail = false }
        do {
            try await GmailIMAPService.shared.validateConnection(
                email: imapAccount,
                backgroundEnabled: imapBackgroundEnabled
            )
            isGmailAuthenticated = true
            hasGmailStoredCredential = true
            gmailConnectionFailure = nil
            NotificationCenter.default.post(name: .gmailAuthChanged, object: true)
        } catch {
            isGmailAuthenticated = false
            hasGmailStoredCredential = MailCredentialFailurePolicy.hasStoredCredential(after: error)
            gmailConnectionFailure = mailErrorMessage(error)
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func connectOutlook() async {
        isConnectingOutlook = true
        defer { isConnectingOutlook = false }
        do {
            try await OutlookIMAPService.shared.authenticateAndSave(
                email: outlookEmail,
                appPassword: outlookPassword,
                backgroundEnabled: outlookBackgroundEnabled
            )
            let canonical = OutlookIMAPCredentialStore.canonicalAccount(outlookEmail) ?? outlookEmail
            outlookAccount = canonical
            outlookPassword = ""
            isOutlookAuthenticated = true
            hasOutlookStoredCredential = true
            NotificationCenter.default.post(name: Notification.Name("pieroot.todo.outlookAuthChanged"), object: true)
            lastFetchMessage = String(format: AppLanguage.localized("mail.connection.connectedProvider", defaultValue: "%@ connected", language: .current, comment: "Successful mail provider connection. %@ is Gmail IMAP or Outlook IMAP."), "Outlook IMAP")
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    private func connectGmail() async {
        isConnectingGmail = true
        defer { isConnectingGmail = false }
        do {
            try await GmailIMAPService.shared.authenticateAndSave(
                email: imapEmail,
                appPassword: imapPassword,
                backgroundEnabled: imapBackgroundEnabled
            )
            imapAccount = IMAPCredentialStore.canonicalAccount(imapEmail) ?? imapEmail
            imapPassword = ""
            isGmailAuthenticated = true
            hasGmailStoredCredential = true
            NotificationCenter.default.post(name: .gmailAuthChanged, object: true)
            lastFetchMessage = String(format: AppLanguage.localized("mail.connection.connectedProvider", defaultValue: "%@ connected", language: .current, comment: "Successful mail provider connection. %@ is Gmail IMAP or Outlook IMAP."), "Gmail IMAP")
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
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
        guard !isFetchingEmails else { return }
        isFetchingEmails = true
        defer { isFetchingEmails = false }

        let emailContext = AppDataContainer.shared.emailContainer.mainContext
        var todoCount = 0
        let eventCount = 0
        var failures: [String] = []
        var didSucceed = false

        switch provider {
        case .gmail:
            if isGmailAuthenticated {
                do {
                    let account = imapAccount.isEmpty ? imapEmail : imapAccount
                    let result = try await GmailIMAPIngestionService(emailContext: emailContext)
                        .sync(account: account, backgroundEnabled: imapBackgroundEnabled)
                    todoCount += result.analyzedCount
                    didSucceed = true
                } catch {
                    failures.append("Gmail IMAP: \(error.localizedDescription)")
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
