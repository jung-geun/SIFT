import SwiftUI

struct PersonaSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTutorialState) private var tutorial
    @EnvironmentObject private var appUpdate: AppUpdateService
    @State private var languageOverrideRaw = AppLanguage.userOverride?.rawValue ?? ""
    @State private var selectedAppLanguage = AppLanguage.current
    @State private var showsAdvancedSettings = false
    var body: some View {
        Form {
            Section {
                NavigationLink(destination: EmailDetailView()) {
                    Label("이메일 연동", systemImage: "envelope")
                        .appTutorialGlow(tutorial?.currentStep == .emailOptional)
                }
                NavigationLink(destination: CalendarDetailView()) {
                    Label("캘린더 설정", systemImage: "calendar")
                }
                NavigationLink(destination: ICloudSyncDetailView()) {
                    Label("iCloud 동기화", systemImage: "icloud")
                }
                NavigationLink(destination: RoutineDetailView()) {
                    Label(copy("routines.title", fallback: "루틴 학습·추천"), systemImage: "repeat")
                }
                .accessibilityIdentifier("settings.routinesRow")
                NavigationLink(destination: OpenAISettingsView()) {
                    Label(copy("openai.title", fallback: "OpenAI · ChatGPT"), systemImage: "person.crop.circle.badge.checkmark")
                }
                .accessibilityIdentifier("settings.openAIRow")
            }
            Section {
                NavigationLink(destination: SystemStatusDetailView()) {
                    Label("시스템 권한 및 상태", systemImage: "shield")
                        .appTutorialGlow(tutorial?.currentStep == .permissions)
                }
                NavigationLink(destination: AppInfoDetailView()) {
                    HStack {
                        Label("앱 정보", systemImage: "info.circle")
                        Spacer()
                        if appUpdate.hasUpdate {
                            Text("업데이트 가능")
                                .font(.caption)
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                }
                .accessibilityIdentifier("settings.appInfoRow")
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
            }
            Section {
                DisclosureGroup(isExpanded: $showsAdvancedSettings) {
                    NavigationLink(destination: PersonaDetailView()) {
                        Label("나의 페르소나", systemImage: "person.circle")
                            .appTutorialGlow(tutorial?.currentStep == .persona)
                    }
                    NavigationLink(destination: MemoryDetailView()) {
                        Label("행동 패턴 분석", systemImage: "brain.head.profile")
                    }
                    NavigationLink(destination: VocabularyDetailView()) {
                        Label("사용자 단어장", systemImage: "text.book.closed")
                    }
                    .accessibilityIdentifier("settings.vocabularyRow")
                    NavigationLink(destination: IntelligenceDetailView()) {
                        Label("TODO 우선순위 규칙", systemImage: "slider.horizontal.3")
                            .appTutorialGlow(tutorial?.currentStep == .priorityRules)
                    }
                    NavigationLink(destination: BetaFeaturesView()) {
                        Label("베타 기능", systemImage: "testtube.2")
                    }
                    .accessibilityIdentifier("settings.betaFeaturesRow")
                } label: {
                    Label(copy("settings.advanced", fallback: "고급 설정"), systemImage: "slider.horizontal.3")
                        .accessibilityIdentifier("settings.advanced")
                }
            }

        }
        .environment(\.locale, selectedAppLanguage.locale)
        .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { _ in
            selectedAppLanguage = AppLanguage.current
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if let tutorial {
                AppTutorialTipHost(tutorial: tutorial, screen: .settings)
            }
        }
        .navigationTitle(copy("settings.title", fallback: "설정"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(copy("action.close", fallback: "닫기")) { dismiss() }
                    .accessibilityIdentifier("settings.closeButton")
            }
        }
        .onAppear { revealTutorialSettings() }
        .onChange(of: tutorial?.currentStep) { _, _ in revealTutorialSettings() }
    }

    private func copy(_ key: String, fallback: String) -> String {
        AppLanguage.localized(
            key,
            defaultValue: fallback,
            language: selectedAppLanguage,
            comment: "Settings localization copy."
        )
    }

    private func revealTutorialSettings() {
        if tutorial?.currentStep == .persona || tutorial?.currentStep == .priorityRules {
            showsAdvancedSettings = true
        }
    }
}
