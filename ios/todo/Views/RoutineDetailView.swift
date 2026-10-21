import SwiftUI
import SwiftData
import UIKit

struct RoutineDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var todos: [Todo]
    @ObservedObject private var store = RoutineStore.shared
    @ObservedObject private var regionalAvailability = OpenAIRegionalAvailability.shared
    @State private var now = Date()
    @State private var editingRoutine: LearnedRoutine?
    @State private var reviewingSuggestion: RoutineSuggestion?
    @State private var postponingSuggestion: RoutineSuggestion?
    @State private var errorMessage: String?
    @State private var confirmDeleteAll = false
    @State private var confirmRemote = false
    @State private var requestedTier: OpenAIAnalysisTier = .basic
    @State private var analysisTask: Task<Void, Never>?
    @State private var isAnalyzing = false
    @State private var narrative: RoutineNarrative?

    private var suggestions: [RoutineSuggestion] { store.suggestions(now: now, todos: todos) }

    var body: some View {
        Form {
            if !HealthHistoryReader.availableCategories.isEmpty || HealthRoutineStore.shared.hasLocalData {
            Section {
                NavigationLink {
                    HealthHistorySettingsView()
                } label: {
                    Label(HealthCopy.text("health.title", "Health & fitness history", "건강·운동 기록"), systemImage: "heart.text.square")
                }
                Text(HealthCopy.text("health.entry.explanation", "Connect real HealthKit history separately. Manual task checkoffs below are not health records.", "실제 HealthKit 기록을 별도로 연결합니다. 아래의 수동 할 일 완료 기록은 건강 기록이 아닙니다."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }

            Section {
                Toggle(copy("routines.learning.enabled", fallback: "루틴 학습·추천 허용"), isOn: Binding(
                    get: { store.isLearningEnabled }, set: { store.setLearningEnabled($0); now = Date() }
                ))
                .accessibilityIdentifier("routines.enabled")
                .fixedSize(horizontal: false, vertical: true)
                Button(copy("routines.analyze", fallback: "완료 기록에서 루틴 후보 분석")) { refresh() }
                    .disabled(!store.isLearningEnabled)
                    .accessibilityIdentifier("routines.analyze")
                Text(copy("routines.learning.explanation", fallback: "기기 내에서 최근 90일의 완료된 수동 할 일을 활동별 동일 제목으로 묶습니다. 최소 3일의 완료 기록이 필요합니다. 메일·회의·캘린더·등록 대기·삭제 기록은 제외합니다. 완료 시각은 실제 복약·운동·수면의 수행 시각이나 건강 상태가 아닙니다."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(copy("routines.records.title", fallback: "루틴 후보·확인된 루틴")) {
                if store.routines.isEmpty {
                    Text(copy("routines.records.empty", fallback: "아직 루틴 후보가 없습니다. 기록이 부족하거나 주기가 불규칙하면 추천을 만들지 않습니다."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(store.routines) { routine in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                        HStack {
                            Text(routine.title)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if routine.isConfirmed {
                                Image(systemName: "checkmark.seal")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(RoutineViewCopy.evidence(routine))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(RoutineViewCopy.format("routines.evidence.hours", fallback: "기록된 완료 시각: %@", routine.recordedCompletionHours.map { String(format: "%02d", locale: AppLanguage.current.locale, $0) }.joined(separator: ", ")))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(RoutineViewCopy.format("routines.evidence.nextOccurrence", fallback: "다음 발생 추정: %@", RoutineViewCopy.date(routine.nextOccurrence)))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(RoutineViewCopy.uncertainty(routine))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if routine.isSuppressed {
                            Text(copy("routines.suppressed", fallback: "반복 거절로 추천 중지됨 · 수정해서 다시 확인 가능"))
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                            Button(copy("routines.review", fallback: "확인·주기·시간 수정")) { editingRoutine = routine }
                                .accessibilityIdentifier("routines.review.\(routine.id.uuidString)")
                                .frame(minHeight: 44, alignment: .leading)
                            Button(copy("routines.delete", fallback: "삭제"), role: .destructive) {
                                do { try store.delete(routine.id); narrative = nil }
                                catch { errorMessage = RoutineViewCopy.errorMessage(error) }
                            }
                            .frame(minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, AppTheme.Spacing.compact)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("routines.record")
                }
            }

            Section(copy("routines.suggestions.title", fallback: "새 할 일 추천")) {
                if !store.isLearningEnabled {
                    Text(copy("routines.suggestions.disabled", fallback: "학습이 꺼져 있어 추천하지 않습니다. 저장 기록은 직접 삭제할 수 있습니다."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if suggestions.isEmpty {
                    Text(copy("routines.suggestions.empty", fallback: "확인된 신뢰 가능한 루틴의 새 발생분만 추천합니다. 이미 만든 할 일·거절한 발생분은 중복 제안하지 않습니다."))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(suggestions) { suggestion in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                        Text(suggestion.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(RoutineViewCopy.date(suggestion.preferredStart))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                            Button(copy("routines.suggestions.accept", fallback: "수락·일정 검토")) { reviewingSuggestion = suggestion }
                                .accessibilityIdentifier("routines.accept")
                                .frame(minHeight: 44, alignment: .leading)
                            Button(copy("routines.suggestions.postpone", fallback: "미루기")) { postponingSuggestion = suggestion }
                                .accessibilityIdentifier("routines.postpone")
                                .frame(minHeight: 44, alignment: .leading)
                            Button(copy("routines.suggestions.reject", fallback: "거절"), role: .destructive) { reject(suggestion) }
                                .accessibilityIdentifier("routines.reject")
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, AppTheme.Spacing.compact)
                }
            }

            if regionalAvailability.isAvailable {
                OpenAIConsentSection(scope: .routines)
                Section(copy("routines.remote.title", fallback: "OpenAI 해석 · 검토용 미리보기")) {
                    Button(copy("routines.remote.basic", fallback: "기초 해석 요청 · gpt-6-luna")) { requestRemote(.basic) }
                        .disabled(store.routines.isEmpty || isAnalyzing || !store.isLearningEnabled)
                        .accessibilityIdentifier("routines.basicRequest")
                    Button(copy("routines.remote.advanced", fallback: "고급 모델로 다시 요청 · gpt-6.1-sol")) { requestRemote(.advanced) }
                        .disabled(store.routines.isEmpty || isAnalyzing || !store.isLearningEnabled)
                        .accessibilityIdentifier("routines.advancedRequest")
                    if isAnalyzing {
                        ProgressView()
                        Button(copy("routines.remote.cancel", fallback: "요청 취소"), role: .cancel) { analysisTask?.cancel() }
                    }
                    if let narrative {
                        Text(narrative.modelID)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(narrative.summary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(narrative.observations, id: \.self) {
                            Text($0)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(copy("routines.remote.clear", fallback: "미리보기 지우기")) { self.narrative = nil }
                    }
                    Text(copy("routines.remote.explanation", fallback: "외부 해석은 저장된 주기·시간·신뢰도·확인 상태를 변경하거나 할 일을 만들지 않습니다. 고급 모델은 자동으로 재호출하지 않습니다."))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(copy("routines.feedback.title", fallback: "추천 피드백·삭제")) {
                let counts = store.feedback.reduce(into: (accepted: 0, rejected: 0, postponed: 0)) { counts, feedback in
                    switch feedback.action {
                    case .accepted: counts.accepted += 1
                    case .rejected: counts.rejected += 1
                    case .postponed: counts.postponed += 1
                    }
                }
                Text(RoutineViewCopy.format("routines.feedback.summary", fallback: "%1$@ · %2$@ · %3$@",
                    RoutineViewCopy.count("routines.feedback.accepted.count", counts.accepted, fallback: "수락 %lld건"),
                    RoutineViewCopy.count("routines.feedback.rejected.count", counts.rejected, fallback: "거절 %lld건"),
                    RoutineViewCopy.count("routines.feedback.postponed.count", counts.postponed, fallback: "미루기 %lld건")))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(store.feedback.suffix(20).reversed())) { feedback in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                        Text(RoutineViewCopy.feedbackLabel(feedback.action)).font(.subheadline.weight(.semibold))
                        Text(RoutineViewCopy.date(feedback.recordedAt)).font(.subheadline).foregroundStyle(.secondary)
                        if let applied = feedback.appliedTime {
                            Text(RoutineViewCopy.date(applied)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !store.pendingAcceptances.isEmpty {
                    Text(RoutineViewCopy.count("routines.feedback.pending", store.pendingAcceptances.count, fallback: "저장 결과를 확인 중인 수락 %lld건은 중복 생성하지 않습니다."))
                        .font(.subheadline).foregroundStyle(AppTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(copy("routines.deleteAll", fallback: "루틴·근거·피드백 모두 삭제"), role: .destructive) { confirmDeleteAll = true }
                    .accessibilityIdentifier("routines.deleteAll")
                Text(copy("routines.storage.explanation", fallback: "기기 내 보호된 파일에 저장하며, 전체 iCloud 저장에 동의하면 루틴·근거·피드백·수락 예약도 동기화합니다. 이미 승인해 만든 할 일은 따로 삭제해야 합니다. 삭제 후 다시 학습하려면 분석을 직접 실행해야 합니다."))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.errorMessage {
                Text(error)
                    .foregroundStyle(AppTheme.destructive)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .appFormStyle()
        .navigationTitle(copy("routines.title", fallback: "루틴 학습·추천"))
        .navigationBarTitleDisplayMode(.inline)
        .task { reconcile() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in reconcile() }
        .onDisappear { analysisTask?.cancel() }
        .onChange(of: regionalAvailability.isAvailable) { _, available in
            guard !available else { return }
            confirmRemote = false
            analysisTask?.cancel()
            narrative = nil
            errorMessage = nil
        }
        .sheet(item: $editingRoutine) { RoutineEditView(routine: $0) }
        .sheet(item: $reviewingSuggestion, onDismiss: { now = Date() }) { ScheduleApprovalView(suggestion: $0) }
        .sheet(item: $postponingSuggestion, onDismiss: { now = Date() }) { RoutinePostponeView(suggestion: $0) }
        .confirmationDialog(copy("routines.deleteAll.confirmation", fallback: "루틴과 피드백을 모두 삭제할까요?"), isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button(copy("routines.deleteAll.action", fallback: "모두 삭제"), role: .destructive) {
                analysisTask?.cancel()
                do { try store.deleteAll(); narrative = nil; now = Date() }
                catch { errorMessage = RoutineViewCopy.errorMessage(error) }
            }
        }
        .confirmationDialog(RoutineViewCopy.format("routines.remote.confirmation", fallback: "루틴 제목·완료 기록의 근거를 OpenAI %@로 보낼까요?", requestedTier.modelID), isPresented: $confirmRemote, titleVisibility: .visible) {
            Button(copy("routines.remote.confirm", fallback: "이 모델로 요청")) { analyzeRemote() }
            Button(copy("action.cancel", fallback: "취소"), role: .cancel) {}
        }
        .alert(copy("routines.error.title", fallback: "루틴 처리 오류"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(copy("action.ok", fallback: "확인"), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func reconcile() {
        now = Date()
        do { try store.reconcileAcceptances(todos: modelContext.fetch(FetchDescriptor<Todo>())) }
        catch { errorMessage = RoutineViewCopy.errorMessage(error) }
    }
    private func refresh() {
        do {
            if modelContext.hasChanges { try modelContext.save() }
            let live = try modelContext.fetch(FetchDescriptor<Todo>())
            try store.reconcileAcceptances(todos: live)
            now = Date()
            try store.refresh(todos: live, now: now)
            narrative = nil
        } catch { errorMessage = RoutineViewCopy.errorMessage(error) }
    }
    private func reject(_ suggestion: RoutineSuggestion) {
        do {
            try store.record(RoutineFeedback(routineID: suggestion.routineID, occurrence: suggestion.occurrence,
                                            action: .rejected, suggestedTime: suggestion.preferredStart))
            now = Date()
        } catch { errorMessage = RoutineViewCopy.errorMessage(error) }
    }
    private func requestRemote(_ tier: OpenAIAnalysisTier) {
        guard regionalAvailability.isAvailable else { return }
        requestedTier = tier
        confirmRemote = true
    }
    private func analyzeRemote() {
        guard regionalAvailability.isAvailable, !isAnalyzing, store.isLearningEnabled else { return }
        analysisTask?.cancel()
        let records = store.routines
        let tier = requestedTier
        analysisTask = Task {
            isAnalyzing = true
            defer { isAnalyzing = false }
            do {
                let result = try await OpenAIAnalysisService().routines(records, tier: tier)
                try Task.checkCancellation()
                guard regionalAvailability.isAvailable, store.isLearningEnabled, records == store.routines else { return }
                narrative = result
            } catch is CancellationError { }
            catch { if !Task.isCancelled, regionalAvailability.isAvailable { errorMessage = OpenAIViewCopy.errorMessage(error) } }
        }
    }
    private func copy(_ key: String, fallback: String) -> String { RoutineViewCopy.copy(key, fallback: fallback) }
}

private struct RoutineEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LearnedRoutine
    @State private var errorMessage: String?
    init(routine: LearnedRoutine) { _draft = State(initialValue: routine) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(copy("routines.edit.activity", fallback: "활동 제목"), text: $draft.title)
                    Stepper(RoutineViewCopy.count("routines.edit.period", draft.periodDays, fallback: "주기: %lld일"), value: $draft.periodDays, in: 1...90)
                    Stepper(RoutineViewCopy.format("routines.edit.hour", fallback: "선호 시: %lld", Int64(draft.preferredHour)), value: $draft.preferredHour, in: 0...23)
                    Stepper(RoutineViewCopy.format("routines.edit.minute", fallback: "선호 분: %lld", Int64(draft.preferredMinute)), value: $draft.preferredMinute, in: 0...59)
                    Stepper(RoutineViewCopy.count("routines.edit.duration", draft.estimatedDurationMinutes, fallback: "소요 시간: %lld분"), value: $draft.estimatedDurationMinutes, in: 1...1440)
                    DatePicker(copy("routines.edit.nextOccurrence", fallback: "다음 발생"), selection: $draft.nextOccurrence)
                        .environment(\.timeZone, TimeZone(identifier: draft.timeZoneIdentifier) ?? .current)
                    Text(draft.timeZoneIdentifier)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(copy("routines.edit.suppress", fallback: "추천 중지"), isOn: $draft.isSuppressed)
                }
                Section {
                    Text(copy("routines.edit.explanation", fallback: "완료 기록으로 추정한 주기·시각입니다. 실제 생활 활동이나 건강 상태를 확정하지 않습니다. 불규칙한 기록은 주기·선호 시각을 직접 수정해야 확인할 수 있습니다."))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(AppTheme.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(copy("routines.edit.save", fallback: "수정 내용 확인·저장")) {
                        do { try RoutineStore.shared.confirm(draft); dismiss() }
                        catch { errorMessage = RoutineViewCopy.errorMessage(error) }
                    }
                    .accessibilityIdentifier("routines.confirm")
                }
            }
            .appFormStyle()
            .navigationTitle(copy("routines.edit.title", fallback: "루틴 확인"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(copy("action.cancel", fallback: "취소")) { dismiss() } } }
        }
    }
    private func copy(_ key: String, fallback: String) -> String { RoutineViewCopy.copy(key, fallback: fallback) }
}

private struct RoutinePostponeView: View {
    let suggestion: RoutineSuggestion
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var errorMessage: String?
    init(suggestion: RoutineSuggestion) {
        self.suggestion = suggestion
        _date = State(initialValue: max(suggestion.preferredStart.addingTimeInterval(3600), Date().addingTimeInterval(3600)))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(suggestion.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    DatePicker(RoutineViewCopy.copy("routines.postpone.date", fallback: "미룰 시각"), selection: $date, in: Date()...)
                }
                Section {
                    Button(RoutineViewCopy.copy("routines.postpone.save", fallback: "미루기 저장")) {
                        do {
                            try RoutineStore.shared.record(RoutineFeedback(routineID: suggestion.routineID, occurrence: suggestion.occurrence,
                                                                           action: .postponed, suggestedTime: suggestion.preferredStart,
                                                                           appliedTime: date))
                            dismiss()
                        } catch { errorMessage = RoutineViewCopy.errorMessage(error) }
                    }
                    .accessibilityIdentifier("routines.savePostpone")
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(AppTheme.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .appFormStyle()
            .navigationTitle(RoutineViewCopy.copy("routines.postpone.title", fallback: "이번 발생분 미루기"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(RoutineViewCopy.copy("action.cancel", fallback: "취소")) { dismiss() } } }
        }
    }
}

// UI-only rendering: persisted evidence and feedback identifiers stay untranslated.
enum RoutineViewCopy {
    static func copy(_ key: String, fallback: String) -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current)
    }

    static func count(_ key: String, _ value: Int, fallback: String) -> String {
        AppLanguage.localizedCount(key, count: value, defaultValue: fallback, language: .current)
    }

    static func format(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        String(format: copy(key, fallback: fallback), locale: AppLanguage.current.locale, arguments: arguments)
    }

    static func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguage.current.locale))
    }

    private static func samples(_ routine: LearnedRoutine) -> String {
        count("routines.evidence.samples", routine.sampleCount, fallback: "기록된 완료 %lld건")
    }

    private static func days(_ routine: LearnedRoutine) -> String {
        count("routines.evidence.days", routine.distinctCompletionDays, fallback: "서로 다른 %lld일")
    }

    private static func confidence(_ routine: LearnedRoutine) -> String {
        format("routines.evidence.confidence", fallback: "신뢰도 %.0f%%", routine.confidence * 100)
    }

    static func evidence(_ routine: LearnedRoutine) -> String {
        format("routines.evidence.summary", fallback: "%1$@ · %2$@ / %3$@ · %4$@",
               count("routines.recurrence", routine.periodDays, fallback: "%lld일 간격"),
               samples(routine), days(routine), confidence(routine))
    }

    static func uncertainty(_ routine: LearnedRoutine) -> String {
        let caveat = routine.confidence < RoutineLearningService.minimumPredictionConfidence
            ? copy("routines.uncertainty.irregular", fallback: "주기가 불규칙합니다. 이 후보를 사용하기 전에 확인하고 수정하세요.")
            : copy("routines.uncertainty.review", fallback: "사용하기 전에 활동·주기·선호 시각을 확인하세요.")
        return format("routines.uncertainty.summary",
                      fallback: "%1$@, %2$@의 근거입니다. %3$@. 완료 시각은 실제 활동 시각이나 소요 시간을 증명하지 않습니다. %4$@",
                      samples(routine), days(routine), confidence(routine), caveat)
    }

    static func feedbackLabel(_ action: RoutineFeedback.Action) -> String {
        switch action {
        case .accepted: copy("routines.feedback.accepted", fallback: "수락")
        case .rejected: copy("routines.feedback.rejected", fallback: "거절")
        case .postponed: copy("routines.feedback.postponed", fallback: "미루기")
        }
    }


    static func errorMessage(_ error: Error) -> String {
        if let error = error as? RoutineStoreError { return error.errorDescription(language: .current) }
        if error is OpenAIRequestError || error is OpenAIConnectionError {
            return OpenAIViewCopy.errorMessage(error)
        }
        return copy("routines.error.operationFailed", fallback: "루틴 처리를 완료하지 못했습니다. 다시 시도하세요.")
    }
}
