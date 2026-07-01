import SwiftUI

// 7. iCloud 동기화
struct ICloudSyncDetailView: View {
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @State private var showSyncRestartAlert = false
    @ObservedObject private var settingsStore = SettingsStore.shared
    
    var body: some View {
        Form {
            Section {
                Toggle("데이터 동기화 (iCloud)", isOn: Binding(
                    get: { iCloudSyncEnabled },
                    set: { newValue in
                        iCloudSyncEnabled = newValue
                        if newValue {
                            SettingsStore.shared.uploadLocalSettingsToCloud()
                        }
                        KeychainStore.applySyncPolicy()
                        showSyncRestartAlert = true
                    }
                ))
                
                if iCloudSyncEnabled {
                    Label("할 일·페르소나가 iCloud를 통해 동기화됩니다", systemImage: "checkmark.icloud.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("데이터가 이 기기에만 저장됩니다", systemImage: "iphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("iCloud 동기화를 활성화하면 할 일, 페르소나, 할 일 감사 기록이 같은 Apple ID로 로그인한 모든 기기와 동기화됩니다. 행동 패턴 분석과 이메일 학습 데이터는 기기 로컬에만 저장됩니다.")
            }
            .alert("앱 재시작 필요", isPresented: $showSyncRestartAlert) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(iCloudSyncEnabled
                     ? "iCloud 동기화가 활성화되었습니다. 앱을 종료 후 다시 실행하면 동기화가 시작됩니다."
                     : "iCloud 동기화가 비활성화되었습니다. 앱을 종료 후 다시 실행하면 로컬 전용으로 전환됩니다.")
            }
            
            if iCloudSyncEnabled {
                Section {
                    syncManagementRow(title: "AI 자동화", key: "pieroot.todo.onDeviceLLMEnabled")
                    syncManagementRow(title: "TODO 자동 정렬 AI", key: "selectedAIProvider")
                    syncManagementRow(title: "메일 자동 분석", key: "pieroot.todo.emailAutoAnalysisEnabled")
                    syncManagementRow(title: "자동 동기화 시각", key: "pieroot.todo.emailRefreshHour")
                    syncManagementRow(title: "메일 확인 기간", key: "pieroot.todo.emailLookbackDays")
                    syncManagementRow(title: "마감 자동 캘린더 등록", key: "pieroot.todo.calendarAutoRegister")
                    syncManagementRow(title: "완료 시 처리", key: "pieroot.todo.calendarCompletionAction")
                } header: {
                    Label("iCloud 동기화 관리", systemImage: "icloud.fill")
                } footer: {
                    Text("각 설정 항목의 저장 위치를 iCloud 동기화 또는 로컬 전용으로 일괄 지정할 수 있습니다.")
                }
            }
        }
        .navigationTitle("iCloud 동기화")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func syncManagementRow(title: String, key: String) -> some View {
        HStack {
            Text(title)
                .font(.body)
            Spacer()
            Menu {
                Button {
                    SettingsStore.shared.setLocal(key: key, isLocal: false)
                } label: {
                    Label("iCloud 동기화", systemImage: "icloud")
                }
                Button {
                    SettingsStore.shared.setLocal(key: key, isLocal: true)
                } label: {
                    Text("로컬")
                }
            } label: {
                HStack(spacing: 4) {
                    if SettingsStore.shared.isLocal(key: key) {
                        Text("로컬")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("iCloud", systemImage: "icloud")
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
