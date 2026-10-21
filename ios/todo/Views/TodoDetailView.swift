import SwiftUI
import SwiftData

/// 상세 화면 편집 초안. 저장을 눌러야 Todo에 반영된다.
private struct TodoDraft: Equatable {
    var title: String = ""
    var notes: String = ""
    var dueDate: Date?
    var startDate: Date?
    var manualPriority: Int?
    var reminderOffsets: [Double] = []
    var tags: [String] = []
    var calendarLinked: Bool = false

    init() {}

    init(todo: Todo) {
        title = todo.title
        notes = todo.notes
        dueDate = todo.dueDate
        startDate = todo.startDate
        manualPriority = todo.manualPriority
        reminderOffsets = todo.reminderOffsets.sorted()
        tags = todo.tags
        calendarLinked = todo.calendarEventID != nil
    }

    /// 마감이 없거나 마감보다 이르지 않은 시작 시각은 저장하지 않는다.
    var resolvedStartDate: Date? {
        guard let dueDate, let startDate, startDate < dueDate else { return nil }
        return startDate
    }
}

struct TodoDetailView: View {
    @Bindable var todo: Todo
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.userVocabulary) private var userVocabulary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft = TodoDraft()
    @State private var initialDraft = TodoDraft()
    @State private var didLoadDraft = false
    @State private var calendarError: String?
    @State private var showDeleteConfirm = false
    @State private var showDiscardConfirm = false
    @State private var saveError: String?
    @State private var showingScheduleApproval = false
    /// 앱 내 메일 상세 시트 — 로컬 EmailMessage가 있을 때 표시
    @State private var showingEmail: EmailMessage?
    @State private var isResolvingEmail = false
    @State private var emailErrorWrapper: EmbeddedMailErrorWrapper?

    // MARK: - Body

    var body: some View {
        Form {
            titleSection
            schedulingSection
            if !todo.isCompleted, !todo.isFixedSchedule, todo.todoSource != .calendar, todo.triage == .todo {
                Section {
                    Button(AppLanguage.localized("todo.detail.scheduleReview", defaultValue: "Recommend and approve a schedule", language: .current, comment: "Open schedule recommendation and approval.")) { showingScheduleApproval = true }
                        .disabled(hasPendingChanges)
                        .accessibilityIdentifier("todo.scheduleReview")
                    if hasPendingChanges {
                        Text(AppLanguage.localized("todo.detail.scheduleDraftNotice", defaultValue: "Save or discard this draft before scheduling.", language: .current, comment: "Scheduling disabled while the to-do draft has unsaved edits."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            prioritySection
            remindersSection
            calendarSection
            tagSection
            metaSection
            completionSection
            deleteSection
        }
        .appFormStyle()
        .font(.body)
        .navigationTitle(AppLanguage.localized(
            "todo.detail.navigationTitle",
            defaultValue: "할 일 세부",
            language: .current,
            comment: "To-do detail screen title."
        ))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(hasPendingChanges)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { cancelButton }
            ToolbarItem(placement: .confirmationAction) { saveButton }
        }
        .onAppear {
            if !didLoadDraft {
                draft = TodoDraft(todo: todo)
                initialDraft = draft
                didLoadDraft = true
            }
        }
        .sheet(isPresented: $showingScheduleApproval, onDismiss: {
            draft = TodoDraft(todo: todo)
            initialDraft = draft
        }) {
            ScheduleApprovalView(todoID: todo.id)
        }
        .alert(
            "캘린더 오류",
            isPresented: Binding(
                get: { calendarError != nil },
                set: { if !$0 { calendarError = nil } }
            )
        ) {
            Button("확인") { calendarError = nil }
        } message: {
            Text(calendarError ?? "")
        }
        .confirmationDialog(
            "할일을 삭제하시겠습니까?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) { deleteTodo() }
            Button("취소", role: .cancel) { }
        }
        .confirmationDialog(
            AppLanguage.localized(
                "todo.detail.unsavedChanges",
                defaultValue: "저장하지 않은 변경사항이 있습니다",
                language: .current,
                comment: "Unsaved to-do edits confirmation."
            ),
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button(AppLanguage.localized(
                "action.save",
                defaultValue: "저장",
                language: .current,
                comment: "Save to-do edits."
            )) {
                commitAndDismiss()
            }
            Button(
                AppLanguage.localized(
                    "action.discard",
                    defaultValue: "폐기",
                    language: .current,
                    comment: "Discard unsaved to-do edits."
                ),
                role: .destructive
            ) {
                dismiss()
            }
            Button(
                AppLanguage.localized(
                    "action.cancel",
                    defaultValue: "취소",
                    language: .current,
                    comment: "Cancel to-do edits."
                ),
                role: .cancel
            ) { }
        }
        .alert(
            AppLanguage.localized(
                "todo.detail.saveErrorTitle",
                defaultValue: "저장 오류",
                language: .current,
                comment: "To-do save error title."
            ),
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button(AppLanguage.localized(
                "action.close",
                defaultValue: "닫기",
                language: .current,
                comment: "Dismiss to-do save error."
            )) {
                saveError = nil
            }
        } message: {
            Text(saveError ?? "")
        }
        .sheet(item: $showingEmail) { email in
            MailDetailView(email: email)
                .modelContainer(AppDataContainer.shared.emailContainer)
        }
        .alert(item: $emailErrorWrapper) { wrapper in
            Alert(
                title: Text("이메일 로드 오류"),
                message: Text(wrapper.error.localizedDescription),
                primaryButton: .default(Text("다시 시도")) {
                    openOriginalEmail()
                },
                secondaryButton: .cancel(Text("취소"))
            )
        }
    }

    // MARK: - Sections

    private var titleSection: some View {
        Section("제목 및 메모") {
            TextField("제목", text: $draft.title)
                .font(.headline)
                .accessibilityIdentifier("todo.detail.titleField")
            TextField("메모 (선택)", text: $draft.notes, axis: .vertical)
                .lineLimit(3...8)
                .font(.body)
                .accessibilityIdentifier("todo.detail.notesField")
        }
    }

    private var schedulingSection: some View {
        Section("마감 일정") {
            Toggle(isOn: Binding(
                get: { draft.dueDate != nil },
                set: { on in
                    if on {
                        draft.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
                    } else {
                        draft.dueDate = nil
                        draft.startDate = nil
                        draft.reminderOffsets = []
                    }
                }
            ).animation(AppTheme.motion(reduceMotion: reduceMotion))) {
                Label("마감 시각 설정", systemImage: "calendar.badge.clock")
            }

            if draft.dueDate != nil {
                DatePicker(
                    "마감",
                    selection: Binding(
                        get: { draft.dueDate ?? Date() },
                        set: { draft.dueDate = $0 }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)

                if !todo.isCompleted, draft.dueDate.map({ $0 < Date() }) ?? false {
                    Label("기한이 초과되었습니다", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let due = draft.dueDate {
                    Toggle(isOn: Binding(
                        get: { draft.startDate != nil },
                        set: { on in
                            draft.startDate = on ? due.addingTimeInterval(-3600) : nil
                        }
                    )) {
                        Label(
                            AppLanguage.localized(
                                "todo.detail.startTimeToggle",
                                defaultValue: "시작 시각 설정",
                                language: .current,
                                comment: "Toggle that gives a to-do a start time in addition to its deadline."
                            ),
                            systemImage: "play.circle"
                        )
                    }
                    .accessibilityIdentifier("todo.detail.startDateToggle")

                    if draft.startDate != nil {
                        DatePicker(
                            AppLanguage.localized(
                                "todo.detail.startTimeLabel",
                                defaultValue: "시작",
                                language: .current,
                                comment: "Start time picker label on the to-do detail screen."
                            ),
                            selection: Binding(
                                get: { draft.startDate ?? due.addingTimeInterval(-3600) },
                                set: { draft.startDate = $0 }
                            ),
                            in: ...due.addingTimeInterval(-1),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .accessibilityIdentifier("todo.detail.startDatePicker")
                    }
                }
            }
        }
    }

    private var prioritySection: some View {
        Section("우선순위") {
            Picker(selection: $draft.manualPriority) {
                Text("설정 안함").tag(Int?.none)
                ForEach(TodoPriority.allCases, id: \.rawValue) { priority in
                    Text(priority.label).tag(Int?.some(priority.rawValue))
                }
            } label: {
                Text("수동 우선순위")
            }
            .pickerStyle(.menu)
            .accessibilityLabel(AppLanguage.localized("todo.priority.accessibilityLabel", defaultValue: "우선순위 선택", language: .current, comment: "To-do priority picker."))
            .accessibilityIdentifier("todo.priorityPicker")

            if !todo.priorityReason.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.item) {
                        Text("AI 우선순위")
                            .font(.headline)
                        Spacer(minLength: AppTheme.Spacing.item)
                        Text(String(format: "%.0f%%", todo.computedPriorityScore * 100))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(todo.priorityReason)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if !todo.aiDetail.isEmpty {
                        Text(todo.aiDetail)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let recommendation = todo.aiRecommendedTime {
                        Label("추천 처리 시각: \(recommendation.formatted(.dateTime.month().day().hour().minute()))", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if todo.aiNeedsNotification {
                        Label("알림 자동 설정됨", systemImage: "bell")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if todo.aiPersonaFit {
                        Text("페르소나 부합 항목")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if todo.manualPriority != nil {
                        Text("수동 우선순위가 AI 점수를 덮어씁니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, AppTheme.Spacing.compact)
            }
        }
    }

    private var remindersSection: some View {
        Section {
            if draft.dueDate == nil {
                Text("마감 시각을 설정해야 알림을 추가할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(draft.reminderOffsets, id: \.self) { offset in
                    HStack {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(.secondary)
                        Text(offsetLabel(offset))
                        Spacer()
                        Button(role: .destructive) {
                            removeOffset(offset)
                        } label: {
                            Image(systemName: "minus.circle")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("삭제"))
                        .accessibilityValue(offsetLabel(offset))
                    }
                }

                Menu {
                    ForEach(NotificationService.presetOffsets, id: \.offset) { preset in
                        if !draft.reminderOffsets.contains(preset.offset) {
                            Button(preset.label) { addOffset(preset.offset) }
                        }
                    }
                } label: {
                    Label("알림 추가", systemImage: "plus")
                }
            }
        } header: {
            Text("알림")
        } footer: {
            if !draft.reminderOffsets.isEmpty {
                Text("마감 기준 상대 시각으로 알림을 보냅니다.")
                    .font(.caption)
            }
        }
    }

    private var calendarSection: some View {
        Section("캘린더 연동") {
            if draft.dueDate == nil {
                Text("마감 시각을 설정해야 캘린더에 등록할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if CalendarService.shared.isAuthorized {
                Toggle(isOn: $draft.calendarLinked) {
                    Label(
                        draft.calendarLinked ? AppLanguage.localized("todo.detail.calendarLinked", defaultValue: "Added to Calendar", language: .current, comment: "Calendar toggle label when linked.") : AppLanguage.localized("todo.detail.calendarLink", defaultValue: "Add to Calendar", language: .current, comment: "Calendar toggle label when unlinked."),
                        systemImage: "calendar"
                    )
                }
            } else {
                Button {
                    Task {
                        await CalendarService.shared.requestAccess()
                    }
                } label: {
                    Label("캘린더 접근 허용", systemImage: "calendar.badge.exclamationmark")
                }
            }
        }
    }

    private var tagSection: some View {
        Section("태그") {
            TagEditorView(tags: $draft.tags)
        }
    }

    private var metaSection: some View {
        Section {
            metaRow(AppLanguage.localized("todo.detail.sourceLabel", defaultValue: "Source", language: .current, comment: "To-do metadata source label.")) {
                sourceDescription
            }
            if todo.isFixedSchedule {
                metaRow(AppLanguage.localized("todo.detail.typeLabel", defaultValue: "Type", language: .current, comment: "To-do metadata type label.")) {
                    Label("고정 일정 (반복)", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }
            }
            if todo.todoSource == .email {
                if !todo.sourceSender.isEmpty {
                    metaRow(AppLanguage.localized("todo.detail.senderLabel", defaultValue: "Sender", language: .current, comment: "Original email sender metadata label.")) {
                        Text(todo.sourceSender)
                            .foregroundStyle(.secondary)
                    }
                }
                if !todo.sourceRef.isEmpty {
                    Button { openOriginalEmail() } label: {
                        HStack(spacing: 6) {
                            Label("원본 메일 열기", systemImage: "arrow.up.right.square")
                            if isResolvingEmail {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                    .disabled(isResolvingEmail)
                }
            }
            metaRow(AppLanguage.localized("todo.detail.createdLabel", defaultValue: "Created", language: .current, comment: "To-do creation date metadata label.")) {
                Text(todo.createdAt, style: .date)
                    .foregroundStyle(.secondary)
            }
            if let completed = todo.completedAt {
                metaRow(AppLanguage.localized("todo.detail.completedLabel", defaultValue: "Completed", language: .current, comment: "To-do completion date metadata label.")) {
                    Text(completed, style: .date)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var completionSection: some View {
        Section {
            Button { toggleCompletionAndDismiss() } label: {
                Label(
                    AppLanguage.localized(
                        todo.isCompleted ? "action.undo" : "todo.detail.completeAction",
                        defaultValue: todo.isCompleted ? "되돌리기" : "완료 처리",
                        language: .current,
                        comment: "Complete or undo to-do action."
                    ),
                    systemImage: todo.isCompleted ? "arrow.uturn.left" : "checkmark.circle.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: AppTheme.controlRadius))
            .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("todo.detail.completeButton")
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label(
                    AppLanguage.localized("action.delete", defaultValue: "삭제", language: .current, comment: "Delete to-do action."),
                    systemImage: "trash"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: AppTheme.controlRadius))
            .accessibilityIdentifier("todo.detail.deleteButton")
        }
    }

    // MARK: - Helpers

    private var saveButton: some View {
        Button { commitAndDismiss() } label: {
            Text(AppLanguage.localized("action.save", defaultValue: "저장", language: .current, comment: "Save to-do edits."))
                .fontWeight(.semibold)
        }
        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("todo.detail.saveButton")
    }

    private var cancelButton: some View {
        Button {
            if hasPendingChanges {
                showDiscardConfirm = true
            } else {
                dismiss()
            }
        } label: {
            Text(AppLanguage.localized("action.cancel", defaultValue: "취소", language: .current, comment: "Cancel to-do edits."))
        }
        .accessibilityIdentifier("todo.detail.cancelButton")
    }

    private var hasPendingChanges: Bool {
        didLoadDraft && draft != initialDraft
    }

    @ViewBuilder
    private func metaRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 12)
            content()
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private var sourceDescription: some View {
        switch todo.todoSource {
        case .manual:
            Text("직접 입력").foregroundStyle(.secondary)
        case .email:
            Text("이메일").foregroundStyle(.secondary)
        case .calendar:
            Text("캘린더").foregroundStyle(.secondary)
        case .meeting:
            Text("회의").foregroundStyle(.secondary)
        }
    }

    /// 원본 메일을 앱 내에서 엽니다.
    /// `EmbeddedTodoMailResolver`를 이용해 식별자 검증 및 캐시 미스시 원격 본문을 로드하고 `MailDetailView`로 표시합니다.
    private func openOriginalEmail() {
        guard !isResolvingEmail else { return }
        isResolvingEmail = true
        let emailContext = AppDataContainer.shared.emailContainer.mainContext
        Task {
            let result = await EmbeddedTodoMailResolver.shared.resolveAndHydrate(todo: todo, in: emailContext)
            isResolvingEmail = false
            switch result {
            case .success(let email):
                showingEmail = email
            case .failure(let error):
                emailErrorWrapper = EmbeddedMailErrorWrapper(error: error)
            }
        }
    }

    private func offsetLabel(_ offset: Double) -> String {
        ReminderTiming.detailLabel(for: offset)
    }

    private func addOffset(_ offset: Double) {
        guard !draft.reminderOffsets.contains(offset) else { return }
        draft.reminderOffsets.append(offset)
        draft.reminderOffsets.sort()
    }

    private func removeOffset(_ offset: Double) {
        draft.reminderOffsets.removeAll { $0 == offset }
    }

    /// 초안을 Todo에 반영하고 캘린더·알림 부작용을 적용한다.
    /// - Parameter rescheduleNotifications: 저장 직후 완료 처리할 때는 false로 넘겨
    ///   update와 완료 취소가 경쟁해 알림이 남는 race를 막는다.
    /// - Returns: 로컬 저장과 필요한 캘린더 쓰기가 모두 성공하면 true.
    @discardableResult
    private func commitDraft(rescheduleNotifications: Bool = true) -> Bool {
        let previousTitle = todo.title
        let previousDueDate = todo.dueDate
        let previousPriority = todo.manualPriority
        let wasLinked = todo.calendarEventID != nil
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            saveError = AppLanguage.localized(
                "todo.detail.titleRequired",
                defaultValue: "제목을 입력해주세요.",
                language: .current,
                comment: "Validation shown when saving a to-do without a title."
            )
            return false
        }

        // 1. 초안 필드 일괄 반영.
        todo.title = trimmedTitle
        todo.notes = draft.notes
        todo.startDate = draft.resolvedStartDate
        todo.dueDate = draft.dueDate
        todo.manualPriority = draft.manualPriority
        todo.reminderOffsets = draft.dueDate == nil ? [] : draft.reminderOffsets
        todo.tags = draft.tags
        todo.updatedAt = Date()

        // 2. 이전 버전 데이터 기준선 백필: 지금까지의 제목은 캘린더가 준 값이다.
        if todo.title != previousTitle,
           todo.calendarSyncedTitle.isEmpty,
           (todo.todoSource == .calendar || wasLinked) {
            todo.calendarSyncedTitle = previousTitle
        }

        // 3. 캘린더 부작용
        var calendarFailure: String?
        do {
            try CalendarService.shared.applyTodoCalendarEdit(for: todo, linked: draft.calendarLinked)
        } catch {
            calendarFailure = error.localizedDescription
        }
        if todo.dueDate == nil {
            NotificationService.shared.cancel(todo: todo)
        }

        // 4. 행동 로그 — 실제로 바뀐 항목만
        if previousDueDate != todo.dueDate {
            TaskBehaviorRecorder.recordDueDateChange(
                of: todo,
                from: previousDueDate,
                to: todo.dueDate,
                actor: .user,
                in: modelContext
            )
        }
        if previousPriority != todo.manualPriority {
            TaskBehaviorRecorder.recordManualPriorityChange(
                of: todo,
                from: previousPriority,
                to: todo.manualPriority,
                actor: .user,
                in: modelContext
            )
        }

        // 5. 로컬 저장. 실패해도 공유 메인 컨텍스트를 rollback하지 않는다.
        do {
            try modelContext.save()
        } catch {
            DiagnosticRecorder.shared.record(error: error, component: "todo.detail", operation: "commitDraft")
            saveError = error.localizedDescription
            return false
        }

        // 저장 성공 지점에서만 dirty 기준선을 전진시킨다.
        initialDraft = TodoDraft(todo: todo)
        draft = initialDraft

        // 6. 저장된 값으로 알림 재예약 / 어휘 관찰
        if rescheduleNotifications, todo.dueDate != nil {
            Task { await NotificationService.shared.update(todo: todo) }
        }
        if !todo.isCompleted, let observer = userVocabulary?.observer {
            let document = VocabularySourceDocumentBuilder.todo(todo)
            Task { await observer.observeDocument(document, false) }
        }

        if let calendarFailure {
            // 로컬 필드는 저장되었지만 외부 캘린더 갱신은 실패했다. 화면을 유지하고 사용자에게 알린다.
            calendarError = calendarFailure
            return false
        }
        return true
    }

    private func commitAndDismiss() {
        if commitDraft() {
            dismiss()
        }
    }

    private func toggleCompletionAndDismiss() {
        // 미저장 초안이 있으면 먼저 명시적 저장 경계를 통과시킨다.
        // 완료 mutation이 알림을 취소하므로 그 직전에 update Task를 만들지 않는다.
        guard commitDraft(rescheduleNotifications: false) else { return }
        // 완료 상태 부작용/자동 저장은 목록과 동일한 단일 choke point가 담당한다.
        TodoMutations.setCompleted(todo, completed: !todo.isCompleted, in: modelContext)
        dismiss()
    }

    private func deleteTodo() {
        // 삭제는 초안 내용을 저장하지 않는다. 확인 후 현재 Todo 자체를 삭제한다.
        do {
            try TodoMutations.delete(todo, in: modelContext)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Tag Editor

struct TagEditorView: View {
    @Binding var tags: [String]
    @State private var newTag = ""

    var body: some View {
        // Tags remain individual removable values without compact decorative pills.
        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
            ForEach(tags, id: \.self) { tag in
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.item) {
                    Text(tag)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(role: .destructive) {
                        tags.removeAll { $0 == tag }
                    } label: {
                        Image(systemName: "minus.circle")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(AppLanguage.localized("todo.tag.delete.accessibilityLabel", defaultValue: "태그 삭제", language: .current, comment: "To-do tag delete button."))
                    .accessibilityValue(tag)
                    .accessibilityIdentifier("todo.tagDeleteButton")
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: AppTheme.Spacing.item) {
                TextField("태그 추가…", text: $newTag)
                    .font(.body)
                    .onSubmit { addTag() }
                Button("추가", action: addTag)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .buttonBorderShape(.roundedRectangle(radius: AppTheme.controlRadius))
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, AppTheme.Spacing.compact)
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
        tags.append(trimmed)
        newTag = ""
    }
}

// MARK: - Flow Layout (태그 래핑)

struct FlowLayout<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let content: (Data.Element) -> Content

    init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    var body: some View {
        // iOS 16+ Layout 프로토콜 활용
        _FlowLayout {
            ForEach(Array(data), id: \.self) { item in
                content(item)
            }
        }
    }
}

private struct _FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth && rowWidth > 0 {
                height += rowHeight + spacing
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: height + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct EmbeddedMailErrorWrapper: Identifiable {
    let id = UUID()
    let error: EmbeddedMailError
}
#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Todo.self, configurations: config)
    let todo = Todo(title: "디자인 시안 검토", notes: "클라이언트 미팅 전 확인", dueDate: Date().addingTimeInterval(3600))
    todo.computedPriorityScore = 0.85
    todo.priorityReason = "1시간 이내 마감"
    container.mainContext.insert(todo)
    return NavigationStack { TodoDetailView(todo: todo) }
        .modelContainer(container)
}
