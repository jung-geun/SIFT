import SwiftUI
import SwiftData
#if targetEnvironment(macCatalyst)
import UIKit
#endif

// MARK: - Todo Row

private struct TodoRowView: View {
    let todo: Todo
    var onToggleComplete: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onPromote: (() -> Void)? = nil

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(todo.title.isEmpty
                     ? AppLanguage.localized("todo.noTitle", defaultValue: "(제목 없음)", language: .current, comment: "Untitled to-do placeholder.")
                     : todo.title)
                    .font(.body.weight(.medium))
                    .strikethrough(todo.isCompleted)
                    .foregroundStyle(todo.isCompleted ? .secondary : .primary)

                if let dueDate = todo.dueDate {
                    Label(
                        dueDate.formatted(
                            .dateTime.year().month(.abbreviated).day().hour().minute()
                                .locale(AppLanguage.current.locale)
                        ),
                        systemImage: "calendar"
                    )
                    .font(.subheadline)
                    .foregroundStyle(todo.isOverdue ? AppTheme.destructive : .secondary)
                }

                if todo.todoSource == .email, !todo.sourceSender.isEmpty {
                    Label(todo.sourceSender, systemImage: "envelope")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if todo.hasSuccessfulAIAnalysis {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("AI 정리 완료")
                    .accessibilityIdentifier("todo.row.aiAnalyzed")
            }

            // Preserve the pointer shortcut alongside swipe and context actions.
            if isHovered {
                Menu {
                    rowMenuActions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(AppLanguage.localized("todo.moreActions", defaultValue: "더 보기", language: .current, comment: "Secondary to-do toolbar menu accessibility label."))
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            rowMenuActions
        }
    }

    @ViewBuilder
    private var rowMenuActions: some View {
        if todo.triage == .review {
            Button {
                onPromote?()
            } label: {
                Label(
                    AppLanguage.localized("action.promoteToActive", defaultValue: "진행중으로 추가", language: .current, comment: "Promote review item to active action."),
                    systemImage: "checkmark.circle"
                )
            }
        } else {
            Button {
                onToggleComplete?()
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
        }

        Button(role: .destructive) {
            onDelete?()
        } label: {
            Label(
                AppLanguage.localized("action.delete", defaultValue: "삭제", language: .current, comment: "Delete to-do action."),
                systemImage: "trash"
            )
        }
    }

}

// MARK: - Todo Undo Support

private struct TodoUndoSnapshot {
    let id: UUID
    let title: String
    let notes: String
    let dueDate: Date?
    let startDate: Date?
    let isCompleted: Bool
    let completedAt: Date?
    let manualPriority: Int?
    let computedPriorityScore: Double
    let priorityReason: String
    let reminderOffsets: [Double]
    let estimatedDurationMinutes: Int
    let source: String
    let sourceRef: String
    let sourceSender: String
    let sourceMessageID: String
    let sourceThreadID: String
    let sourceSenderEmail: String
    let sourceAccountNamespace: String
    let triageStatus: String
    let tags: [String]
    let calendarEventID: String?
    let isFixedSchedule: Bool
    let aiRecommendedTime: Date?
    let aiEngine: String
    let aiPersonaFit: Bool
    let aiFallbackReason: String

    init(from todo: Todo) {
        self.id = todo.id
        self.title = todo.title
        self.notes = todo.notes
        self.dueDate = todo.dueDate
        self.startDate = todo.startDate
        self.isCompleted = todo.isCompleted
        self.completedAt = todo.completedAt
        self.manualPriority = todo.manualPriority
        self.computedPriorityScore = todo.computedPriorityScore
        self.priorityReason = todo.priorityReason
        self.reminderOffsets = todo.reminderOffsets
        self.estimatedDurationMinutes = todo.estimatedDurationMinutes
        self.source = todo.source
        self.sourceRef = todo.sourceRef
        self.sourceSender = todo.sourceSender
        self.sourceMessageID = todo.sourceMessageID
        self.sourceThreadID = todo.sourceThreadID
        self.sourceSenderEmail = todo.sourceSenderEmail
        self.sourceAccountNamespace = todo.sourceAccountNamespace
        self.triageStatus = todo.triageStatus
        self.tags = todo.tags
        self.calendarEventID = todo.calendarEventID
        self.isFixedSchedule = todo.isFixedSchedule
        self.aiRecommendedTime = todo.aiRecommendedTime
        self.aiEngine = todo.aiEngine
        self.aiPersonaFit = todo.aiPersonaFit
        self.aiFallbackReason = todo.aiFallbackReason
    }

    func restore(into context: ModelContext) -> Todo {
        let todo = Todo(title: title, dueDate: dueDate, tags: tags)
        todo.id = id
        todo.notes = notes
        todo.startDate = startDate
        todo.isCompleted = isCompleted
        todo.completedAt = completedAt
        todo.manualPriority = manualPriority
        todo.computedPriorityScore = computedPriorityScore
        todo.priorityReason = priorityReason
        todo.reminderOffsets = reminderOffsets
        todo.estimatedDurationMinutes = estimatedDurationMinutes
        todo.source = source
        todo.sourceRef = sourceRef
        todo.sourceSender = sourceSender
        todo.sourceMessageID = sourceMessageID
        todo.sourceThreadID = sourceThreadID
        todo.sourceSenderEmail = sourceSenderEmail
        todo.sourceAccountNamespace = sourceAccountNamespace
        todo.triageStatus = triageStatus
        todo.calendarEventID = calendarEventID
        todo.isFixedSchedule = isFixedSchedule
        todo.aiRecommendedTime = aiRecommendedTime
        todo.aiEngine = aiEngine
        todo.aiPersonaFit = aiPersonaFit
        todo.aiFallbackReason = aiFallbackReason
        context.insert(todo)
        try? context.save()
        return todo
    }

    func apply(to todo: Todo) {
        todo.title = title
        todo.notes = notes
        todo.dueDate = dueDate
        todo.startDate = startDate
        todo.isCompleted = isCompleted
        todo.completedAt = completedAt
        todo.manualPriority = manualPriority
        todo.computedPriorityScore = computedPriorityScore
        todo.priorityReason = priorityReason
        todo.reminderOffsets = reminderOffsets
        todo.estimatedDurationMinutes = estimatedDurationMinutes
        todo.source = source
        todo.sourceRef = sourceRef
        todo.sourceSender = sourceSender
        todo.sourceMessageID = sourceMessageID
        todo.sourceThreadID = sourceThreadID
        todo.sourceSenderEmail = sourceSenderEmail
        todo.sourceAccountNamespace = sourceAccountNamespace
        todo.triageStatus = triageStatus
        todo.tags = tags
        todo.calendarEventID = calendarEventID
        todo.isFixedSchedule = isFixedSchedule
        todo.aiRecommendedTime = aiRecommendedTime
        todo.aiEngine = aiEngine
        todo.aiPersonaFit = aiPersonaFit
        todo.aiFallbackReason = aiFallbackReason
        todo.updatedAt = Date()
    }
}

private enum TodoUndoAction {
    case toggleComplete(todoID: UUID, wasCompleted: Bool, previousCompletedAt: Date?)
    case promote(todoID: UUID, previousTriage: String)
    case delete(snapshot: TodoUndoSnapshot)
    case restore(snapshot: TodoUndoSnapshot)
}

// The iPhone home list is deadline-led; AI scores never hide or outrank an overdue task.
enum TodoListOrdering {
    static func activeTodos(from todos: [Todo]) -> [Todo] {
        todos.filter { !$0.isCompleted && $0.triage == .todo }
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (left?, right?) where left != right: return left < right
                case (.some, nil): return true
                case (nil, .some): return false
                default: break
                }
                if lhs.manualPriority != rhs.manualPriority {
                    return (lhs.manualPriority ?? 0) > (rhs.manualPriority ?? 0)
                }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }
}

// MARK: - Main List View

struct TodoListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Todo.createdAt, order: .reverse) private var todos: [Todo]
    @Query(sort: \Persona.updatedAt, order: .reverse) private var personas: [Persona]
    @Query private var auditEvents: [TaskAuditEvent]
    @Query private var behaviorEvents: [TaskBehaviorEvent]
    @Query private var memoryAnalyses: [MemoryAnalysis]

    @ObservedObject private var emailAutomation = EmailAutomationOrchestrator.shared
    @AppStorage("pieroot.todo.hasOnboarded") private var hasOnboarded = false
    @AppStorage("pieroot.todo.hasCompletedTutorial") private var hasCompletedTutorial = false
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("pieroot.todo.board.showActive") private var showActiveColumn = true
    @AppStorage("pieroot.todo.board.showOverdue") private var showOverdueColumn = true
    @AppStorage("pieroot.todo.board.showReview") private var showReviewColumn = true
    @AppStorage("pieroot.todo.board.showCompleted") private var showCompletedColumn = true
    @AppStorage("pieroot.todo.board.isBoardMode") private var isBoardMode = true
    @AppStorage("pieroot.todo.board.autoHideEmpty") private var autoHideEmpty = false
    @State private var undoStack: [TodoUndoAction] = []

    private var areAllColumnsVisible: Bool {
        showActiveColumn && showOverdueColumn && showReviewColumn && showCompletedColumn
    }

    /// Global search is surfaced from this tab's native pull-down search drawer.
    let globalSearchAppContainer: ModelContainer?
    let globalSearchEmailContainer: ModelContainer?
    let globalSearchMeetingContainer: ModelContainer?
    let globalSearchMailAccess: MailboxCachedProviderAccess?
    /// Root-owned onboarding/tutorial, selected-tab, and foreground eligibility.
    let isAdPlacementEligible: Bool

    @State private var showAddTodo = false
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
    @State private var saveError: String?
    @State private var lastNotificationSignature = ""

    @State private var globalSearchText = ""
#if DEBUG
    @State private var calendarRefreshCount = 0
#endif

#if DEBUG
    private var isRefreshObservationEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-test-observe-todo-refresh")
    }
#endif

    init(
        globalSearchAppContainer: ModelContainer? = nil,
        globalSearchEmailContainer: ModelContainer? = nil,
        globalSearchMeetingContainer: ModelContainer? = nil,
        globalSearchMailAccess: MailboxCachedProviderAccess? = nil,
        isAdPlacementEligible: Bool = false
    ) {
        self.globalSearchAppContainer = globalSearchAppContainer
        self.globalSearchEmailContainer = globalSearchEmailContainer
        self.globalSearchMeetingContainer = globalSearchMeetingContainer
        self.globalSearchMailAccess = globalSearchMailAccess
        self.isAdPlacementEligible = isAdPlacementEligible
    }
    // MARK: - iCloud Sync (앱 레벨에서 주입받음 — todoApp.swift의 @StateObject)
    @EnvironmentObject private var syncMonitor: CloudSyncMonitor
    @EnvironmentObject private var appUpdate: AppUpdateService
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
        case review
        case overdue
        case all
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
                .sorted(by: TodoPriorityOrdering.higherPriorityFirst)
        case .active:
            return TodoListOrdering.activeTodos(from: todos)
        case .overdue:
            return todos.filter { $0.isOverdue && $0.triage == .todo }
                .sorted(by: TodoPriorityOrdering.higherPriorityFirst)
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
            return todos.filter { $0.isCompleted }
                .sorted {
                    let date0 = $0.completedAt ?? $0.updatedAt
                    let date1 = $1.completedAt ?? $1.updatedAt
                    return date0 > date1
                }
        }
    }

    var overdueCount: Int { todos.filter { $0.isOverdue && $0.triage == .todo }.count }
    var reviewCount: Int  { todos.filter { !$0.isCompleted && $0.triage == .review }.count }

    // MARK: - Body

    var body: some View {
        NavigationStack {
        AppTutorialObserving {
            Group {
                if horizontalSizeClass == .regular && isBoardMode {
                    todoBoard
                } else {
                    todoList
                }
            }
                .searchable(
                    text: $globalSearchText,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: Text(AppLanguage.localized(
                        "search.prompt",
                        defaultValue: "할 일, 메일, 회의 검색",
                        language: .current,
                        comment: "Global pull-down search prompt."
                    ))
                )
                .navigationDestination(for: Todo.self) { todo in
                    TodoDetailView(todo: todo)
                }
                .overlay {
                    if let globalSearchAppContainer,
                       let globalSearchEmailContainer,
                       let globalSearchMeetingContainer,
                       !globalSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        GlobalSearchResultsView(
                            appContainer: globalSearchAppContainer,
                            emailContainer: globalSearchEmailContainer,
                            meetingContainer: globalSearchMeetingContainer,
                            mailAccess: globalSearchMailAccess,
                            searchText: $globalSearchText
                        )
                    }
                }
                .navigationBarTitleDisplayMode(horizontalSizeClass == .regular ? .inline : .large)
                .navigationTitle("할 일")
                .toolbar { toolbarContent }
                .disableNavigationBarMinimization()
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let tutorial {
                        AppTutorialTipHost(tutorial: tutorial, screen: .todoList)
                    }
                }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let updateInfo = appUpdate.updateInfo {
                        appUpdateBanner(updateInfo)
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                    VStack(spacing: 8) {
                        if syncMonitor.phase != .idle {
                            iCloudSyncBanner
                                .transition(reduceMotion ? .identity : .opacity)
                        }
                        if showPrioritizingIndicator || emailAutomation.isRunning {
                            prioritizingBanner
                        }
                    }
                    .allowsHitTesting(false)
                }
                .padding(.bottom, 8)
            }
        }
        }
        .background {
            Button("실행 취소 (Control)") {
                undoLastAction()
            }
            .keyboardShortcut("z", modifiers: .control)
            .opacity(0)
            .allowsHitTesting(false)
        }
        .background {
            Button("실행 취소 (Command)") {
                undoLastAction()
            }
            .keyboardShortcut("z", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
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
        #if targetEnvironment(macCatalyst)
        // Catalyst unboxes toolbar buttons into AppKit; keep the presentation host in the window.
        .outsideDismissSheet(isPresented: $showAddTodo, onDismiss: {
            tutorial?.handleAddTodoDismissed()
        }) {
            AddTodoView()
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .tutorialRunPrioritizeRequested)) { _ in
            let activeTodos = TodoPriorityScope.candidates(from: todos)
            guard !isPrioritizing, !activeTodos.isEmpty else { return }
            Task { await runPrioritize() }
        }
        .onAppear {
            tutorial?.handleTodoListAppeared()
        }
        .task {
            // Reconcile review eligibility before any notification reschedule.
            await TodoEligibilityReconciler.shared.reconcileAll(todos)
            // 등록 대기열 만료 항목 자동 제거
            let now = Date()
            let analysisCalendarIDs = CalendarService.taskAnalysisCalendarIDs()
            for todo in todos where TodoEligibilityReconciler.isExpiredReview(
                todo, now: now, selectedCalendarIDs: analysisCalendarIDs
            ) {
                await TodoEligibilityReconciler.shared.reconcile(todo)
                TaskBehaviorRecorder.recordDeletion(of: todo, actor: .system, in: modelContext)
                modelContext.delete(todo)
            }
            // Only selected, unambiguous calendar suggestions can auto-promote.
            await TodoEligibilityReconciler.shared.promoteUpcomingRecurringReviews(
                in: todos, now: now, selectedCalendarIDs: analysisCalendarIDs
            )
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
            guard UserCloudSyncPolicy.isRequested, FullCloudSyncService.shared.hasFinishedInitialRestore else { return }
            // Only confirmed import plus local restore may trigger post-sync setup.
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
        .alert(
            AppLanguage.localized("todo.detail.saveErrorTitle", defaultValue: "저장 오류", language: .current, comment: "To-do save error title."),
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button(AppLanguage.localized("action.confirm", defaultValue: "확인", language: .current, comment: "Dismiss to-do save error.")) {
                saveError = nil
            }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Subviews

    private var todoBoard: some View {
        VStack(spacing: 0) {
            #if !targetEnvironment(macCatalyst)
            boardCategoryBar
            taskBanner
            #endif
            TodoBoardView(
                todos: todos,
                showActiveColumn: $showActiveColumn,
                showOverdueColumn: $showOverdueColumn,
                showReviewColumn: $showReviewColumn,
                showCompletedColumn: $showCompletedColumn,
                autoHideEmpty: $autoHideEmpty,
                onToggleComplete: { toggleComplete($0) },
                onDelete: { deleteTodo($0) },
                onPromote: { promoteTodo($0) },
                onMoveTodoToColumn: { moveTodo($0, toColumn: $1) },
                onAddTodo: { openAddTodoIfAllowed() },
                canOpenAddTodo: canOpenAddTodoDuringTutorial
            )
        }
    }

    #if !targetEnvironment(macCatalyst)
    /// These categories control actual board visibility, not the independent list filter.
    private var boardCategoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BoardColumnType.allCases) { column in
                    boardCategoryChip(column)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func boardCategoryChip(_ column: BoardColumnType) -> some View {
        let visibility = boardColumnVisibility(column)
        let isVisible = visibility.wrappedValue
        return Button {
            withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) {
                visibility.wrappedValue.toggle()
            }
        } label: {
            Label(column.title, systemImage: isVisible ? "checkmark.circle.fill" : "circle")
                .font(.subheadline.weight(isVisible ? .semibold : .regular))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: AppTheme.controlRadius))
        .tint(isVisible ? AppTheme.accent : .secondary)
        .accessibilityLabel(column.title)
        .accessibilityAddTraits(isVisible ? [.isSelected] : [])
        .accessibilityIdentifier("todo.board.category.\(column.rawValue)")
    }

    private func boardColumnVisibility(_ column: BoardColumnType) -> Binding<Bool> {
        switch column {
        case .active: return $showActiveColumn
        case .overdue: return $showOverdueColumn
        case .review: return $showReviewColumn
        case .completed: return $showCompletedColumn
        }
    }
    #endif

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TodoFilter.allCases, id: \.self) { f in
                    filterChip(f)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func filterChip(_ f: TodoFilter) -> some View {
        let isSelected = filter == f
        return Button {
            withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) { filter = f }
        } label: {
            HStack(spacing: 6) {
                Text(f.localizedTitle)
                if f == .overdue && overdueCount > 0 {
                    Text("\(overdueCount)")
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.destructive)
                }
                if f == .review && reviewCount > 0 {
                    Text("\(reviewCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .frame(minHeight: 32)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: AppTheme.controlRadius))
        .tint(isSelected ? AppTheme.accent : .secondary)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("todo.filter.\(f.rawValue)")
    }

    private var todoList: some View {
        todoRows
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    filterBar
                    taskBanner
                }
                .background(AppTheme.canvas, ignoresSafeAreaEdges: [])
            }
    }

    @ViewBuilder
    private var taskBanner: some View {
        #if !targetEnvironment(macCatalyst)
        BannerAdStrip(isEligible: isAdPlacementEligible && globalSearchText.isEmpty)
        #endif
    }

    private var todoRows: some View {
        List {
            if filteredTodos.isEmpty {
                Section {
                    emptyState
                        .frame(maxWidth: .infinity, minHeight: 280)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(filteredTodos) { todo in
                    NavigationLink(value: todo) {
                        TodoRowView(
                            todo: todo,
                            onToggleComplete: { toggleComplete(todo) },
                            onDelete: { deleteTodo(todo) },
                            onPromote: { promoteTodo(todo) }
                        )
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
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
        }
        .appListStyle()
        .refreshable {
            await CalendarService.shared.syncCalendarWithTodos(context: modelContext)
#if DEBUG
            if isRefreshObservationEnabled {
                calendarRefreshCount += 1
            }
#endif
        }
#if DEBUG
        .overlay(alignment: .bottom) {
            if isRefreshObservationEnabled {
                Text("todo.refreshCount.\(calendarRefreshCount)")
                    .font(.caption2)
                    .opacity(0.01)
                    .accessibilityIdentifier("todo.refreshObserved")
            }
        }
#endif
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: emptyIcon)
                .font(.largeTitle.weight(.light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(emptyTitle)
                .font(.title3.weight(.semibold))
            if !emptyDescription.isEmpty {
                Text(emptyDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if filter != .completed {
                Button {
                    openAddTodoIfAllowed()
                } label: {
                    Text(
                        AppLanguage.localized("todo.add", defaultValue: "할 일 추가", language: .current, comment: "Add to-do button")
                    )
                    .font(.body.weight(.semibold))
                    .frame(minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.roundedRectangle(radius: AppTheme.controlRadius))
                .padding(.top, 8)
                .disabled(!canOpenAddTodoDuringTutorial)
            }
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
    }

    private var emptyTitle: String {
        let (key, fallback): (String, String) = switch filter {
        case .all:       ("todo.empty.title.all", "할 일이 없습니다")
        case .active:    todos.contains(where: \.isCompleted)
            ? ("todo.empty.title.active", "모두 완료했습니다!")
            : ("todo.empty.title.all", "할 일이 없습니다")
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
        case .active:    ("todo.empty.description.active", "새 할 일을 적고 필요하면 마감일을 설정하세요.")
        case .overdue:   ("todo.empty.description.overdue", "모든 항목이 기한 내에 있습니다.")
        case .completed: ("todo.empty.description.completed", "완료한 항목이 여기에 표시됩니다.")
        case .review:    ("todo.empty.description.review", "캘린더에서 가져온 일정이 마감일 순으로 표시됩니다. 스와이프해 진행중으로 추가하면 캘린더에 등록됩니다.")
        default:         ("todo.empty.description.none", "")
        }
        return AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "To-do empty state description")
    }

    private var prioritizingBanner: some View {
        HStack(alignment: .top, spacing: 12) {
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
            VStack(alignment: .leading, spacing: 6) {
                Text(prioritizingStatusText)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    AppLanguage.localized(
                        "todo.priority.backgroundWarning",
                        defaultValue: "앱을 나가거나 화면을 끄면 분석이 중단됩니다",
                        language: .current,
                        comment: "Background analysis warning."
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .padding(.horizontal, 24)
    }

    private func appUpdateBanner(_ updateInfo: AppUpdateInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(AppTheme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(updateInfo.title)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(updateInfo.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("업데이트") {
                appUpdate.openAppStore()
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button {
                appUpdate.dismissCurrentUpdate()
            } label: {
                Image(systemName: "xmark")
                    .font(.body)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("업데이트 알림 닫기")
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .padding(.horizontal, 24)
    }

    // MARK: - iCloud Sync Banner

    private var iCloudSyncBanner: some View {
        HStack(alignment: .top, spacing: 12) {
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
            VStack(alignment: .leading, spacing: 6) {
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(AppLanguage.localized("todo.icloud.empty", defaultValue: "할 일, 페르소나, 설정 정보를 불러오고 있습니다", language: .current, comment: "iCloud sync progress."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .completed:
                    Text(AppLanguage.localized("todo.icloud.completed", defaultValue: "저장된 데이터 불러오기 완료", language: .current, comment: "Confirmed local restoration, not a promise that every upload completed."))
                        .font(.subheadline.weight(.medium))
                case .idle:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .padding(.horizontal, 24)
    }

    // MARK: - Swipe Actions

    private func completeButton(_ todo: Todo) -> some View {
        Button {
            withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) { toggleComplete(todo) }
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
            withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) { _ = deleteTodo(todo) }
        } label: {
            Label(
                AppLanguage.localized("action.delete", defaultValue: "삭제", language: .current, comment: "Delete to-do action."),
                systemImage: "trash"
            )
        }
    }
    private func promoteTodo(_ todo: Todo) {
        undoStack.append(.promote(todoID: todo.id, previousTriage: todo.triageStatus))
        Task { @MainActor in
            await TodoEligibilityReconciler.shared.setTriage(.todo, for: todo)
            _ = withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) {
                CalendarService.shared.applyAutoRegistration(for: todo)
            }
        }
    }

    /// 등록 대기열 항목을 진행중으로 승격 + 캘린더 자동 등록 정책 적용
    private func promoteButton(_ todo: Todo) -> some View {
        Button {
            promoteTodo(todo)
        } label: {
            Label(
                AppLanguage.localized("action.promoteToActive", defaultValue: "진행중으로 추가", language: .current, comment: "Promote review item to active action."),
                systemImage: "checkmark.circle"
            )
        }
        .tint(AppTheme.accent)
    }

    // MARK: - Toolbar

    private var settingsButtonNeedsTutorialGlow: Bool {
        switch tutorial?.currentStep {
        case .persona, .priorityRules, .emailOptional, .permissions:
            return true
        default:
            return false
        }
    }

    private var canOpenAddTodoDuringTutorial: Bool {
        guard tutorial?.isActive == true else { return true }
        return tutorial?.currentStep == .addTodoOpen
            || (tutorial?.currentStep == .autoSort
                && !todos.contains { !$0.isCompleted && $0.triage == .todo })
    }

    private var canOpenSettingsDuringTutorial: Bool {
        guard tutorial?.isActive == true else { return true }
        return settingsButtonNeedsTutorialGlow
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if horizontalSizeClass == .regular || tutorial?.currentStep == .autoSort {
            ToolbarItem(placement: .topBarTrailing) {
                #if targetEnvironment(macCatalyst)
                // A UIKit host keeps the disabled control alive; native toolbar
                // unboxing replaces its button with an image and leaves stale constraints.
                CatalystToolbarButton(
                    title: AppLanguage.localized("action.prioritize", defaultValue: "AI 정리", language: .current, comment: "Prioritize with AI action."),
                    systemImage: "sparkles", accessibilityIdentifier: "todo.prioritizeButton"
                ) {
                    tutorial?.handlePrioritizeTriggered()
                    Task { await runPrioritize() }
                }
                .disabled(isPrioritizing || !todos.contains { !$0.isCompleted && $0.triage == .todo })
                .appTutorialGlow(tutorial?.currentStep == .autoSort)
                #else
                Button {
                    tutorial?.handlePrioritizeTriggered()
                    Task { await runPrioritize() }
                } label: {
                    Label(
                        AppLanguage.localized("action.prioritize", defaultValue: "AI 정리", language: .current, comment: "Prioritize with AI action."),
                        systemImage: "sparkles"
                    )
                    .appTutorialGlow(tutorial?.currentStep == .autoSort)
                }
                .disabled(isPrioritizing || !todos.contains { !$0.isCompleted && $0.triage == .todo })
                .accessibilityIdentifier("todo.prioritizeButton")
                #endif
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                openAddTodoIfAllowed()
            } label: {
                Label {
                    Text(AppLanguage.localized("todo.add.accessibilityLabel", defaultValue: "새 할 일 추가", language: .current, comment: "Add to-do button."))
                } icon: {
                    Image(systemName: "plus")
                        .appTutorialGlow(tutorial?.currentStep == .addTodoOpen)
                }
                .labelStyle(.iconOnly)
            }
            .disabled(!canOpenAddTodoDuringTutorial)
            .accessibilityLabel(AppLanguage.localized("todo.add.accessibilityLabel", defaultValue: "새 할 일 추가", language: .current, comment: "Add to-do button."))
            .accessibilityIdentifier("todo.addButton")
            #if !targetEnvironment(macCatalyst)
            .outsideDismissSheet(isPresented: $showAddTodo, onDismiss: {
                tutorial?.handleAddTodoDismissed()
            }) {
                AddTodoView()
                    // iPad popovers report compact traits; size the editor for the presenting window.
                    .environment(\.horizontalSizeClass, horizontalSizeClass)
            }
            #endif
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if horizontalSizeClass == .regular {
                    if isBoardMode {
                        Section(AppLanguage.localized("board.columns.title", defaultValue: "보드 컬럼 표시", language: .current, comment: "Board columns")) {
                            Toggle(isOn: $showActiveColumn) {
                                Label(TodoFilter.active.localizedTitle, systemImage: "play.circle")
                            }
                            Toggle(isOn: $showOverdueColumn) {
                                Label(TodoFilter.overdue.localizedTitle, systemImage: "exclamationmark.circle")
                            }
                            Toggle(isOn: $showReviewColumn) {
                                Label(TodoFilter.review.localizedTitle, systemImage: "tray.full")
                            }
                            Toggle(isOn: $showCompletedColumn) {
                                Label(TodoFilter.completed.localizedTitle, systemImage: "checkmark.circle")
                            }
                        }

                        Section {
                            Toggle(isOn: $autoHideEmpty) {
                                Label(
                                    AppLanguage.localized("board.columns.autoHideEmpty", defaultValue: "빈 컬럼 숨기기", language: .current, comment: "Auto hide empty columns"),
                                    systemImage: "eye.slash.circle"
                                )
                            }
                        }
                    }

                    Section(AppLanguage.localized("board.viewMode.title", defaultValue: "보기 방식", language: .current, comment: "View mode toggle")) {
                        Button {
                            withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) { isBoardMode = true }
                        } label: {
                            Label(
                                AppLanguage.localized("board.viewMode.board", defaultValue: "보드 보기", language: .current, comment: "Board view mode"),
                                systemImage: isBoardMode ? "checkmark" : "rectangle.split.3x1"
                            )
                        }

                        Button {
                            withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) { isBoardMode = false }
                        } label: {
                            Label(
                                AppLanguage.localized("board.viewMode.list", defaultValue: "목록 보기", language: .current, comment: "List view mode"),
                                systemImage: !isBoardMode ? "checkmark" : "list.bullet"
                            )
                        }
                    }

                    if isBoardMode && !areAllColumnsVisible {
                        Section {
                            Button(AppLanguage.localized("board.columns.showAll", defaultValue: "모든 컬럼 표시", language: .current, comment: "Show all columns")) {
                                withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) {
                                    showActiveColumn = true
                                    showOverdueColumn = true
                                    showReviewColumn = true
                                    showCompletedColumn = true
                                }
                            }
                        }
                    }
                    Divider()
                }

                Button {
                    guard canOpenSettingsDuringTutorial else { return }
                    NotificationCenter.default.post(name: .settingsRequested, object: nil)
                } label: {
                    Label(
                        AppLanguage.localized("todo.settings.accessibilityLabel", defaultValue: "설정", language: .current, comment: "Settings button."),
                        systemImage: "gear"
                    )
                    .appTutorialGlow(settingsButtonNeedsTutorialGlow)
                }
                .disabled(!canOpenSettingsDuringTutorial)
                .accessibilityIdentifier("todo.settingsButton")

                if horizontalSizeClass != .regular && tutorial?.isActive != true {
                    Button {
                        Task { await runPrioritize() }
                    } label: {
                        Label(
                            AppLanguage.localized("action.prioritize", defaultValue: "AI 정리", language: .current, comment: "Prioritize with AI action."),
                            systemImage: "sparkles"
                        )
                    }
                    .disabled(isPrioritizing || !todos.contains { !$0.isCompleted && $0.triage == .todo })
                    .accessibilityIdentifier("todo.prioritizeButton")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .appTutorialGlow(settingsButtonNeedsTutorialGlow)
            }
            .toggleStyle(.automatic) // Menus retain native checkmarks, not form switches.
            .disabled(tutorial?.isActive == true && !canOpenSettingsDuringTutorial)
            .accessibilityLabel(AppLanguage.localized("todo.moreActions", defaultValue: "더 보기", language: .current, comment: "Secondary to-do toolbar menu accessibility label."))
            .accessibilityIdentifier("todo.moreActionsMenu")
        }
    }

    // MARK: - Actions

    private func openAddTodoIfAllowed() {
        guard canOpenAddTodoDuringTutorial else { return }
        tutorial?.handleAddTodoOpened()
        showAddTodo = true
    }

    private func undoLastAction() {
        guard let lastAction = undoStack.popLast() else { return }
        withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) {
            switch lastAction {
            case .toggleComplete(let todoID, let wasCompleted, let previousCompletedAt):
                if let todo = todos.first(where: { $0.id == todoID }) {
                    TodoMutations.setCompleted(todo, completed: wasCompleted, in: modelContext)
                    todo.completedAt = previousCompletedAt
                    try? modelContext.save()
                }
            case .promote(let todoID, let previousTriage):
                if let todo = todos.first(where: { $0.id == todoID }) {
                    todo.triageStatus = previousTriage
                    todo.updatedAt = Date()
                    try? modelContext.save()
                }
            case .delete(let snapshot):
                _ = snapshot.restore(into: modelContext)
            case .restore(let snapshot):
                if let todo = todos.first(where: { $0.id == snapshot.id }) {
                    snapshot.apply(to: todo)
                    try? modelContext.save()
                }
            }
        }
    }

    private func moveTodo(_ todoID: UUID, toColumn col: BoardColumnType) {
        guard let todo = todos.first(where: { $0.id == todoID }) else { return }
        let snapshot = TodoUndoSnapshot(from: todo)
        undoStack.append(.restore(snapshot: snapshot))

        withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) {
            switch col {
            case .active:
                if todo.isCompleted {
                    TodoMutations.setCompleted(todo, completed: false, in: modelContext)
                }
                if todo.triage != .todo {
                    Task { @MainActor in
                        await TodoEligibilityReconciler.shared.setTriage(.todo, for: todo)
                        _ = withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) {
                            CalendarService.shared.applyAutoRegistration(for: todo)
                        }
                    }
                }
                if todo.isOverdue {
                    let endOfToday = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date()) ?? Date().addingTimeInterval(3600 * 4)
                    todo.dueDate = endOfToday
                }
                todo.updatedAt = Date()
                try? modelContext.save()

            case .overdue:
                if todo.isCompleted {
                    TodoMutations.setCompleted(todo, completed: false, in: modelContext)
                }
                if todo.triage != .todo {
                    todo.triageStatus = TodoTriage.todo.rawValue
                }
                if !todo.isOverdue {
                    todo.dueDate = Date().addingTimeInterval(-3600)
                }
                todo.updatedAt = Date()
                try? modelContext.save()

            case .review:
                if todo.isCompleted {
                    TodoMutations.setCompleted(todo, completed: false, in: modelContext)
                }
                todo.triageStatus = TodoTriage.review.rawValue
                todo.updatedAt = Date()
                try? modelContext.save()

            case .completed:
                if !todo.isCompleted {
                    TodoMutations.setCompleted(todo, completed: true, in: modelContext)
                }
            }
        }
    }

    private func toggleComplete(_ todo: Todo) {
        undoStack.append(.toggleComplete(todoID: todo.id, wasCompleted: todo.isCompleted, previousCompletedAt: todo.completedAt))
        TodoMutations.setCompleted(todo, completed: !todo.isCompleted, in: modelContext)
    }

    @discardableResult
    private func deleteTodo(_ todo: Todo) -> Bool {
        let snapshot = TodoUndoSnapshot(from: todo)
        do {
            try TodoMutations.delete(todo, in: modelContext)
            undoStack.append(.delete(snapshot: snapshot))
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        let selectedTodos = offsets.map { filteredTodos[$0] }
        for todo in selectedTodos {
            guard deleteTodo(todo) else { break }
        }
    }

    private func applyPriorityResult(_ result: PriorityResult, in activeTodos: [Todo]) {
        guard let candidate = activeTodos.first(where: { $0.id == result.todoID }) else { return }
        let previousScore = candidate.computedPriorityScore
        guard let todo = TodoPriorityScope.apply(result, in: activeTodos) else { return }
        TaskBehaviorRecorder.recordComputedPriorityChange(
            of: todo,
            from: previousScore,
            to: todo.computedPriorityScore,
            actor: result.engine == .heuristic ? .system : .artificialIntelligence,
            in: modelContext
        )
        guard todo.aiNeedsNotification,
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
        let routingDecision = BetaFeaturePolicy().routingDecision(for: .standardAnalysis)
        let activeTodos = TodoPriorityScope.candidates(from: todos)
        
        isPrioritizing = true
        let routingName: String
        switch routingDecision {
        case .rules:
            routingName = PriorityEngine.heuristic.displayName(language: .current)
        case .providers(let providers):
            routingName = providers.first?.displayName(language: .current)
                ?? PriorityEngine.heuristic.displayName(language: .current)
        }
        prioritizingStatusText = String(
            format: AppLanguage.localized("todo.ai.starting", defaultValue: "%@ 시작 중…", language: .current, comment: "AI prioritization progress."),
            routingName
        )
        prioritizingProgressValue = nil
        #if DEBUG
        print("[TodoListView] priority rules tapped, route=\(routingName), activeTodos=\(activeTodos.count)")
        #endif
        withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) { showPrioritizingIndicator = true }
        defer {
            isPrioritizing = false
            prioritizingProgressValue = nil
            withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) { showPrioritizingIndicator = false }
        }

        let persona = PersonaContext(
            types: personas.first?.personaTypes ?? [],
            description: personas.first?.descriptionText ?? ""
        )
        let analysisSelection = CalendarService.taskAnalysisCalendarIDs()
        let events = CalendarService.shared.taskAnalysisEvents()

        var appliedResultIDs = Set<UUID>()
        let service = RoutedIntelligenceEngine()
        let results: [PriorityResult]
        do {
            results = try await service.prioritize(
                todos: activeTodos,
                events: events,
                persona: persona,
                progress: { event in
                    guard CalendarService.taskAnalysisCalendarIDs() == analysisSelection else { return }
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
            guard CalendarService.taskAnalysisCalendarIDs() == analysisSelection else { return }
            for result in results where !appliedResultIDs.contains(result.todoID) {
                applyPriorityResult(result, in: activeTodos)
                appliedResultIDs.insert(result.todoID)
            }
            // Finish only after streamed and final results survive app termination.
            try modelContext.save()
        } catch is CancellationError {
            return
        } catch {
            showAFMError = true
            return
        }
    }
}

#Preview {
    TodoListView()
        .modelContainer(for: [Todo.self, Persona.self], inMemory: true)
}
