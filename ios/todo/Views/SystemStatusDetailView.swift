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
                            .appTutorialGlow(tutorial?.currentStep == .permissions && notificationStatus != .granted)
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
                            .appTutorialGlow(tutorial?.currentStep == .permissions && calendarStatus != .granted)
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
            if let tutorial, tutorial.currentStep == .permissions,
               let hint = permissionTutorialHint {
                AppTutorialTipView(hint: hint)
            }
        }
    }

    private var permissionTutorialHint: AppTutorialHint? {
        let needsNotification = notificationStatus != .granted
        let needsCalendar = calendarStatus != .granted

        switch (needsNotification, needsCalendar) {
        case (true, true):
            return AppTutorialHint(
                title: "필요한 권한 허용",
                body: "알림과 캘린더가 아직 허용되지 않았습니다. 각 행의 허용 버튼을 눌러 마감 알림과 캘린더 등록을 사용할 수 있게 해주세요."
            )
        case (true, false):
            return AppTutorialHint(
                title: "알림 권한 허용",
                body: "알림이 아직 허용되지 않았습니다. 알림 행의 허용 버튼을 눌러 마감 알림을 받을 수 있게 해주세요."
            )
        case (false, true):
            return AppTutorialHint(
                title: "캘린더 권한 허용",
                body: "캘린더가 아직 허용되지 않았습니다. 캘린더 행의 허용 버튼을 눌러 마감 일정을 자동 등록할 수 있게 해주세요."
            )
        case (false, false):
            return AppTutorialHint(
                title: "권한 확인 완료",
                body: "필요한 권한이 허용되어 있습니다. 뒤로 돌아가 튜토리얼을 계속하세요."
            )
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
