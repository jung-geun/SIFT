import SwiftUI
import SwiftData

// 1. 나의 페르소나
struct PersonaDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appTutorialState) private var tutorial
    @Query(sort: \Persona.updatedAt, order: .reverse) private var personas: [Persona]
    @Query private var todos: [Todo]
    
    @State private var isGenerating = false
    @State private var generationResult: (personaText: String, insights: [String])?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showOnboardingResetup = false
    @State private var afmAvailable = false
    
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
                                Text("AI 분석 중…")
                            }
                        } else {
                            Label(
                                personas.first?.descriptionText.isEmpty ?? true ? "AI 페르소나 생성" : "AI 페르소나 개선",
                                systemImage: "sparkles"
                            )
                            .fontWeight(.medium)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isGenerating || !afmAvailable)
                    
                    if !afmAvailable {
                        Label("이 기기에서 Apple Foundation Models를 사용할 수 없습니다", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    
                    if let result = generationResult {
                        generationResultCard(result)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            } footer: {
                Text("생활 유형은 AI 키 없이도 할 일 우선순위에 즉시 반영됩니다. AI 페르소나 개선은 사용자의 패턴을 토대로 자동으로 점진적으로 개선합니다.")
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
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                afmAvailable = FoundationModelsService.isAvailable
            } else {
                afmAvailable = false
            }
            #else
            afmAvailable = false
            #endif
        }
        .onDisappear {
            tutorial?.handlePersonaDetailClosed()
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if let tutorial, let hint = tutorial.hint(for: .personaDetail) {
                AppTutorialHintCard(hint: hint)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
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
    private func generationResultCard(_ result: (personaText: String, insights: [String])) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("생성된 페르소나", systemImage: "checkmark.circle")
                .font(.subheadline.bold())
                .foregroundStyle(.green)
            
            Text(result.personaText)
                .font(.body)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            
            if !result.insights.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("발견된 패턴")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(result.insights, id: \.self) { insight in
                        Text("• \(insight)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
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
            let provider = SettingsStore.selectedProvider()
            let result = try await generationService.generate(
                existingPersona: existing,
                todos: todos,
                provider: provider
            )
            generationResult = result
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func applyGeneratedPersona() {
        guard let result = generationResult, let p = personas.first else { return }
        p.descriptionText = result.personaText
        p.updatedAt = Date()
        generationResult = nil
    }
}
