import SwiftUI
import SwiftData

// MARK: - Onboarding View

/// 첫 실행 페르소나 초기 설정 화면.
/// isResetup = false: 전체화면(TodoListView fullScreenCover) — 건너뛰기 가능
/// isResetup = true : 설정 내 시트(PersonaSettingsView) — 재설정 모드
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \Persona.updatedAt, order: .reverse) private var personas: [Persona]
    @AppStorage("pieroot.todo.hasOnboarded") private var hasOnboarded = false


    @Binding var isPresented: Bool
    var isResetup: Bool = false

    @State private var step: Int
    @State private var tempICloudSync: Bool = false
    @State private var selectedTypes: Set<PersonaType> = []
    @State private var selectedPresets: Set<String> = []
    @State private var customText: String = ""
    @State private var syncSetupTask: Task<Void, Never>?
    @State private var isSettingUpSync = false
    @State private var syncSetupError: String?

    init(isPresented: Binding<Bool>, isResetup: Bool = false) {
        self._isPresented = isPresented
        self.isResetup = isResetup
        self._step = State(initialValue: isResetup ? 1 : 0)
    }

    // 선택된 모든 유형의 프리셋 합집합
    private var combinedPresets: [String] {
        Array(Set(selectedTypes.flatMap(\.presetDescriptions))).sorted()
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if step == 0 {
                    iCloudSyncStep
                } else if step == 1 {
                    typeSelectionStep
                } else {
                    descriptionStep
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .appScreenStyle()
            .navigationTitle(AppLanguage.localized(isResetup ? "페르소나 다시 설정" : "처음 오셨군요!", defaultValue: isResetup ? "페르소나 다시 설정" : "처음 오셨군요!", language: .current, comment: "Persona onboarding title."))
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .animation(AppTheme.motion(reduceMotion: reduceMotion), value: step)
            .task {
                // 재설정 모드: 유형 + 프리셋 칩 + 커스텀 텍스트 복원
                guard isResetup, let p = personas.first else { return }
                selectedTypes = Set(p.personaTypes)

                // descriptionText를 ". " 기준으로 분리해 프리셋 칩과 커스텀 텍스트 구분
                let allPresets = Set(selectedTypes.flatMap(\.presetDescriptions))
                let parts = p.descriptionText
                    .components(separatedBy: ". ")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                var restoredPresets = Set<String>()
                var customParts: [String] = []
                for part in parts {
                    if allPresets.contains(part) {
                        restoredPresets.insert(part)
                    } else {
                        customParts.append(part)
                    }
                }
                selectedPresets = restoredPresets
                customText = customParts.joined(separator: ". ")
            }
            .onDisappear {
                syncSetupTask?.cancel()
                if isSettingUpSync {
                    Task { try? await FullCloudSyncService.shared.setEnabled(false) }
                }
            }
        }
    }

    // MARK: - Step 0: 유형 선택

    private var typeSelectionStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("어떤 생활을 하고 계신가요?")
                    .font(.title2.bold())
                    .padding(.horizontal, 20)

                Text("중복 선택 가능합니다. 선택한 유형에 따라 AI가 할 일 우선순위를 더 정확하게 조정합니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: AppTheme.Spacing.item) {
                    ForEach(PersonaType.selectable, id: \.rawValue) { type in
                        typeCard(type)
                    }
                }
                .padding(.horizontal, 16)

                Button {
                    step = 2
                } label: {
                    Label("다음", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.compact)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.roundedRectangle(radius: AppTheme.controlRadius))
                .disabled(selectedTypes.isEmpty)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .padding(.vertical, 24)
        }
    }

    private func typeCard(_ type: PersonaType) -> some View {
        let isSelected = selectedTypes.contains(type)
        return Button {
            if isSelected { selectedTypes.remove(type) }
            else          { selectedTypes.insert(type) }
            selectedPresets = []
        } label: {
            VStack(spacing: AppTheme.Spacing.item) {
                Image(systemName: type.systemImage)
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text(type.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                isSelected ? AppTheme.neutralFill : AppTheme.surface,
                in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.accent)
                        .padding(AppTheme.Spacing.item)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Step 1: 자기소개

    private var descriptionStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 선택된 유형 배지 (다중)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(selectedTypes).sorted(by: { $0.displayName < $1.displayName }), id: \.rawValue) { type in
                            HStack(spacing: 6) {
                                Image(systemName: type.systemImage)
                                Text(type.displayName)
                            }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(AppTheme.insetSurface, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 20)
                }

                Text("나에 대해 조금 더 알려주세요")
                    .font(.title2.bold())
                    .padding(.horizontal, 20)

                Text("해당되는 항목을 선택하거나 직접 입력하세요. AI 우선순위 조정에 사용됩니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                // 프리셋 칩 (선택된 모든 유형의 합산)
                if !combinedPresets.isEmpty {
                    FlowLayout(combinedPresets) { preset in
                        presetChip(preset)
                    }
                    .padding(.horizontal, 20)
                }

                // 직접 입력
                VStack(alignment: .leading, spacing: 6) {
                    Text("직접 입력 (선택)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextField("예: 야간 대학원생, 프리랜서 병행 중…", text: $customText, axis: .vertical)
                        .lineLimit(3...5)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
                }
                .padding(.horizontal, 20)

                // 완료 버튼
                Button {
                    save()
                } label: {
                    Text(AppLanguage.localized(isResetup ? "action.save" : "시작하기", defaultValue: isResetup ? "저장" : "시작하기", language: .current, comment: "Complete persona onboarding."))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.compact)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.roundedRectangle(radius: AppTheme.controlRadius))
                .padding(.horizontal, 20)
                .padding(.top, 8)

                // 약관 동의 안내 (App Store 요건)
                Text("계속하면 [개인정보 처리방침](https://jung-geun.github.io/SIFT/privacy-policy.html)과 [서비스 약관](https://jung-geun.github.io/SIFT/terms-of-service.html)에 동의한 것으로 간주합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
            }
            .padding(.vertical, 24)
        }
    }

    private func presetChip(_ text: String) -> some View {
        let isSelected = selectedPresets.contains(text)
        return Button {
            if isSelected { selectedPresets.remove(text) }
            else          { selectedPresets.insert(text) }
        } label: {
            Text(text)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, AppTheme.Spacing.item)
                .background(
                    isSelected ? AppTheme.neutralFill : AppTheme.surface,
                    in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                )
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Step 0: iCloud Sync Setup

    private var iCloudSyncStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("데이터 동기화 설정")
                    .font(.title2.bold())
                    .padding(.horizontal, 20)
                
                Group {
                    if SettingsStore.supportsICloud {
                        Text(AppLanguage.localized("settings.sync.full.onboardingPrompt", defaultValue: "로컬 실행은 iCloud 없이도 사용할 수 있습니다. iCloud를 선택하면 메일·회의 녹음까지 포함한 앱 데이터를 같은 Apple 계정에서 저장·복원합니다. 다른 기기에는 Apple의 전송 완료 후 적용됩니다.", language: .current))
                    } else {
                        Text(AppLanguage.localized(
                            "settings.sync.unavailableMessage",
                            defaultValue: "이 빌드에서는 iCloud 동기화를 사용할 수 없습니다. 기존 데이터는 기기에만 보존됩니다.",
                            language: .current,
                            comment: "iCloud sync unavailable in this build."
                        ))
                    }
                }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                
                VStack(spacing: 16) {
                    // Option 1: iCloud Sync
                    Button {
                        guard SettingsStore.supportsICloud else { return }
                        tempICloudSync = true
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("iCloud 동기화 활성화", systemImage: "cloud.fill")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if tempICloudSync {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(AppTheme.accent)
                                }
                            }
                            Text(AppLanguage.localized("settings.sync.full.onboardingScope", defaultValue: "할 일·페르소나·분석·메일 본문·회의 음성/전사·루틴·학습 사전·설정·연결 정보를 저장합니다. 건강정보·OS 권한·재다운로드 가능한 모델 파일은 제외합니다. iCloud 키체인이 필요하며 ChatGPT 전송 동의와는 별개입니다.", language: .current))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .lineSpacing(4)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            tempICloudSync ? AppTheme.neutralFill : AppTheme.surface,
                            in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tempICloudSync ? .isSelected : [])
                    .disabled(!SettingsStore.supportsICloud)
                    .opacity(SettingsStore.supportsICloud ? 1 : 0.5)
                    
                    // Option 2: Local Only
                    Button {
                        tempICloudSync = false
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("이 기기에만 저장 (로컬)", systemImage: "folder")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if !tempICloudSync {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(AppTheme.accent)
                                }
                            }
                            if SettingsStore.supportsICloud {
                                Text("데이터를 클라우드에 업로드하지 않고 현재 기기에만 보관합니다. 추후 설정에서 언제든지 iCloud 동기화를 켤 수 있습니다.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .lineSpacing(4)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            !tempICloudSync ? AppTheme.neutralFill : AppTheme.surface,
                            in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(!tempICloudSync ? .isSelected : [])
                }
                .padding(.horizontal, 20)
                
                Button {
                    if SettingsStore.supportsICloud && tempICloudSync {
                        isSettingUpSync = true
                        syncSetupError = nil
                        syncSetupTask = Task {
                            defer { isSettingUpSync = false }
                            do {
                                try await FullCloudSyncService.shared.setEnabled(true)
                                hasOnboarded = true
                            } catch is CancellationError { }
                            catch { syncSetupError = FullCloudSyncService.shared.errorMessage }
                        }
                    } else {
                        step = 1
                    }
                } label: {
                    Text(AppLanguage.localized(SettingsStore.supportsICloud && tempICloudSync ? "iCloud 연동하고 시작하기" : "로컬 전용으로 다음 단계 진행", defaultValue: SettingsStore.supportsICloud && tempICloudSync ? "iCloud 연동하고 시작하기" : "로컬 전용으로 다음 단계 진행", language: .current, comment: "Continue onboarding with the chosen storage mode."))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.compact)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.roundedRectangle(radius: AppTheme.controlRadius))
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .disabled(isSettingUpSync)
                if isSettingUpSync { ProgressView().frame(maxWidth: .infinity) }
                if let syncSetupError {
                    Text(syncSetupError).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 24)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if step == 2 || (step == 1 && !isResetup) {
                Button("이전") { step -= 1 }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if !isResetup {
                Button("건너뛰기") { skip() }
                    .foregroundStyle(.secondary)
            } else {
                Button("취소") { isPresented = false }
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func save() {
        let persona = personas.first ?? {
            let p = Persona()
            modelContext.insert(p)
            return p
        }()

        persona.personaTypes = Array(selectedTypes)

        var parts: [String] = Array(selectedPresets).sorted()
        if !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(customText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !parts.isEmpty {
            persona.descriptionText = parts.joined(separator: ". ")
        }
        persona.updatedAt = Date()

        hasOnboarded = true
        isPresented = false
    }

    private func skip() {
        hasOnboarded = true
        isPresented = false
    }
}


#Preview {
    OnboardingView(isPresented: .constant(true))
        .modelContainer(for: [Todo.self, Persona.self], inMemory: true)
}
