import SwiftUI
import SwiftData

// 1. 나의 페르소나
struct PersonaDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appTutorialState) private var tutorial
    @ObservedObject private var regionalAvailability = OpenAIRegionalAvailability.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var connection = OpenAIConnection.shared
    @AppStorage(OpenAIPrivacy.consentKey(for: .persona)) private var allowsOpenAIPersona = false
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
    @State private var activeAdvancedSession: UUID?
    @State private var pendingAdvancedSession: UUID?
    
    private let generationService = PersonaGenerationService()

    private var canRequestAdvanced: Bool {
        regionalAvailability.isAvailable
            && SettingsStore.betaProviderAccess().openAIEnabled
            && connection.activeProfile != nil
    }

    private var canUsePendingResult: Bool {
        guard pendingAdvancedSession != nil || generationResult?.processorDescription.hasPrefix("OpenAI") == true else { return true }
        return canRequestAdvanced && allowsOpenAIPersona
            && pendingAdvancedSession == connection.sessionGeneration
    }
    
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
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                                ForEach(types, id: \.rawValue) { type in
                                    Label(type.displayName, systemImage: type.systemImage)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if !desc.isEmpty {
                            Text(desc)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
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
                                personas.first?.descriptionText.isEmpty ?? true ? AppLanguage.localized("persona.detail.generate", defaultValue: "Generate Persona", language: .current, comment: "Action generating a persona from behavior patterns.") : AppLanguage.localized("persona.detail.improve", defaultValue: "Update Persona", language: .current, comment: "Action improving an existing persona from behavior patterns."),
                                systemImage: "person.crop.circle.badge.checkmark"
                            )
                            .fontWeight(.medium)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isGenerating)
                    if canRequestAdvanced {
                        Button(AppLanguage.localized("memory.analysis.advancedRequest", defaultValue: "Analyze with gpt-6.1-sol", language: .current, comment: "Explicit advanced persona analysis request.")) {
                            showAdvancedRequest = true
                        }
                        .disabled(isGenerating)
                        .accessibilityIdentifier("persona.advancedRequest")
                    }
                    if isGenerating {
                        Button(AppLanguage.localized("memory.analysis.cancelRequest", defaultValue: "Cancel request", language: .current, comment: "Cancel persona analysis request."), role: .cancel) { generationTask?.cancel() }
                    }
                    
                    
                    if let result = generationResult,
                       canUsePendingResult {
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
                Text(AppLanguage.localized("persona.detail.evidenceSummary", defaultValue: "Uses local behavior records, consistent rules, and confidence levels.", language: .current, comment: "Local persona evidence and confidence boundary."))
            }
            if canRequestAdvanced {
                OpenAIConsentSection(scope: .persona)
            }
        }
        .appFormStyle()
        .navigationTitle("나의 페르소나")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 중복된 페르소나 정리
            todoApp.deduplicatePersonas(context: modelContext)
            
            if UserCloudSyncPolicy.isRequested,
               !(await FullCloudSyncService.shared.waitForInitialRestore()) { return }
            guard !Task.isCancelled else { return }
            if personas.isEmpty {
                let p = Persona()
                modelContext.insert(p)
            }
        }
        .onDisappear {
            generationTask?.cancel()
            tutorial?.handlePersonaDetailClosed()
        }
        .onChange(of: canRequestAdvanced) { _, available in
            if !available { invalidateAdvancedRequest() }
        }
        .onChange(of: connection.sessionGeneration) { _, _ in
            invalidateAdvancedRequest()
        }
        .onChange(of: allowsOpenAIPersona) { _, allowed in
            if !allowed { invalidateAdvancedRequest() }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
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
        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
            Text("페르소나 미리보기")
                .font(.headline)
            Text(result.processorDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                Text("현재")
                    .font(.subheadline.weight(.semibold))
                Text(existingTypes.map(\.displayName).joined(separator: ", ").isEmpty
                     ? AppLanguage.localized("persona.detail.noTypes", defaultValue: "No types selected", language: .current, comment: "Placeholder when no persona types are selected.")
                     : existingTypes.map(\.displayName).joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(existingDescription.isEmpty ? AppLanguage.localized("persona.detail.noDescription", defaultValue: "No description", language: .current, comment: "Placeholder when persona description is empty.") : existingDescription)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                Text("초안")
                    .font(.subheadline.weight(.semibold))
                Text(result.personaTypes.map(\.displayName).joined(separator: ", ").isEmpty
                     ? AppLanguage.localized("persona.detail.noTypes", defaultValue: "No types selected", language: .current, comment: "Placeholder when no persona types are selected.")
                     : result.personaTypes.map(\.displayName).joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(result.descriptionText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(
                "신뢰도: \(result.confidence.label(language: .current))",
                systemImage: "checkmark.seal"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !result.evidence.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                    Text("근거")
                        .font(.subheadline.weight(.semibold))
                    ForEach(result.evidence, id: \.self) { insight in
                        Text("• \(insight)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text(AppLanguage.localized("analysis.preview.applyNotice", defaultValue: "Nothing changes until you apply this preview.", language: .current, comment: "Analysis previews require manual application."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                Button("이 페르소나 사용") { applyGeneratedPersona() }

                Button("다시 생성") {
                    startGeneration()
                }

                Button("취소") { generationResult = nil }
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AppTheme.Spacing.compact)
    }
    
    private func invalidateAdvancedRequest() {
        showAdvancedRequest = false
        if activeAdvancedSession != nil {
            generationTask?.cancel()
        }
        if pendingAdvancedSession != nil || generationResult?.processorDescription.hasPrefix("OpenAI") == true {
            generationResult = nil
            pendingAdvancedSession = nil
        }
        showError = false
        errorMessage = nil
    }

    private func startGeneration(tier: OpenAIAnalysisTier = .basic) {
        guard !isGenerating, tier != .advanced || canRequestAdvanced else { return }
        generationTask?.cancel()
        let session = tier == .advanced ? connection.sessionGeneration : nil
        activeAdvancedSession = session
        generationTask = Task { await runGeneration(tier: tier, session: session) }
    }

    private func runGeneration(tier: OpenAIAnalysisTier = .basic, session: UUID? = nil) async {
        guard !Task.isCancelled, !isGenerating,
              tier != .advanced || (canRequestAdvanced && session == connection.sessionGeneration) else { return }
        isGenerating = true
        activeAdvancedSession = session
        defer {
            isGenerating = false
            activeAdvancedSession = nil
        }
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
            let result = try await generationService.generate(
                existingPersona: existing,
                todos: todos,
                context: context,
                now: now,
                tier: tier
            )
            try Task.checkCancellation()
            guard tier != .advanced || (canRequestAdvanced && allowsOpenAIPersona
                && session == connection.sessionGeneration) else { return }
            guard regionalAvailability.isAvailable || !result.processorDescription.hasPrefix("OpenAI") else { return }
            pendingAdvancedSession = session
            generationResult = result
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            if tier == .advanced,
               !canRequestAdvanced || session != connection.sessionGeneration { return }
            if !regionalAvailability.isAvailable,
               error is OpenAIRequestError || error is OpenAIConnectionError { return }
            errorMessage = error.localizedDescription
            showError = true
        }

    }
    private func applyGeneratedPersona() {
        guard let result = generationResult, let p = personas.first,
              canUsePendingResult else { return }
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
