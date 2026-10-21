import SwiftUI
import SwiftData
import EventKit
import Combine

// MARK: - Notification Names
extension Notification.Name {
    static let calendarScrollToToday = Notification.Name("pieroot.todo.calendarScrollToToday")
}

// ─────────────────────────────────────────────────────────────
// MARK: - 파일 수준 공유 헬퍼
// ─────────────────────────────────────────────────────────────

/// [start, end) 반열린 구간 기준으로 이벤트가 특정 날짜를 점유하는지 판정.
/// 다일(multi-day) 이벤트를 올바르게 표시하기 위해 startDate 비교 대신 사용.
private func eventOccupiesDay(
    _ event: CalendarService.CalendarEventSummary,
    day: Date,
    using cal: Calendar = .current
) -> Bool {
    let day0 = cal.startOfDay(for: day)
    guard let day1 = cal.date(byAdding: .day, value: 1, to: day0) else { return false }
    return event.startDate < day1 && event.endDate > day0
}

/// 종일 밴드에 배치해야 하는 이벤트: isAllDay 플래그이거나 23h 59m 이상인 다일 이벤트.
private func eventIsAllDayStyle(_ event: CalendarService.CalendarEventSummary) -> Bool {
    event.isAllDay || event.endDate.timeIntervalSince(event.startDate) >= 86340
}

/// 캘린더 ID → 대표 Color
private func calendarEventColor(for id: String) -> Color {
    CalendarPresentation.color(forCalendarID: id)
}

// ─────────────────────────────────────────────────────────────
// MARK: - 타임라인 공유 타입 (DayDetailSheet)
// ─────────────────────────────────────────────────────────────

private enum CalTimelineItem {
    case event(CalendarService.CalendarEventSummary)
    case todo(Todo)

    var start: Date {
        switch self {
        case .event(let e): return e.startDate
        case .todo(let t): return t.scheduleAnchor ?? Date()
        }
    }
    var end: Date {
        switch self {
        case .event(let e): return e.endDate
        case .todo(let t):
            let start = t.scheduleAnchor ?? Date()
            let end = t.scheduledRange?.end ?? start
            return max(end, start.addingTimeInterval(1800))
        }
    }
}

private struct CalColumnedItem {
    let item: CalTimelineItem
    let column: Int
    let columnCount: Int
}

/// 그리디 열 배정: 겹치는 아이템을 좌우로 분리
private func layoutCalColumns(_ items: [CalTimelineItem]) -> [CalColumnedItem] {
    let sorted = items.sorted { $0.start < $1.start }
    var columnEnds: [Date] = []
    var assignments: [(item: CalTimelineItem, column: Int)] = []

    for item in sorted {
        if let col = columnEnds.firstIndex(where: { $0 <= item.start }) {
            columnEnds[col] = item.end
            assignments.append((item, col))
        } else {
            columnEnds.append(item.end)
            assignments.append((item, columnEnds.count - 1))
        }
    }

    var result: [CalColumnedItem] = []
    var i = 0
    while i < assignments.count {
        var clusterEnd = assignments[i].item.end
        var j = i + 1
        while j < assignments.count && assignments[j].item.start < clusterEnd {
            clusterEnd = max(clusterEnd, assignments[j].item.end)
            j += 1
        }
        let maxCol = assignments[i..<j].map { $0.column }.max() ?? 0
        let colCount = maxCol + 1
        for k in i..<j {
            result.append(CalColumnedItem(item: assignments[k].item,
                                          column: assignments[k].column,
                                          columnCount: colCount))
        }
        i = j
    }
    return result
}

// ─────────────────────────────────────────────────────────────
// MARK: - CalendarTabView
// ─────────────────────────────────────────────────────────────

struct CalendarTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTutorialState) private var tutorial
    @Query private var allTodos: [Todo]
    @State private var displayMonth = CalendarTabView.currentMonthStart
    @State private var selectedDate: Date?
    @State private var activeSheet: CalendarActiveSheet?
    @State private var showSourceSheet = false
    @State private var sidebarVisible = true
    @State private var allEvents: [CalendarService.CalendarEventSummary] = []
    @State private var calendarSources: [CalendarService.CalendarSourceGroup] = []
    @State private var calendarColors: [String: Color] = [:]
    @State private var disabledIDs: Set<String> = []
    @State private var authorized = false
    @State private var reloadRevision = 0
    @State private var isLoading = false
    @State private var isSyncing = false

    static var currentMonthStart: Date {
        Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    }

    private var request: CalendarMonthRequest {
        CalendarMonthRequest(month: displayMonth, revision: reloadRevision,
                             disabledIDs: disabledIDs, authorized: authorized,
                             timeZone: Calendar.current.timeZone.identifier)
    }

    var body: some View {
        NavigationStack {
            Group {
                if authorized { mainContent } else { noPermissionView }
            }
            .background(colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemBackground))
            .safeAreaInset(edge: .top, spacing: 0) {
                if let tutorial { AppTutorialTipHost(tutorial: tutorial, screen: .calendarTab) }
            }
            .navigationTitle(horizontalSizeClass == .regular ? Text("") : Text("캘린더"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            .sheet(item: $activeSheet, onDismiss: reloadAllEvents) { activeSheetView($0) }
            .sheet(isPresented: $showSourceSheet) {
                CalendarSourceSheet(sources: calendarSources, disabledIDs: $disabledIDs)
            }
        }
        .task { refreshAuthorization() }
        .task(id: request) {
            let expected = request
            guard expected.authorized else { return }
            isLoading = true
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            let interval = CalendarMonthGeometry(month: expected.month).interval
            let events = await CalendarService.shared.events(from: interval.start, to: interval.end)
            guard !Task.isCancelled, request == expected else { return }
            allEvents = events
            refreshSources()
            isLoading = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: RunLoop.main)) { _ in
            if authorized { reloadAllEvents() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .calendarAuthorizationChanged)
            .receive(on: RunLoop.main)) { _ in refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshAuthorization() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .calendarScrollToToday)) { _ in goToToday() }
        .onAppear { tutorial?.handleCalendarTabAppeared() }
    }

    private var noPermissionView: some View {
        ContentUnavailableView {
            Label(AppLanguage.localized("calendar.permissionUnavailable", defaultValue: "캘린더 접근 권한 없음", language: .current, comment: "Calendar permission state title."), systemImage: "calendar.badge.exclamationmark")
                .accessibilityIdentifier("calendar.permissionUnavailable")
        } description: {
            Text(AppLanguage.localized("calendar.permissionDescription", defaultValue: "설정 > 개인정보 보호 > 캘린더에서 이 앱의 접근을 허용해주세요.", language: .current, comment: "Calendar permission state description."))
        }
    }

    private var mainContent: some View {
        GeometryReader { geometry in
            let desktop = horizontalSizeClass == .regular && geometry.size.width >= 700
            HStack(spacing: 0) {
                if desktop && sidebarVisible {
                    sidebar.frame(width: 224)
                    Divider()
                }
                VStack(spacing: 0) {
                    monthHeader(desktop: desktop)
                    CalendarMonthGrid(
                        month: displayMonth, selectedDate: selectedDate,
                        events: allEvents.filter { !disabledIDs.contains($0.calendarID) },
                        todos: Array(allTodos), colors: calendarColors, desktop: desktop,
                        onDayTap: selectDay
                    )
                    .refreshable { await performSync() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func monthHeader(desktop: Bool) -> some View {
        HStack(spacing: 12) {
            if desktop {
                Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                    .accessibilityLabel(calendarCopy("calendar.sidebar.toggle", "Show or hide calendars", "캘린더 사이드바 표시 또는 가리기"))
                    .accessibilityIdentifier("calendar.sidebarToggle")
            }
            Text(monthTitle(desktop: desktop))
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            if isLoading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(calendarCopy("calendar.loading", "Loading events", "일정 로딩 중"))
            }
            HStack(spacing: 0) {
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 30, height: 30) }
                    .accessibilityLabel(calendarCopy("calendar.month.previous", "Previous month", "이전 달"))
                    .accessibilityIdentifier("calendar.previousMonth")
                Button("오늘", action: goToToday).padding(.horizontal, 8)
                    .accessibilityIdentifier("calendar.today")
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 30, height: 30) }
                    .accessibilityLabel(calendarCopy("calendar.month.next", "Next month", "다음 달"))
                    .accessibilityIdentifier("calendar.nextMonth")
            }
            .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, desktop ? 14 : 12).padding(.vertical, desktop ? 18 : 12)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(calendarSources) { source in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(source.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(source.calendars) { info in
                                Button { toggleCalendar(info.id) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: disabledIDs.contains(info.id) ? "square" : "checkmark.square.fill")
                                            .foregroundStyle(calendarColors[info.id] ?? .accentColor)
                                        Text(info.title).foregroundStyle(.primary).lineLimit(2)
                                        Spacer(minLength: 0)
                                    }.font(.system(size: 13)).frame(minHeight: 22).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(disabledIDs.contains(info.id)
                                    ? calendarCopy("calendar.source.deselected", "Not selected", "선택 안 됨")
                                    : calendarCopy("calendar.source.selected", "Selected", "선택됨"))
                                .accessibilityIdentifier("calendar.source.\(info.id)")
                            }
                        }
                    }
                }.padding(16)
            }
            Divider()
            CalendarMiniMonth(month: displayMonth, selectedDate: selectedDate, onSelect: selectMiniDay)
                .padding(14)
        }
        .background(colorScheme == .dark ? Color(.tertiarySystemBackground) : Color(.secondarySystemBackground))
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button { showSourceSheet = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .accessibilityLabel(AppLanguage.localized("calendar.filter.accessibilityLabel", defaultValue: "캘린더 필터", language: .current, comment: "Calendar filter button."))
                .accessibilityIdentifier("calendar.filterButton").disabled(!authorized)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { activeSheet = .newEvent(date: selectedDate ?? Date()) } label: { Image(systemName: "plus") }
                .accessibilityLabel(AppLanguage.localized("calendar.add.accessibilityLabel", defaultValue: "일정 추가", language: .current, comment: "Calendar add button."))
                .accessibilityIdentifier("calendar.addButton").disabled(!authorized)
        }
    }

    @ViewBuilder private func activeSheetView(_ sheet: CalendarActiveSheet) -> some View {
        switch sheet {
        case .dayDetail(let date):
            DayDetailSheet(date: date, events: allEvents.filter { !disabledIDs.contains($0.calendarID) }, todos: Array(allTodos)) { reloadAllEvents() }
        case .newEvent(let date): EventEditSheet(mode: .create(date: date)) { reloadAllEvents() }
        case .editEvent(let detail): EventEditSheet(mode: .edit(detail: detail)) { reloadAllEvents() }
        }
    }

    private func selectDay(_ date: Date) {
        selectedDate = date
        activeSheet = .dayDetail(date: date)
    }

    private func selectMiniDay(_ date: Date) {
        selectedDate = date
        displayMonth = Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
    }


    private func monthTitle(desktop: Bool) -> AttributedString {
        var title = displayMonth.formatted(.dateTime.year().month(.wide).locale(AppLanguage.current.locale).attributedStyle)
        let size: CGFloat = desktop ? 32 : 22
        for run in title.runs {
            title[run.range].font = .system(size: size, weight: run.dateField == .year ? .light : .semibold)
        }
        return title
    }

    private func moveMonth(_ offset: Int) {
        guard let date = Calendar.current.date(byAdding: .month, value: offset, to: displayMonth) else { return }
        displayMonth = date
        selectedDate = nil
    }

    private func goToToday() {
        displayMonth = Self.currentMonthStart
        selectedDate = Calendar.current.startOfDay(for: Date())
    }

    private func toggleCalendar(_ id: String) {
        if disabledIDs.contains(id) { disabledIDs.remove(id) } else { disabledIDs.insert(id) }
        CalendarService.shared.disabledCalendarIDs = disabledIDs
    }

    private func refreshAuthorization() {
        CalendarService.shared.restoreAuthorizationIfGranted()
        authorized = CalendarService.shared.isAuthorized
        if authorized {
            disabledIDs = CalendarService.shared.disabledCalendarIDs
            reloadAllEvents()
        } else {
            allEvents = []
            calendarSources = []
            calendarColors = [:]
            activeSheet = nil
            showSourceSheet = false
            isLoading = false
        }
    }

    private func refreshSources() {
        calendarSources = CalendarService.shared.availableCalendars()
        calendarColors = Dictionary(uniqueKeysWithValues: calendarSources.flatMap(\.calendars).map {
            ($0.id, CalendarPresentation.color(forCalendarID: $0.id))
        })
    }

    func reloadAllEvents() { reloadRevision += 1 }

    @MainActor func performSync() async {
        guard authorized, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await CalendarService.shared.syncCalendarTodos(context: modelContext)
        reloadAllEvents()
    }
}

struct CalendarMonthRequest: Equatable, Hashable {
    let month: Date
    let revision: Int
    let disabledIDs: Set<String>
    let authorized: Bool
    let timeZone: String
}

func calendarCopy(_ key: String, _ english: String, _ korean: String) -> String {
    AppLanguage.localized(key, defaultValue: AppLanguage.current == .english ? english : korean,
                          language: .current, comment: "Calendar month interface.")
}

// ─────────────────────────────────────────────────────────────
// MARK: - CalendarActiveSheet
// ─────────────────────────────────────────────────────────────

enum CalendarActiveSheet: Identifiable {
    case dayDetail(date: Date)
    case newEvent(date: Date)
    case editEvent(detail: CalendarService.CalendarEventDetail)

    var id: String {
        switch self {
        case .dayDetail(let d):   return "day-\(d.timeIntervalSince1970)"
        case .newEvent(let d):    return "new-\(d.timeIntervalSince1970)"
        case .editEvent(let det): return "edit-\(det.identifier)"
        }
    }
}


// ─────────────────────────────────────────────────────────────
// MARK: - DayDetailSheet  (24h 타임라인)
// ─────────────────────────────────────────────────────────────

struct DayDetailSheet: View {
    let date: Date
    let events: [CalendarService.CalendarEventSummary]
    let todos: [Todo]
    var onDataChanged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var editingDetail: CalendarService.CalendarEventDetail?
    @State private var editingTodo: Todo?
    /// 현재 시각 (1분 타이머로 갱신)
    @State private var now: Date = Date()

    private let hourHeight: CGFloat = 64
    private let labelWidth: CGFloat = 44
    private let cal = Calendar.current
    private var dayStart: Date { cal.startOfDay(for: date) }
    private var dayEnd: Date { cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart }

    // MARK: Filtered data

    /// occupiesDay 기반 다일 이벤트 포함 필터
    private var dayEvents: [CalendarService.CalendarEventSummary] {
        events.filter { eventOccupiesDay($0, day: date) }
    }

    private var dayTodos: [Todo] {
        todos.filter {
            guard !$0.isCompleted, let anchor = $0.scheduleAnchor else { return false }
            return cal.isDate(anchor, inSameDayAs: date)
        }
    }

    /// Todo와 연동된 캘린더 이벤트 ID 집합 — 중복 표시 방지용
    private var linkedEventIDs: Set<String> {
        Set(dayTodos.compactMap { $0.calendarEventID })
    }

    /// 종일 밴드: isAllDay 또는 다일 이벤트 (연동된 Todo가 있는 이벤트는 숨김)
    private var allDayEvents: [CalendarService.CalendarEventSummary] {
        dayEvents.filter { eventIsAllDayStyle($0) && !linkedEventIDs.contains($0.identifier) }
    }

    private var timedEvents: [CalendarService.CalendarEventSummary] {
        dayEvents.filter { !eventIsAllDayStyle($0) && !linkedEventIDs.contains($0.identifier) }
    }

    private var dateTitle: String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func yOffset(for time: Date) -> CGFloat {
        let daySpan = dayEnd.timeIntervalSince(dayStart)
        guard daySpan.isFinite, daySpan > 0 else { return 0 }
        let rawOffset = time.timeIntervalSince(dayStart)
        let finiteOffset = rawOffset.isFinite ? rawOffset : 0
        let clippedSeconds = min(max(finiteOffset, 0), daySpan)
        return CGFloat(clippedSeconds / 60) * (hourHeight / 60)
    }

    private func clippedEventRange(for event: CalendarService.CalendarEventSummary) -> (start: Date, end: Date) {
        let start = max(event.startDate, dayStart)
        let end = min(event.endDate, dayEnd)
        if end <= start { return (start: start, end: start) }
        return (start: start, end: end)
    }

    private func clippedTodoRange(for todo: Todo) -> (start: Date, end: Date)? {
        guard let anchor = todo.scheduleAnchor else { return nil }
        let start = max(anchor, dayStart)
        let end = min(todo.scheduledRange?.end ?? anchor, dayEnd)
        return (start: start, end: max(end, start))
    }

    private var initialScrollHour: Int {
        let hours = timedEvents
            .map { cal.component(.hour, from: clippedEventRange(for: $0).start) }
            + dayTodos.compactMap { $0.scheduleAnchor.map { cal.component(.hour, from: $0) } }
        return max(0, (hours.min() ?? cal.component(.hour, from: Date())) - 1)
    }


    // MARK: Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !allDayEvents.isEmpty {
                    allDaySection
                    Divider()
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        if timedEvents.isEmpty && dayTodos.isEmpty && allDayEvents.isEmpty {
                            ContentUnavailableView("일정 없음", systemImage: "calendar")
                                .padding(.top, 60)
                        } else {
                            timelineGrid.padding(.bottom, 24)
                        }
                    }
                    .onAppear {
                        let h = initialScrollHour
                        DispatchQueue.main.async { proxy.scrollTo("hour-\(h)", anchor: .top) }
                    }
                }
            }
            .background(AppTheme.surface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(dateTitle).font(.headline)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
            .sheet(item: $editingDetail) { detail in
                EventEditSheet(mode: .edit(detail: detail)) {
                    Task { @MainActor in
                        await CalendarService.shared.syncCalendarWithTodos(context: modelContext)
                        onDataChanged()
                    }
                }
            }
            .sheet(item: $editingTodo) { todo in
                NavigationStack { TodoDetailView(todo: todo) }
            }
            // 1분 타이머 — 현재 시각 표시줄 갱신
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                now = Date()
            }
        }
    }

    // MARK: All-day section (compact pill 한 줄)

    private var allDaySection: some View {
        HStack(spacing: 0) {
            Text("종일")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .center)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(allDayEvents, id: \.identifier) { allDayChip($0) }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, AppTheme.Spacing.item)
    }

    @ViewBuilder
    private func allDayChip(_ event: CalendarService.CalendarEventSummary) -> some View {
        let color = calendarEventColor(for: event.calendarID)
        let day0  = cal.startOfDay(for: date)
        let day1  = cal.date(byAdding: .day, value: 1, to: day0) ?? day0
        let contL = event.startDate < day0
        let contR = event.endDate   > day1

        Button { openEventEdit(event) } label: {
            HStack(spacing: 3) {
                if contL {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                }
                Text(event.title.isEmpty ? AppLanguage.localized("calendar.event.noTitle", defaultValue: "(No Title)", language: .current, comment: "Placeholder for a calendar event without a title.") : event.title)
                    .font(.caption).fontWeight(.medium).lineLimit(1)
                    .foregroundStyle(.white)
                if event.isRecurring {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 7)).foregroundStyle(.white.opacity(0.85))
                }
                if contR {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(color.opacity(0.9), in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Timeline


    private var timelineGrid: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d", hour))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: labelWidth, height: hourHeight, alignment: .top)
                        .padding(.top, 3)
                        .id("hour-\(hour)")
                }
            }
            Rectangle().fill(Color(.separator)).frame(width: 0.5)
            GeometryReader { geo in
                let items: [CalTimelineItem] = timedEvents.map { .event($0) } + dayTodos.map { .todo($0) }
                let columned = layoutCalColumns(items)
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { _ in
                            Divider()
                            Spacer().frame(height: max(hourHeight - 0.5, 0))
                        }
                    }
                    ForEach(Array(columned.enumerated()), id: \.offset) { _, ci in
                        columnedItemView(ci, trackWidth: geo.size.width)
                    }
                    // 현재 시각 표시줄 (오늘만)
                    if cal.isDateInToday(date) {
                        let lineY = yOffset(for: now)
                        Rectangle()
                            .fill(AppTheme.destructive)
                            .frame(height: 1.5)
                            .offset(y: lineY)
                        Circle()
                            .fill(AppTheme.destructive)
                            .frame(width: 6, height: 6)
                            .position(x: 3, y: lineY)
                    }
                }
            }
            .frame(height: CGFloat(24) * hourHeight)
        }
    }

    @ViewBuilder
    private func columnedItemView(_ ci: CalColumnedItem, trackWidth: CGFloat) -> some View {
        let gap: CGFloat = 2
        let columns = max(ci.columnCount, 1)
        let safeTrackWidth: CGFloat = {
            guard trackWidth.isFinite else { return 0 }
            return max(trackWidth, 0)
        }()
        let reserved = gap * CGFloat(columns - 1) + 6
        let rawWidth = safeTrackWidth - reserved
        if rawWidth.isFinite && rawWidth > 0 {
            let colWidth = max(rawWidth / CGFloat(columns), 1)
            let xOffset  = CGFloat(ci.column) * (colWidth + gap) + 3
            switch ci.item {
            case .event(let event):
                let range = clippedEventRange(for: event)
                eventBlock(event, start: range.start, end: range.end)
                    .frame(width: colWidth)
                    .offset(x: xOffset, y: yOffset(for: range.start))
            case .todo(let todo):
                let range = clippedTodoRange(for: todo)
                todoBlock(todo, start: range?.start ?? dayStart, end: range?.end ?? dayStart)
                    .frame(width: colWidth)
                    .offset(x: xOffset, y: range.map { yOffset(for: $0.start) } ?? 0)
            }
        }
    }

    private func eventBlock(_ event: CalendarService.CalendarEventSummary, start: Date, end: Date) -> some View {
        let color = calendarEventColor(for: event.calendarID)
        let spanDuration = end.timeIntervalSince(start)
        let dh = spanDuration.isFinite ? max(spanDuration, 1800) : 1800
        let bh    = max(CGFloat(dh / 3600) * hourHeight, 30)
        return Button { openEventEdit(event) } label: {
            HStack(alignment: .top, spacing: 4) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(event.title.isEmpty ? AppLanguage.localized("calendar.event.noTitle", defaultValue: "(No Title)", language: .current, comment: "Placeholder for a calendar event without a title.") : event.title)
                            .font(.caption.weight(.semibold)).foregroundStyle(Color(.label))
                            .lineLimit(bh > 44 ? 2 : 1)
                        Image(systemName: event.isRecurring
                              ? "arrow.triangle.2.circlepath" : "calendar")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if bh > 38 {
                        Text("\(event.startDate, style: .time) – \(event.endDate, style: .time)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(5)
            .frame(height: bh, alignment: .top)
            .background(AppTheme.insetSurface, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func todoBlock(_ todo: Todo, start: Date, end: Date) -> some View {
        let linkedEvent = linkedCalendarEvent(for: todo)
        let bh = max(CGFloat(max(end.timeIntervalSince(start), 1800) / 3600) * hourHeight, 30)
        HStack(spacing: 2) {
            Button { editingTodo = todo } label: {
                HStack(spacing: 4) {
                    Image(systemName: "circle").font(.caption).foregroundStyle(AppTheme.accent)
                    Text(todo.title.isEmpty ? AppLanguage.localized("todo.noTitle", defaultValue: "(No Title)", language: .current, comment: "Placeholder for a to-do without a title.") : todo.title)
                        .font(.caption.weight(.medium)).foregroundStyle(Color(.label)).lineLimit(1)
                    Spacer(minLength: 0)
                    if todo.todoSource == .calendar {
                        Image(systemName: todo.isFixedSchedule
                              ? "arrow.triangle.2.circlepath" : "calendar")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if todo.todoSource == .email {
                        Image(systemName: "envelope.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let range = todo.scheduledRange {
                        Text("\(range.start, style: .time)–\(range.end, style: .time)")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if let due = todo.dueDate {
                        Text(due, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: bh, alignment: .leading)
            }
            .buttonStyle(.plain)

            if let linkedEvent {
                Button {
                    openEventEdit(linkedEvent)
                } label: {
                    Image(systemName: linkedEvent.isRecurring
                          ? "arrow.triangle.2.circlepath.circle.fill"
                          : "calendar.circle.fill")
                        .foregroundStyle(AppTheme.accent)
                        .frame(minWidth: 30, minHeight: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("캘린더 일정 편집")
                .accessibilityIdentifier("calendar.editLinkedEvent")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(AppTheme.insetSurface, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
    }

    private func linkedCalendarEvent(for todo: Todo) -> CalendarService.CalendarEventSummary? {
        guard let eventID = todo.calendarEventID else { return nil }
        return dayEvents.first(where: { $0.identifier == eventID })
    }

    private func openEventEdit(_ event: CalendarService.CalendarEventSummary) {
        let detail = event.isRecurring
            ? CalendarService.shared.occurrenceDetail(identifier: event.identifier, on: event.startDate)
            : CalendarService.shared.eventDetail(identifier: event.identifier)
        editingDetail = detail
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - EventEditMode
// ─────────────────────────────────────────────────────────────

enum EventEditMode {
    case create(date: Date)
    case edit(detail: CalendarService.CalendarEventDetail)

    var isCreate: Bool {
        if case .create = self { return true }
        return false
    }
}

private enum RecurrenceMutation {
    case save
    case delete
}


// ─────────────────────────────────────────────────────────────
// MARK: - EventEditSheet
// ─────────────────────────────────────────────────────────────

struct EventEditSheet: View {
    let mode: EventEditMode
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var notes: String
    @State private var calendarID: String
    @State private var calendarSources: [CalendarService.CalendarSourceGroup] = []
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false
    @State private var showRecurrenceScope = false
    @State private var recurrenceMutation: RecurrenceMutation = .save


    init(mode: EventEditMode, onSave: @escaping () -> Void) {
        self.mode   = mode
        self.onSave = onSave
        switch mode {
        case .create(let date):
            _title      = State(initialValue: "")
            _startDate  = State(initialValue: date)
            _endDate    = State(initialValue: date.addingTimeInterval(3600))
            _notes      = State(initialValue: "")
            _calendarID = State(initialValue: "")
        case .edit(let detail):
            _title      = State(initialValue: detail.title)
            _startDate  = State(initialValue: detail.startDate)
            _endDate    = State(initialValue: detail.endDate)
            _notes      = State(initialValue: detail.notes)
            _calendarID = State(initialValue: detail.calendarID)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("제목") {
                    TextField("이벤트 제목", text: $title)
                }
                Section("시간") {
                    DatePicker("시작", selection: $startDate,
                               displayedComponents: [.date, .hourAndMinute])
                    DatePicker("종료", selection: $endDate, in: startDate...,
                               displayedComponents: [.date, .hourAndMinute])
                }
                Section("메모") {
                    TextField("메모 (선택 사항)", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
                if case .edit(let detail) = mode {
                    Section("일정 정보") {
                        Label(
                            detail.isRecurring
                                ? AppLanguage.localized("calendar.event.recurring", defaultValue: "Recurring event", language: .current, comment: "Calendar event recurrence type.")
                                : AppLanguage.localized("calendar.event.nonRecurring", defaultValue: "Non-recurring event", language: .current, comment: "Calendar event recurrence type."),
                            systemImage: detail.isRecurring
                                ? "arrow.triangle.2.circlepath"
                                : "calendar"
                        )
                        Label(eventOriginLabel(for: detail), systemImage: "link")
                    }
                }

                if mode.isCreate {
                    Section("캘린더") {
                        Picker("캘린더 선택", selection: $calendarID) {
                            Text(AppLanguage.localized("calendar.destination.unselected", defaultValue: "Choose a calendar", language: .current)).tag("")
                            Text(AppLanguage.localized("calendar.destination.systemDefault", defaultValue: "System Default Calendar", language: .current))
                                .tag(CalendarService.systemDefaultCalendarID)
                            if !calendarID.isEmpty,
                               calendarID != CalendarService.systemDefaultCalendarID,
                               !calendarSources.flatMap(\.calendars).contains(where: { $0.id == calendarID }) {
                                Text(AppLanguage.localized("calendar.destination.unavailable", defaultValue: "Choose another writable calendar", language: .current)).tag(calendarID)
                            }
                            ForEach(calendarSources) { source in
                                ForEach(source.calendars) { calInfo in
                                    calendarLabel(calInfo).tag(calInfo.id)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                if let err = errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(AppTheme.destructive)
                    }
                }
            }
            .appFormStyle()
            .navigationTitle(mode.isCreate
                ? AppLanguage.localized("calendar.event.createTitle", defaultValue: "New Event", language: .current, comment: "New calendar event navigation title.")
                : AppLanguage.localized("calendar.event.editTitle", defaultValue: "Edit Event", language: .current, comment: "Calendar event editor navigation title."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !mode.isCreate {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("이벤트 삭제", systemImage: "trash")
                                .foregroundStyle(AppTheme.destructive)
                        }
                    }
                }
            }
        }
        .confirmationDialog("이벤트를 삭제하시겠습니까?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { requestDelete() }
            Button("취소", role: .cancel) { }
        }
        .confirmationDialog(
            recurrenceMutation == .delete
                ? AppLanguage.localized("calendar.recurrence.deleteScopeTitle", defaultValue: "Choose which recurring events to delete", language: .current, comment: "Recurring event deletion scope confirmation title.")
                : AppLanguage.localized("calendar.recurrence.changeScopeTitle", defaultValue: "Choose which recurring events to change", language: .current, comment: "Recurring event edit scope confirmation title."),
            isPresented: $showRecurrenceScope,
            titleVisibility: .visible
        ) {
            Button("이 일정만") { performRecurrenceMutation(scope: .thisEvent) }
            Button("이후 모든 일정") { performRecurrenceMutation(scope: .futureEvents) }
            Button(
                recurrenceMutation == .delete
                    ? AppLanguage.localized("calendar.recurrence.deleteAll", defaultValue: "Delete entire series", language: .current, comment: "Delete all occurrences of a recurring calendar event.")
                    : AppLanguage.localized("calendar.recurrence.changeAll", defaultValue: "Change entire series", language: .current, comment: "Change all occurrences of a recurring calendar event."),
                role: recurrenceMutation == .delete ? .destructive : nil
            ) {
                performRecurrenceMutation(scope: .allEvents)
            }
            Button("취소", role: .cancel) { }
        } message: {
            Text("선택한 날짜의 일정, 이후 일정 또는 전체 시리즈에 적용할 수 있습니다.")
        }
        .task {
            calendarSources = CalendarService.shared.availableCalendars(writableOnly: true)
            if calendarID.isEmpty {
                calendarID = CalendarService.shared.defaultCalendarID
            }
        }
    }

    @ViewBuilder
    private func calendarLabel(_ info: CalendarService.CalendarInfo) -> some View {
        let color = CalendarPresentation.color(forCalendarID: info.id)
        Label {
            Text("\(info.sourceTitle) · \(info.title)")
        } icon: {
            Circle().fill(color).frame(width: 10, height: 10)
        }
    }

    private func eventOriginLabel(for detail: CalendarService.CalendarEventDetail) -> String {
        switch detail.marker?.origin {
        case .siftRecommendation:
            return AppLanguage.localized("calendar.event.origin.recommendation", defaultValue: "SIFT-recommended event", language: .current, comment: "Calendar event origin label for a SIFT recommendation.")
        case .siftManual, .siftEmail, .siftMeeting, .siftHealth:
            return AppLanguage.localized("calendar.event.origin.sift", defaultValue: "Event created in SIFT", language: .current, comment: "Calendar event origin label for an event created in SIFT.")
        case .externalCalendar, nil:
            return AppLanguage.localized("calendar.event.origin.external", defaultValue: "External calendar event", language: .current, comment: "Calendar event origin label for an external calendar event.")
        }
    }

    private func save() {
        guard case .edit(let detail) = mode, detail.isRecurring else {
            persistSave(scope: nil)
            return
        }
        recurrenceMutation = .save
        showRecurrenceScope = true
    }

    private func persistSave(scope: CalendarRecurrenceScope?) {
        do {
            switch mode {
            case .create:
                try CalendarService.shared.createEvent(
                    title: title, startDate: startDate, endDate: endDate,
                    notes: notes, calendarID: calendarID)
            case .edit(let detail):
                if detail.isRecurring {
                    try CalendarService.shared.updateOccurrence(
                        identifier: detail.identifier,
                        on: detail.occurrenceDate ?? detail.startDate,
                        title: title,
                        startDate: startDate,
                        endDate: endDate,
                        notes: notes,
                        scope: scope ?? .thisEvent
                    )
                } else {
                    try CalendarService.shared.updateEvent(
                        identifier: detail.identifier,
                        title: title, startDate: startDate, endDate: endDate, notes: notes)
                }
            }
            onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestDelete() {
        guard case .edit(let detail) = mode, detail.isRecurring else {
            deleteEvent(scope: nil)
            return
        }
        recurrenceMutation = .delete
        showRecurrenceScope = true
    }

    private func performRecurrenceMutation(scope: CalendarRecurrenceScope) {
        switch recurrenceMutation {
        case .save:
            persistSave(scope: scope)
        case .delete:
            deleteEvent(scope: scope)
        }
    }

    private func deleteEvent(scope: CalendarRecurrenceScope?) {
        guard case .edit(let detail) = mode else { return }
        do {
            if detail.isRecurring {
                try CalendarService.shared.removeEventOccurrence(
                    eventID: detail.identifier,
                    on: detail.occurrenceDate ?? detail.startDate,
                    scope: scope ?? .thisEvent
                )
            } else {
                _ = try CalendarService.shared.removeEvent(eventID: detail.identifier)
            }
            onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - CalendarSourceSheet
// ─────────────────────────────────────────────────────────────

struct CalendarSourceSheet: View {
    let sources: [CalendarService.CalendarSourceGroup]
    @Binding var disabledIDs: Set<String>

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if sources.isEmpty {
                    ContentUnavailableView("캘린더 없음", systemImage: "calendar.badge.exclamationmark")
                } else {
                    ForEach(sources) { source in
                        Section(source.title) {
                            ForEach(source.calendars) { calInfo in
                                calendarToggleRow(calInfo)
                            }
                        }
                    }
                }
            }
            .appListStyle()
            .navigationTitle("캘린더 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func calendarToggleRow(_ info: CalendarService.CalendarInfo) -> some View {
        let color = CalendarPresentation.color(forCalendarID: info.id)
        HStack {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(info.title)
            Spacer()
            Toggle(info.title, isOn: Binding(
                get: { !disabledIDs.contains(info.id) },
                set: { enabled in
                    CalendarService.shared.setCalendar(info.id, enabled: enabled)
                    if enabled { disabledIDs.remove(info.id) }
                    else       { disabledIDs.insert(info.id) }
                }
            ))
            .labelsHidden()
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - DefaultCalendarPickerView
// ─────────────────────────────────────────────────────────────

struct DefaultCalendarPickerView: View {
    @State private var selectedID: String = CalendarService.shared.defaultCalendarID
    @State private var sources: [CalendarService.CalendarSourceGroup] = []

    var body: some View {
        List {
            Section {
                Button {
                    selectedID = CalendarService.systemDefaultCalendarID
                    CalendarService.shared.defaultCalendarID = CalendarService.systemDefaultCalendarID
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(copy("calendar.destination.systemDefault", fallback: "시스템 기본 캘린더"))
                                .foregroundStyle(Color(.label))
                            Text(copy("calendar.destination.systemDefaultSubtitle", fallback: "iOS 시스템 기본 설정을 따릅니다"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedID == CalendarService.systemDefaultCalendarID {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("calendar.picker.systemDefault")
            } header: {
                Text(copy("calendar.destination.defaultHeader", fallback: "기본값"))
            }

            ForEach(sources) { source in
                Section(source.title) {
                    ForEach(source.calendars) { calInfo in
                        calendarRow(calInfo)
                    }
                }
            }
        }
        .appListStyle()
        .navigationTitle(copy("calendar.destination.title", fallback: "등록 대상 캘린더"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refreshCalendars)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshCalendars()
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            refreshCalendars()
        }
    }

    @ViewBuilder
    private func calendarRow(_ info: CalendarService.CalendarInfo) -> some View {
        let color = CalendarPresentation.color(forCalendarID: info.id)
        Button {
            selectedID = info.id
            CalendarService.shared.defaultCalendarID = info.id
        } label: {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title).foregroundStyle(Color(.label))
                    Text(info.sourceTitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if selectedID == info.id {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold)).foregroundStyle(AppTheme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("calendar.picker.row.\(info.id)")
    }

    private func refreshCalendars() {
        CalendarService.shared.restoreAuthorizationIfGranted()
        selectedID = CalendarService.shared.defaultCalendarID
        sources = CalendarService.shared.availableCalendars(writableOnly: true)
    }

    private func copy(_ key: String, fallback: String) -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "Calendar destination picker copy.")
    }
}
