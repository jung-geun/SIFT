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
    @Environment(\.appTutorialState) private var tutorial
    @Query private var allTodos: [Todo]
    @State private var displayMonth: Date = CalendarTabView.currentMonthStart
    @State private var selectedDate: Date?
    @State private var activeSheet: CalendarActiveSheet?
    @State private var showSourceSheet = false
    @State private var allEvents: [CalendarService.CalendarEventSummary] = []
    @State private var calendarSources: [CalendarService.CalendarSourceGroup] = []
    @State private var disabledIDs: Set<String> = []
    @State private var authorized: Bool = false
    @State private var initialScrollDone = false
    @State private var scrollToTodayTrigger = 0
    @State private var isSyncing = false

    private let cal = Calendar.current

    // 오늘이 현재 월에 표시되는지 여부 — "오늘" 버튼 강조에 사용
    private var isTodayVisible: Bool {
        let today = cal.dateComponents([.year, .month], from: Date())
        let disp  = cal.dateComponents([.year, .month], from: displayMonth)
        return today.year == disp.year && today.month == disp.month
    }

    static var currentMonthStart: Date {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return Calendar.current.date(from: comps) ?? Date()
    }

    private var scrollMonths: [Date] {
        (-12...12).compactMap { cal.date(byAdding: .month, value: $0, to: Self.currentMonthStart) }
    }

    private func monthID(_ date: Date) -> String {
        let c = cal.dateComponents([.year, .month], from: date)
        return "month-\(c.year ?? 0)-\(c.month ?? 0)"
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if !authorized {
                    noPermissionView
                } else {
                    mainContent
                }
            }
            .navigationTitle("캘린더")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            .sheet(item: $activeSheet) { sheet in
                activeSheetView(sheet)
            }
            .sheet(isPresented: $showSourceSheet, onDismiss: { reloadAllEvents() }) {
                CalendarSourceSheet(sources: calendarSources, disabledIDs: $disabledIDs)
            }
        }
        .task {
            authorized = CalendarService.shared.isAuthorized
            if authorized {
                disabledIDs = CalendarService.shared.disabledCalendarIDs
                calendarSources = CalendarService.shared.availableCalendars()
                reloadAllEvents()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            if authorized { reloadAllEvents() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && authorized { reloadAllEvents() }
        }
        // 캘린더 탭 재탭 시 오늘로 이동
        .onReceive(NotificationCenter.default.publisher(for: .calendarScrollToToday)) { _ in
            displayMonth = Self.currentMonthStart
            scrollToTodayTrigger += 1
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if let tutorial {
                AppTutorialTipHost(tutorial: tutorial, screen: .calendarTab)
            }
        }
        .onAppear {
            tutorial?.handleCalendarTabAppeared()
        }
    }

    // MARK: Permission Placeholder

    private var noPermissionView: some View {
        ContentUnavailableView {
            Label(
                AppLanguage.localized("calendar.permissionUnavailable", defaultValue: "캘린더 접근 권한 없음", language: .current, comment: "Calendar permission state title."),
                systemImage: "calendar.badge.exclamationmark"
            )
                .accessibilityIdentifier("calendar.permissionUnavailable")
        } description: {
            Text(
                AppLanguage.localized(
                    "calendar.permissionDescription",
                    defaultValue: "설정 > 개인정보 보호 > 캘린더에서 이 앱의 접근을 허용해주세요.",
                    language: .current,
                    comment: "Calendar permission state description."
                )
            )
        }
    }

    // MARK: Main Content

    private var mainContent: some View {
        monthGridView
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                showSourceSheet = true
            } label: {
                Image(systemName: disabledIDs.isEmpty
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityLabel(AppLanguage.localized("calendar.filter.accessibilityLabel", defaultValue: "캘린더 필터", language: .current, comment: "Calendar filter button."))
            .accessibilityIdentifier("calendar.filterButton")
            .disabled(!authorized)
        }
        // 네비게이션 타이틀 영역 — 현재 뷰 모드를 드롭다운 Menu로 표시
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                displayMonth = Self.currentMonthStart
                scrollToTodayTrigger += 1
            } label: {
                Text("오늘")
                    .fontWeight(isTodayVisible ? .regular : .semibold)
                    .foregroundStyle(isTodayVisible ? AppTheme.accent : AppTheme.destructive)
            }
            .disabled(!authorized)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                activeSheet = .newEvent(date: selectedDate ?? Date())
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(AppLanguage.localized("calendar.add.accessibilityLabel", defaultValue: "일정 추가", language: .current, comment: "Calendar add button."))
            .accessibilityIdentifier("calendar.addButton")
            .disabled(!authorized)
        }
    }

    // MARK: Sheet Routing

    @ViewBuilder
    private func activeSheetView(_ sheet: CalendarActiveSheet) -> some View {
        switch sheet {
        case .dayDetail(let date):
            DayDetailSheet(date: date, events: allEvents, todos: Array(allTodos)) { reloadAllEvents() }
        case .newEvent(let date):
            EventEditSheet(mode: .create(date: date)) { reloadAllEvents() }
        case .editEvent(let detail):
            EventEditSheet(mode: .edit(detail: detail)) { reloadAllEvents() }
        }
    }

    // MARK: Month Grid View

    private var monthGridView: some View {
        VStack(spacing: 0) {
            weekdayHeader
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(scrollMonths, id: \.timeIntervalSince1970) { month in
                            MonthBlock(
                                month: month,
                                allEvents: allEvents,
                                allTodos: Array(allTodos),
                                onDayTap: { date in
                                    selectedDate = date
                                    activeSheet = .dayDetail(date: date)
                                }
                            )
                            .id(monthID(month))
                        }
                    }
                }
                .onAppear {
                    guard !initialScrollDone else { return }
                    initialScrollDone = true
                    DispatchQueue.main.async {
                        proxy.scrollTo(monthID(Self.currentMonthStart), anchor: .top)
                    }
                }
                .onChange(of: scrollToTodayTrigger) { _, _ in
                    withAnimation {
                        proxy.scrollTo(monthID(Self.currentMonthStart), anchor: .top)
                    }
                }
                .refreshable {
                    reloadAllEvents()
                    await performSync()
                }
            }
        }
    }

    // MARK: Weekday Header

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(["일","월","화","수","목","금","토"], id: \.self) { d in
                Text(d)
                    .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .background(Color(.systemBackground))
    }

    // MARK: Data

    @MainActor
    func performSync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await CalendarService.shared.syncCalendarTodos(context: modelContext)
        reloadAllEvents()
    }

    func reloadAllEvents() {
        guard let start = cal.date(byAdding: .month, value: -13, to: Self.currentMonthStart),
              let end   = cal.date(byAdding: .month, value:  14, to: Self.currentMonthStart)
        else { return }
        allEvents = CalendarService.shared.events(from: start, to: end)
    }
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
// MARK: - MonthBlock  (주 행 기반 재구성)
// ─────────────────────────────────────────────────────────────

private struct MonthBlock: View {
    let month: Date
    let allEvents: [CalendarService.CalendarEventSummary]
    let allTodos: [Todo]
    let onDayTap: (Date) -> Void

    private let cal = Calendar.current

    /// 월을 7-element 주 배열로 분해 (nil = 선행/후행 빈칸)
    private var weekRows: [[Date?]] {
        let comps = cal.dateComponents([.year, .month], from: month)
        guard let firstDay = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: firstDay) else { return [] }
        let leadingNils = cal.component(.weekday, from: firstDay) - 1
        var days: [Date?] = Array(repeating: nil, count: leadingNils)
        for offset in 0..<range.count {
            days.append(cal.date(byAdding: .day, value: offset, to: firstDay))
        }
        while days.count % 7 != 0 { days.append(nil) }
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<($0+7)]) }
    }

    private var monthTitle: String {
        let language = AppLanguage.current
        let fmt = DateFormatter()
        fmt.locale = language.locale
        fmt.dateFormat = language == .english ? "LLLL yyyy" : "yyyy년 M월"
        return fmt.string(from: month)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(monthTitle).font(.headline)
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                Spacer()
            }
            ForEach(Array(weekRows.enumerated()), id: \.offset) { _, row in
                WeekRowView(days: row, allEvents: allEvents, allTodos: allTodos, onDayTap: onDayTap)
            }
            Divider()
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - WeekRowView
// ─────────────────────────────────────────────────────────────

private struct WeekRowView: View {
    let days: [Date?]       // 7 elements (nil = 빈칸)
    let allEvents: [CalendarService.CalendarEventSummary]
    let allTodos: [Todo]
    let onDayTap: (Date) -> Void

    private let cal = Calendar.current

    // Layout constants
    private let maxLanes = 3
    private let dayH: CGFloat = 28
    private let laneH: CGFloat = 16
    private let laneGap: CGFloat = 2
    private let overH: CGFloat = 13

    private var rowH: CGFloat { dayH + CGFloat(maxLanes) * (laneH + laneGap) + overH }

    // MARK: Date helpers

    private var weekStart: Date? { days.compactMap { $0 }.first }
    private var weekEnd: Date? {
        guard let last = days.compactMap({ $0 }).last,
              let end = cal.date(byAdding: .day, value: 1, to: last) else { return nil }
        return end
    }

    /// 이 주에 걸치는 모든 이벤트
    private var weekEvents: [CalendarService.CalendarEventSummary] {
        guard let ws = weekStart, let we = weekEnd else { return [] }
        return allEvents.filter { $0.startDate < we && $0.endDate > ws }
    }

    /// Todo와 연동된 캘린더 이벤트 ID 집합 — 중복 표시 방지용
    private var linkedEventIDs: Set<String> {
        Set(allTodos.compactMap { $0.calendarEventID })
    }

    /// 스팬 바 이벤트 — 긴 것 먼저 (연동된 Todo가 있는 이벤트는 숨김)
    private var spanBarEvents: [CalendarService.CalendarEventSummary] {
        let linked = linkedEventIDs
        return weekEvents.filter { eventIsAllDayStyle($0) && !linked.contains($0.identifier) }
            .sorted { a, b in
                let (acs, ace) = spanCols(a); let (bcs, bce) = spanCols(b)
                let aL = ace - acs; let bL = bce - bcs
                return aL != bL ? aL > bL : a.startDate < b.startDate
            }
    }

    /// 단일일 타임드 이벤트 (컬럼별, 연동된 Todo가 있는 이벤트는 숨김)
    private var timedByCol: [Int: [CalendarService.CalendarEventSummary]] {
        let linked = linkedEventIDs
        var d: [Int: [CalendarService.CalendarEventSummary]] = [:]
        for e in weekEvents where !eventIsAllDayStyle(e) && !linked.contains(e.identifier) {
            if let col = colIndex(for: e.startDate) { d[col, default: []].append(e) }
        }
        return d
    }

    private var todosByCol: [Int: [Todo]] {
        var d: [Int: [Todo]] = [:]
        for todo in allTodos where !todo.isCompleted {
            guard let anchor = todo.scheduleAnchor, let col = colIndex(for: anchor) else { continue }
            d[col, default: []].append(todo)
        }
        return d
    }

    // MARK: Lane assignment

    private struct LaneItem {
        let event: CalendarService.CalendarEventSummary
        let lane: Int
        let colStart: Int
        let colEnd: Int
    }

    private var laneItems: [LaneItem] {
        var laneLastCol: [Int: Int] = [:]
        var result: [LaneItem] = []
        for event in spanBarEvents {
            let (cs, ce) = spanCols(event)
            guard cs <= ce else { continue }
            var assignedLane: Int? = nil
            for lane in 0..<maxLanes {
                if (laneLastCol[lane] ?? -1) < cs { assignedLane = lane; break }
            }
            guard let lane = assignedLane else { continue }  // overflow
            laneLastCol[lane] = ce
            result.append(LaneItem(event: event, lane: lane, colStart: cs, colEnd: ce))
        }
        return result
    }

    // MARK: Geometry helpers

    private func spanCols(_ event: CalendarService.CalendarEventSummary) -> (Int, Int) {
        var cs = 7, ce = -1
        for (i, day) in days.enumerated() {
            guard let day else { continue }
            if eventOccupiesDay(event, day: day) { cs = min(cs, i); ce = max(ce, i) }
        }
        return (cs == 7 ? 0 : cs, ce < 0 ? 0 : ce)
    }

    private func colIndex(for date: Date) -> Int? {
        for (i, day) in days.enumerated() {
            guard let day else { continue }
            if cal.isDate(date, inSameDayAs: day) { return i }
        }
        return nil
    }

    private func availableLanes(col: Int, cachedLaneItems: [LaneItem]) -> [Int] {
        let used = Set(cachedLaneItems.filter { $0.colStart <= col && $0.colEnd >= col }.map { $0.lane })
        return (0..<maxLanes).filter { !used.contains($0) }
    }

    // MARK: Chip model

    private enum ChipContent {
        case event(CalendarService.CalendarEventSummary)
        case todo(Todo)
        var title: String {
            switch self { case .event(let e): return e.title; case .todo(let t): return t.title }
        }
        var color: Color {
            switch self {
            case .event(let e): return calendarEventColor(for: e.calendarID)
            case .todo: return AppTheme.accent
            }
        }
    }

    private func chips(col: Int) -> [ChipContent] {
        var items: [ChipContent] = []
        if let evts = timedByCol[col] { items += evts.map { .event($0) } }
        if let todos = todosByCol[col] { items += todos.map { .todo($0) } }
        return items
    }

    private func overflowCount(col: Int, cachedLaneItems: [LaneItem], cachedSpanBarEvents: [CalendarService.CalendarEventSummary]) -> Int {
        let spanOverflow = cachedSpanBarEvents.filter { e in
            let (cs, ce) = spanCols(e)
            return cs <= col && ce >= col &&
                   !cachedLaneItems.contains(where: { $0.event.identifier == e.identifier })
        }.count
        let avail = availableLanes(col: col, cachedLaneItems: cachedLaneItems).count
        let chipOverflow = max(0, chips(col: col).count - avail)
        return spanOverflow + chipOverflow
    }

    // MARK: Body

    var body: some View {
        let cached = laneItems
        let cachedSpan = spanBarEvents
        let wFirst = weekStart
        let wLast  = weekEnd

        return GeometryReader { geo in
            let cw = max(geo.size.width / 7, 0)

            ZStack(alignment: .topLeading) {

                // ⓪ 투명 탭 레이어 — 전체 셀 높이, 가장 아래 z 레이어
                ForEach(0..<7, id: \.self) { col in
                    if let day = days[col] {
                        Color.clear
                            .frame(width: cw, height: rowH)
                            .contentShape(Rectangle())
                            .offset(x: CGFloat(col) * cw)
                            .onTapGesture { onDayTap(day) }
                    }
                }

                // ① 날짜 숫자 (히트테스트 비활성 → 탭이 ⓪으로 통과)
                ForEach(0..<7, id: \.self) { col in
                    if let day = days[col] {
                        DayNumCell(date: day)
                            .frame(width: cw, height: dayH)
                            .offset(x: CGFloat(col) * cw)
                            .allowsHitTesting(false)
                    }
                }

                // ② 스팬 바 (히트테스트 비활성)
                ForEach(Array(cached.enumerated()), id: \.offset) { _, item in
                    spanBarView(item: item, cw: cw, weekFirst: wFirst, weekLast: wLast)
                        .offset(y: dayH + CGFloat(item.lane) * (laneH + laneGap))
                        .allowsHitTesting(false)
                }

                // ③ 칩 + 오버플로 (히트테스트 비활성)
                ForEach(0..<7, id: \.self) { col in
                    let avail = availableLanes(col: col, cachedLaneItems: cached)
                    let cs = chips(col: col)
                    let paired = Array(zip(avail, cs))

                    ForEach(Array(paired.enumerated()), id: \.offset) { pairIdx, laneChip in
                        chipView(chip: laneChip.1)
                            .frame(width: max(cw - 2, 0), height: laneH)
                            .offset(x: CGFloat(col) * cw + 1,
                                    y: dayH + CGFloat(laneChip.0) * (laneH + laneGap))
                            .allowsHitTesting(false)
                    }

                    let ov = overflowCount(col: col, cachedLaneItems: cached, cachedSpanBarEvents: cachedSpan)
                    if ov > 0 {
                        Text("+\(ov)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: max(cw, 0), alignment: .leading)
                            .offset(x: CGFloat(col) * cw + 3,
                                    y: dayH + CGFloat(maxLanes) * (laneH + laneGap) + 1)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(height: rowH)
    }

    // MARK: Sub-views

    @ViewBuilder
    private func spanBarView(item: LaneItem, cw: CGFloat,
                              weekFirst: Date?, weekLast: Date?) -> some View {
        let color = calendarEventColor(for: item.event.calendarID)
        let x = CGFloat(item.colStart) * cw
        let rawBarW = CGFloat(item.colEnd - item.colStart + 1) * cw
        let barW = max(rawBarW, 0)
        let contL: Bool = {
            guard let wf = weekFirst else { return false }
            return item.event.startDate < cal.startOfDay(for: wf)
        }()
        let contR: Bool = {
            guard let wl = weekLast else { return false }
            return item.event.endDate > wl
        }()
        let lRad: CGFloat = contL ? 0 : 4
        let rRad: CGFloat = contR ? 0 : 4
        let frameWidth = max(barW - (contL ? 0 : 1) - (contR ? 0 : 1), 0)

        HStack(spacing: 2) {
            if contL {
                Image(systemName: "chevron.left")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.leading, 1)
            }
            Text(item.event.title.isEmpty ? "(제목 없음)" : item.event.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if contR {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.trailing, 1)
            }
        }
        .padding(.horizontal, contL || contR ? 0 : 3)
        .frame(width: frameWidth, height: laneH)
        .background(color, in: UnevenRoundedRectangle(
            topLeadingRadius: lRad, bottomLeadingRadius: lRad,
            bottomTrailingRadius: rRad, topTrailingRadius: rRad
        ))
        .offset(x: x + (contL ? 0 : 1))
    }

    @ViewBuilder
    private func chipView(chip: ChipContent) -> some View {
        HStack(spacing: 2) {
            Circle().fill(chip.color).frame(width: 5, height: 5)
            Text(chip.title.isEmpty ? "(없음)" : chip.title)
                .font(.system(size: 10)).lineLimit(1).foregroundStyle(Color(.label))
        }
        .frame(height: laneH)
    }

}

// ─────────────────────────────────────────────────────────────
// MARK: - DayNumCell
// ─────────────────────────────────────────────────────────────

private struct DayNumCell: View {
    let date: Date
    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if isToday {
                    Circle().fill(AppTheme.accent).frame(width: 24, height: 24)
                }
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(.callout, design: .rounded))
                    .fontWeight(isToday ? .semibold : .regular)
                    .foregroundStyle(isToday ? .white : Color(.label))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 3)
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
        .padding(.vertical, 6)
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
                Text(event.title.isEmpty ? "(제목 없음)" : event.title)
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
            .background(color.opacity(0.9), in: Capsule())
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
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(event.title.isEmpty ? "(제목 없음)" : event.title)
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
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.35), lineWidth: 0.5))
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
                    Text(todo.title.isEmpty ? "(제목 없음)" : todo.title)
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
        .background(AppTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.accentStroke, lineWidth: 0.5))
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
                            detail.isRecurring ? "반복 일정" : "일반 일정",
                            systemImage: detail.isRecurring
                                ? "arrow.triangle.2.circlepath"
                                : "calendar"
                        )
                        Label(eventOriginLabel(for: detail), systemImage: "link")
                    }
                }

                if !calendarSources.isEmpty {
                    Section("캘린더") {
                        Picker("캘린더 선택", selection: $calendarID) {
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
            .navigationTitle(mode.isCreate ? "새 이벤트" : "이벤트 편집")
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
                ? "반복 일정 삭제 범위를 선택하세요"
                : "반복 일정 변경 범위를 선택하세요",
            isPresented: $showRecurrenceScope,
            titleVisibility: .visible
        ) {
            Button("이 일정만") { performRecurrenceMutation(scope: .thisEvent) }
            Button("이후 모든 일정") { performRecurrenceMutation(scope: .futureEvents) }
            Button(
                recurrenceMutation == .delete ? "전체 반복 일정 삭제" : "전체 반복 일정 변경",
                role: recurrenceMutation == .delete ? .destructive : nil
            ) {
                performRecurrenceMutation(scope: .allEvents)
            }
            Button("취소", role: .cancel) { }
        } message: {
            Text("선택한 날짜의 일정, 이후 일정 또는 전체 시리즈에 적용할 수 있습니다.")
        }
        .task {
            calendarSources = CalendarService.shared.availableCalendars()
            if calendarID.isEmpty {
                let defaultID = CalendarService.shared.defaultCalendarID
                calendarID = defaultID.isEmpty
                    ? (calendarSources.first?.calendars.first?.id ?? "")
                    : defaultID
            }
        }
    }

    @ViewBuilder
    private func calendarLabel(_ info: CalendarService.CalendarInfo) -> some View {
        let color = CalendarPresentation.color(forCalendarID: info.id)
        Label {
            Text(info.title)
        } icon: {
            Circle().fill(color).frame(width: 10, height: 10)
        }
    }

    private func eventOriginLabel(for detail: CalendarService.CalendarEventDetail) -> String {
        switch detail.marker?.origin {
        case .siftRecommendation:
            return "SIFT 추천 일정"
        case .siftManual, .siftEmail, .siftMeeting:
            return "SIFT에서 생성한 일정"
        case .externalCalendar, nil:
            return "외부 캘린더 일정"
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
                    notes: notes, calendarID: calendarID.isEmpty ? nil : calendarID)
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
            Toggle("", isOn: Binding(
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
    private let sources: [CalendarService.CalendarSourceGroup]

    init() {
        self.sources = CalendarService.shared.availableCalendars()
    }

    var body: some View {
        List {
            ForEach(sources) { source in
                Section(source.title) {
                    ForEach(source.calendars) { calInfo in
                        calendarRow(calInfo)
                    }
                }
            }
        }
        .navigationTitle("기본 캘린더")
        .navigationBarTitleDisplayMode(.inline)
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
                Text(info.title).foregroundStyle(Color(.label))
                Spacer()
                if selectedID == info.id {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold)).foregroundStyle(AppTheme.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
