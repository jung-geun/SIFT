import SwiftUI
import SwiftData

struct HealthHistorySettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var store = HealthRoutineStore.shared
    @State private var operationTask: Task<Void, Never>?
    @State private var selectedCandidate: HealthRoutineCandidate?
    @State private var showAutoCreateConsent = false
    @State private var showEraseConfirmation = false
    @State private var showResetConfirmation = false
    @State private var mutationError: String?

    var body: some View {
        Form {
            if !HealthHistoryReader.availableCategories.isEmpty {
            Section {
                Text(HealthCopy.text("health.history.disclosure", "Read up to the latest 90 days of workout or medication history, independently for each category. Only approved sources can produce routine suggestions; nothing is enabled until you review and confirm it.", "운동 또는 복약 기록을 각 항목별로 최근 최대 90일까지만 읽습니다. 승인한 출처만 루틴을 제안하며, 직접 검토하고 확정하기 전에는 활성화되지 않습니다."))
                    .fixedSize(horizontal: false, vertical: true)
                Text(HealthCopy.text("health.privacy.local", "Raw history and routine candidates stay on this device in protected storage excluded from backups. They never sync and are not sent to OpenAI. This feature does not write to HealthKit or calendars, or schedule notifications.", "원본 기록과 루틴 후보는 백업에서 제외된 보호 저장소에 기기 내에서만 보관됩니다. 동기화하거나 OpenAI로 보내지 않습니다. 이 기능은 HealthKit·캘린더에 쓰거나 알림을 예약하지 않습니다."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(HealthHistoryReader.availableCategories) { category in
                categorySection(category)
            }

            Section {
                if store.isRefreshing {
                    ProgressView(HealthCopy.text("health.refresh.progress", "Reading health history…", "건강 기록 읽는 중…"))
                    Button(HealthCopy.text("health.refresh.cancel", "Cancel reading", "기록 읽기 취소"), role: .cancel) {
                        cancelWork()
                    }
                } else {
                    Button {
                        startWork { await store.refresh(context: modelContext) }
                    } label: {
                        Label(HealthCopy.text("health.refresh", "Refresh history and create eligible tasks", "기록 새로고침 및 조건에 맞는 할 일 생성"), systemImage: "arrow.clockwise")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(!store.states.values.contains(where: { $0.isConnected }))
                    .accessibilityIdentifier("health.refresh")
                }
                Text(HealthCopy.text("health.refresh.explanation", "After confirming a routine or enabling automatic creation, refresh to create its next future occurrence. Foreground refresh can also create it. At most one next occurrence per routine is created per refresh; past occurrences are not backfilled.", "루틴 확정 또는 자동 생성 활성화 후 새로고침하면 다음 미래 일정의 할 일을 생성합니다. 앱을 다시 사용할 때의 새로고침에서도 생성될 수 있습니다. 새로고침마다 루틴별 다음 일정 하나만 생성하며 과거 일정은 소급 생성하지 않습니다."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("health.error")
                }
            }

            Section {
                Text(Self.syncDisclosure)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(HealthCopy.text("health.autoCreate", "Automatically create tasks from confirmed routines", "확정한 루틴에서 할 일 자동 생성"), isOn: Binding(
                    get: { store.autoCreateEnabled },
                    set: { enabled in
                        if enabled { showAutoCreateConsent = true }
                        else { mutate { try store.setAutoCreateEnabled(false) } }
                    }
                ))
                .accessibilityIdentifier("health.autoCreate")
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(HealthCopy.text("health.creation.section", "Task creation and sync", "할 일 생성 및 동기화"))
            }
            }

            if !store.candidates.isEmpty {
            Section {
                ForEach(store.candidates) { candidate in
                    candidateRow(candidate)
                }
            } header: {
                Text(HealthCopy.text("health.candidates.section", "Evidence-based routine suggestions", "기록에 근거한 루틴 제안"))
            }
            }

            if !HealthHistoryReader.availableCategories.isEmpty || store.hasLocalData {
            Section {
                Button(HealthCopy.text("health.erase", "Erase local health history", "로컬 건강 기록 지우기"), role: .destructive) {
                    showEraseConfirmation = true
                }
                Button(HealthCopy.text("health.reset", "Reset all health data and duplicate prevention", "모든 건강 데이터 및 중복 방지 기록 초기화"), role: .destructive) {
                    showResetConfirmation = true
                }
            } header: {
                Text(HealthCopy.text("health.data.section", "Local data controls", "로컬 데이터 관리"))
            } footer: {
                Text(Self.eraseDisclosure)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
        }
        .appFormStyle()
        .navigationTitle(HealthCopy.text("health.title", "Health & fitness history", "건강·운동 기록"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedCandidate) { candidate in
            HealthRoutineReviewSheet(candidate: candidate, store: store)
        }
        .alert(
            HealthCopy.text("health.autoCreate.confirm.title", "Allow automatic task creation?", "할 일 자동 생성을 허용할까요?"),
            isPresented: $showAutoCreateConsent
        ) {
            Button(HealthCopy.text("health.autoCreate.confirm.action", "Allow automatic creation", "자동 생성 허용")) {
                mutate { try store.setAutoCreateEnabled(true) }
            }
            Button(Self.cancelTitle, role: .cancel) {}
        } message: {
            Text(Self.syncDisclosure)
        }
        .alert(
            HealthCopy.text("health.erase.confirm.title", "Erase local health history?", "로컬 건강 기록을 지울까요?"),
            isPresented: $showEraseConfirmation
        ) {
            Button(HealthCopy.text("health.erase", "Erase local health history", "로컬 건강 기록 지우기"), role: .destructive) {
                cancelWork()
                mutate { try store.eraseHistory() }
            }
            Button(Self.cancelTitle, role: .cancel) {}
        } message: {
            Text(Self.eraseDisclosure)
        }
        .alert(
            HealthCopy.text("health.reset.confirm.title", "Also delete duplicate-prevention history?", "중복 방지 기록도 삭제할까요?"),
            isPresented: $showResetConfirmation
        ) {
            Button(HealthCopy.text("health.reset.confirm.action", "Reset everything, including duplicate prevention", "중복 방지 기록을 포함해 모두 초기화"), role: .destructive) {
                cancelWork()
                mutate { try store.resetAll() }
            }
            Button(Self.cancelTitle, role: .cancel) {}
        } message: {
            Text(HealthCopy.text("health.reset.warning", "This stops connections and automatic-creation consent, and deletes all local health history, candidates, and nonclinical duplicate-prevention markers. Existing generated tasks remain. After reconnecting, approving sources, confirming routines, and allowing creation again, previously consumed occurrences can be created again—even if their earlier tasks were completed or deleted.", "연결과 자동 생성 동의를 중지하고 로컬 건강 기록·후보·비임상 중복 방지 표식을 모두 삭제합니다. 이미 생성된 할 일은 남습니다. 다시 연결하고 출처를 승인한 뒤 루틴을 확정하고 생성을 허용하면, 이전 할 일을 완료하거나 삭제했더라도 이미 처리한 일정이 다시 생성될 수 있습니다."))
        }
        .alert(HealthCopy.text("health.error.title", "Health history could not be updated", "건강 기록을 변경하지 못했습니다"), isPresented: Binding(
            get: { mutationError != nil },
            set: { if !$0 { mutationError = nil } }
        )) {
            Button(HealthCopy.text("health.action.ok", "OK", "확인"), role: .cancel) { mutationError = nil }
        } message: {
            Text(mutationError ?? "")
        }
        .onDisappear { cancelWork() }
    }

    @ViewBuilder
    private func categorySection(_ category: HealthHistoryCategory) -> some View {
        let state = store.states[category] ?? HealthCategoryState()
        let records = store.records.filter { $0.category == category }
        let sources = Dictionary(grouping: records, by: \.sourceID)
        let unavailableReason = store.unavailableReason(for: category)
        Section {
            if state.isConnected {
                Label(HealthCopy.text("health.connection.promptCompleted", "Read prompt completed—not proof of read permission", "읽기 요청 완료 — 읽기 권한 허용의 증거는 아님"), systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let lastRead = state.lastRead {
                    LabeledContent(HealthCopy.text("health.history.lastRead", "Last read", "마지막 읽기")) {
                        Text(lastRead, format: Date.FormatStyle(date: .abbreviated, time: .shortened, locale: AppLanguage.current.locale))
                    }
                    LabeledContent(HealthCopy.text("health.history.count", "Visible records in the 90-day window", "최근 90일 동안 보이는 기록 수"), value: state.readRecordCount.formatted(.number.locale(AppLanguage.current.locale)))
                }
                if records.isEmpty {
                    Text(HealthCopy.text("health.history.empty", "No visible records. There may be no history in the last 90 days, or read access may be denied or restricted. HealthKit hides read authorization, so this app cannot tell the difference.", "보이는 기록이 없습니다. 최근 90일 동안 기록이 없거나 읽기 접근이 거부·제한되었을 수 있습니다. HealthKit은 읽기 권한 상태를 숨기므로 앱에서 구별할 수 없습니다."))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("health.history.empty.\(category.rawValue)")
                }
                Button(HealthCopy.text("health.disconnect", "Disconnect this category", "이 항목 연결 해제"), role: .destructive) {
                    cancelWork()
                    store.disconnect(category)
                }
                .accessibilityIdentifier("health.disconnect.\(category.rawValue)")
                Text(HealthCopy.text("health.disconnect.explanation", "Disconnecting stops this category and erases its local history, source approvals, and suggestions. Existing tasks and duplicate-prevention markers remain. It does not revoke Health access in iOS Settings.", "연결을 해제하면 이 항목을 중지하고 로컬 기록·출처 승인·제안을 지웁니다. 기존 할 일과 중복 방지 표식은 남습니다. iOS 설정의 건강 접근 권한은 철회되지 않습니다."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    startWork { await store.connect(category, context: modelContext) }
                } label: {
                    Label(HealthCopy.text("health.connect", "Connect and request read access", "연결 및 읽기 접근 요청"), systemImage: "heart.text.clipboard")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(store.isRefreshing || unavailableReason != nil)
                .accessibilityIdentifier("health.connect.\(category.rawValue)")
            }
            if let reason = unavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }
            if state.isConnected && !sources.isEmpty {
                Text(HealthCopy.text("health.sources.explanation", "Discovered sources are off by default. Approve each source you trust for learning; approval alone does not confirm a routine or allow task creation.", "발견된 출처는 기본적으로 꺼져 있습니다. 학습에 사용할 신뢰하는 출처를 각각 승인하세요. 출처 승인만으로 루틴이 확정되거나 할 일이 생성되지는 않습니다."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(sources.keys.sorted(), id: \.self) { sourceID in
                    let sourceRecords = sources[sourceID] ?? []
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                        Toggle(isOn: Binding(
                            get: { store.states[category]?.approvedSourceIDs.contains(sourceID) == true },
                            set: { approved in mutate { try store.approveSource(sourceID, category: category, approved: approved) } }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sourceRecords.first?.sourceName ?? sourceID)
                                Text(sourceID)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityHint(HealthCopy.text("health.sources.approval.hint", "Allow this source to contribute evidence for routine suggestions.", "이 출처의 기록을 루틴 제안의 근거로 사용하도록 허용합니다."))
                        LabeledContent(HealthCopy.text("health.evidence.count", "Evidence records", "근거 기록 수"), value: sourceRecords.count.formatted(.number.locale(AppLanguage.current.locale)))
                        if let first = sourceRecords.lazy.map(\.startDate).min(), let last = sourceRecords.lazy.map(\.startDate).max() {
                            HealthEvidenceRange(start: first, end: last)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(category == .workout
                 ? HealthCopy.text("health.category.workout", "Workouts", "운동")
                 : HealthCopy.text("health.category.medication", "Medications", "복약"))
        }
    }

    private func candidateRow(_ candidate: HealthRoutineCandidate) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
            Text(candidate.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            HealthCandidateEvidence(candidate: candidate)
            if candidate.isConfirmed {
                Toggle(HealthCopy.text("health.routine.enabled", "Enable this confirmed routine", "이 확정한 루틴 활성화"), isOn: Binding(
                    get: { store.candidates.first(where: { $0.id == candidate.id })?.isEnabled == true },
                    set: { enabled in mutate { try store.setRoutineEnabled(candidate.id, enabled: enabled) } }
                ))
                .accessibilityHint(candidate.title)
            } else {
                Label(HealthCopy.text("health.routine.unconfirmed", "Disabled until you review and confirm", "검토 및 확정 전까지 비활성화"), systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(HealthCopy.text("health.routine.review", "Review title and schedule", "제목 및 일정 검토")) {
                selectedCandidate = candidate
            }
            .accessibilityHint(candidate.title)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, AppTheme.Spacing.compact)
    }

    private func startWork(_ operation: @escaping @MainActor () async -> Void) {
        cancelWork()
        operationTask = Task { await operation() }
    }

    private func cancelWork() {
        operationTask?.cancel()
        operationTask = nil
        store.cancelRefresh()
    }

    private func mutate(_ operation: () throws -> Void) {
        do { try operation() }
        catch { mutationError = error.localizedDescription }
    }

    private static var cancelTitle: String {
        HealthCopy.text("health.action.cancel", "Cancel", "취소")
    }

    private static var syncDisclosure: String {
        HealthCopy.text("health.autoCreate.disclosure", "Generated Todo titles and schedules can reveal health information. Health data, routine candidates and health-generated tasks are excluded from iCloud. Generated tasks are still included if you manually export an encrypted Firebase snapshot. Creation requires an approved source, your confirmed enabled routine, and this separate consent. No HealthKit or calendar writes or notifications are made. Refresh after allowing creation to create the next future task.", "생성된 할 일의 제목과 일정은 건강 정보를 드러낼 수 있습니다. 건강 데이터·루틴 후보·건강 기록에서 생성된 할 일은 iCloud에서 제외합니다. 다만 암호화된 Firebase 스냅샷을 수동으로 내보내면 생성된 할 일은 포함됩니다. 생성하려면 승인한 출처, 직접 확정하고 활성화한 루틴, 이 별도의 동의가 모두 필요합니다. HealthKit·캘린더 쓰기나 알림은 실행하지 않습니다. 허용 후 새로고침하여 다음 미래 일정의 할 일을 생성하세요.")
    }

    private static var eraseDisclosure: String {
        HealthCopy.text("health.erase.disclosure", "Erasing stops all category connections and automatic-creation consent, and deletes local raw history, source approvals, and routine candidates. Existing generated tasks remain. Nonclinical consumed-occurrence markers are kept to prevent duplicates. HealthKit records and iOS Health permissions are unchanged.", "지우면 모든 항목의 연결과 자동 생성 동의를 중지하고 로컬 원본 기록·출처 승인·루틴 후보를 삭제합니다. 이미 생성된 할 일은 남습니다. 중복 방지를 위해 비임상 처리 일정 표식은 유지합니다. HealthKit 기록과 iOS 건강 권한은 변경하지 않습니다.")
    }
}

private struct HealthEvidenceRange: View {
    let start: Date
    let end: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(HealthCopy.text("health.evidence.range", "Evidence range", "근거 기록 기간")).foregroundStyle(.secondary)
            Text(start, format: Date.FormatStyle(date: .abbreviated, time: .standard, locale: AppLanguage.current.locale))
            Text(end, format: Date.FormatStyle(date: .abbreviated, time: .standard, locale: AppLanguage.current.locale))
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

private struct HealthCandidateEvidence: View {
    let candidate: HealthRoutineCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            LabeledContent(HealthCopy.text("health.evidence.source", "Source", "출처"), value: candidate.sourceName)
            Text(candidate.sourceID).font(.footnote).foregroundStyle(.secondary)
            LabeledContent(HealthCopy.text("health.evidence.count", "Evidence records", "근거 기록 수"), value: candidate.recordCount.formatted(.number.locale(AppLanguage.current.locale)))
            LabeledContent(HealthCopy.text("health.evidence.days", "Distinct evidence days", "기록이 있는 날짜 수"), value: candidate.distinctDays.formatted(.number.locale(AppLanguage.current.locale)))
            HealthEvidenceRange(start: candidate.evidenceStart, end: candidate.evidenceEnd)
            LabeledContent(HealthCopy.text("health.evidence.regularity", "Observed regularity, not medical confidence", "관찰된 규칙성 (의학적 신뢰도가 아님)"), value: candidate.regularity.formatted(.percent.precision(.fractionLength(1)).locale(AppLanguage.current.locale)))
            Text(HealthCopy.text("health.schedule.proposed", "Proposed schedule", "제안 일정")).font(.subheadline.weight(.semibold))
            LabeledContent(HealthCopy.text("health.schedule.period", "Period in days", "반복 주기 (일)"), value: candidate.periodDays.formatted(.number.locale(AppLanguage.current.locale)))
            LabeledContent(HealthCopy.text("health.schedule.hour", "Hour (0–23)", "시 (0~23)"), value: candidate.hour.formatted(.number.locale(AppLanguage.current.locale)))
            LabeledContent(HealthCopy.text("health.schedule.minute", "Minute (0–59)", "분 (0~59)"), value: candidate.minute.formatted(.number.locale(AppLanguage.current.locale)))
            LabeledContent(HealthCopy.text("health.schedule.anchor", "Anchor date", "기준 날짜")) {
                Text(candidate.anchorDate, format: Date.FormatStyle(
                    date: .abbreviated,
                    time: .omitted,
                    locale: AppLanguage.current.locale,
                    timeZone: TimeZone(identifier: candidate.timeZoneIdentifier) ?? .current
                ))
            }
            LabeledContent(HealthCopy.text("health.schedule.timeZone", "Time zone", "시간대"), value: candidate.timeZoneIdentifier)
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HealthRoutineReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: HealthRoutineStore
    @State private var draft: HealthRoutineCandidate
    @State private var hasReviewed = false
    @State private var errorMessage: String?
    private let evidence: HealthRoutineCandidate
    private static let timeZoneIdentifiers = TimeZone.knownTimeZoneIdentifiers.sorted()

    init(candidate: HealthRoutineCandidate, store: HealthRoutineStore) {
        self.store = store
        self.evidence = candidate
        _draft = State(initialValue: candidate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HealthCandidateEvidence(candidate: evidence)
                } header: {
                    Text(HealthCopy.text("health.review.evidence", "Original evidence and suggestion", "원본 근거 및 제안"))
                }
                Section {
                    TextField(HealthCopy.text("health.schedule.title", "Task title", "할 일 제목"), text: $draft.title, axis: .vertical)
                    Stepper(value: $draft.periodDays, in: 1...90) {
                        LabeledContent(HealthCopy.text("health.schedule.period", "Period in days", "반복 주기 (일)"), value: draft.periodDays.formatted(.number.locale(AppLanguage.current.locale)))
                    }
                    Picker(HealthCopy.text("health.schedule.hour", "Hour (0–23)", "시 (0~23)"), selection: $draft.hour) {
                        ForEach(0..<24, id: \.self) { hour in Text(hour.formatted(.number.locale(AppLanguage.current.locale))).tag(hour) }
                    }
                    Picker(HealthCopy.text("health.schedule.minute", "Minute (0–59)", "분 (0~59)"), selection: $draft.minute) {
                        ForEach(0..<60, id: \.self) { minute in Text(minute.formatted(.number.locale(AppLanguage.current.locale))).tag(minute) }
                    }
                    DatePicker(HealthCopy.text("health.schedule.anchor", "Anchor date", "기준 날짜"), selection: $draft.anchorDate, displayedComponents: .date)
                        .environment(\.timeZone, TimeZone(identifier: draft.timeZoneIdentifier) ?? .current)
                    Picker(HealthCopy.text("health.schedule.timeZone", "Time zone", "시간대"), selection: $draft.timeZoneIdentifier) {
                        if !Self.timeZoneIdentifiers.contains(draft.timeZoneIdentifier) {
                            Text(draft.timeZoneIdentifier).tag(draft.timeZoneIdentifier)
                        }
                        ForEach(Self.timeZoneIdentifiers, id: \.self) { identifier in
                            Text(identifier).tag(identifier)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text(HealthCopy.text("health.review.edit", "Confirm or edit every schedule field", "각 일정 항목 확인 또는 수정"))
                }
                Section {
                    if draft.category == .medication {
                        Text(HealthCopy.text("health.medication.safety", "History is not a prescription or proof of your prescribed schedule. Confirm this reminder against your own clinician-provided schedule. This feature does not recommend prescription or dose changes, or give missed-dose or make-up-dose advice.", "복약 기록은 처방전이나 처방 일정의 증거가 아닙니다. 본인이 의료진에게 안내받은 일정과 이 알림을 대조해 확인하세요. 이 기능은 처방·용량 변경을 권하거나 복용 누락·보충 복용에 관한 조언을 제공하지 않습니다."))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(HealthCopy.text("health.review.consent", "Confirming saves your edited title and schedule and enables this routine. Tasks are created only when the separate automatic-creation consent is on. Refresh afterward to create the next future occurrence.", "확정하면 수정한 제목과 일정을 저장하고 이 루틴을 활성화합니다. 별도의 자동 생성 동의가 켜져 있을 때만 할 일을 생성합니다. 이후 새로고침하여 다음 미래 일정의 할 일을 생성하세요."))
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(HealthCopy.text("health.review.acknowledge", "I reviewed the title, period, time, anchor date, and time zone", "제목·주기·시간·기준 날짜·시간대를 확인했습니다"), isOn: $hasReviewed)
                        .fixedSize(horizontal: false, vertical: true)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .appFormStyle()
            .navigationTitle(HealthCopy.text("health.review.title", "Confirm routine", "루틴 확정"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(HealthCopy.text("health.action.cancel", "Cancel", "취소")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(HealthCopy.text("health.review.confirm", "Confirm and enable", "확정 및 활성화")) {
                        do {
                            try store.confirm(draft)
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(!hasReviewed || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("health.routine.confirm")
                }
            }
        }
    }
}
