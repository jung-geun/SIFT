import SwiftUI
import EventKit

// 5. 캘린더 설정
struct CalendarDetailView: View {
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("마감 자동 캘린더 등록", isOn: Binding(
                        get: { CalendarAutoPolicy.isAuto },
                        set: { newValue in
                            saveSetting(key: "pieroot.todo.calendarAutoRegister", value: newValue) { val in
                                let isLocal = !SettingsStore.supportsICloud || !iCloudSyncEnabled || SettingsStore.shared.isLocal(key: "pieroot.todo.calendarAutoRegister")
                                if isLocal {
                                    SettingsStore.shared.setLocal("pieroot.todo.calendarAutoChoiceMade", value: true)
                                } else {
                                    SettingsStore.shared.setGlobal("pieroot.todo.calendarAutoChoiceMade", value: true)
                                }
                            }
                        }
                    ))
                    .disabled(!CalendarService.shared.isAuthorized)
                }
                
                if !CalendarService.shared.isAuthorized {
                    Label("캘린더 권한이 필요합니다", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Picker("완료 시 처리", selection: settingsBinding(key: "pieroot.todo.calendarCompletionAction", defaultValue: "silence")) {
                        Text("이벤트 삭제").tag("remove")
                        Text("알람만 끄기").tag("silence")
                    }
                    .pickerStyle(.menu)
                    .disabled(!CalendarService.shared.isAuthorized)
                }
            } footer: {
                Text("마감 시각이 있는 모든 할 일(수동·이메일 모두)을 시스템 캘린더에 자동으로 등록합니다. 긴급·최우선 항목은 이 설정과 무관하게 항상 등록됩니다. '알람만 끄기'는 이벤트는 캘린더에 남기고 리마인더만 제거합니다.")
            }

            defaultCalendarSection
        }
        .navigationTitle("캘린더 설정")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 기본 캘린더 설정이 비어있으면 시스템 기본값 ID를 초기화
            if CalendarService.shared.isAuthorized
                && CalendarService.shared.defaultCalendarID.isEmpty,
               let sysDefault = CalendarService.shared.preferredDefaultCalendar {
                CalendarService.shared.defaultCalendarID = sysDefault.calendarIdentifier
            }
        }
    }

    @ViewBuilder
    private var defaultCalendarSection: some View {
        if CalendarService.shared.isAuthorized {
            Section {
                let currentID    = CalendarService.shared.defaultCalendarID
                let currentColor = CalendarPresentation.color(forCalendarID: currentID)
                let currentTitle: String = CalendarService.shared
                    .availableCalendars()
                    .flatMap { $0.calendars }
                    .first { $0.id == currentID }
                    .map { $0.title } ?? AppLanguage.localized("calendar.default", defaultValue: "Default", language: .current, comment: "Fallback display name when the default calendar cannot be found.")

                NavigationLink(destination: DefaultCalendarPickerView()) {
                    HStack(spacing: 10) {
                        Text("기본 캘린더")
                        Spacer()
                        Circle()
                            .fill(currentColor)
                            .frame(width: 10, height: 10)
                        Text(currentTitle)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("기본 캘린더")
            } footer: {
                Text("새 할 일·이벤트를 추가할 때 기본으로 사용할 캘린더입니다. 개별 추가 시 변경할 수 있습니다.")
            }
        }
    }

    private func saveSetting<T>(key: String, value: T, onChange: ((T) -> Void)? = nil) {
        let isLocal = !SettingsStore.supportsICloud || !iCloudSyncEnabled || SettingsStore.shared.isLocal(key: key)
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
}
