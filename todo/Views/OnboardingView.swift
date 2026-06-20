import SwiftUI
import SwiftData

// MARK: - Onboarding View

/// 첫 실행 페르소나 초기 설정 화면.
/// isResetup = false: 전체화면(TodoListView fullScreenCover) — 건너뛰기 가능
/// isResetup = true : 설정 내 시트(PersonaSettingsView) — 재설정 모드
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var personas: [Persona]
    @AppStorage("pieroot.todo.hasOnboarded") private var hasOnboarded = false

    @Binding var isPresented: Bool
    var isResetup: Bool = false

    @State private var step: Int = 0
    @State private var selectedTypes: Set<PersonaType> = []
    @State private var selectedPresets: Set<String> = []
    @State private var customText: String = ""

    // 선택된 모든 유형의 프리셋 합집합
    private var combinedPresets: [String] {
        Array(Set(selectedTypes.flatMap(\.presetDescriptions))).sorted()
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if step == 0 {
                    typeSelectionStep
                } else {
                    descriptionStep
                }
            }
            .navigationTitle(isResetup ? "페르소나 다시 설정" : "처음 오셨군요!")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .animation(.easeInOut(duration: 0.25), value: step)
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

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(PersonaType.selectable, id: \.rawValue) { type in
                        typeCard(type)
                    }
                }
                .padding(.horizontal, 16)

                Button {
                    withAnimation { step = 1 }
                } label: {
                    Label("다음", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            selectedTypes.isEmpty ? Color.gray.opacity(0.3) : Color.accentColor,
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .foregroundStyle(selectedTypes.isEmpty ? Color.secondary : .white)
                        .fontWeight(.semibold)
                }
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
            withAnimation(.spring(duration: 0.2)) {
                if isSelected { selectedTypes.remove(type) }
                else          { selectedTypes.insert(type) }
                selectedPresets = []
            }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: type.systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(isSelected ? .white : Color.accentColor)
                Text(type.displayName)
                    .font(.subheadline.bold())
                    .foregroundStyle(isSelected ? .white : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                isSelected ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.clear : Color(.separator), lineWidth: 1)
            )
            .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : .clear, radius: 6, y: 3)
        }
        .buttonStyle(.plain)
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
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
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
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 20)

                // 완료 버튼
                Button {
                    save()
                } label: {
                    Text(isResetup ? "저장" : "시작하기")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .padding(.vertical, 24)
        }
    }

    private func presetChip(_ text: String) -> some View {
        let isSelected = selectedPresets.contains(text)
        return Button {
            withAnimation(.spring(duration: 0.15)) {
                if isSelected { selectedPresets.remove(text) }
                else          { selectedPresets.insert(text) }
            }
        } label: {
            Text(text)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isSelected ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? .white : .primary)
                .overlay(Capsule().stroke(isSelected ? Color.clear : Color(.separator), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if step == 1 {
                Button("이전") { withAnimation { step = 0 } }
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
