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
                Text(todo.title.isEmpty ? "(제목 없음)" : todo.title)
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
                            .foregroundStyle(todo.isOverdue ? .red : .secondary)
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
                                .foregroundStyle(.purple)
                        }
                        // 산출 엔진 배지 — "휴리스틱"이면 LLM 경로가 메모리 부족 등으로 폴백됐음을 명시
                        if !todo.aiEngine.isEmpty {
                            let isHeuristic = todo.aiEngine == PriorityEngine.heuristic.rawValue
                            Text(todo.aiEngine)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(isHeuristic ? Color.orange : Color.blue)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    (isHeuristic ? Color.orange : Color.blue).opacity(0.1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 3))
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
        case 0.8...: return .red
        case 0.6...: return .orange
        case 0.4...: return .blue
        default:     return .gray.opacity(0.4)
        }
    }

    private var deadlineColor: Color {
        guard let due = todo.dueDate else { return .gray.opacity(0.4) }
        let days = due.timeIntervalSinceNow / 86400
        if days < 1 { return .red }      // 당일 또는 이미 지남
        if days < 3 { return .orange }   // 2-3일
        if days < 7 { return .blue }     // 4-7일
        return .gray.opacity(0.4)        // 1주+
    }

    @ViewBuilder
    private var sourceBadge: some View {
        switch todo.todoSource {
        case .email:
            Image(systemName: "envelope.fill")
                .font(.caption)
                .foregroundStyle(.blue)
        case .calendar:
            Image(systemName: todo.isFixedSchedule ? "arrow.triangle.2.circlepath" : "calendar")
                .font(.caption)
                .foregroundStyle(.green)
        case .manual:
            EmptyView()
        }
    }
}

// MARK: - Main List View

struct TodoListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Todo.createdAt, order: .reverse) private var todos: [Todo]
    @Query private var personas: [Persona]

    @ObservedObject private var llmOrchestrator = LLMAutomationOrchestrator.shared
    @AppStorage("pieroot.todo.hasOnboarded") private var hasOnboarded = false
    // "remove" = 이벤트 삭제 (기본), "silence" = 알람만 끄기
    @AppStorage("pieroot.todo.calendarCompletionAction") private var calendarCompletionAction = "remove"

    @State private var showAddTodo = false
    @State private var showSettings = false
    @State private var filter: TodoFilter = .active
    @State private var isPrioritizing = false
    @State private var showPrioritizingIndicator = false
    // MARK: - Filter

    enum TodoFilter: String, CaseIterable {
        case active    = "진행중"
        case overdue   = "기한초과"
        case all       = "전체"
        case review    = "등록 대기열"
        case completed = "완료"
    }

    var filteredTodos: [Todo] {
        switch filter {
        case .all:
            // 등록 대기열(review) 제외 — review 탭에서 별도 확인
            return todos.filter { !$0.isCompleted && $0.triage == .todo }
                .sorted { $0.effectivePriority > $1.effectivePriority }
        case .active:
            return todos.filter { !$0.isCompleted && !$0.isOverdue && $0.triage == .todo }
                .sorted { $0.effectivePriority > $1.effectivePriority }
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
            return todos.filter { $0.isCompleted }
                .sorted { $0.effectivePriority > $1.effectivePriority }
        }
    }

    var overdueCount: Int { todos.filter { $0.isOverdue && $0.triage == .todo }.count }
    var activeCount: Int  { todos.filter { !$0.isCompleted && !$0.isOverdue && $0.triage == .todo }.count }
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
                if showPrioritizingIndicator || llmOrchestrator.isRunning {
                    prioritizingBanner
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !hasOnboarded },
            set: { if !$0 { hasOnboarded = true } }
        )) {
            OnboardingView(isPresented: Binding(
                get: { !hasOnboarded },
                set: { if !$0 { hasOnboarded = true } }
            ))
        }
        .sheet(isPresented: $showAddTodo) {
            AddTodoView()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { PersonaSettingsView() }
        }
        .task {
            // 등록 대기열 만료 항목 자동 제거 (마감 지났지만 진행중으로 미등록된 항목)
            let now = Date()
            for todo in todos where todo.triage == .review && !todo.isCompleted {
                if let due = todo.dueDate, due < now { modelContext.delete(todo) }
            }
            // 반복 일정 자동 승급: 1주일 이내 마감 → 등록 대기열에서 진행중으로
            let weekAhead = now.addingTimeInterval(7 * 24 * 3600)
            for todo in todos where todo.triage == .review && todo.isFixedSchedule && !todo.isCompleted {
                if let due = todo.dueDate, due >= now, due <= weekAhead {
                    todo.triageStatus = TodoTriage.todo.rawValue
                }
            }
            await NotificationService.shared.reschedule(todos: todos)
        }
        .onChange(of: todos.count) {
            Task { await NotificationService.shared.reschedule(todos: todos) }
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
                Text(f.rawValue)
                if f == .overdue && overdueCount > 0 {
                    Text("\(overdueCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                }
                if f == .review && reviewCount > 0 {
                    Text("\(reviewCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.gray)
            .overlay {
                if isSelected {
                    Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
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
                Button("할 일 추가") { showAddTodo = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .all:       "할 일이 없습니다"
        case .active:    "모두 완료했습니다! 🎉"
        case .overdue:   "기한 초과 항목 없음"
        case .review:    "등록 대기열이 비어 있습니다"
        case .completed: "완료된 항목 없음"
        }
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
        switch filter {
        case .active:    "+ 버튼을 눌러 새 할 일을 추가하세요."
        case .overdue:   "모든 항목이 기한 내에 있습니다."
        case .completed: "완료한 항목이 여기에 표시됩니다."
        case .review:    "캘린더에서 가져온 일정이 마감일 순으로 표시됩니다. 스와이프해 진행중으로 추가하면 캘린더에 등록됩니다."
        default:         ""
        }
    }

    private var prioritizingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 우선순위 정리 중…")
                    .font(.subheadline.weight(.medium))
                Text("앱을 나가거나 화면을 끄면 분석이 중단됩니다")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    // MARK: - Swipe Actions

    private func completeButton(_ todo: Todo) -> some View {
        Button {
            withAnimation { toggleComplete(todo) }
        } label: {
            Label(
                todo.isCompleted ? "되돌리기" : "완료",
                systemImage: todo.isCompleted ? "arrow.uturn.left" : "checkmark"
            )
        }
        .tint(todo.isCompleted ? .orange : .green)
    }

    private func deleteButton(_ todo: Todo) -> some View {
        Button(role: .destructive) {
            withAnimation { deleteTodo(todo) }
        } label: {
            Label("삭제", systemImage: "trash")
        }
    }

    /// 등록 대기열 항목을 진행중으로 승격 + 캘린더 자동 등록 정책 적용
    private func promoteButton(_ todo: Todo) -> some View {
        Button {
            withAnimation { todo.triageStatus = TodoTriage.todo.rawValue }
            CalendarService.shared.applyAutoRegistration(for: todo)
        } label: {
            Label("진행중으로 추가", systemImage: "checkmark.circle")
        }
        .tint(.blue)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 4) {
                Button { showAddTodo = true } label: {
                    Image(systemName: "plus")
                        .fontWeight(.semibold)
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gear")
                }
            }
        }
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                Task { await runPrioritize() }
            } label: {
                Label("AI 정리", systemImage: "sparkles")
            }
            .disabled(isPrioritizing || todos.filter { !$0.isCompleted }.isEmpty)
        }
    }

    // MARK: - Actions

    private func toggleComplete(_ todo: Todo) {
        todo.isCompleted.toggle()
        todo.completedAt = todo.isCompleted ? Date() : nil
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
        if let eventID = todo.calendarEventID {
            try? CalendarService.shared.removeEvent(eventID: eventID)
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
        modelContext.insert(TaskAuditEvent(from: todo))
        modelContext.delete(todo)
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets { deleteTodo(filteredTodos[index]) }
    }

    private func runPrioritize() async {
        isPrioritizing = true
        withAnimation { showPrioritizingIndicator = true }
        defer {
            isPrioritizing = false
            withAnimation { showPrioritizingIndicator = false }
        }

        let activeTodos = todos.filter { !$0.isCompleted }
        let persona = PersonaContext(
            types: personas.first?.personaTypes ?? [],
            description: personas.first?.descriptionText ?? ""
        )
        let events = CalendarService.shared.isAuthorized
            ? CalendarService.shared.upcomingEvents()
            : []

        let service = IntelligenceServiceFactory.makeService()
        let results = await service.prioritize(todos: activeTodos, events: events, persona: persona)

        for result in results {
            if let todo = activeTodos.first(where: { $0.id == result.todoID }),
               todo.manualPriority == nil {    // 수동 우선순위 절대 덮어쓰지 않음
                todo.computedPriorityScore = result.score
                todo.priorityReason        = result.reason
                todo.aiEngine              = result.engine.rawValue
                todo.aiDetail              = result.detail
                todo.aiNeedsNotification   = result.needsNotification
                todo.aiRecommendedTime     = result.recommendedTime
                todo.aiPersonaFit          = result.personaFit

                // 알림 자동 스케줄: needsNotification + dueDate 있음 + reminderOffsets 미설정
                if result.needsNotification && todo.dueDate != nil && todo.reminderOffsets.isEmpty {
                    if let rec = result.recommendedTime, let due = todo.dueDate {
                        // 추천 시각에 발화: offset = recommendedTime - dueDate
                        let offset = rec.timeIntervalSince(due)
                        todo.reminderOffsets = [offset]
                    } else {
                        // 기본: 1시간 전
                        todo.reminderOffsets = [-3600]
                    }
                    Task { await NotificationService.shared.update(todo: todo) }
                }
            }
        }
    }
}

#Preview {
    TodoListView()
        .modelContainer(for: [Todo.self, Persona.self], inMemory: true)
}
