import SwiftUI
import SwiftData

// MARK: - Board Column Definition

enum BoardColumnType: String, CaseIterable, Identifiable {
    case active
    case overdue
    case review
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active:
            return AppLanguage.localized("todo.filter.active", defaultValue: "진행중", language: .current, comment: "Active column")
        case .overdue:
            return AppLanguage.localized("todo.filter.overdue", defaultValue: "기한초과", language: .current, comment: "Overdue column")
        case .review:
            return AppLanguage.localized("todo.filter.review", defaultValue: "등록 대기열", language: .current, comment: "Review queue column")
        case .completed:
            return AppLanguage.localized("todo.filter.completed", defaultValue: "완료", language: .current, comment: "Completed column")
        }
    }

    var themeColor: Color {
        switch self {
        case .active: return AppTheme.accent
        case .overdue: return AppTheme.destructive
        case .review: return AppTheme.warning
        case .completed: return AppTheme.success
        }
    }

    var iconName: String {
        switch self {
        case .active: return "play.circle.fill"
        case .overdue: return "exclamationmark.circle.fill"
        case .review: return "tray.full.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }
}

// MARK: - Notion Style Board Card

private struct TodoDragPreview: View {
    let todo: Todo
    let col: BoardColumnType

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(col.themeColor)
                .frame(width: 8, height: 8)
            Text(todo.title.isEmpty ? AppLanguage.localized("todo.noTitle", defaultValue: "(제목 없음)", language: .current, comment: "Untitled to-do placeholder.") : todo.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        )
    }
}

struct TodoBoardCardView: View {
    let todo: Todo
    var onToggleComplete: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onPromote: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(priorityColor)
                    .frame(width: 3.5, height: 16)
                    .padding(.top, 2)

                Text(todo.title.isEmpty
                     ? AppLanguage.localized("todo.noTitle", defaultValue: "(제목 없음)", language: .current, comment: "Untitled to-do placeholder.")
                     : todo.title)
                    .font(.subheadline.weight(.medium))
                    .strikethrough(todo.isCompleted)
                    .foregroundStyle(todo.isCompleted ? .secondary : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                sourceBadge

                Menu {
                    cardMenuActions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .background(Color.primary.opacity(isHovered ? 0.08 : 0), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
            }

            if todo.todoSource == .email, !todo.sourceSender.isEmpty {
                Label(todo.sourceSender, systemImage: "person.crop.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                if let label = todo.dueDateLabel {
                    Label(label, systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(todo.isOverdue ? AppTheme.destructive : .secondary)
                }
                if !todo.tags.isEmpty {
                    Label(todo.tags.prefix(1).joined(), systemImage: "tag")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !todo.priorityReason.isEmpty && todo.manualPriority == nil {
                    if todo.aiPersonaFit {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.accent)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovered ? AppTheme.accent.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(isHovered ? 0.08 : 0.02), radius: isHovered ? 4 : 1, y: 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            cardMenuActions
        }
    }

    @ViewBuilder
    private var cardMenuActions: some View {
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

    private var priorityColor: Color {
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
        if days < 1 { return AppTheme.destructive }
        if days < 3 { return AppTheme.warning }
        if days < 7 { return AppTheme.accent }
        return .gray.opacity(0.4)
    }

    @ViewBuilder
    private var sourceBadge: some View {
        switch todo.todoSource {
        case .email:
            Image(systemName: "envelope.fill")
                .font(.caption2)
                .foregroundStyle(AppTheme.accent)
        case .calendar:
            Image(systemName: todo.isFixedSchedule ? "arrow.triangle.2.circlepath" : "calendar")
                .font(.caption2)
                .foregroundStyle(AppTheme.accent)
        case .meeting:
            Image(systemName: "person.2.fill")
                .font(.caption2)
                .foregroundStyle(AppTheme.accent)
        case .manual:
            EmptyView()
        }
    }
}

// MARK: - Notion Style Board View

struct TodoBoardView: View {
    let todos: [Todo]
    @Binding var showActiveColumn: Bool
    @Binding var showOverdueColumn: Bool
    @Binding var showReviewColumn: Bool
    @Binding var showCompletedColumn: Bool
    @Binding var autoHideEmpty: Bool
    let onToggleComplete: (Todo) -> Void
    let onDelete: (Todo) -> Void
    let onPromote: (Todo) -> Void
    let onMoveTodoToColumn: (UUID, BoardColumnType) -> Void
    let onAddTodo: () -> Void
    let canOpenAddTodo: Bool

    @State private var isDropTargeted: [BoardColumnType: Bool] = [:]

    private func isColumnVisible(_ col: BoardColumnType) -> Bool {
        switch col {
        case .active: return showActiveColumn
        case .overdue: return showOverdueColumn
        case .review: return showReviewColumn
        case .completed: return showCompletedColumn
        }
    }

    private func toggleColumn(_ col: BoardColumnType) {
        withAnimation(.easeInOut(duration: 0.2)) {
            switch col {
            case .active: showActiveColumn.toggle()
            case .overdue: showOverdueColumn.toggle()
            case .review: showReviewColumn.toggle()
            case .completed: showCompletedColumn.toggle()
            }
        }
    }

    private var visibleColumns: [BoardColumnType] {
        BoardColumnType.allCases.filter { col in
            guard isColumnVisible(col) else { return false }
            if autoHideEmpty && todosForColumn(col).isEmpty {
                return false
            }
            return true
        }
    }

    private func todosForColumn(_ col: BoardColumnType) -> [Todo] {
        switch col {
        case .active:
            return todos.filter {
                guard !$0.isCompleted && $0.triage == .todo else { return false }
                return !$0.isOverdue || $0.effectivePriority >= 0.8
            }
            .sorted(by: TodoPriorityOrdering.higherPriorityFirst)
        case .overdue:
            return todos.filter { $0.isOverdue && $0.triage == .todo }
                .sorted(by: TodoPriorityOrdering.higherPriorityFirst)
        case .review:
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
                .sorted {
                    let date0 = $0.completedAt ?? $0.updatedAt
                    let date1 = $1.completedAt ?? $1.updatedAt
                    return date0 > date1
                }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if visibleColumns.isEmpty {
                ContentUnavailableView {
                    Label(
                        AppLanguage.localized("board.empty.title", defaultValue: "표시할 컬럼이 없습니다", language: .current, comment: "No columns visible title"),
                        systemImage: "eye.slash"
                    )
                } description: {
                    Text(AppLanguage.localized("board.empty.desc", defaultValue: "상단의 눈 버튼을 눌러 컬럼을 활성화해주세요.", language: .current, comment: "No columns visible description"))
                } actions: {
                    Button(AppLanguage.localized("board.columns.showAll", defaultValue: "모든 컬럼 표시", language: .current, comment: "Show all columns")) {
                        withAnimation {
                            showActiveColumn = true
                            showOverdueColumn = true
                            showReviewColumn = true
                            showCompletedColumn = true
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let availableWidth = geometry.size.width - 40 - CGFloat(visibleColumns.count - 1) * 16
                let dynamicWidth = max(280, min(350, availableWidth / CGFloat(max(1, visibleColumns.count))))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(visibleColumns) { col in
                            boardColumn(col)
                                .frame(width: dynamicWidth)
                                .frame(maxHeight: max(200, geometry.size.height - 32))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func boardColumn(_ col: BoardColumnType) -> some View {
        let items = todosForColumn(col)

        return VStack(alignment: .leading, spacing: 12) {
            // Column Header
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(col.themeColor)
                        .frame(width: 7, height: 7)
                    Text(col.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(items.count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(col.themeColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(col.themeColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

                Spacer()

                Button {
                    toggleColumn(col)
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .help(AppLanguage.localized("board.column.hide", defaultValue: "이 컬럼 숨기기", language: .current, comment: "Hide column"))
                .accessibilityLabel(AppLanguage.localized("board.column.hide", defaultValue: "이 컬럼 숨기기", language: .current, comment: "Hide column"))

                Button {
                    onAddTodo()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .disabled(!canOpenAddTodo)
            }
            .padding(.horizontal, 4)

            // Column Cards
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    if items.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: col.iconName)
                                .font(.title2)
                                .foregroundStyle(col.themeColor.opacity(0.35))
                            Text(AppLanguage.localized("board.column.empty", defaultValue: "항목 없음", language: .current, comment: "Empty column"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 100)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .foregroundStyle(Color.primary.opacity(0.08))
                        )
                    } else {
                        ForEach(items) { todo in
                            NavigationLink(value: todo) {
                                TodoBoardCardView(
                                    todo: todo,
                                    onToggleComplete: { onToggleComplete(todo) },
                                    onDelete: { onDelete(todo) },
                                    onPromote: { onPromote(todo) }
                                )
                            }
                            .buttonStyle(.plain)
                            .draggable(todo.id.uuidString) {
                                TodoDragPreview(todo: todo, col: col)
                            }
                        }
                    }

                    Button {
                        onAddTodo()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.caption.bold())
                            Text(AppLanguage.localized("todo.add", defaultValue: "새 할 일", language: .current, comment: "Add task"))
                                .font(.caption.weight(.medium))
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canOpenAddTodo)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill((isDropTargeted[col] == true) ? col.themeColor.opacity(0.12) : Color(uiColor: .tertiarySystemGroupedBackground).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    (isDropTargeted[col] == true) ? col.themeColor : Color.clear,
                    lineWidth: (isDropTargeted[col] == true) ? 2 : 0
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted[col])
        .dropDestination(for: String.self) { droppedIDs, location in
            guard let idString = droppedIDs.first, let uuid = UUID(uuidString: idString) else { return false }
            onMoveTodoToColumn(uuid, col)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeInOut(duration: 0.15)) {
                isDropTargeted[col] = targeted
            }
        }
    }
}
