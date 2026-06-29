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

    private var emailLookbackDays: Int {
        get { SettingsStore.shared.get("pieroot.todo.emailLookbackDays", defaultValue: 3) }
        nonmutating set { saveSetting(key: "pieroot.todo.emailLookbackDays", value: newValue) }
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
                            Stepper("메일 확인 기간: \(emailLookbackDays)일", value: settingsBinding(key: "pieroot.todo.emailLookbackDays", defaultValue: 3), in: 1...30)
                            Text("최근 \(emailLookbackDays)일치 메일을 분석합니다. 기본값 3일.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            scopeBadge(for: "pieroot.todo.emailLookbackDays", iCloudSyncEnabled: iCloudSyncEnabled)
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
        HStack {
            Label(title, systemImage: icon)
                .symbolRenderingMode(.multicolor)
            Spacer()
            Text(connected ? "연결됨" : "미연결")
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
        case 0:  return "자정 00:00"
        case 12: return "정오 12:00"
        default:
            let period = h < 12 ? "오전" : "오후"
            let display = h <= 12 ? h : h - 12
            return "\(period) \(display)시 (\(String(format: "%02d", h)):00)"
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
            lastFetchMessage = "Gmail 연결 완료"
        } catch {
            let nsError = error as NSError
            if nsError.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && nsError.code == 1 {
                errorMessage = "로그인이 취소되었습니다."
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
            lastFetchMessage = "Outlook 연결 완료"
        } catch OutlookMailError.missingClientID {
            errorMessage = OutlookMailError.missingClientID.localizedDescription
            showError = true
        } catch {
            let nsError = error as NSError
            if nsError.domain == MSALErrorDomain && nsError.code == MSALError.userCanceled.rawValue {
                errorMessage = "로그인이 취소되었습니다."
            } else {
                errorMessage = error.localizedDescription
            }
            showError = true
        }
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

        var parts: [String] = []
        if todoCount > 0 { parts.append("할 일 \(todoCount)개") }
        if eventCount > 0 { parts.append("일정 \(eventCount)개") }

        if !failures.isEmpty {
            let prefix = parts.isEmpty ? "" : parts.joined(separator: ", ") + " / "
            lastFetchMessage = prefix + failures.joined(separator: "\n")
        } else {
            lastFetchMessage = parts.isEmpty ? "새 항목 없음" : parts.joined(separator: ", ") + " 추출됨"
        }
    }
}
