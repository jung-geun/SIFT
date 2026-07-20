import SwiftUI
import SwiftData

// MARK: - Todo Row

private struct TodoRowView: View {
    let todo: Todo

    var body: some View {
        HStack(spacing: 12) {
            // 우선순위 컬러 인디케이터
            RoundedRectangle(cornerRadius: 3)
                .fill(priorityColor)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text(todo.title.isEmpty
                     ? AppLanguage.localized("todo.noTitle", defaultValue: "(제목 없음)", language: .current, comment: "Untitled to-do placeholder.")
                     : todo.title)
                    .font(.body)
                    .strikethrough(todo.isCompleted)
                    .foregroundStyle(todo.isCompleted ? .secondary : .primary)

                if todo.todoSource == .email, !todo.sourceSender.isEmpty {
                    Label(todo.sourceSender, systemImage: "person.crop.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if let label = todo.dueDateLabel {
                        Label(label, systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(todo.isOverdue ? AppTheme.destructive : .secondary)
                    }
                    if !todo.tags.isEmpty {
                        Label(todo.tags.prefix(2).joined(separator: ", "), systemImage: "tag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !todo.priorityReason.isEmpty && todo.manualPriority == nil {
                    HStack(spacing: 4) {
                        if todo.aiPersonaFit {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.accent)
                        }
                        // 산출 엔진 배지 — "휴리스틱"이면 LLM 경로가 실패로 폴백됐음을 의미
                        if let engine = PriorityEngine(rawValue: todo.aiEngine) {
                            let isHeuristic = engine == .heuristic
                            Text(engine.displayName)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(isHeuristic ? AppTheme.warning : AppTheme.accent)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    (isHeuristic ? AppTheme.warning : AppTheme.accent).opacity(0.1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        if !todo.aiFallbackReason.isEmpty {
                            Label(
                                AppLanguage.localized("todo.priority.fallback", defaultValue: "폴백", language: .current, comment: "Heuristic fallback badge."),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(AppTheme.warning)
                        }
                        Text(todo.priorityReason)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        if let rec = todo.aiRecommendedTime {
                            Text("· \(rec.formatted(.dateTime.hour().minute()))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer()

            // 출처 배지
            sourceBadge
        }
        .padding(.vertical, 4)
    }

    private var priorityColor: Color {
        // 등록 대기열 항목은 선호도 대신 마감일 기반 색상
        if todo.triage == .review { return deadlineColor }
        switch todo.effectivePriority {
        case 0.8...: return AppTheme.destructive
        case 0.6...: return AppTheme.warning
        case 0.4...: return AppTheme.accent
        default:     return .gray.opacity(0.4)
        }
    }

    private var deadlineColor: Color {
        guard let due = todo.dueDate else { return .gray.opacity(0.4) }
        let days = due.timeIntervalSinceNow / 86400
        if days < 1 { return AppTheme.destructive }      // 당일 또는 이미 지남
        if days < 3 { return AppTheme.warning }          // 2-3일
        if days < 7 { return AppTheme.accent }           // 4-7일
        return .gray.opacity(0.4)                        // 1주+
    }

    @ViewBuilder
    private var sourceBadge: some View {
        switch todo.todoSource {
        case .email:
            Image(systemName: "envelope.fill")
                .font(.caption)
                .foregroundStyle(AppTheme.accent)
        case .calendar:
            Image(systemName: todo.isFixedSchedule ? "arrow.triangle.2.circlepath" : "calendar")
                .font(.caption)
                .foregroundStyle(AppTheme.accent)
        case .meeting:
            Image(systemName: "person.2.fill")
                .font(.caption)
                .foregroundStyle(AppTheme.accent)
        case .manual:
            EmptyView()
        }
    }
}

// MARK: - Main List View

struct TodoListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Todo.createdAt, order: .reverse) private var todos: [Todo]
    @Query(sort: \Persona.updatedAt, order: .reverse) private var personas: [Persona]
    @Query private var auditEvents: [TaskAuditEvent]
    @Query private var behaviorEvents: [TaskBehaviorEvent]
    @Query private var memoryAnalyses: [MemoryAnalysis]

    @ObservedObject private var llmOrchestrator = LLMAutomationOrchestrator.shared
    @AppStorage("pieroot.todo.hasOnboarded") private var hasOnboarded = false
    @AppStorage("pieroot.todo.hasCompletedTutorial") private var hasCompletedTutorial = false
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("pieroot.todo.calendarCompletionAction") private var calendarCompletionAction = "silence"

    @State private var showAddTodo = false
    @State private var showSettings = false
    @State private var filter: TodoFilter = .active
    @State private var isPrioritizing = false
    @State private var showPrioritizingIndicator = false
    @State private var prioritizingStatusText = AppLanguage.localized(
        "todo.ai.initial",
        defaultValue: "AI 우선순위 정리 중…",
        language: .current,
        comment: "Initial AI prioritization progress."
    )
    @State private var prioritizingProgressValue: Double? = nil
    @State private var showAFMError = false
    @State private var lastNotificationSignature = ""
    @State private var replayTutorialAfterSettingsDismiss = false

    // MARK: - iCloud Sync (앱 레벨에서 주입받음 — todoApp.swift의 @StateObject)
    @EnvironmentObject private var syncMonitor: CloudSyncMonitor
    @Environment(\.appTutorialState) private var tutorial
    @AppStorage("pieroot.todo.iCloudInitialSyncDone") private var initialSyncDone = false
    @State private var showPostSyncPersonaSetup = false

    /// 모든 CloudKit-backed 앱 스키마 엔티티의 라이브 합계.
    private var totalSyncedCount: Int {
        todos.count
            + personas.count
            + auditEvents.count
            + behaviorEvents.count
            + memoryAnalyses.count
    }

    private var notificationSignature: String {
        let futureTodos = todos
            .filter { !$0.isCompleted && ($0.dueDate ?? .distantPast) > Date() }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        return futureTodos.map { todo in
            let dueDate = todo.dueDate?.timeIntervalSince1970 ?? 0
            let offsets = todo.reminderOffsets.sorted().map { String($0) }.joined(separator: ",")
            return [
                todo.id.uuidString,
                todo.title,
                String(dueDate),
                offsets,
                String(todo.effectivePriority),
                String(todo.updatedAt.timeIntervalSince1970)
            ].joined(separator: "|")
        }.joined(separator: "\n")
    }

    private func rescheduleNotificationsIfNeeded(force: Bool = false) async {
        let signature = notificationSignature
        guard force || signature != lastNotificationSignature else { return }
        lastNotificationSignature = signature
        await NotificationService.shared.reschedule(todos: todos)
    }

    // MARK: - Filter

    enum TodoFilter: String, CaseIterable {
        case active
        case overdue
        case all
        case review
        case completed

        var localizedTitle: String {
            let key: String
            let fallback: String
            switch self {
            case .active: key = "todo.filter.active"; fallback = "진행중"
            case .overdue: key = "todo.filter.overdue"; fallback = "기한초과"
            case .all: key = "todo.filter.all"; fallback = "전체"
            case .review: key = "todo.filter.review"; fallback = "등록 대기열"
            case .completed: key = "todo.filter.completed"; fallback = "완료"
            }
            return AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "To-do list filter label.")
        }
    }

    var filteredTodos: [Todo] {
        switch filter {
        case .all:
            // 등록 대기열(review) 제외 — review 탭에서 별도 확인
            return todos.filter { !$0.isCompleted && $0.triage == .todo }
                .sorted { $0.effectivePriority > $1.effectivePriority }
        case .active:
            return todos.filter {
                guard !$0.isCompleted && $0.triage == .todo else { return false }
                // 기한 초과여도 긴급(0.8+) 이상이면 진행중에 포함
                return !$0.isOverdue || $0.effectivePriority >= 0.8
            }
            .sorted {
                // 기한 초과 + 긴급 항목은 동점일 때 일반 항목보다 위에 정렬
                let aBoost: Double = ($0.isOverdue && $0.effectivePriority >= 0.8) ? 0.05 : 0
                let bBoost: Double = ($1.isOverdue && $1.effectivePriority >= 0.8) ? 0.05 : 0
                return ($0.effectivePriority + aBoost) > ($1.effectivePriority + bBoost)
            }
        case .overdue:
            return todos.filter { $0.isOverdue && $0.triage == .todo }
                .sorted { $0.effectivePriority > $1.effectivePriority }
        case .review:
            // 등록 대기열: 마감일 기준 오름차순 (선호도 무시)
            return todos.filter { !$0.isCompleted && $0.triage == .review }
                .sorted {
                    switch ($0.dueDate, $1.dueDate) {
                    case (let a?, let b?): return a < b
                    case (.some, .none):   return true
                    default:               return false
                    }
                }
        case .completed:
            let oneMonthAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 86400)
            return todos.filter { $0.isCompleted && ($0.completedAt == nil || $0.completedAt! >= oneMonthAgo) }
                .sorted { $0.effectivePriority > $1.effectivePriority }
        }
    }

    var overdueCount: Int { todos.filter { $0.isOverdue && $0.triage == .todo }.count }
    var activeCount: Int  {
        todos.filter {
            guard !$0.isCompleted && $0.triage == .todo else { return false }
            return !$0.isOverdue || $0.effectivePriority >= 0.8
        }.count
    }
    var reviewCount: Int  { todos.filter { !$0.isCompleted && $0.triage == .review }.count }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider()
                todoList
            }
            .navigationTitle("할 일")
            .toolbar { toolbarContent }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if syncMonitor.phase != .idle {
                        iCloudSyncBanner
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if showPrioritizingIndicator || llmOrchestrator.isRunning {
                        prioritizingBanner
                    }
                }
                .padding(.bottom, 8)
                .allowsHitTesting(false)
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { !hasOnboarded },
                set: { if !$0 { hasOnboarded = true } }
            ),
            onDismiss: {
                guard hasOnboarded, !hasCompletedTutorial else { return }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .appTutorialRequested, object: nil)
                }
            }
        ) {
            OnboardingView(isPresented: Binding(
                get: { !hasOnboarded },
                set: { if !$0 { hasOnboarded = true } }
            ))
        }
        .sheet(isPresented: $showAddTodo, onDismiss: {
            tutorial?.handleAddTodoDismissed()
        }) {
            AddTodoView()
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            guard replayTutorialAfterSettingsDismiss else { return }
            replayTutorialAfterSettingsDismiss = false
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .appTutorialRequested, object: nil)
            }
        }) {
            NavigationStack { PersonaSettingsView() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDismissRequested)) { _ in
            replayTutorialAfterSettingsDismiss = true
            showSettings = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .tutorialRunPrioritizeRequested)) { _ in
            let activeTodos = TodoAISortScope.candidates(from: todos)
            guard !isPrioritizing, !activeTodos.isEmpty else { return }
            Task { await runPrioritize() }
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if let tutorial, let hint = tutorial.hint(for: .todoList) {
                AppTutorialHintCard(hint: hint)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .onAppear {
            tutorial?.handleTodoListAppeared()
        }
        .task {
            // 등록 대기열 만료 항목 자동 제거
            let now = Date()
            for todo in todos where todo.triage == .review && !todo.isCompleted {
                if let due = todo.dueDate, due < now {
                    TaskBehaviorRecorder.recordDeletion(of: todo, actor: .system, in: modelContext)
                    modelContext.delete(todo)
                }
            }
            // 반복 일정 자동 승급: 1주일 이내 마감 → 진행중으로
            let weekAhead = now.addingTimeInterval(7 * 24 * 3600)
            for todo in todos where todo.triage == .review && todo.isFixedSchedule && !todo.isCompleted {
                if let due = todo.dueDate, due >= now, due <= weekAhead {
                    todo.triageStatus = TodoTriage.todo.rawValue
                }
            }
            await rescheduleNotificationsIfNeeded(force: true)
            // 앱 레벨에서 initialCount: 0으로 startObserving한 경우 기준치 보정
            syncMonitor.updateBaseline(totalSyncedCount)
        }
        .onChange(of: notificationSignature) {
            Task { await rescheduleNotificationsIfNeeded() }
        }
        .onChange(of: totalSyncedCount) {
            syncMonitor.updateCount(totalSyncedCount)
        }
        .onChange(of: syncMonitor.phase) { _, newPhase in
            guard iCloudSyncEnabled else { return }
            // 첫 동기화 완료/타임아웃 후 페르소나 유무 판정
            if (newPhase == .idle || newPhase == .completed) && !initialSyncDone {
                initialSyncDone = true
                DispatchQueue.main.async {
                    todoApp.deduplicatePersonas(context: modelContext)
                    if personas.isEmpty {
                        showPostSyncPersonaSetup = true
                    }
                }
            }
        }
        .sheet(isPresented: $showPostSyncPersonaSetup, onDismiss: {
            guard hasOnboarded, !hasCompletedTutorial else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .appTutorialRequested, object: nil)
            }
        }) {
            // 동기화 완료 후 페르소나가 없는 경우 초기 세팅 진행
            OnboardingView(isPresented: $showPostSyncPersonaSetup, isResetup: true)
        }
        .alert(
            AppLanguage.localized("todo.priority.error.title", defaultValue: "분석 오류", language: .current, comment: "Priority analysis error title."),
            isPresented: $showAFMError
        ) {
            Button(AppLanguage.localized("action.retry", defaultValue: "다시 시도", language: .current, comment: "Retry action.")) {
                Task { await runPrioritize() }
            }
            Button(AppLanguage.localized("action.cancel", defaultValue: "취소", language: .current, comment: "Cancel action."), role: .cancel) {}
        } message: {
            Text(AppLanguage.localized("todo.priority.error.message", defaultValue: "우선순위 분석 중 오류가 발생했습니다.", language: .current, comment: "Priority analysis error message."))
        }
    }

    // MARK: - Subviews

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TodoFilter.allCases, id: \.self) { f in
                    filterChip(f)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func filterChip(_ f: TodoFilter) -> some View {
        let isSelected = filter == f
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { filter = f }
        } label: {
            HStack(spacing: 4) {
                Text(f.localizedTitle)
                if f == .overdue && overdueCount > 0 {
                    Text("\(overdueCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .background(AppTheme.destructive, in: Capsule())
                        .foregroundStyle(.white)
                }
                if f == .review && reviewCount > 0 {
                    Text("\(reviewCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .background(AppTheme.warning, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? AppTheme.accentSoft : AppTheme.neutralFill,
                in: Capsule()
            )
            .foregroundStyle(isSelected ? AppTheme.accent : Color.gray)
            .overlay {
                if isSelected {
                    Capsule().stroke(AppTheme.accentStroke, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var todoList: some View {
        List {
            ForEach(filteredTodos) { todo in
                NavigationLink(value: todo) {
                    TodoRowView(todo: todo)
                }
                .swipeActions(edge: .leading) {
                    if todo.triage == .review {
                        promoteButton(todo)
                    } else {
                        completeButton(todo)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    deleteButton(todo)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await CalendarService.shared.syncCalendarWithTodos(context: modelContext)
        }
        .overlay {
            if filteredTodos.isEmpty {
                emptyState
            }
        }
        .navigationDestination(for: Todo.self) { todo in
            TodoDetailView(todo: todo)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyIcon)
        } description: {
            Text(emptyDescription)
        } actions: {
            if filter != .completed {
                Button(AppLanguage.localized("todo.add", defaultValue: "할 일 추가", language: .current, comment: "Add to-do button")) { showAddTodo = true }
            }
        }
    }

    private var emptyTitle: String {
        let (key, fallback): (String, String) = switch filter {
        case .all:       ("todo.empty.title.all", "할 일이 없습니다")
        case .active:    ("todo.empty.title.active", "모두 완료했습니다!")
        case .overdue:   ("todo.empty.title.overdue", "기한 초과 항목 없음")
        case .review:    ("todo.empty.title.review", "등록 대기열이 비어 있습니다")
        case .completed: ("todo.empty.title.completed", "완료된 항목 없음")
        }
        return AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "To-do empty state title")
    }

    private var emptyIcon: String {
        switch filter {
        case .overdue:   "checkmark.circle"
        case .completed: "tray"
        case .review:    "tray"
        default:         "checklist"
        }
    }

    private var emptyDescription: String {
        let (key, fallback): (String, String) = switch filter {
        case .active:    ("todo.empty.description.active", "+ 버튼을 눌러 새 할 일을 추가하세요.")
        case .overdue:   ("todo.empty.description.overdue", "모든 항목이 기한 내에 있습니다.")
        case .completed: ("todo.empty.description.completed", "완료한 항목이 여기에 표시됩니다.")
        case .review:    ("todo.empty.description.review", "캘린더에서 가져온 일정이 마감일 순으로 표시됩니다. 스와이프해 진행중으로 추가하면 캘린더에 등록됩니다.")
        default:         ("todo.empty.description.none", "")
        }
        return AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "To-do empty state description")
    }

    private var prioritizingBanner: some View {
        HStack(spacing: 10) {
            Group {
                if let prioritizingProgressValue {
                    ProgressView(value: prioritizingProgressValue)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(prioritizingStatusText)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(
                    AppLanguage.localized(
                        "todo.priority.backgroundWarning",
                        defaultValue: "앱을 나가거나 화면을 끄면 분석이 중단됩니다",
                        language: .current,
                        comment: "Background analysis warning."
                    )
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .padding(.horizontal, 24)
    }

    // MARK: - iCloud Sync Banner

    private var iCloudSyncBanner: some View {
        HStack(spacing: 10) {
            Group {
                switch syncMonitor.phase {
                case .importing:
                    ProgressView()
                        .controlSize(.small)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.success)
                        .font(.body)
                case .idle:
                    EmptyView()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                switch syncMonitor.phase {
                case .importing:
                    Text(AppLanguage.localized("todo.icloud.importing", defaultValue: "iCloud 데이터 동기화 중…", language: .current, comment: "iCloud sync progress."))
                        .font(.subheadline.weight(.medium))
                    if syncMonitor.importedCount > 0 {
                        Text(
                            AppLanguage.localizedCount(
                                "todo.icloud.importedCount",
                                count: syncMonitor.importedCount,
                                defaultValue: AppLanguage.current == .english
                                    ? (syncMonitor.importedCount == 1 ? "%lld item imported" : "%lld items imported")
                                    : "불러온 항목 %lld개",
                                language: .current,
                                comment: "iCloud sync progress."
                            )
                        )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(AppLanguage.localized("todo.icloud.empty", defaultValue: "할 일, 페르소나, 설정 정보를 불러오고 있습니다", language: .current, comment: "iCloud sync progress."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case .completed:
                    Text(AppLanguage.localized("todo.icloud.completed", defaultValue: "동기화 완료", language: .current, comment: "iCloud sync progress."))
                        .font(.subheadline.weight(.medium))
                case .idle:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .padding(.horizontal, 24)
    }

    // MARK: - Swipe Actions

    private func completeButton(_ todo: Todo) -> some View {
        Button {
            withAnimation { toggleComplete(todo) }
        } label: {
            Label(
                AppLanguage.localized(
                    todo.isCompleted ? "action.undo" : "action.complete",
                    defaultValue: todo.isCompleted ? "되돌리기" : "완료",
                    language: .current,
                    comment: "Complete or undo to-do action."
                ),
                systemImage: todo.isCompleted ? "arrow.uturn.left" : "checkmark"
            )
        }
        .tint(todo.isCompleted ? AppTheme.warning : AppTheme.success)
    }

    private func deleteButton(_ todo: Todo) -> some View {
        Button(role: .destructive) {
            withAnimation { deleteTodo(todo) }
        } label: {
            Label(
                AppLanguage.localized("action.delete", defaultValue: "삭제", language: .current, comment: "Delete to-do action."),
                systemImage: "trash"
            )
        }
    }

    /// 등록 대기열 항목을 진행중으로 승격 + 캘린더 자동 등록 정책 적용
    private func promoteButton(_ todo: Todo) -> some View {
        Button {
            withAnimation { todo.triageStatus = TodoTriage.todo.rawValue }
            CalendarService.shared.applyAutoRegistration(for: todo)
        } label: {
            Label(
                AppLanguage.localized("action.promoteToActive", defaultValue: "진행중으로 추가", language: .current, comment: "Promote review item to active action."),
                systemImage: "checkmark.circle"
            )
        }
        .tint(AppTheme.accent)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gear")
            }
            .accessibilityLabel(AppLanguage.localized("todo.settings.accessibilityLabel", defaultValue: "설정", language: .current, comment: "Settings button."))
            .accessibilityIdentifier("todo.settingsButton")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showAddTodo = true
            } label: {
                Image(systemName: "plus")
                    .fontWeight(.semibold)
            }
            .accessibilityLabel(AppLanguage.localized("todo.add.accessibilityLabel", defaultValue: "새 할 일 추가", language: .current, comment: "Add to-do button."))
            .accessibilityIdentifier("todo.addButton")
        }
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                tutorial?.handlePrioritizeTriggered()
                Task { await runPrioritize() }
            } label: {
                Label(
                    AppLanguage.localized("action.prioritize", defaultValue: "AI 정리", language: .current, comment: "Prioritize with AI action."),
                    systemImage: "sparkles"
                )
            }
            .disabled(isPrioritizing || todos.filter { !$0.isCompleted }.isEmpty)
        }
    }

    // MARK: - Actions

    private func toggleComplete(_ todo: Todo) {
        let wasCompleted = todo.isCompleted
        todo.isCompleted.toggle()
        todo.completedAt = todo.isCompleted ? Date() : nil
        todo.updatedAt = Date()
        TaskBehaviorRecorder.recordCompletionChange(
            of: todo,
            from: wasCompleted,
            to: todo.isCompleted,
            actor: .user,
            in: modelContext
        )
        NotificationService.shared.cancel(todo: todo)
        if todo.isCompleted, let eventID = todo.calendarEventID {
            if calendarCompletionAction == "silence" {
                try? CalendarService.shared.removeAlarms(eventID: eventID)
                // 알람만 끈 경우 calendarEventID는 유지 (이벤트는 캘린더에 남음)
            } else {
                try? CalendarService.shared.removeEvent(eventID: eventID)
                todo.calendarEventID = nil
            }
        }
    }

    private func deleteTodo(_ todo: Todo) {
        NotificationService.shared.cancel(todo: todo)
        // 대기열(review) 항목은 캘린더 이벤트 보존 — 큐에서 제거해도 이벤트는 유지
        // 태스크(todo)로 승격된 항목만 함께 삭제
        if !todo.isCompleted && todo.triage == .todo, let eventID = todo.calendarEventID {
            if todo.isFixedSchedule, let due = todo.dueDate {
                // 반복 이벤트: dueDate 기준 해당 발생분만 제거
                try? CalendarService.shared.removeEventOccurrence(eventID: eventID, on: due)
            } else {
                try? CalendarService.shared.removeEvent(eventID: eventID)
            }
        }
        // 이메일 출처 삭제 → 학습 기록 (단일 choke point)
        // - messageID(sourceRef) → dismissed 영속화: 재폴링 시 재생성 방지
        // - senderEmail → 삭제 카운트 누적: 2회 이상 시 자동 억제
        if todo.todoSource == .email {
            EmailLearningStore.shared.recordDeletion(
                senderEmail: todo.sourceSenderEmail,
                messageID: todo.sourceRef
            )
        }
        // 삭제 이력 audit 기록 (사용자 주도 삭제 전용 — 자동 만료 sweep 제외)
        TaskBehaviorRecorder.recordDeletion(of: todo, actor: .user, in: modelContext)
        modelContext.insert(TaskAuditEvent(from: todo))
        modelContext.delete(todo)
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets { deleteTodo(filteredTodos[index]) }
    }

    private func applyPriorityResult(_ result: PriorityResult, in activeTodos: [Todo]) {
        guard let candidate = activeTodos.first(where: { $0.id == result.todoID }) else { return }
        let previousScore = candidate.computedPriorityScore
        guard let todo = TodoAISortScope.apply(result, in: activeTodos) else { return }
        TaskBehaviorRecorder.recordComputedPriorityChange(
            of: todo,
            from: previousScore,
            to: todo.computedPriorityScore,
            actor: result.engine == .heuristic ? .system : .artificialIntelligence,
            in: modelContext
        )
        guard result.needsNotification,
              let dueDate = todo.dueDate,
              todo.reminderOffsets.isEmpty,
              todo.manualPriority == nil else {
            return
        }

        guard let offset = reminderOffset(for: result, dueDate: dueDate) else { return }
        todo.reminderOffsets = [offset]
        Task { await NotificationService.shared.update(todo: todo) }
    }

    private func reminderOffset(for result: PriorityResult, dueDate: Date) -> Double? {
        guard result.needsNotification else { return nil }
        return ReminderTiming.automaticOffset(dueDate: dueDate)
    }

    private func runPrioritize() async {
        let requestedProvider = SettingsStore.selectedProvider()
        let activeTodos = TodoAISortScope.candidates(from: todos)
        
        isPrioritizing = true
        prioritizingStatusText = String(
            format: AppLanguage.localized("todo.ai.starting", defaultValue: "%@ 시작 중…", language: .current, comment: "AI prioritization progress."),
            requestedProvider.displayName(language: .current)
        )
        prioritizingProgressValue = nil
        print("[TodoListView] AI 정리 tapped, provider=\(requestedProvider.rawValue), activeTodos=\(activeTodos.count)")
        withAnimation { showPrioritizingIndicator = true }
        defer {
            isPrioritizing = false
            prioritizingProgressValue = nil
            withAnimation { showPrioritizingIndicator = false }
        }

        let persona = PersonaContext(
            types: personas.first?.personaTypes ?? [],
            description: personas.first?.descriptionText ?? ""
        )
        let events = CalendarService.shared.isAuthorized
            ? CalendarService.shared.upcomingEvents()
            : []

        var appliedResultIDs = Set<UUID>()
        let service = RoutedIntelligenceEngine(requestedProvider: requestedProvider)
        let results: [PriorityResult]
        do {
            results = try await service.prioritize(
                todos: activeTodos,
                events: events,
                persona: persona,
                progress: { event in
                    switch event {
                    case .preparing(let total, let provider):
                        prioritizingProgressValue = total > 0 ? 0 : nil
                        prioritizingStatusText = String(format: AppLanguage.localized("todo.ai.preparing", defaultValue: "%@ 준비 중…", language: .current, comment: "AI prioritization progress."), provider)
                    case .requesting(let index, let total, let title, let provider):
                        prioritizingProgressValue = total > 0 ? Double(max(0, index - 1)) / Double(total) : nil
                        prioritizingStatusText = String(format: AppLanguage.localized("todo.ai.requesting", defaultValue: "%@ 요청 %d/%d: %@", language: .current, comment: "AI prioritization progress."), provider, index, total, title)
                    case .received(let index, let total, let title, let provider):
                        prioritizingProgressValue = total > 0 ? Double(index) / Double(total) : nil
                        prioritizingStatusText = String(format: AppLanguage.localized("todo.ai.received", defaultValue: "%@ 응답 %d/%d: %@", language: .current, comment: "AI prioritization progress."), provider, index, total, title)
                    case .fallback(let from, let to, let reason):
                        prioritizingStatusText = String(format: AppLanguage.localized("todo.ai.fallback", defaultValue: "%@ 실패 → %@: %@", language: .current, comment: "AI prioritization progress."), from, to, reason)
                    case .applying(let index, let total, let title):
                        prioritizingProgressValue = total > 0 ? Double(index) / Double(total) : nil
                        prioritizingStatusText = String(format: AppLanguage.localized("todo.ai.applying", defaultValue: "결과 적용 %d/%d: %@", language: .current, comment: "AI prioritization progress."), index, total, title)
                    case .result(let result, let index, let total, let title):
                        prioritizingProgressValue = total > 0 ? Double(index) / Double(total) : nil
                        prioritizingStatusText = String(format: AppLanguage.localized("todo.ai.result", defaultValue: "%@ 반영 %d/%d: %@", language: .current, comment: "AI prioritization progress."), result.engine.displayName(language: .current), index, total, title)
                        if !appliedResultIDs.contains(result.todoID) {
                            applyPriorityResult(result, in: activeTodos)
                            appliedResultIDs.insert(result.todoID)
                        }
                    case .completed(let finalProvider, let total):
                        prioritizingProgressValue = total > 0 ? 1 : nil
                        prioritizingStatusText = String(format: AppLanguage.localized("todo.ai.completed", defaultValue: "%@ 완료 (%d개)", language: .current, comment: "AI prioritization progress."), finalProvider, total)
                    }
                }
            )
        } catch {
            showAFMError = true
            return
        }

        for result in results where !appliedResultIDs.contains(result.todoID) {
            applyPriorityResult(result, in: activeTodos)
            appliedResultIDs.insert(result.todoID)
        }
    }
}

#Preview {
    TodoListView()
        .modelContainer(for: [Todo.self, Persona.self], inMemory: true)
}
