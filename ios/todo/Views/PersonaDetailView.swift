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
    @State private var generationTask: Task<Void, Never>?
    @State private var showAdvancedRequest = false
    
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
                        startGeneration()
                    } label: {
                        if isGenerating {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("행동 근거 분석 중…")
                            }
                        } else {
                            Label(
                                personas.first?.descriptionText.isEmpty ?? true ? AppLanguage.localized("persona.detail.generate", defaultValue: "Generate Pattern-Based Persona", language: .current, comment: "Action generating a persona from behavior patterns.") : AppLanguage.localized("persona.detail.improve", defaultValue: "Improve Pattern-Based Persona", language: .current, comment: "Action improving an existing persona from behavior patterns."),
                                systemImage: "person.crop.circle.badge.checkmark"
                            )
                            .fontWeight(.medium)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isGenerating)
                    Button(AppLanguage.localized("memory.analysis.advancedRequest", defaultValue: "Re-request with gpt-6.1-sol", language: .current, comment: "Explicit advanced persona analysis request.")) {
                        showAdvancedRequest = true
                    }
                    .disabled(isGenerating)
                    .accessibilityIdentifier("persona.advancedRequest")
                    if isGenerating {
                        Button(AppLanguage.localized("memory.analysis.cancelRequest", defaultValue: "Cancel request", language: .current, comment: "Cancel persona analysis request."), role: .cancel) { generationTask?.cancel() }
                    }
                    
                    
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
            OpenAIConsentSection(scope: .persona)
        }
        .navigationTitle("나의 페르소나")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 중복된 페르소나 정리
            todoApp.deduplicatePersonas(context: modelContext)
            
            // iCloud 활성화 시 CloudKit 동기화 도착을 최대 3초 대기한 뒤 Persona 생성
            let useICloud = SettingsStore.isICloudSyncEnabled
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
            generationTask?.cancel()
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
        .confirmationDialog(AppLanguage.localized("persona.detail.advancedConfirmation", defaultValue: "Send the persona and verified behavior evidence to OpenAI using gpt-6.1-sol?", language: .current, comment: "Confirmation before sharing persona and behavior evidence with OpenAI."), isPresented: $showAdvancedRequest, titleVisibility: .visible) {
            Button(AppLanguage.localized("memory.analysis.sendAdvanced", defaultValue: "Send advanced request", language: .current, comment: "Send advanced persona analysis request.")) { startGeneration(tier: .advanced) }
            Button(AppLanguage.localized("action.cancel", defaultValue: "Cancel", language: .current, comment: "Cancel action."), role: .cancel) {}
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
            Text(result.processorDescription).font(.caption2).foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("현재")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(existingTypes.map(\.displayName).joined(separator: ", ").isEmpty
                         ? AppLanguage.localized("persona.detail.noTypes", defaultValue: "No types selected", language: .current, comment: "Placeholder when no persona types are selected.")
                         : existingTypes.map(\.displayName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(existingDescription.isEmpty ? AppLanguage.localized("persona.detail.noDescription", defaultValue: "No description", language: .current, comment: "Placeholder when persona description is empty.") : existingDescription)
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
                         ? AppLanguage.localized("persona.detail.noTypes", defaultValue: "No types selected", language: .current, comment: "Placeholder when no persona types are selected.")
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
                    startGeneration()
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
    
    private func startGeneration(tier: OpenAIAnalysisTier = .basic) {
        guard !isGenerating else { return }
        generationTask?.cancel()
        generationTask = Task { await runGeneration(tier: tier) }
    }

    private func runGeneration(tier: OpenAIAnalysisTier = .basic) async {
        guard !isGenerating else { return }
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
                now: now,
                tier: tier
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            showError = true
        }

    }
    private func applyGeneratedPersona() {
        guard let result = generationResult, let p = personas.first else { return }
        do {
            if modelContext.hasChanges { try modelContext.save() }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            return
        }
        let previousTypes = p.personaTypes
        let previousDescription = p.descriptionText
        let previousDate = p.updatedAt
        p.personaTypes = result.personaTypes
        p.descriptionText = result.descriptionText
        p.updatedAt = Date()
        do {
            try modelContext.save()
            generationResult = nil
        } catch {
            p.personaTypes = previousTypes
            p.descriptionText = previousDescription
            p.updatedAt = previousDate
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
