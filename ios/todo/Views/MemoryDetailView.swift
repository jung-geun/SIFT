import SwiftUI
import SwiftData

// 2. 행동 패턴 분석
struct MemoryDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var regionalAvailability = OpenAIRegionalAvailability.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var connection = OpenAIConnection.shared
    @AppStorage(OpenAIPrivacy.consentKey(for: .routines)) private var allowsOpenAIRoutines = false
    @Query private var todos: [Todo]
    @Query private var auditEvents: [TaskAuditEvent]
    @Query private var behaviorEvents: [TaskBehaviorEvent]
    @Query(sort: \MemoryAnalysis.createdAt, order: .reverse) private var analyses: [MemoryAnalysis]
    
    @State private var isAnalyzing = false
    @State private var pendingMemoryResult: MemoryAnalysisResult?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var analysisTask: Task<Void, Never>?
    @State private var showAdvancedRequest = false
    @State private var activeAdvancedSession: UUID?
    @State private var pendingAdvancedSession: UUID?
    
    private var canRequestAdvanced: Bool {
        regionalAvailability.isAvailable
            && SettingsStore.betaProviderAccess().openAIEnabled
            && connection.activeProfile != nil
    }

    private var canUsePendingResult: Bool {
        guard pendingAdvancedSession != nil || pendingMemoryResult?.processorDescription.hasPrefix("OpenAI") == true else { return true }
        return canRequestAdvanced && allowsOpenAIRoutines
            && pendingAdvancedSession == connection.sessionGeneration
    }
    
    var body: some View {
        Form {
            Section {
                if pendingMemoryResult == nil, analyses.isEmpty {
                    Text("아직 분석 데이터가 없습니다. 할 일을 완료한 후 분석을 실행하세요.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                if let result = pendingMemoryResult,
                   canUsePendingResult {
                    memoryAnalysisResultCard(result)
                }
                
                Button {
                    startAnalysis()
                } label: {
                    if isAnalyzing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(AppLanguage.localized(
                                "memory.analysis.progress",
                                defaultValue: "행동 패턴 분석 중…",
                                language: .current,
                                comment: "Behavior-pattern analysis progress."
                            ))
                        }
                    } else {
                        Label(AppLanguage.localized(pendingMemoryResult == nil ? "지금 패턴 분석" : "다시 분석", defaultValue: pendingMemoryResult == nil ? "지금 패턴 분석" : "다시 분석", language: .current, comment: "Start or repeat behavior analysis."), systemImage: "chart.bar.xaxis")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isAnalyzing)
                if canRequestAdvanced {
                    Button(AppLanguage.localized(
                        "memory.analysis.advancedRequest",
                        defaultValue: "Analyze with gpt-6.1-sol",
                        language: .current,
                        comment: "Button to explicitly re-request behavior analysis using gpt-6.1-sol. Keep the model name unchanged."
                    )) { showAdvancedRequest = true }
                        .disabled(isAnalyzing)
                        .accessibilityIdentifier("memory.advancedRequest")
                }
                if isAnalyzing {
                    Button(AppLanguage.localized(
                        "memory.analysis.cancelRequest",
                        defaultValue: "요청 취소",
                        language: .current,
                        comment: "Cancel the currently running behavior-analysis request."
                    ), role: .cancel) { analysisTask?.cancel() }
                }
            } footer: {
                Text(AppLanguage.localized(
                    "memory.analysis.footer.local",
                    defaultValue: "Uses local task records from the last 90 days. Completion times do not prove an activity happened. Apply to save; review routine suggestions in Routines.",
                    language: .current,
                    comment: "Local behavior evidence, activity-evidence limit, manual application, and separate routine review."
                ))
            }
            if canRequestAdvanced {
                OpenAIConsentSection(scope: .routines)
            }

            Section {
                if analyses.isEmpty {
                    Text("아직 저장된 분석이 없습니다.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(analyses) { analysis in
                        savedAnalysisCard(analysis)
                    }
                }
            } header: {
                Text("저장된 분석")
            }
        }
        .appFormStyle()
        .navigationTitle("행동 패턴 분석")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { analysisTask?.cancel() }
        .onChange(of: canRequestAdvanced) { _, available in
            if !available { invalidateAdvancedRequest() }
        }
        .onChange(of: connection.sessionGeneration) { _, _ in
            invalidateAdvancedRequest()
        }
        .onChange(of: allowsOpenAIRoutines) { _, allowed in
            if !allowed { invalidateAdvancedRequest() }
        }
        .confirmationDialog(AppLanguage.localized(
            "memory.analysis.advancedConfirmation",
            defaultValue: "결정론적 행동 통계를 OpenAI의 gpt-6.1-sol로 보낼까요?",
            language: .current,
            comment: "Confirmation before sharing deterministic behavior statistics with OpenAI for an advanced request. Keep the model name unchanged."
        ), isPresented: $showAdvancedRequest, titleVisibility: .visible) {
            Button(AppLanguage.localized(
                "memory.analysis.sendAdvanced",
                defaultValue: "고급 분석 요청",
                language: .current,
                comment: "Confirm sending the advanced behavior-analysis request."
            )) { startAnalysis(tier: .advanced) }
            Button(AppLanguage.localized(
                "action.cancel",
                defaultValue: "취소",
                language: .current,
                comment: "Dismiss the advanced behavior-analysis confirmation without sending a request."
            ), role: .cancel) {}
        }
        .alert("분석 오류", isPresented: $showError) {
            Button("확인", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    @ViewBuilder
    private func memoryAnalysisResultCard(_ result: MemoryAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
            Text("새 분석 결과")
                .font(.headline)
            Text(result.processorDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(
                format: AppLanguage.localized(
                    "memory.analysis.evidence.window",
                    defaultValue: "%2$@ · 근거 %1$lld건 · %3$@~%4$@",
                    language: .current,
                    comment: "Preview evidence line: %1$lld is the evidence-record count (not completed activities), %2$@ is the confidence label, and %3$@/%4$@ are the formatted start/end dates. Plural selection uses the first argument. Positional placeholders may be reordered."
                ),
                locale: AppLanguage.current.locale,
                Int64(result.behaviorProfile.sampleCount),
                result.behaviorProfile.confidence.label,
                result.behaviorProfile.windowStart.formatted(date: .abbreviated, time: .omitted),
                result.behaviorProfile.windowEnd.formatted(date: .abbreviated, time: .omitted)
            ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            if !result.summary.isEmpty {
                Text(result.summary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            if !result.insights.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                    Text("발견된 패턴")
                        .font(.subheadline.weight(.semibold))
                    ForEach(result.insights, id: \.self) { insight in
                        Text("• \(insight)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                Button("적용") {
                    Task { await applyMemoryAnalysis() }
                }

                Button("다시 분석") {
                    startAnalysis()
                }

                Button("취소") { pendingMemoryResult = nil }
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AppTheme.Spacing.compact)
    }
    
    @ViewBuilder
    private func savedAnalysisCard(_ analysis: MemoryAnalysis) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                Text(analysis.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !analysis.processorDescription.isEmpty,
                   regionalAvailability.isAvailable || !analysis.processorDescription.hasPrefix("OpenAI") {
                    Text(analysis.processorDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                    Text(String(
                        format: AppLanguage.localized(
                            "memory.analysis.evidence.count",
                            defaultValue: "%2$@ · 근거 %1$lld건",
                            language: .current,
                            comment: "Saved analysis evidence line: %1$lld is the evidence-record count, not a count of completed activities, and %2$@ is the confidence label. Plural selection uses the first argument. Positional placeholders may be reordered."
                        ),
                        locale: AppLanguage.current.locale,
                        Int64(analysis.sampleCount),
                        analysis.confidence.label
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !analysis.summary.isEmpty {
                Text(analysis.summary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !analysis.insights.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                    ForEach(analysis.insights, id: \.self) { insight in
                        Text("• \(insight)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Button("삭제", role: .destructive) {
                MemoryService.shared.deleteAnalysis(analysis, context: modelContext)
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AppTheme.Spacing.compact)
    }

    private func invalidateAdvancedRequest() {
        showAdvancedRequest = false
        if activeAdvancedSession != nil {
            analysisTask?.cancel()
        }
        if pendingAdvancedSession != nil || pendingMemoryResult?.processorDescription.hasPrefix("OpenAI") == true {
            pendingMemoryResult = nil
            pendingAdvancedSession = nil
        }
        showError = false
        errorMessage = nil
    }

    private func startAnalysis(tier: OpenAIAnalysisTier = .basic) {
        guard !isAnalyzing, tier != .advanced || canRequestAdvanced else { return }
        analysisTask?.cancel()
        let session = tier == .advanced ? connection.sessionGeneration : nil
        activeAdvancedSession = session
        analysisTask = Task { await analyzeMemory(tier: tier, session: session) }
    }

    private func analyzeMemory(tier: OpenAIAnalysisTier = .basic, session: UUID? = nil) async {
        guard !Task.isCancelled, !isAnalyzing,
              tier != .advanced || (canRequestAdvanced && session == connection.sessionGeneration) else { return }
        isAnalyzing = true
        defer {
            isAnalyzing = false
            activeAdvancedSession = nil
        }

        do {
            let result = try await MemoryService.shared.analyzeForegroundPreview(
                todos: todos,
                auditEvents: auditEvents,
                behaviorEvents: behaviorEvents,
                tier: tier
            )
            try Task.checkCancellation()
            guard tier != .advanced || (canRequestAdvanced && allowsOpenAIRoutines
                && session == connection.sessionGeneration) else { return }
            guard regionalAvailability.isAvailable || !result.processorDescription.hasPrefix("OpenAI") else { return }
            if !result.summary.isEmpty || !result.insights.isEmpty {
                pendingAdvancedSession = session
                pendingMemoryResult = result
            }
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
    
    private func applyMemoryAnalysis() async {
        guard let result = pendingMemoryResult,
              canUsePendingResult else { return }
        do {
            try await MemoryService.shared.applyAnalysisResult(result)
            pendingMemoryResult = nil
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
