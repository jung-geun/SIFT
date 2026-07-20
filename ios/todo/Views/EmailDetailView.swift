import SwiftUI
import SwiftData
import MSAL

// 4. 이메일 연동
struct EmailDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appTutorialState) private var tutorial
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("pieroot.todo.lastEmailFetchDate") private var lastEmailFetchTimestamp: Double = 0

    @State private var isGmailAuthenticated = false
    @State private var isOutlookAuthenticated = false
    @State private var isConnectingGmail = false
    @State private var isConnectingOutlook = false
    @State private var isFetchingEmails = false
    @State private var lastFetchMessage: String?
    @State private var showEmailPeriod = false
    @State private var suppressedSendersList: [String] = []
    @State private var errorMessage: String?
    @State private var showError = false

    private var isAnyMailAuthenticated: Bool {
        isGmailAuthenticated || isOutlookAuthenticated
    }

    private var selectedProvider: PersonaAIProvider {
        PersonaAIProvider(
            rawValue: SettingsStore.shared.get("selectedAIProvider", defaultValue: PersonaAIProvider.foundationModels.rawValue)
        ) ?? .foundationModels
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

    private var canEnableGeminiEmailAnalysis: Bool {
        selectedProvider == .gemini && GeminiProviderService.storedAPIKey != nil
    }

    private var outlookAvailable: Bool {
        OutlookMailService.shared.isConfigured
    }

    var body: some View {
        Form {
            Section {
                accountRow(
                    title: "Gmail 계정",
                    connected: isGmailAuthenticated,
                    icon: "envelope.circle.fill",
                    tint: .green,
                    onFetch: { Task { await fetchEmailsNow() } },
                    onSignOut: signOutGmail
                )

                if !isGmailAuthenticated {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            Task { await connectGmail() }
                        } label: {
                            if isConnectingGmail {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("연결 중…")
                                }
                            } else {
                                Label("Gmail 연결", systemImage: "plus.circle")
                            }
                        }
                        .disabled(isConnectingGmail || isConnectingOutlook)
                    }
                }

                if outlookAvailable {
                    accountRow(
                        title: "Outlook 계정",
                        connected: isOutlookAuthenticated,
                        icon: "envelope.badge",
                        tint: .blue,
                        onFetch: { Task { await fetchEmailsNow() } },
                        onSignOut: signOutOutlook
                    )

                    if !isOutlookAuthenticated {
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                Task { await connectOutlook() }
                            } label: {
                                if isConnectingOutlook {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text("연결 중…")
                                    }
                                } else {
                                    Label("Outlook 연결", systemImage: "plus.circle")
                                }
                            }
                            .disabled(isConnectingGmail || isConnectingOutlook)
                        }
                    }
                }

                if isAnyMailAuthenticated {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("메일 자동 분석", isOn: settingsBinding(key: "pieroot.todo.emailAutoAnalysisEnabled", defaultValue: true))
                        scopeBadge(for: "pieroot.todo.emailAutoAnalysisEnabled", iCloudSyncEnabled: iCloudSyncEnabled)
                    }

                    if canEnableGeminiEmailAnalysis {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(
                                "메일 본문 분석 허용",
                                isOn: settingsBinding(key: "pieroot.todo.providerEmailAnalysisEnabled", defaultValue: false)
                            )
                            scopeBadge(for: "pieroot.todo.providerEmailAnalysisEnabled", iCloudSyncEnabled: iCloudSyncEnabled)
                            Text("켜면 메일 내용을 더 정확히 분석하기 위해 외부 분석 서비스로 전송할 수 있습니다.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    DisclosureGroup(isExpanded: $showEmailPeriod) {
                        HStack {
                            Label("마지막 동기화", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            if lastEmailFetchTimestamp > 0 {
                                Text(Date(timeIntervalSince1970: lastEmailFetchTimestamp), style: .relative)
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            } else {
                                Text("없음")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Picker("자동 동기화 시각", selection: settingsBinding(key: "pieroot.todo.emailRefreshHour", defaultValue: 7) { _ in
                                scheduleEmailRefresh()
                            }) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(Self.hourLabel(h)).tag(h)
                                }
                            }
                            .pickerStyle(.menu)
                            scopeBadge(for: "pieroot.todo.emailRefreshHour", iCloudSyncEnabled: iCloudSyncEnabled)
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
                            scopeBadge(for: EmailAnalysisLookbackPolicy.lookbackSettingKey, iCloudSyncEnabled: iCloudSyncEnabled)
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
                Text("'메일 자동 분석'을 켜면 연결된 메일을 분석해 할 일 후보를 자동으로 정리합니다. 실행 시각은 기기 상태나 네트워크 상황에 따라 달라질 수 있습니다.")
            }

            if isAnyMailAuthenticated {
                Section {
                    if suppressedSendersList.isEmpty {
                        Text("숨긴 발신자 없음")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
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
                                .tint(.orange)
                            }
                        }
                    }
                } header: {
                    Label("자동 숨긴 발신자", systemImage: "eye.slash")
                } footer: {
                    Text("같은 발신자의 이메일을 2회 이상 삭제하면 자동으로 숨겨집니다. 해제하면 이후 메일이 다시 분류됩니다.")
                }
            }
        }
        .navigationTitle("이메일 연동")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isGmailAuthenticated = EmailService.shared.isAuthenticated
            isOutlookAuthenticated = outlookAvailable
                ? await OutlookMailService.shared.canAccessMailSilently()
                : false
            suppressedSendersList = EmailLearningStore.shared.suppressedSenders()
        }
        .onDisappear {
            tutorial?.handleEmailDetailClosed()
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if let tutorial, let hint = tutorial.hint(for: .emailDetail) {
                AppTutorialHintCard(hint: hint)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
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
        connected: Bool,
        icon: String,
        tint: Color,
        onFetch: @escaping () -> Void,
        onSignOut: @escaping () -> Void
    ) -> some View {
        let titleKey = title.hasPrefix("Gmail") ? "mail.account.gmail" : "mail.account.outlook"
        let localizedTitle = AppLanguage.localized(titleKey, defaultValue: title, language: .current, comment: "Mail account label.")
        let connection = AppLanguage.localized(
            connected ? "mail.account.connected" : "mail.account.disconnected",
            defaultValue: connected ? "연결됨" : "미연결",
            language: .current,
            comment: "Mail account connection state."
        )
        HStack {
            Label(localizedTitle, systemImage: icon)
                .symbolRenderingMode(.multicolor)
            Spacer()
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

    private static func hourLabel(_ h: Int) -> String {
        switch h {
        case 0:
            return AppLanguage.localized("mail.hour.midnight", defaultValue: "자정 00:00", language: .current, comment: "Mail refresh hour.")
        case 12:
            return AppLanguage.localized("mail.hour.noon", defaultValue: "정오 12:00", language: .current, comment: "Mail refresh hour.")
        default:
            let periodKey = h < 12 ? "mail.hour.am" : "mail.hour.pm"
            let periodFallback = h < 12 ? "오전" : "오후"
            let period = AppLanguage.localized(periodKey, defaultValue: periodFallback, language: .current, comment: "Mail refresh hour period.")
            let display = h <= 12 ? h : h - 12
            let clock = String(format: "%02d:00", h)
            if AppLanguage.current == .english {
                return "\(display) \(period) (\(clock))"
            }
            return "\(period) \(display)시 (\(clock))"
        }
    }

    private func signOutGmail() {
        EmailService.shared.signOut()
        isGmailAuthenticated = false
        lastFetchMessage = nil
    }

    private func signOutOutlook() {
        OutlookMailService.shared.signOut()
        isOutlookAuthenticated = false
        lastFetchMessage = nil
    }

    private func connectGmail() async {
        isConnectingGmail = true
        defer { isConnectingGmail = false }
        do {
            try await EmailService.shared.authenticate()
            isGmailAuthenticated = true
            lastFetchMessage = AppLanguage.localized("mail.connection.gmail.success", defaultValue: "Gmail connected", language: .current, comment: "Gmail connection success.")
        } catch {
            let nsError = error as NSError
            if nsError.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && nsError.code == 1 {
                errorMessage = AppLanguage.localized("mail.auth.cancelled", defaultValue: "Sign-in was cancelled.", language: .current, comment: "Mail authentication cancellation.")
            } else {
                errorMessage = error.localizedDescription
            }
            showError = true
        }
    }

    private func connectOutlook() async {
        isConnectingOutlook = true
        defer { isConnectingOutlook = false }
        do {
            try await OutlookMailService.shared.authenticate()
            isOutlookAuthenticated = true
            lastFetchMessage = AppLanguage.localized("mail.connection.outlook.success", defaultValue: "Outlook connected", language: .current, comment: "Outlook connection success.")
        } catch OutlookMailError.missingClientID {
            errorMessage = OutlookMailError.missingClientID.localizedDescription
            showError = true
        } catch {
            let nsError = error as NSError
            if nsError.domain == MSALErrorDomain && nsError.code == MSALError.userCanceled.rawValue {
                errorMessage = AppLanguage.localized("mail.auth.cancelled", defaultValue: "Sign-in was cancelled.", language: .current, comment: "Mail authentication cancellation.")
            } else {
                errorMessage = error.localizedDescription
            }
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
            parts.append(
                AppLanguage.localizedCount(
                    "mail.fetch.todoCount",
                    count: todoCount,
                    defaultValue: language == .english
                        ? (todoCount == 1 ? "%lld To-Do" : "%lld To-Dos")
                        : "할 일 %lld개",
                    language: language,
                    comment: "Count of extracted to-dos."
                )
            )
        }
        if eventCount > 0 {
            parts.append(
                AppLanguage.localizedCount(
                    "mail.fetch.eventCount",
                    count: eventCount,
                    defaultValue: language == .english
                        ? (eventCount == 1 ? "%lld Calendar Event" : "%lld Calendar Events")
                        : "일정 %lld개",
                    language: language,
                    comment: "Count of extracted calendar events."
                )
            )
        }

        if !failures.isEmpty {
            let prefix = parts.isEmpty ? "" : parts.joined(separator: ", ") + " / "
            return prefix + failures.joined(separator: "\n")
        }
        guard !parts.isEmpty else {
            return AppLanguage.localized(
                "mail.fetch.none",
                defaultValue: language == .english ? "No New Items" : "새 항목 없음",
                language: language,
                comment: "No extracted mail items."
            )
        }
        return parts.joined(separator: ", ") + " " + AppLanguage.localized(
            "mail.fetch.extracted",
            defaultValue: language == .english ? "extracted" : "추출됨",
            language: language,
            comment: "Extracted mail items suffix."
        )
    }

    private func fetchEmailsNow() async {
        guard !isFetchingEmails else { return }
        isFetchingEmails = true
        defer { isFetchingEmails = false }

        let emailContext = AppDataContainer.shared.emailContainer.mainContext
        var todoCount = 0
        var eventCount = 0
        var failures: [String] = []
        var didSucceed = false

        if isGmailAuthenticated {
            do {
                _ = try await EmailService.shared.syncRecentMessageCache(
                    emailContext: emailContext,
                    todoContext: modelContext
                )
                let result = try await EmailService.shared.fetchAndStoreExtractedItems(context: modelContext)
                todoCount += result.todoCount
                eventCount += result.eventCount
                didSucceed = true
            } catch {
                failures.append("Gmail: \(error.localizedDescription)")
            }
        }

        if isOutlookAuthenticated {
            do {
                _ = try await OutlookMailService.shared.syncRecentMessageCache(
                    emailContext: emailContext,
                    todoContext: modelContext
                )
                let result = try await OutlookMailService.shared.fetchAndStoreExtractedItems(context: modelContext)
                todoCount += result.todoCount
                eventCount += result.eventCount
                didSucceed = true
            } catch {
                failures.append("Outlook: \(error.localizedDescription)")
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
    }
}
