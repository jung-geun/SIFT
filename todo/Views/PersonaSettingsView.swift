import SwiftUI

struct PersonaSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTutorialState) private var tutorial
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    
    var body: some View {
        Form {
            Section {
                NavigationLink(destination: PersonaDetailView()) {
                    Label("나의 페르소나", systemImage: "person.circle")
                }
                
                NavigationLink(destination: MemoryDetailView()) {
                    Label("행동 패턴 분석", systemImage: "brain.head.profile")
                }
                
                NavigationLink(destination: IntelligenceDetailView()) {
                    Label("TODO 자동 정렬 및 AI", systemImage: "brain")
                }
                
                NavigationLink(destination: EmailDetailView()) {
                    Label("이메일 연동", systemImage: "envelope")
                }
                
                NavigationLink(destination: CalendarDetailView()) {
                    Label("캘린더 설정", systemImage: "calendar")
                }

                NavigationLink(destination: LaunchScreenDetailView()) {
                    Label("시작 화면", systemImage: "rectangle.on.rectangle")
                }

                NavigationLink(destination: SystemStatusDetailView()) {
                    Label("시스템 권한 및 상태", systemImage: "shield")
                }
                
                NavigationLink(destination: ICloudSyncDetailView()) {
                    Label("iCloud 동기화", systemImage: "icloud")
                }
                
                NavigationLink(destination: AppInfoDetailView()) {
                    Label("앱 정보", systemImage: "info.circle")
                }
                .accessibilityIdentifier("settings.appInfoRow")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if let tutorial, let hint = tutorial.hint(for: .settings) {
                AppTutorialHintCard(hint: hint)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("닫기") { dismiss() }
            }
        }
        .task {
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: "pieroot.todo.didMigrateToUnifiedAI") {
                defaults.set(true, forKey: "pieroot.todo.didMigrateToUnifiedAI")
            }
        }
    }
}
