import SwiftUI

// 7. 시스템 권한 및 상태
struct SystemStatusDetailView: View {
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
    @State private var notificationStatus: PermissionStatus = .checking
    @State private var calendarStatus: PermissionStatus = .checking
    var body: some View {
        Form {
            Section {
                HStack {
                    Label("알림", systemImage: "bell.badge")
                    Spacer()
                    Text(notificationStatus.label)
                        .font(.subheadline)
                        .foregroundStyle(notificationStatus == .granted ? .green : .orange)
                    if notificationStatus != .granted {
                        Button("허용") { Task { await requestNotification() } }
                            .font(.caption).buttonStyle(.bordered).controlSize(.small)
                    }
                }

                HStack {
                    Label("캘린더", systemImage: "calendar")
                    Spacer()
                    Text(calendarStatus.label)
                        .font(.subheadline)
                        .foregroundStyle(calendarStatus == .granted ? .green : .orange)
                    if calendarStatus != .granted {
                        Button("허용") { Task { await requestCalendar() } }
                            .font(.caption).buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .navigationTitle("시스템 권한 및 상태")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshStatus()
        }
        .onDisappear {
            tutorial?.handlePermissionsClosed()
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if let tutorial, let hint = tutorial.hint(for: .permissionsDetail) {
                AppTutorialHintCard(hint: hint)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }
    
    private func refreshStatus() async {
        let status = await NotificationService.shared.authorizationStatus()
        notificationStatus = switch status {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notConfigured
        @unknown default: .unknown
        }
        calendarStatus = CalendarService.shared.isAuthorized ? .granted : .notConfigured
    }

    private func requestNotification() async {
        notificationStatus = await NotificationService.shared.requestAuthorization() ? .granted : .denied
    }

    private func requestCalendar() async {
        calendarStatus = await CalendarService.shared.requestAccess() ? .granted : .denied
    }
}
