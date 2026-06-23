import SwiftUI
import SwiftData
import EventKit

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
    if let ek = CalendarService.shared.ekCalendar(withIdentifier: id) {
        return Color(cgColor: ek.cgColor)
    }
    return .accentColor
}

// ─────────────────────────────────────────────────────────────
// MARK: - 타임라인 공유 타입 (DayDetailSheet / MultiDayTimelineView)
// ─────────────────────────────────────────────────────────────

private enum CalTimelineItem {
    case event(CalendarService.CalendarEventSummary)
    case todo(Todo)

    var start: Date {
        switch self {
        case .event(let e): return e.startDate
        case .todo(let t): return t.dueDate ?? Date()
        }
    }
    var end: Date {
        switch self {
        case .event(let e): return e.endDate
        case .todo(let t): return (t.dueDate ?? Date()).addingTimeInterval(1800)
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
    @Query private var allTodos: [Todo]

    @State private var viewMode: CalViewMode = .month
    @State private var displayMonth: Date = CalendarTabView.currentMonthStart
    @State private var anchorDate: Date = Date()        // 주/3일 기준일
    @State private var selectedDate: Date?
    @State private var activeSheet: CalendarActiveSheet?
    @State private var showSourceSheet = false
    @State private var allEvents: [CalendarService.CalendarEventSummary] = []
    @State private var calendarSources: [CalendarService.CalendarSourceGroup] = []
    @State private var disabledIDs: Set<String> = []
    @State private var authorized: Bool = false
    @State private var initialScrollDone = false
    @State private var scrollToTodayTrigger = 0

    enum CalViewMode: String, CaseIterable {
        case month = "월"
        case week  = "주"
        case day   = "일"
    }

    private let cal = Calendar.current

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
            if !authorized {
                authorized = await CalendarService.shared.requestAccess()
            }
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
    }

    // MARK: Permission Placeholder

    private var noPermissionView: some View {
        ContentUnavailableView {
            Label("캘린더 접근 권한 없음", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text("설정 > 개인정보 보호 > 캘린더에서 이 앱의 접근을 허용해주세요.")
        }
    }

    // MARK: Main Content

    private var mainContent: some View {
        switch viewMode {
        case .month:
            AnyView(monthGridView)
        case .week:
            AnyView(MultiDayTimelineView(dayCount: 3,
                                         anchorDate: $anchorDate,
                                         allEvents: allEvents,
                                         todos: Array(allTodos),
                                         onDataChanged: reloadAllEvents))
        case .day:
            AnyView(MultiDayTimelineView(dayCount: 1,
                                         anchorDate: $anchorDate,
                                         allEvents: allEvents,
                                         todos: Array(allTodos),
                                         onDataChanged: reloadAllEvents))
        }
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
            .disabled(!authorized)
        }
        // 네비게이션 타이틀 영역 — 현재 뷰 모드를 드롭다운 Menu로 표시
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(CalViewMode.allCases, id: \.self) { mode in
                    Button {
                        viewMode = mode
                    } label: {
                        if viewMode == mode {
                            Label(mode.rawValue, systemImage: "checkmark")
                        } else {
                            Text(mode.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(viewMode.rawValue)
                        .font(.headline)
                        .foregroundStyle(Color(.label))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!authorized)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("오늘") {
                // 현재 모드에 따라 동작 분리
                switch viewMode {
                case .month:
                    displayMonth = Self.currentMonthStart   // 월 보기 유지, 이번 달로
                    scrollToTodayTrigger += 1
                case .week, .day:
                    anchorDate = Date()                      // 현재 모드 유지, 오늘로
                }
            }
            .disabled(!authorized)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                activeSheet = .newEvent(date: selectedDate ?? Date())
            } label: {
                Image(systemName: "plus")
            }
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
                .refreshable { reloadAllEvents() }
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
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ko_KR")
        fmt.dateFormat = "yyyy년 M월"
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

    /// 스팬 바 이벤트 — 긴 것 먼저
    private var spanBarEvents: [CalendarService.CalendarEventSummary] {
        weekEvents.filter { eventIsAllDayStyle($0) }
            .sorted { a, b in
                let (acs, ace) = spanCols(a); let (bcs, bce) = spanCols(b)
                let aL = ace - acs; let bL = bce - bcs
                return aL != bL ? aL > bL : a.startDate < b.startDate
            }
    }

    /// 단일일 타임드 이벤트 (컬럼별)
    private var timedByCol: [Int: [CalendarService.CalendarEventSummary]] {
        var d: [Int: [CalendarService.CalendarEventSummary]] = [:]
        for e in weekEvents where !eventIsAllDayStyle(e) {
            if let col = colIndex(for: e.startDate) { d[col, default: []].append(e) }
        }
        return d
    }

    private var todosByCol: [Int: [Todo]] {
        var d: [Int: [Todo]] = [:]
        for todo in allTodos where !todo.isCompleted {
            guard let due = todo.dueDate, let col = colIndex(for: due) else { continue }
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
            case .todo: return .orange
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
            let cw = geo.size.width / 7

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
                            .frame(width: cw - 2, height: laneH)
                            .offset(x: CGFloat(col) * cw + 1,
                                    y: dayH + CGFloat(laneChip.0) * (laneH + laneGap))
                            .allowsHitTesting(false)
                    }

                    let ov = overflowCount(col: col, cachedLaneItems: cached, cachedSpanBarEvents: cachedSpan)
                    if ov > 0 {
                        Text("+\(ov)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: cw, alignment: .leading)
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
        let barW = CGFloat(item.colEnd - item.colStart + 1) * cw
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
        .frame(width: barW - (contL ? 0 : 1) - (contR ? 0 : 1), height: laneH)
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
                    Circle().fill(Color.accentColor).frame(width: 24, height: 24)
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
// MARK: - MultiDayTimelineView  (주/3일 보기)
// ─────────────────────────────────────────────────────────────

struct MultiDayTimelineView: View {
    let dayCount: Int
    @Binding var anchorDate: Date
    let allEvents: [CalendarService.CalendarEventSummary]
    let todos: [Todo]
    let onDataChanged: () -> Void

    @State private var editingDetail: CalendarService.CalendarEventDetail?
    @State private var editingTodo: Todo?
    /// 스크롤 기준일 (LazyHStack offset=0 이 이 날에 해당). onAppear에서 anchorDate 기준으로 설정.
    @State private var baseDate: Date = Calendar.current.startOfDay(for: Date())
    /// 현재 LazyHStack 리딩 가장자리에 보이는 dayOffset (baseDate 기준 일수)
    @State private var scrollPositionDayOffset: Int? = 0
    /// 헤더 동기화용 — body 수평 ScrollView의 contentOffset.x를 실시간 반영
    @State private var headerScrollOffset: CGFloat = 0

    private let cal = Calendar.current
    private let hourH: CGFloat = 60
    private let gutterW: CGFloat = 44

    // MARK: Period

    private var periodStart: Date {
        cal.startOfDay(for: anchorDate)
    }

    private var days: [Date] {
        (0..<dayCount).compactMap { cal.date(byAdding: .day, value: $0, to: periodStart) }
    }

    private var periodEnd: Date {
        cal.date(byAdding: .day, value: dayCount, to: periodStart) ?? periodStart
    }

    // MARK: Events

    private var periodEvents: [CalendarService.CalendarEventSummary] {
        allEvents.filter { $0.startDate < periodEnd && $0.endDate > periodStart }
    }

    private var allDayBandEvents: [CalendarService.CalendarEventSummary] {
        periodEvents.filter { eventIsAllDayStyle($0) }
    }

    private var timedEventsByCol: [[CalendarService.CalendarEventSummary]] {
        days.map { day in periodEvents.filter { !eventIsAllDayStyle($0) && eventOccupiesDay($0, day: day) } }
    }

    private func todosForDay(_ day: Date) -> [Todo] {
        todos.filter { t in
            guard !t.isCompleted, let due = t.dueDate else { return false }
            return cal.isDate(due, inSameDayAs: day)
        }
    }

    private var initialScrollHour: Int {
        let hours = timedEventsByCol.flatMap { $0 }.map { cal.component(.hour, from: $0.startDate) }
        return max(0, (hours.min() ?? cal.component(.hour, from: Date())) - 1)
    }

    // MARK: Body

    var body: some View {
        GeometryReader { fullGeo in
            let availW = fullGeo.size.width
            let colW   = (availW - gutterW - 0.5) / CGFloat(max(dayCount, 1))

            VStack(spacing: 0) {
                smoothColumnHeader(colW: colW, scrollOffset: headerScrollOffset)
                Divider()
                if !allDayBandEvents.isEmpty {
                    allDayBand.padding(.vertical, 4)
                    Divider()
                }
                ScrollViewReader { vProxy in
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            timeGutterStrip
                            Rectangle().fill(Color(.separator)).frame(width: 0.5)
                            // 수평 스크롤: 하루 단위 LazyHStack, viewAligned 스냅
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 0) {
                                    ForEach(-365...365, id: \.self) { offset in
                                        singleDayColumn(dayOffset: offset, colW: colW)
                                    }
                                }
                                .scrollTargetLayout()
                            }
                            .scrollTargetBehavior(.viewAligned)
                            .frame(width: availW - gutterW - 0.5)
                            .scrollPosition(id: $scrollPositionDayOffset)
                            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                                headerScrollOffset = x
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    .onAppear {
                        let dayDiff = cal.dateComponents(
                            [.day], from: baseDate, to: cal.startOfDay(for: anchorDate)).day ?? 0
                        scrollPositionDayOffset = dayDiff
                        let h = initialScrollHour
                        DispatchQueue.main.async { vProxy.scrollTo("mdhour-\(h)", anchor: .top) }
                    }
                }
            }
        }
        .onAppear { baseDate = cal.startOfDay(for: anchorDate) }
        .onChange(of: anchorDate) { _, newAnchor in
            // 외부(오늘 버튼 등)에 의한 anchorDate 변경 → scrollPosition 동기화
            let newDay = cal.startOfDay(for: newAnchor)
            let currentDay = cal.date(byAdding: .day, value: scrollPositionDayOffset ?? 0, to: baseDate)
                               .map { cal.startOfDay(for: $0) }
            if currentDay != newDay {
                scrollPositionDayOffset = cal.dateComponents([.day], from: baseDate, to: newDay).day
            }
        }
        .onChange(of: scrollPositionDayOffset) { _, newOffset in
            guard let offset = newOffset else { return }
            if let newDay = cal.date(byAdding: .day, value: offset, to: baseDate) {
                let newDayStart = cal.startOfDay(for: newDay)
                if cal.startOfDay(for: anchorDate) != newDayStart { anchorDate = newDayStart }
            }
        }
        .sheet(item: $editingDetail) { detail in
            EventEditSheet(mode: .edit(detail: detail)) { onDataChanged() }
        }
        .sheet(item: $editingTodo) { todo in
            NavigationStack { TodoDetailView(todo: todo) }
        }
    }

    // MARK: Column Header (smooth — mirrors horizontal scroll offset)

    /// headerScrollOffset 을 반영하여 day 헤더 셀이 body 수평 스크롤과 함께 움직임.
    /// baseDate+offset i에 해당하는 셀의 x 위치 = (i + 365) * colW - scrollOffset
    @ViewBuilder
    private func smoothColumnHeader(colW: CGFloat, scrollOffset: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterW, height: 48)
            if colW > 0 {
                let firstIdx = Int(floor(scrollOffset / colW)) - 366  // 버퍼 1칸 여유
                let lastIdx  = firstIdx + dayCount + 2
                ZStack(alignment: .topLeading) {
                    ForEach(firstIdx...lastIdx, id: \.self) { idx in
                        let xPos = CGFloat(idx + 365) * colW - scrollOffset
                        if let day = cal.date(byAdding: .day, value: idx, to: baseDate) {
                            dayHeaderCell(day: day)
                                .frame(width: colW)
                                .offset(x: xPos)
                        }
                    }
                }
                .frame(width: CGFloat(dayCount) * colW)
                .clipped()
            }
        }
    }

    @ViewBuilder
    private func dayHeaderCell(day: Date) -> some View {
        let isToday = cal.isDateInToday(day)
        VStack(spacing: 2) {
            Text(weekdayLabel(day))
                .font(.caption2)
                .foregroundStyle(isToday ? Color.accentColor : .secondary)
            ZStack {
                if isToday { Circle().fill(Color.accentColor).frame(width: 28, height: 28) }
                Text("\(cal.component(.day, from: day))")
                    .font(.callout.weight(isToday ? .semibold : .regular))
                    .foregroundStyle(isToday ? .white : Color(.label))
            }
        }
        .padding(.vertical, 4)
    }

    private func weekdayLabel(_ date: Date) -> String {
        let labels = ["일","월","화","수","목","금","토"]
        return labels[(cal.component(.weekday, from: date) - 1) % 7]
    }

    // MARK: All-day Band

    private var allDayBand: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("종일").font(.caption2).foregroundStyle(.secondary)
                .frame(width: gutterW, alignment: .center).padding(.top, 2)
            GeometryReader { geo in
                let cw = geo.size.width / CGFloat(dayCount)
                let lanes = assignAllDayLanes()
                let count = max(1, (lanes.map { $0.lane }.max() ?? 0) + 1)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(lanes.enumerated()), id: \.offset) { _, item in
                        allDayBarView(item: item, cw: cw)
                            .offset(y: CGFloat(item.lane) * 22)
                    }
                }
                .frame(height: CGFloat(count) * 22)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct AllDayLaneItem {
        let event: CalendarService.CalendarEventSummary
        let lane: Int
        let colStart: Int
        let colEnd: Int
    }

    private func assignAllDayLanes() -> [AllDayLaneItem] {
        let sorted = allDayBandEvents.sorted {
            let a = colRange($0); let b = colRange($1)
            let aL = a.1-a.0; let bL = b.1-b.0
            return aL != bL ? aL > bL : $0.startDate < $1.startDate
        }
        var laneEnds: [Int: Int] = [:]
        var result: [AllDayLaneItem] = []
        for event in sorted {
            let (cs, ce) = colRange(event)
            guard cs <= ce else { continue }
            var lane = 0
            while (laneEnds[lane] ?? -1) >= cs { lane += 1 }
            laneEnds[lane] = ce
            result.append(AllDayLaneItem(event: event, lane: lane, colStart: cs, colEnd: ce))
        }
        return result
    }

    private func colRange(_ event: CalendarService.CalendarEventSummary) -> (Int, Int) {
        var cs = dayCount, ce = -1
        for (i, day) in days.enumerated() {
            if eventOccupiesDay(event, day: day) { cs = min(cs, i); ce = max(ce, i) }
        }
        return (max(0, cs), max(0, ce))
    }

    @ViewBuilder
    private func allDayBarView(item: AllDayLaneItem, cw: CGFloat) -> some View {
        let color = calendarEventColor(for: item.event.calendarID)
        let x = CGFloat(item.colStart) * cw
        let barW = CGFloat(item.colEnd - item.colStart + 1) * cw - 2
        let contL = item.event.startDate < periodStart
        let contR = item.event.endDate > periodEnd

        HStack(spacing: 2) {
            if contL {
                Image(systemName: "chevron.left")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.white).padding(.leading, 1)
            }
            Text(item.event.title.isEmpty ? "(제목 없음)" : item.event.title)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if contR {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.white).padding(.trailing, 1)
            }
        }
        .padding(.horizontal, 4)
        .frame(width: barW, height: 18)
        .background(color.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
        .offset(x: x + 1)
    }

    // MARK: Time Gutter Strip (수직 고정, 수평 스크롤 밖)

    private var timeGutterStrip: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                Text(String(format: "%02d", h))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: gutterW, height: hourH, alignment: .top)
                    .padding(.top, 3)
                    .id("mdhour-\(h)")
            }
        }
    }

    // MARK: Single Day Column (LazyHStack 아이템)

    /// dayOffset: baseDate 기준 일수 (예: 0=baseDate, 1=내일, -1=어제)
    @ViewBuilder
    private func singleDayColumn(dayOffset: Int, colW: CGFloat) -> some View {
        if let day = cal.date(byAdding: .day, value: dayOffset, to: baseDate) {
            let dayTimedEvents = allEvents.filter { !eventIsAllDayStyle($0) && eventOccupiesDay($0, day: day) }
            let dayTodos       = todosForDay(day)
            let items: [CalTimelineItem] = dayTimedEvents.map { .event($0) } + dayTodos.map { .todo($0) }
            let columned       = layoutCalColumns(items)

            ZStack(alignment: .topLeading) {
                // 시간 그리드 라인
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { _ in
                        Divider()
                        Spacer().frame(height: hourH - 0.5)
                    }
                }
                // 이벤트·할일 블록
                ForEach(Array(columned.enumerated()), id: \.offset) { _, ci in
                    mdColumnItemView(ci, trackWidth: colW)
                }
            }
            .frame(width: colW, height: CGFloat(24) * hourH)
            // 열 오른쪽 구분선 (오버레이 — 레이아웃 폭 불변)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color(.separator)).frame(width: 0.5)
            }
        }
    }

    @ViewBuilder
    private func mdColumnItemView(_ ci: CalColumnedItem, trackWidth: CGFloat) -> some View {
        let gap: CGFloat = 1
        let colWidth = (trackWidth - gap * CGFloat(max(ci.columnCount-1, 0)) - 4) / CGFloat(ci.columnCount)
        let xOffset  = CGFloat(ci.column) * (colWidth + gap) + 2
        switch ci.item {
        case .event(let event):
            mdEventBlock(event)
                .frame(width: colWidth)
                .offset(x: xOffset, y: yOffset(event.startDate))
        case .todo(let todo):
            mdTodoBlock(todo)
                .frame(width: colWidth)
                .offset(x: xOffset, y: todo.dueDate.map { yOffset($0) } ?? 0)
        }
    }

    @ViewBuilder
    private func mdEventBlock(_ event: CalendarService.CalendarEventSummary) -> some View {
        let color = calendarEventColor(for: event.calendarID)
        let dur   = max(event.endDate.timeIntervalSince(event.startDate), 1800)
        let bh    = max(CGFloat(dur / 3600) * hourH, 24)
        Button {
            let d = event.isRecurring
                ? CalendarService.shared.occurrenceDetail(identifier: event.identifier, on: event.startDate)
                : CalendarService.shared.eventDetail(identifier: event.identifier)
            editingDetail = d
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title.isEmpty ? "(제목 없음)" : event.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(bh > 36 ? 2 : 1)
                    .foregroundStyle(Color(.label))
                if bh > 32 {
                    Text(event.startDate, style: .time)
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(3)
            .frame(height: bh, alignment: .top)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 2)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func mdTodoBlock(_ todo: Todo) -> some View {
        Button { editingTodo = todo } label: {
            HStack(spacing: 3) {
                Image(systemName: "circle").font(.system(size: 8)).foregroundStyle(.orange)
                Text(todo.title.isEmpty ? "(없음)" : todo.title)
                    .font(.system(size: 10)).lineLimit(1).foregroundStyle(Color(.label))
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            .frame(minHeight: 24, alignment: .center)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private func yOffset(_ date: Date) -> CGFloat {
        let c = cal.dateComponents([.hour, .minute], from: date)
        return CGFloat(c.hour ?? 0) * hourH + CGFloat(c.minute ?? 0) / 60 * hourH
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

    @State private var editingDetail: CalendarService.CalendarEventDetail?
    @State private var editingTodo: Todo?

    private let hourHeight: CGFloat = 64
    private let labelWidth: CGFloat = 44
    private let cal = Calendar.current

    // MARK: Filtered data

    /// occupiesDay 기반 다일 이벤트 포함 필터
    private var dayEvents: [CalendarService.CalendarEventSummary] {
        events.filter { eventOccupiesDay($0, day: date) }
    }

    private var dayTodos: [Todo] {
        todos.filter {
            guard !$0.isCompleted, let due = $0.dueDate else { return false }
            return cal.isDate(due, inSameDayAs: date)
        }
    }

    /// 종일 밴드: isAllDay 또는 다일 이벤트
    private var allDayEvents: [CalendarService.CalendarEventSummary] {
        dayEvents.filter { eventIsAllDayStyle($0) }
    }

    private var timedEvents: [CalendarService.CalendarEventSummary] {
        dayEvents.filter { !eventIsAllDayStyle($0) }
    }

    private var dateTitle: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ko_KR")
        fmt.dateFormat = "M월 d일 (E)"
        return fmt.string(from: date)
    }

    private func yOffset(for time: Date) -> CGFloat {
        let c = cal.dateComponents([.hour, .minute], from: time)
        return CGFloat(c.hour ?? 0) * hourHeight + CGFloat(c.minute ?? 0) / 60 * hourHeight
    }

    private var initialScrollHour: Int {
        let hours = timedEvents.map { cal.component(.hour, from: $0.startDate) }
                  + dayTodos.compactMap { $0.dueDate.map { cal.component(.hour, from: $0) } }
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
            .navigationTitle(dateTitle)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editingDetail) { detail in
                EventEditSheet(mode: .edit(detail: detail)) { onDataChanged() }
            }
            .sheet(item: $editingTodo) { todo in
                NavigationStack { TodoDetailView(todo: todo) }
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
            .padding(.horizontal, 8).padding(.vertical, 4)
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
                            Spacer().frame(height: hourHeight - 0.5)
                        }
                    }
                    ForEach(Array(columned.enumerated()), id: \.offset) { _, ci in
                        columnedItemView(ci, trackWidth: geo.size.width)
                    }
                }
            }
            .frame(height: CGFloat(24) * hourHeight)
        }
    }

    @ViewBuilder
    private func columnedItemView(_ ci: CalColumnedItem, trackWidth: CGFloat) -> some View {
        let gap: CGFloat = 2
        let colWidth = (trackWidth - gap * CGFloat(max(ci.columnCount-1, 0)) - 6) / CGFloat(ci.columnCount)
        let xOffset  = CGFloat(ci.column) * (colWidth + gap) + 3
        switch ci.item {
        case .event(let event):
            eventBlock(event)
                .frame(width: colWidth)
                .offset(x: xOffset, y: yOffset(for: event.startDate))
        case .todo(let todo):
            todoBlock(todo)
                .frame(width: colWidth)
                .offset(x: xOffset, y: todo.dueDate.map { yOffset(for: $0) } ?? 0)
        }
    }

    @ViewBuilder
    private func eventBlock(_ event: CalendarService.CalendarEventSummary) -> some View {
        let color = calendarEventColor(for: event.calendarID)
        let dur   = max(event.endDate.timeIntervalSince(event.startDate), 1800)
        let bh    = max(CGFloat(dur / 3600) * hourHeight, 30)
        Button { openEventEdit(event) } label: {
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
    private func todoBlock(_ todo: Todo) -> some View {
        Button { editingTodo = todo } label: {
            HStack(spacing: 4) {
                Image(systemName: "circle").font(.caption).foregroundStyle(.orange)
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
                if let due = todo.dueDate {
                    Text(due, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(minHeight: 30, alignment: .center)
            .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
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
                            .font(.caption).foregroundStyle(.red)
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
            }
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
        let color: Color = {
            if let ek = CalendarService.shared.ekCalendar(withIdentifier: info.id) {
                return Color(cgColor: ek.cgColor)
            }
            return .accentColor
        }()
        Label {
            Text(info.title)
        } icon: {
            Circle().fill(color).frame(width: 10, height: 10)
        }
    }

    private func save() {
        do {
            switch mode {
            case .create:
                try CalendarService.shared.createEvent(
                    title: title, startDate: startDate, endDate: endDate,
                    notes: notes, calendarID: calendarID.isEmpty ? nil : calendarID)
            case .edit(let detail):
                if let occurrenceDate = detail.occurrenceDate {
                    try CalendarService.shared.updateOccurrence(
                        identifier: detail.identifier, on: occurrenceDate,
                        title: title, startDate: startDate, endDate: endDate, notes: notes)
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
        let color: Color = {
            if let ek = CalendarService.shared.ekCalendar(withIdentifier: info.id) {
                return Color(cgColor: ek.cgColor)
            }
            return .accentColor
        }()
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
        let color: Color = {
            if let ek = CalendarService.shared.ekCalendar(withIdentifier: info.id) {
                return Color(cgColor: ek.cgColor)
            }
            return .accentColor
        }()
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
                        .font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
