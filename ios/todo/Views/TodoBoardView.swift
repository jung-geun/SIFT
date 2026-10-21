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

// MARK: - Board Card

struct TodoBoardCardView: View {
    let todo: Todo
    var onToggleComplete: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onPromote: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var cardSize: CGSize = .zero
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        cardSurface
            .onGeometryChange(for: CGSize.self) { geometry in
                geometry.size
            } action: { size in
                cardSize = size
            }
            .contentShape(.dragPreview, RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
            .draggable(todo.id.uuidString) {
                // Reuse the actual card at its laid-out size, including metadata and actions.
                cardSurface
                    .frame(width: cardSize.width, height: cardSize.height)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .allowsHitTesting(false)
            }
            .onHover { hovering in
                withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) {
                    isHovered = hovering
                }
            }
            .contextMenu {
                cardMenuActions
            }
    }

    private var cardSurface: some View {
        // Keep navigation and the action menu as sibling controls, not nested buttons.
        HStack(alignment: .top, spacing: 0) {
            NavigationLink(value: todo) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                    Text(todo.title.isEmpty
                         ? AppLanguage.localized("todo.noTitle", defaultValue: "(제목 없음)", language: .current, comment: "Untitled to-do placeholder.")
                         : todo.title)
                        .font(.headline)
                        .strikethrough(todo.isCompleted)
                        .foregroundStyle(todo.isCompleted ? .secondary : .primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)

                    if hasMetadata {
                        VStack(alignment: .leading, spacing: 6) {
                            if let label = todo.dueDateLabel {
                                Label(label, systemImage: "clock")
                                    .foregroundStyle(todo.isOverdue ? AppTheme.destructive : .secondary)
                            }

                            sourceMetadata

                            if todo.todoSource == .email, !todo.sourceSender.isEmpty {
                                Text(todo.sourceSender)
                                    .lineLimit(2)
                            }

                            if !todo.tags.isEmpty {
                                Label(todo.tags.joined(separator: ", "), systemImage: "tag")
                                    .lineLimit(2)
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                cardMenuActions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel(AppLanguage.localized("todo.moreActions", defaultValue: "더 보기", language: .current, comment: "Secondary to-do toolbar menu accessibility label."))
            .padding(.trailing, 4)
        }
        .frame(minHeight: 52)
        .background(
            isHovered ? AppTheme.insetSurface : AppTheme.surface,
            in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }

    private var hasMetadata: Bool {
        todo.dueDate != nil || todo.todoSource != .manual || !todo.tags.isEmpty
    }

    @ViewBuilder
    private var cardMenuActions: some View {
        NavigationLink(value: todo) {
            Label(
                AppLanguage.localized("action.details", defaultValue: "세부 정보", language: .current, comment: "Open to-do details for viewing and editing."),
                systemImage: "info.circle"
            )
        }
        .accessibilityIdentifier("todo.board.openDetails")

        Divider()

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

    @ViewBuilder
    private var sourceMetadata: some View {
        switch todo.todoSource {
        case .email:
            Label("이메일", systemImage: "envelope")
        case .calendar:
            Label("캘린더", systemImage: todo.isFixedSchedule ? "arrow.triangle.2.circlepath" : "calendar")
        case .meeting:
            Label("회의", systemImage: "person.2")
        case .manual:
            EmptyView()
        }
    }
}

// MARK: - Board View

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func isColumnVisible(_ col: BoardColumnType) -> Bool {
        switch col {
        case .active: return showActiveColumn
        case .overdue: return showOverdueColumn
        case .review: return showReviewColumn
        case .completed: return showCompletedColumn
        }
    }

    private func toggleColumn(_ col: BoardColumnType) {
        withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) {
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
                    Button {
                        withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) {
                            showActiveColumn = true
                            showOverdueColumn = true
                            showReviewColumn = true
                            showCompletedColumn = true
                            autoHideEmpty = false
                        }
                    } label: {
                        Text(AppLanguage.localized("board.columns.showAll", defaultValue: "모든 컬럼 표시", language: .current, comment: "Show all columns"))
                            .frame(minHeight: 44)
                            .padding(.horizontal, AppTheme.Spacing.item)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let availableWidth = geometry.size.width - AppTheme.Spacing.section * 2 - CGFloat(visibleColumns.count - 1) * AppTheme.Spacing.section
                let dynamicWidth = max(280, min(350, availableWidth / CGFloat(max(1, visibleColumns.count))))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: AppTheme.Spacing.section) {
                        ForEach(visibleColumns) { col in
                            boardColumn(col)
                                .frame(width: dynamicWidth)
                                .frame(maxHeight: max(200, geometry.size.height - AppTheme.Spacing.section * 2))
                        }
                    }
                    .padding(AppTheme.Spacing.section)
                }
            }
        }
        .background(AppTheme.canvas)
    }

    private func boardColumn(_ col: BoardColumnType) -> some View {
        let items = todosForColumn(col)

        return VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            HStack(spacing: AppTheme.Spacing.compact) {
                HStack(spacing: AppTheme.Spacing.compact) {
                    Text(col.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("\(items.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 0)

                Button {
                    toggleColumn(col)
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(AppLanguage.localized("board.column.hide", defaultValue: "이 컬럼 숨기기", language: .current, comment: "Hide column"))
                .accessibilityLabel(AppLanguage.localized("board.column.hide", defaultValue: "이 컬럼 숨기기", language: .current, comment: "Hide column"))

                Button {
                    onAddTodo()
                } label: {
                    Image(systemName: "plus")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canOpenAddTodo)
                .accessibilityLabel(AppLanguage.localized("todo.add", defaultValue: "새 할 일", language: .current, comment: "Add task"))
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: AppTheme.Spacing.compact) {
                    if items.isEmpty {
                        VStack(spacing: AppTheme.Spacing.item) {
                            Image(systemName: col.iconName)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text(AppLanguage.localized("board.column.empty", defaultValue: "항목 없음", language: .current, comment: "Empty column"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 100)
                        .padding(AppTheme.Spacing.item)
                    } else {
                        ForEach(items) { todo in
                            TodoBoardCardView(
                                todo: todo,
                                onToggleComplete: { onToggleComplete(todo) },
                                onDelete: { onDelete(todo) },
                                onPromote: { onPromote(todo) }
                            )
                        }
                    }

                    Button {
                        onAddTodo()
                    } label: {
                        HStack(spacing: AppTheme.Spacing.compact) {
                            Image(systemName: "plus")
                            Text(AppLanguage.localized("todo.add", defaultValue: "새 할 일", language: .current, comment: "Add task"))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canOpenAddTodo)
                }
                .padding(.bottom, AppTheme.Spacing.item)
            }
        }
        .padding(AppTheme.Spacing.item)
        .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(isDropTargeted[col] == true ? col.themeColor : Color.clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .dropDestination(for: String.self) { droppedIDs, location in
            guard let idString = droppedIDs.first, let uuid = UUID(uuidString: idString) else { return false }
            onMoveTodoToColumn(uuid, col)
            return true
        } isTargeted: { targeted in
            withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) {
                isDropTargeted[col] = targeted
            }
        }
    }
}
