import SwiftUI

// 7. 시스템 권한 및 상태
struct SystemStatusDetailView: View {
    @Environment(\.appTutorialState) private var tutorial
    @State private var notificationStatus = "확인 중…"
    @State private var calendarStatus     = "확인 중…"
    
    var body: some View {
        Form {
            Section {
                HStack {
                    Label("알림", systemImage: "bell.badge")
                    Spacer()
                    Text(notificationStatus)
                        .font(.subheadline)
                        .foregroundStyle(notificationStatus == "허용됨" ? .green : .orange)
                    if notificationStatus != "허용됨" {
                        Button("허용") { Task { await requestNotification() } }
                            .font(.caption).buttonStyle(.bordered).controlSize(.small)
                    }
                }
                
                HStack {
                    Label("캘린더", systemImage: "calendar")
                    Spacer()
                    Text(calendarStatus)
                        .font(.subheadline)
                        .foregroundStyle(calendarStatus == "허용됨" ? .green : .orange)
                    if calendarStatus != "허용됨" {
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
        case .authorized, .provisional, .ephemeral: "허용됨"
        case .denied: "거부됨"
        case .notDetermined: "미설정"
        @unknown default: "알 수 없음"
        }
        calendarStatus = CalendarService.shared.isAuthorized ? "허용됨" : "미설정"
    }
    
    private func requestNotification() async {
        notificationStatus = await NotificationService.shared.requestAuthorization() ? "허용됨" : "거부됨"
    }
    
    private func requestCalendar() async {
        calendarStatus = await CalendarService.shared.requestAccess() ? "허용됨" : "거부됨"
    }
}
