import SwiftUI

struct TodoSettingsView: View {
    private enum PermissionStatus {
        case checking, granted, denied, notConfigured, unknown

        var label: String {
            let (key, fallback): (String, String) = switch self {
            case .checking: ("system.status.checking", "확인 중…")
            case .granted: ("system.status.granted", "허용됨")
            case .denied: ("system.status.denied", "거부됨")
            case .notConfigured: ("system.status.notConfigured", "미설정")
            case .unknown: ("system.status.unknown", "알 수 없음")
            }
            return AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "System permission status.")
        }
    }

    @Environment(\.appTutorialState) private var tutorial
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var regionalAvailability = OpenAIRegionalAvailability.shared
    @ObservedObject private var connection = OpenAIConnection.shared
    @ObservedObject private var layaService = LayaDecisionService.shared
    @ObservedObject private var llmService = OnDeviceLLMService.shared
    @AppStorage("pieroot.todo.onDeviceModelID") private var onDeviceModelID = OnDeviceLLMService.defaultModelID
    @State private var notificationStatus: PermissionStatus = .checking
    @State private var isRequestingNotification = false

    private var access: BetaProviderAccess { SettingsStore.betaProviderAccess() }
    private var readiness: BetaProviderReadiness { SettingsStore.betaProviderReadiness() }

    private var selectableProviders: [PersonaAIProvider] {
        readiness.selectableProviders(access: access)
            .filter { $0 != .openAI || regionalAvailability.isAvailable }
    }

    private var selectedProviderBinding: Binding<PersonaAIProvider?> {
        Binding(
            get: {
                let selected = SettingsStore.betaSelectedProvider()
                return selected == .openAI && !regionalAvailability.isAvailable ? nil : selected
            },
            set: {
                guard $0 != .openAI || regionalAvailability.isAvailable else { return }
                settingsStore.setBetaSelectedProvider($0)
            }
        )
    }

    var body: some View {
        let providers = selectableProviders
        Form {
            notificationSection

            Section {
                if providers.isEmpty {
                    Text(copy(
                        "todo.settings.priority.unavailable",
                        korean: "사용 가능한 AI가 없어 규칙 기반으로 정렬합니다.",
                        english: "No AI is available, so sorting uses rules."
                    ))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker(
                        copy("todo.settings.priority.provider", korean: "정렬에 사용할 AI", english: "AI for Sorting"),
                        selection: selectedProviderBinding
                    ) {
                        // A ready local provider is the normalized default; nil is only
                        // meaningful when the ready options contain no local provider.
                        if selectedProviderBinding.wrappedValue == nil {
                            Text("없음")
                                .tag(Optional<PersonaAIProvider>.none)
                        }
                        ForEach(providers) { provider in
                            Label(provider.displayName, systemImage: provider.systemImage)
                                .tag(Optional(provider))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("beta.providerPicker")
                }

                NavigationLink(destination: IntelligenceDetailView()) {
                    Label("TODO 우선순위 규칙", systemImage: "slider.horizontal.3")
                        .labelStyle(SettingsRowLabelStyle())
                        .appTutorialGlow(tutorial?.currentStep == .priorityRules)
                }
                .accessibilityIdentifier("todo.priority.rules.row")
                .appTutorialAnchor(screen: .todoSettings, steps: [.priorityRules], above: true)

                NavigationLink(destination: AISettingsView()) {
                    Label(copy(
                        "todo.settings.priority.manageProviders",
                        korean: "AI 제공자 설정",
                        english: "AI Provider Settings"
                    ), systemImage: "brain.head.profile")
                    .labelStyle(SettingsRowLabelStyle())
                }
                .accessibilityIdentifier("todo.aiSettings.row")
            } header: {
                Text(copy("todo.settings.priority.section", korean: "우선순위 정렬", english: "Priority Sorting"))
            } footer: {
                Text(copy(
                    "todo.settings.priority.footer",
                    korean: "사용 가능한 AI만 표시합니다. 사용할 수 없으면 마감·중요도 규칙으로 정렬하며 직접 고정한 우선순위는 유지합니다. 계정 연결과 외부 전송 동의는 별도로 필요합니다. 모델 설치는 베타 기능에서 관리합니다.",
                    english: "Only available AI options are shown. If AI is unavailable, sorting uses due-date and importance rules while preserving manually pinned priorities. Account connection and consent to external data transfers are required separately. Manage model installation in Beta Features."
                ))
            }
        }
        .appFormStyle()
        .navigationTitle(copy("todo.settings.title", korean: "할 일 설정", english: "To-Do Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            refreshProviderSelection()
            await refreshNotificationStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshProviderSelection()
                Task { await refreshNotificationStatus() }
            }
        }
        .onChange(of: onDeviceModelID) { _, _ in
            settingsStore.normalizeBetaSelectedProvider()
        }
        .onChange(of: readiness) { _, _ in
            settingsStore.normalizeBetaSelectedProvider()
        }
        .onChange(of: access) { _, _ in
            settingsStore.normalizeBetaSelectedProvider()
        }
        .onChange(of: regionalAvailability.isAvailable) { _, _ in
            refreshProviderSelection()
        }
        .onDisappear {
            tutorial?.handlePermissionsClosed()
        }
    }

    private var notificationSection: some View {
        Section {
            HStack {
                Label("알림", systemImage: "bell.badge")
                Spacer()
                Text(notificationStatus.label)
                    .font(.subheadline)
                    .foregroundStyle(notificationStatus == .granted ? Color.secondary : Color.orange)
            }
            .accessibilityIdentifier("todo.notifications.status")
            .appTutorialAnchor(screen: .todoSettings, steps: [.permissions])

            if notificationStatus == .notConfigured {
                Button {
                    Task { await requestNotification() }
                } label: {
                    HStack {
                        Text(copy("permissions.action.allow", korean: "허용", english: "Allow"))
                        if isRequestingNotification {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isRequestingNotification)
                .appTutorialGlow(tutorial?.currentStep == .permissions)
                .accessibilityIdentifier("todo.notifications.request")
            } else if notificationStatus == .denied || notificationStatus == .unknown {
                Link(
                    copy("permissions.action.settings", korean: "설정 열기", english: "Open Settings"),
                    destination: URL(string: UIApplication.openSettingsURLString)!
                )
                .appTutorialGlow(tutorial?.currentStep == .permissions)
                .accessibilityIdentifier("todo.notifications.openSettings")
            }
        } header: {
            Text(copy("todo.settings.notifications.section", korean: "마감 알림", english: "Due-Date Reminders"))
        } footer: {
            Text(copy(
                "todo.settings.notifications.footer",
                korean: "권한을 허용해도 할 일에서 설정한 미리 알림에 따라 알림을 보냅니다. 거부된 경우 앱 시스템 설정에서 변경하세요.",
                english: "Even with permission, notifications follow the reminders configured for each to-do. If permission was denied, change it in the app’s system settings."
            ))
        }
    }

    private func refreshProviderSelection() {
        if regionalAvailability.isAvailable { connection.refreshCredentials() }
        settingsStore.migrateLegacyBetaSelectedProviderIfNeeded()
        settingsStore.normalizeBetaSelectedProvider()
    }

    private func refreshNotificationStatus() async {
        let status = await NotificationService.shared.authorizationStatus()
        notificationStatus = switch status {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notConfigured
        @unknown default: .unknown
        }
    }

    private func requestNotification() async {
        guard !isRequestingNotification, notificationStatus == .notConfigured else { return }
        isRequestingNotification = true
        defer { isRequestingNotification = false }
        _ = await NotificationService.shared.requestAuthorization()
        await refreshNotificationStatus()
    }

    private func copy(_ key: String, korean: String, english: String) -> String {
        AppLanguage.localized(
            key,
            defaultValue: AppLanguage.current == .english ? english : korean,
            language: .current,
            comment: "TODO settings copy."
        )
    }
}
