import SwiftUI
import SwiftData

// 1. 나의 페르소나
struct PersonaDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appTutorialState) private var tutorial
    @Query(sort: \Persona.updatedAt, order: .reverse) private var personas: [Persona]
    @Query private var todos: [Todo]
    @Query private var auditEvents: [TaskAuditEvent]
    @Query private var behaviorEvents: [TaskBehaviorEvent]
    
    @State private var isGenerating = false
    @State private var generationResult: PersonaRuleDraft?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showOnboardingResetup = false
    
    private let generationService = PersonaGenerationService()
    
    var body: some View {
        Form {
            Section {
                if let p = personas.first {
                    let types = p.personaTypes
                    let desc  = p.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if types.isEmpty && desc.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "person.circle")
                                .foregroundStyle(.secondary)
                            Text("아직 설정되지 않음")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        if !types.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(types, id: \.rawValue) { type in
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
                                .padding(.vertical, 2)
                            }
                        }
                        if !desc.isEmpty {
                            Text(desc)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 2)
                        }
                    }
                    
                    Button {
                        showOnboardingResetup = true
                    } label: {
                        Label("페르소나 다시 설정", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    
                    Button {
                        generationResult = nil
                        Task { await runGeneration() }
                    } label: {
                        if isGenerating {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("행동 근거 분석 중…")
                            }
                        } else {
                            Label(
                                personas.first?.descriptionText.isEmpty ?? true ? "패턴 기반 페르소나 생성" : "패턴 기반 페르소나 개선",
                                systemImage: "person.crop.circle.badge.checkmark"
                            )
                            .fontWeight(.medium)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isGenerating)
                    
                    
                    if let result = generationResult {
                        generationResultCard(
                            result,
                            existingDescription: desc,
                            existingTypes: types
                        )
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            } footer: {
                Text("최근 행동 기록을 결정론적으로 분석합니다. 모든 지원 기기에서 같은 근거, 계산 규칙, 신뢰도를 사용합니다.")
            }
        }
        .navigationTitle("나의 페르소나")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 중복된 페르소나 정리
            todoApp.deduplicatePersonas(context: modelContext)
            
            // iCloud 활성화 시 CloudKit 동기화 도착을 최대 3초 대기한 뒤 Persona 생성
            let useICloud = UserDefaults.standard.bool(forKey: todoApp.iCloudSyncKey)
            if personas.isEmpty && useICloud {
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if !personas.isEmpty { break }
                }
            }
            if personas.isEmpty {
                let p = Persona()
                modelContext.insert(p)
            }
        }
        .onDisappear {
            tutorial?.handlePersonaDetailClosed()
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if let tutorial {
                AppTutorialTipHost(tutorial: tutorial, screen: .personaDetail)
            }
        }
        .sheet(isPresented: $showOnboardingResetup) {
            OnboardingView(isPresented: $showOnboardingResetup, isResetup: true)
        }
        .alert("오류", isPresented: $showError, presenting: errorMessage) { _ in
            Button("확인", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }
    
    @ViewBuilder
    private func generationResultCard(
        _ result: PersonaRuleDraft,
        existingDescription: String,
        existingTypes: [PersonaType]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("페르소나 미리보기", systemImage: "person.crop.circle.badge.checkmark")
                .font(.subheadline.bold())
                .foregroundStyle(.green)

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("현재")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(existingTypes.map(\.displayName).joined(separator: ", ").isEmpty
                         ? "선택된 유형 없음"
                         : existingTypes.map(\.displayName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(existingDescription.isEmpty ? "설명 없음" : existingDescription)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 6) {
                    Text("초안")
                        .font(.caption.bold())
                        .foregroundStyle(.tint)
                    Text(result.personaTypes.map(\.displayName).joined(separator: ", ").isEmpty
                         ? "선택된 유형 없음"
                         : result.personaTypes.map(\.displayName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.tint)
                    Text(result.descriptionText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            Label(
                "신뢰도: \(result.confidence.label(language: .current))",
                systemImage: "checkmark.seal"
            )
            .font(.caption.bold())
            .foregroundStyle(.secondary)

            if !result.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("근거")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(result.evidence, id: \.self) { insight in
                        Text("• \(insight)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("적용하기 전에는 현재 설명과 유형이 변경되지 않습니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("이 페르소나 사용") { applyGeneratedPersona() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button("다시 생성") {
                    generationResult = nil
                    Task { await runGeneration() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("취소") { generationResult = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func runGeneration() async {
        isGenerating = true
        defer { isGenerating = false }
        do {
            let existing = personas.first?.descriptionText ?? ""
            let now = Date()
            let analysis = MemoryService.computeAnalysis(
                todos: todos,
                auditEvents: auditEvents,
                behaviorEvents: behaviorEvents,
                now: now,
                language: .current
            )
            let context = BehaviorAnalysisContextBuilder.make(
                todos: todos,
                auditEvents: auditEvents,
                behaviorEvents: behaviorEvents,
                now: now,
                calendar: Calendar.current,
                behaviorProfile: analysis.behaviorProfile,
                personaTypes: personas.first?.personaTypes ?? []
            )
            generationResult = try await generationService.generate(
                existingPersona: existing,
                todos: todos,
                context: context,
                now: now
            )
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }

    }
    private func applyGeneratedPersona() {
        guard let result = generationResult, let p = personas.first else { return }
        p.personaTypes = result.personaTypes
        p.descriptionText = result.descriptionText
        p.updatedAt = Date()
        generationResult = nil
    }
}
