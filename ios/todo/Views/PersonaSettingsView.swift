import SwiftUI

struct PersonaSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTutorialState) private var tutorial
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @ObservedObject private var settingsStore = SettingsStore.shared
    @State private var languageOverrideRaw = AppLanguage.userOverride?.rawValue ?? ""
    @State private var selectedAppLanguage = AppLanguage.current
    var body: some View {
        Form {
            Section {
                NavigationLink(destination: PersonaDetailView()) {
                    Label("나의 페르소나", systemImage: "person.circle")
                }
                NavigationLink(destination: MemoryDetailView()) {
                    Label("행동 패턴 분석", systemImage: "brain.head.profile")
                }

                NavigationLink(destination: VocabularyDetailView()) {
                    Label("사용자 단어장", systemImage: "text.book.closed")
                }
                .accessibilityIdentifier("settings.vocabularyRow")
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
            Section {
                Picker(
                    copy("settings.language.label", fallback: "앱 언어"),
                    selection: $languageOverrideRaw
                ) {
                    Text(copy("settings.language.system", fallback: "시스템 언어"))
                        .tag("")
                    ForEach(AppLanguage.supported) { language in
                        Text(language.displayName)
                            .tag(language.rawValue)
                    }
                }
                .onChange(of: languageOverrideRaw) { _, rawValue in
                    let language = AppLanguage.supported.first { $0.rawValue == rawValue }
                    AppLanguage.setUserOverride(language)
                }
                .accessibilityIdentifier("settings.languagePicker")
            } header: {
                Text(copy("settings.language.section", fallback: "언어"))
            } footer: {
                Text(copy(
                    "settings.language.footer",
                    fallback: "기본값은 시스템 언어입니다. 앱에서 선택한 언어는 이 기기에만 적용됩니다."
                ))
            }

            Section {
                Toggle("베타 기능", isOn: settingsBinding(
                    key: SettingsStore.betaFeaturesKey,
                    defaultValue: false
                ))
            } footer: {
                Text("검증 중인 기능을 사용자가 직접 선택할 수 있게 합니다. 회의 음성 노이즈 감소는 베타 기능을 켠 뒤 회의 화면에서 선택할 수 있습니다.")
            }
        }
        .environment(\.locale, selectedAppLanguage.locale)
        .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { _ in
            selectedAppLanguage = AppLanguage.current
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if let tutorial, let hint = tutorial.hint(for: .settings) {
                AppTutorialHintCard(hint: hint)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .navigationTitle(copy("settings.title", fallback: "설정"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(copy("action.close", fallback: "닫기")) { dismiss() }
            }
        }
        .task {
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: "pieroot.todo.didMigrateToUnifiedAI") {
                defaults.set(true, forKey: "pieroot.todo.didMigrateToUnifiedAI")

            }
        }
    }

    private func copy(_ key: String, fallback: String) -> String {
        AppLanguage.localized(
            key,
            defaultValue: fallback,
            language: selectedAppLanguage,
            comment: "Settings localization copy."
        )
    }

    private func settingsBinding<T>(key: String, defaultValue: T) -> Binding<T> {
        Binding(
            get: {
                SettingsStore.shared.get(key, defaultValue: defaultValue)
            },
            set: { newValue in
                SettingsStore.shared.set(key, value: newValue)
            }
        )
    }
}
