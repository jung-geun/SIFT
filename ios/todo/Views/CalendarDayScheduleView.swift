import SwiftUI
import SwiftData
import Combine

private struct SchedulePresentation: Identifiable {
    enum Content {
        case event(EventEditMode)
        case todo(Todo)
    }
    let id = UUID()
    let content: Content
}

private struct ScheduleMutation {
    let detail: CalendarService.CalendarEventDetail
    let range: DateInterval?
    var isDelete: Bool { range == nil }
}

private struct TimelineDraft {
    let day: Date
    let range: DateInterval
    let isRangeDrag: Bool
}

private struct TimelineResize {
    let item: CalendarScheduleItem
    let day: Date
    let range: DateInterval
}

private struct TimelineResizeAccessibility: ViewModifier {
    let enabled: Bool
    let adjust: (CalendarTimelineGeometry.Edge, Int) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityAction(named: calendarCopy("calendar.timeline.startEarlier", "Start 15 minutes earlier", "15분 일찍 시작")) { adjust(.start, -15) }
                .accessibilityAction(named: calendarCopy("calendar.timeline.startLater", "Start 15 minutes later", "15분 늦게 시작")) { adjust(.start, 15) }
                .accessibilityAction(named: calendarCopy("calendar.timeline.endEarlier", "End 15 minutes earlier", "15분 일찍 종료")) { adjust(.end, -15) }
                .accessibilityAction(named: calendarCopy("calendar.timeline.endLater", "End 15 minutes later", "15분 늦게 종료")) { adjust(.end, 15) }
        } else { content }
    }
}

/// Shared across every displayed day so upcoming agendas do not repeatedly scan all links.
struct CalendarScheduleIndex {
    let activeTodos: [Todo]
    let todosByEventID: [String: [Todo]]
    let eventsByID: [String: [CalendarService.CalendarEventSummary]]

    init(events: [CalendarService.CalendarEventSummary], todos: [Todo]) {
        activeTodos = todos.filter { !$0.isCompleted && $0.scheduleAnchor != nil }
        var linked: [String: [Todo]] = [:]
        for todo in activeTodos {
            if let id = todo.calendarEventID { linked[id, default: []].append(todo) }
        }
        todosByEventID = linked
        eventsByID = Dictionary(grouping: events, by: \.identifier)
    }
}

/// A single clipped, half-open day. Civil-day arithmetic deliberately avoids 86,400-second days.
struct CalendarScheduleDay: Identifiable {
    let date: Date
    let end: Date
    let items: [CalendarScheduleItem]
    var id: Date { date }
    var allDayItems: [CalendarScheduleItem] { items.filter(\.isAllDay) }
    var timedItems: [CalendarScheduleItem] { items.filter { !$0.isAllDay } }

    init(date: Date, events: [CalendarService.CalendarEventSummary], todos: [Todo], calendar: Calendar,
         index: CalendarScheduleIndex? = nil) {
        self.date = calendar.startOfDay(for: date)
        end = calendar.dateInterval(of: .day, for: self.date)?.end ?? self.date
        let index = index ?? CalendarScheduleIndex(events: events, todos: todos)
        let matchingTodo: (CalendarService.CalendarEventSummary) -> Todo? = { event in
            index.todosByEventID[event.identifier, default: []].first {
                guard let anchor = $0.scheduleAnchor else { return false }
                return $0.calendarEventID == event.identifier
                    && calendar.isDate(anchor, inSameDayAs: event.startDate)
            }
        }
        var result: [CalendarScheduleItem] = []
        var seenEvents = Set<String>()
        for event in events {
            guard CalendarMonthGeometry.occupies(event, day: self.date, calendar: calendar) else { continue }
            let linkedTodo = matchingTodo(event)
            let spansDays = Self.spansDays(event, calendar: calendar)
            // A task represents one occurrence, not every recurrence with the same EventKit ID.
            if linkedTodo != nil && !spansDays { continue }
            let item = CalendarScheduleItem(source: .event(event), linkedEvent: nil, linkedTodo: linkedTodo,
                                            dayStart: self.date, dayEnd: end, calendar: calendar)
            if seenEvents.insert(item.id).inserted { result.append(item) }
        }
        for todo in index.activeTodos {
            guard let anchor = todo.scheduleAnchor else { continue }
            if todo.scheduledRange == nil && !calendar.isDate(anchor, inSameDayAs: self.date) { continue }
            let linkedEvent = todo.calendarEventID.flatMap { id in
                index.eventsByID[id, default: []].first {
                    calendar.isDate($0.startDate, inSameDayAs: anchor)
                }
            }
            if let linkedEvent, Self.spansDays(linkedEvent, calendar: calendar) { continue }
            let item = CalendarScheduleItem(source: .todo(todo), linkedEvent: linkedEvent, linkedTodo: nil,
                                            dayStart: self.date, dayEnd: end, calendar: calendar)
            guard item.start < end, item.end > self.date else { continue }
            result.append(item)
        }
        items = result.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }

    static func spansDays(_ event: CalendarService.CalendarEventSummary, calendar: Calendar) -> Bool {
        let nextDay = calendar.dateInterval(of: .day, for: event.startDate)?.end ?? event.startDate
        return event.endDate > nextDay
    }

    /// Wall-clock coordinates keep 09:00 aligned across DST boundaries; midnight is the exclusive 24:00 edge.
    func minuteOffset(_ date: Date, calendar: Calendar) -> Double {
        if date <= self.date { return 0 }
        if date >= end { return 1_440 }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
    }
}

struct CalendarScheduleItem: Identifiable {
    enum Source {
        case event(CalendarService.CalendarEventSummary)
        case todo(Todo)
    }
    let source: Source
    let linkedEvent: CalendarService.CalendarEventSummary?
    let linkedTodo: Todo?
    let start: Date
    let end: Date
    let clippedStart: Date
    let clippedEnd: Date
    let isAllDay: Bool
    let displayStartMinute: Double
    let displayEndMinute: Double

    var id: String {
        switch source {
        case .event(let event):
            return "event-\(event.calendarID)-\(event.identifier)-\(event.startDate.timeIntervalSince1970)-\(event.endDate.timeIntervalSince1970)"
        case .todo(let todo): return "todo-\(todo.id.uuidString)"
        }
    }
    var title: String {
        switch source {
        case .event(let event):
            return event.title.isEmpty ? calendarCopy("calendar.event.noTitle", "(No Title)", "(제목 없음)") : event.title
        case .todo(let todo):
            return todo.title.isEmpty ? calendarCopy("todo.noTitle", "(No Title)", "(제목 없음)") : todo.title
        }
    }
    var event: CalendarService.CalendarEventSummary? {
        if case .event(let event) = source { return event }
        return linkedEvent
    }
    var color: Color {
        event.map { CalendarPresentation.color(forCalendarID: $0.calendarID) } ?? AppTheme.accent
    }
    var accessibilityID: String {
        switch source {
        case .event(let event): return "calendar.event.\(event.identifier)"
        case .todo(let todo): return "calendar.todo.\(todo.id.uuidString)"
        }
    }
    var symbol: String {
        switch source {
        case .event(let event): return event.isRecurring ? "arrow.triangle.2.circlepath" : "calendar"
        case .todo(let todo):
            if todo.todoSource == .email { return "envelope.fill" }
            if todo.todoSource == .calendar { return todo.isFixedSchedule ? "arrow.triangle.2.circlepath" : "calendar" }
            return "circle"
        }
    }

    init(source: Source, linkedEvent: CalendarService.CalendarEventSummary?, linkedTodo: Todo?,
         dayStart: Date, dayEnd: Date, calendar: Calendar) {
        self.source = source
        self.linkedEvent = linkedEvent
        self.linkedTodo = linkedTodo
        switch source {
        case .event(let event):
            start = event.startDate
            end = event.endDate
            let nextCivilDay = calendar.date(byAdding: .day, value: 1, to: event.startDate) ?? event.endDate
            isAllDay = event.isAllDay || event.endDate >= nextCivilDay.addingTimeInterval(-60)
        case .todo(let todo):
            let anchor = todo.scheduleAnchor ?? dayStart
            start = anchor
            end = todo.scheduledRange?.end ?? anchor.addingTimeInterval(1_800)
            isAllDay = linkedEvent?.isAllDay ?? false
        }
        clippedStart = max(start, dayStart)
        clippedEnd = max(clippedStart, min(end, dayEnd))
        func minute(_ date: Date) -> Double {
            if date <= dayStart { return 0 }
            if date >= dayEnd { return 1_440 }
            let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
            return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
        }
        let startMinute = minute(clippedStart)
        let endMinute = minute(clippedEnd)
        // Repeated civil hours retain positive duration; midnight clipping must
        // not erase the minimum visual body and its independent edge targets.
        let positiveEnd = endMinute > startMinute ? endMinute
            : startMinute + clippedEnd.timeIntervalSince(clippedStart) / 60
        let visualEnd = min(1_440, max(positiveEnd, startMinute + 28.125))
        displayStartMinute = min(startMinute, max(0, visualEnd - 28.125))
        displayEndMinute = visualEnd
    }
}

/// Greedy overlap columns use the clipped display ranges, including minimum-height and repeated-hour blocks.
struct CalendarScheduleColumn: Identifiable {
    let item: CalendarScheduleItem
    let column: Int
    let columnCount: Int
    var id: String { item.id }

    static func layout(_ items: [CalendarScheduleItem]) -> [Self] {
        let sorted = items.sorted {
            if $0.displayStartMinute != $1.displayStartMinute { return $0.displayStartMinute < $1.displayStartMinute }
            return $0.id < $1.id
        }
        var columnEnds: [Double] = []
        var assignments: [(item: CalendarScheduleItem, column: Int)] = []
        for item in sorted {
            if let column = columnEnds.firstIndex(where: { $0 <= item.displayStartMinute }) {
                columnEnds[column] = item.displayEndMinute
                assignments.append((item, column))
            } else {
                columnEnds.append(item.displayEndMinute)
                assignments.append((item, columnEnds.count - 1))
            }
        }
        var result: [Self] = []
        var index = 0
        while index < assignments.count {
            var clusterEnd = assignments[index].item.displayEndMinute
            var next = index + 1
            while next < assignments.count && assignments[next].item.displayStartMinute < clusterEnd {
                clusterEnd = max(clusterEnd, assignments[next].item.displayEndMinute)
                next += 1
            }
            let count = (assignments[index..<next].map(\.column).max() ?? 0) + 1
            for assignment in assignments[index..<next] {
                result.append(Self(item: assignment.item, column: assignment.column, columnCount: count))
            }
            index = next
        }
        return result
    }
}

/// Embedded day / multi-day / week timeline. Its caller owns navigation and the day headings.
struct CalendarScheduleView: View {
    let startDate: Date
    let dayCount: Int
    let events: [CalendarService.CalendarEventSummary]
    let todos: [Todo]
    let calendar: Calendar
    let today: Date
    var onDataChanged: () -> Void = {}

    var body: some View {
        CalendarScheduleContent(startDate: startDate, dayCount: dayCount, events: events, todos: todos,
                                calendar: calendar, today: today, mode: .timeline(alwaysShow: true),
                                onDataChanged: onDataChanged)
    }
}

/// Embedded chronological agenda, with one section per occupied day and no placeholder events.
struct CalendarAgendaView: View {
    let startDate: Date
    let dayCount: Int
    let events: [CalendarService.CalendarEventSummary]
    let todos: [Todo]
    let calendar: Calendar
    var onDataChanged: () -> Void = {}
    var onLoadMore: (() -> Void)? = nil
    var isLoadingMore = false

    var body: some View {
        CalendarScheduleContent(startDate: startDate, dayCount: dayCount, events: events, todos: todos,
                                calendar: calendar, today: startDate, mode: .agenda,
                                onDataChanged: onDataChanged,
                                onLoadMore: onLoadMore, isLoadingMore: isLoadingMore)
    }
}

/// The desktop / iPad popover retains its own navigation, sizing, and existing editing flows.
struct DayDetailSheet: View {
    let date: Date
    let events: [CalendarService.CalendarEventSummary]
    let todos: [Todo]
    var prefersRoomyLayout = false
    var calendar: Calendar = .current
    var today: Date = Date()
    var onDataChanged: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    private var dateTitle: String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    var body: some View {
        NavigationStack {
            CalendarScheduleContent(startDate: date, dayCount: 1, events: events, todos: todos,
                                    calendar: calendar, today: today, mode: .timeline(alwaysShow: true),
                                    onDataChanged: onDataChanged, showsAddButton: true)
                .navigationTitle(dateTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(calendarCopy("action.close", "Close", "닫기")) { dismiss() }
                    }
                }
        }
        #if targetEnvironment(macCatalyst)
        .frame(width: 520, height: 560)
        .presentationSizing(.fitted)
        #else
        .frame(minWidth: prefersRoomyLayout ? 340 : nil,
               idealWidth: prefersRoomyLayout ? 360 : nil)
        #endif
    }
}

private struct CalendarScheduleContent: View {
    enum Mode {
        case timeline(alwaysShow: Bool)
        case agenda
    }
    let startDate: Date
    let dayCount: Int
    let events: [CalendarService.CalendarEventSummary]
    let todos: [Todo]
    let calendar: Calendar
    let today: Date
    let mode: Mode
    let onDataChanged: () -> Void
    let onLoadMore: (() -> Void)?
    let isLoadingMore: Bool
    @Environment(\.modelContext) private var modelContext
    @State private var presentation: SchedulePresentation?
    @State private var mutation: ScheduleMutation?
    @State private var errorMessage: String?
    @State private var draft: TimelineDraft?
    @State private var resizePreview: TimelineResize?
    @State private var gestureCancelled = false
    @GestureState private var pointerActive = false
    let showsAddButton: Bool
    @State private var now: Date
    @State private var lastAutomaticLoadEnd: Date?
    @State private var lastAutomaticContentDate: Date?
    private let hourHeight: CGFloat = 64
    private let labelWidth: CGFloat = 44
    private let dateFormatter: DateFormatter

    init(startDate: Date, dayCount: Int, events: [CalendarService.CalendarEventSummary], todos: [Todo],
         calendar: Calendar, today: Date, mode: Mode, onDataChanged: @escaping () -> Void,
         onLoadMore: (() -> Void)? = nil, isLoadingMore: Bool = false, showsAddButton: Bool = false) {
        self.startDate = startDate
        self.dayCount = dayCount
        self.events = events
        self.todos = todos
        self.calendar = calendar
        self.today = today
        self.mode = mode
        self.onDataChanged = onDataChanged
        self.onLoadMore = onLoadMore
        self.isLoadingMore = isLoadingMore
        self.showsAddButton = showsAddButton
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        dateFormatter = formatter
        _now = State(initialValue: Date())
    }

    private var days: [CalendarScheduleDay] {
        let start = calendar.startOfDay(for: startDate)
        let index = CalendarScheduleIndex(events: events, todos: todos)
        return (0..<max(dayCount, 0)).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map {
                CalendarScheduleDay(date: calendar.startOfDay(for: $0), events: events, todos: todos, calendar: calendar, index: index)
            }
        }
    }

    var body: some View {
        let scheduleDays = days
        Group {
            switch mode {
            case .agenda: agenda(scheduleDays)
            case .timeline(let alwaysShow): timeline(scheduleDays, alwaysShow: alwaysShow)
            }
        }
        .background(AppTheme.surface)
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .sheet(item: $presentation) { destination in
            switch destination.content {
            case .event(let mode): EventEditSheet(mode: mode, onSave: didMutate)
            case .todo(let todo): NavigationStack { TodoDetailView(todo: todo) }
            }
        }
        .toolbar {
            if showsAddButton {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let hour = calendar.isDate(startDate, inSameDayAs: now)
                            ? min(22, max(8, calendar.component(.hour, from: now))) : 9
                        create(CalendarTimelineGeometry.creationRange(from: Double(hour * 60), to: Double(hour * 60),
                            on: startDate, calendar: calendar, isClick: true))
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel(calendarCopy("calendar.event.newTitle", "New Event", "새 이벤트"))
                    .accessibilityIdentifier("calendar.day.add")
                }
            }
        }
        .confirmationDialog(mutationTitle, isPresented: Binding(get: { mutation != nil },
            set: { if !$0 { mutation = nil } }), titleVisibility: .visible) {
            if let pending = mutation {
                if pending.detail.isRecurring {
                    Button(calendarCopy("calendar.timeline.thisEvent", "This event only", "이 일정만"),
                           role: pending.isDelete ? .destructive : nil) { persist(pending, scope: .thisEvent) }
                    Button(calendarCopy("calendar.timeline.futureEvents", "This and future events", "이후 모든 일정"),
                           role: pending.isDelete ? .destructive : nil) { persist(pending, scope: .futureEvents) }
                    Button(calendarCopy("calendar.timeline.entireSeries", "Entire series", "전체 시리즈"),
                           role: pending.isDelete ? .destructive : nil) { persist(pending, scope: .allEvents) }
                } else {
                    Button(calendarCopy("action.delete", "Delete", "삭제"), role: .destructive) {
                        persist(pending, scope: .thisEvent)
                    }
                }
            }
            Button(calendarCopy("action.cancel", "Cancel", "취소"), role: .cancel) { mutation = nil }
        }
        .alert(calendarCopy("calendar.timeline.errorTitle", "Calendar change failed", "캘린더 변경 실패"),
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(calendarCopy("action.ok", "OK", "확인"), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .overlay(alignment: .topTrailing) {
            #if targetEnvironment(macCatalyst)
            if draft != nil || resizePreview != nil {
                Button(calendarCopy("action.cancel", "Cancel", "취소")) {
                    gestureCancelled = true
                    draft = nil
                    resizePreview = nil
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .padding(8)
                .accessibilityIdentifier("calendar.timeline.cancelGesture")
            }
            #endif
        }
        .onChange(of: pointerActive) { _, active in
            guard !active else { return }
            // Gesture cancellation has no onEnded callback. Defer cleanup until a normal end has consumed its draft.
            DispatchQueue.main.async {
                if !pointerActive {
                    draft = nil
                    resizePreview = nil
                    gestureCancelled = false
                }
            }
        }
    }

    @ViewBuilder
    private func timeline(_ days: [CalendarScheduleDay], alwaysShow: Bool) -> some View {
        let hasTimed = days.contains { !$0.timedItems.isEmpty }
        let allDayCount = days.map { $0.allDayItems.count }.max() ?? 0
        VStack(spacing: 0) {
            if days.count > 1 {
                HStack(spacing: 0) {
                    Color.clear.frame(width: labelWidth + 4)
                    ForEach(days) { day in
                        let isToday = calendar.isDate(day.date, inSameDayAs: today)
                        VStack(spacing: 2) {
                            Text(dateLabel(day.date, template: "EEE"))
                                .font(.caption2)
                            Text(dateLabel(day.date, template: "d"))
                                .font(.subheadline.weight(isToday ? .bold : .medium))
                        }
                        .foregroundStyle(isToday ? AppTheme.destructive : Color.primary)
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(agendaDateTitle(day.date))
                        .accessibilityIdentifier("calendar.schedule.day.\(day.date.timeIntervalSince1970)")
                    }
                }
                .padding(.vertical, 6)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            if allDayCount > 0 {
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        Text(calendarCopy("calendar.allDay", "All-day", "종일"))
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(width: labelWidth, alignment: .trailing)
                            .padding(.trailing, 4)
                        ForEach(days) { day in
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(day.allDayItems) { item in
                                    allDayChip(item, day: day)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 3)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(height: alwaysShow || hasTimed ? min(132, 16 + CGFloat(allDayCount) * 36) : nil)
                .frame(maxHeight: alwaysShow || hasTimed ? nil : .infinity)
                if alwaysShow || hasTimed { Divider() }
            }
            if alwaysShow || hasTimed {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        timelineGrid(days)
                            .padding(.top, 8)
                            .padding(.bottom, 12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { scrollToInitialHour(days, proxy: proxy) }
                    .onChange(of: startDate) { _, _ in scrollToInitialHour(days, proxy: proxy) }
                }
            } else if allDayCount == 0 {
                ContentUnavailableView(calendarCopy("calendar.schedule.empty", "No Events", "일정 없음"), systemImage: "calendar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.timeline")
    }

    private func timelineGrid(_ days: [CalendarScheduleDay]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d", hour))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                        .frame(width: labelWidth + 4, height: hourHeight, alignment: .topTrailing)
                        .id("hour-\(hour)")
                }
            }
            ForEach(days) { day in
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        blankTimeSurface(day)
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { _ in
                                Divider()
                                Spacer().frame(height: hourHeight - 0.5)
                            }
                        }
                        .allowsHitTesting(false)
                        ForEach(CalendarScheduleColumn.layout(day.timedItems)) { item in
                            timelineBlock(item, day: day, trackWidth: geometry.size.width)
                        }
                        if let draft, draft.day == day.date {
                            rangePreview(draft.range, day: day, color: AppTheme.accent)
                        }
                        if let preview = resizePreview, preview.day == day.date {
                            rangePreview(preview.range, day: day, color: preview.item.color)
                        }
                        if calendar.isDate(day.date, inSameDayAs: today), now >= day.date, now < day.end {
                            let lineY = yOffset(now, day: day)
                            Rectangle().fill(AppTheme.destructive)
                                .frame(height: 1.5).offset(y: lineY)
                                .allowsHitTesting(false)
                            Circle().fill(AppTheme.destructive)
                                .frame(width: 6, height: 6).position(x: 3, y: lineY)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipped()
                }
                .frame(maxWidth: .infinity)
                .frame(height: hourHeight * 24)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color(.separator)).frame(width: 0.5)
                }
            }
        }
    }

    private func yOffset(_ date: Date, day: CalendarScheduleDay) -> CGFloat {
        CGFloat(day.minuteOffset(date, calendar: calendar)) * hourHeight / 60
    }

    @ViewBuilder
    private func timelineBlock(_ column: CalendarScheduleColumn, day: CalendarScheduleDay, trackWidth: CGFloat) -> some View {
        let count = max(column.columnCount, 1)
        let width = (trackWidth - 6 - CGFloat(count - 1) * 2) / CGFloat(count)
        if width.isFinite && width > 0 {
            let item = column.item
            let y = CGFloat(item.displayStartMinute) * hourHeight / 60
            let height = CGFloat(item.displayEndMinute - item.displayStartMinute) * hourHeight / 60
            itemControl(item, compact: true, showTime: height > 38, height: height)
                .frame(width: width, height: height, alignment: .top)
                .background(item.color.opacity(0.14), in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                        .strokeBorder(item.color.opacity(0.45), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
                .opacity(resizePreview?.item.id == item.id && resizePreview?.day == day.date ? 0 : 1)
                .overlay(alignment: .top) { resizeHandle(item, day: day, edge: .start, hitHeight: min(10, height / 3)) }
                .overlay(alignment: .bottom) { resizeHandle(item, day: day, edge: .end, hitHeight: min(10, height / 3)) }
                .contextMenu { itemMenu(item) }
                .offset(x: 3 + CGFloat(column.column) * (width + 2), y: y)
        }
    }

    @ViewBuilder
    private func blankTimeSurface(_ day: CalendarScheduleDay) -> some View {
        #if targetEnvironment(macCatalyst)
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .updating($pointerActive) { _, active, _ in active = true }
                .onChanged { value in
                    guard presentation == nil, mutation == nil, !gestureCancelled else { return }
                    let isRangeDrag = draft?.isRangeDrag == true
                        || abs(value.translation.height) >= 4 || abs(value.translation.width) >= 4
                    let range = CalendarTimelineGeometry.creationRange(from: Double(value.startLocation.y / hourHeight * 60),
                        to: Double(value.location.y / hourHeight * 60), on: day.date, calendar: calendar,
                        isClick: !isRangeDrag)
                    draft = TimelineDraft(day: day.date, range: range, isRangeDrag: isRangeDrag)
                }
                .onEnded { _ in
                    let selection = draft
                    draft = nil
                    let cancelled = gestureCancelled
                    gestureCancelled = false
                    guard !cancelled, let selection else { return }
                    create(selection.range)
                })
            .accessibilityHidden(true)
        #else
        Color.clear.allowsHitTesting(false)
        #endif
    }

    private func rangePreview(_ range: DateInterval, day: CalendarScheduleDay, color: Color) -> some View {
        let top = yOffset(max(range.start, day.date), day: day)
        let bottom = yOffset(min(range.end, day.end), day: day)
        return RoundedRectangle(cornerRadius: AppTheme.controlRadius)
            .fill(color.opacity(0.22))
            .overlay(alignment: .topLeading) {
                Text("\(range.start, style: .time) – \(range.end, style: .time)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.primary).padding(6)
            }
            .overlay { RoundedRectangle(cornerRadius: AppTheme.controlRadius).strokeBorder(color, lineWidth: 1.5) }
            .frame(maxWidth: .infinity)
            .frame(height: max(16, bottom - top))
            .offset(y: top)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func resizeHandle(_ item: CalendarScheduleItem, day: CalendarScheduleDay,
                              edge: CalendarTimelineGeometry.Edge, hitHeight: CGFloat) -> some View {
        #if targetEnvironment(macCatalyst)
        if let event = item.event, edge == .start ? event.startDate >= day.date : event.endDate <= day.end {
            Capsule().fill(item.color.opacity(0.65))
                .frame(width: 24, height: 2)
                .frame(maxWidth: .infinity)
                .frame(height: hitHeight)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3)
                    .updating($pointerActive) { _, active, _ in active = true }
                    .onChanged { value in
                        guard presentation == nil, mutation == nil, !gestureCancelled else { return }
                        let original = day.minuteOffset(edge == .start ? event.startDate : event.endDate, calendar: calendar)
                        let range = CalendarTimelineGeometry.resizedRange(start: event.startDate, end: event.endDate, edge: edge,
                            minute: original + Double(value.translation.height / hourHeight * 60), on: day.date, calendar: calendar)
                        resizePreview = TimelineResize(item: item, day: day.date, range: range)
                    }
                    .onEnded { _ in
                        let preview = resizePreview
                        resizePreview = nil
                        let cancelled = gestureCancelled
                        gestureCancelled = false
                        if !cancelled, let preview { requestResize(item, range: preview.range) }
                    })
                .onTapGesture { openEventEdit(event) }
                .accessibilityHidden(true)
        }
        #endif
    }

    @ViewBuilder
    private func itemMenu(_ item: CalendarScheduleItem) -> some View {
        if let event = item.event {
            Button(calendarCopy("calendar.event.editTitle", "Edit Event", "일정 편집")) { openEventEdit(event) }
            if !item.isAllDay {
                Menu(calendarCopy("calendar.timeline.adjustTime", "Adjust time", "시간 조정")) {
                    Button(calendarCopy("calendar.timeline.startEarlier", "Start 15 minutes earlier", "15분 일찍 시작")) {
                        adjust(item, edge: .start, minutes: -15)
                    }
                    Button(calendarCopy("calendar.timeline.startLater", "Start 15 minutes later", "15분 늦게 시작")) {
                        adjust(item, edge: .start, minutes: 15)
                    }
                    Button(calendarCopy("calendar.timeline.endEarlier", "End 15 minutes earlier", "15분 일찍 종료")) {
                        adjust(item, edge: .end, minutes: -15)
                    }
                    Button(calendarCopy("calendar.timeline.endLater", "End 15 minutes later", "15분 늦게 종료")) {
                        adjust(item, edge: .end, minutes: 15)
                    }
                }
            }
            if case .todo(let todo) = item.source {
                Button(calendarCopy("calendar.openLinkedTodo", "Open Linked To-do", "연결된 할 일 열기")) { presentTodo(todo) }
            }
            Button(calendarCopy("action.delete", "Delete", "삭제"), role: .destructive) { requestDelete(event) }
        } else {
            Button(calendarCopy("action.edit", "Edit", "편집")) { open(item) }
        }
    }

    private func scrollToInitialHour(_ days: [CalendarScheduleDay], proxy: ScrollViewProxy) {
        let hours = days.flatMap(\.timedItems).map { calendar.component(.hour, from: $0.clippedStart) }
        let hour = max(0, (hours.min() ?? calendar.component(.hour, from: now)) - 1)
        DispatchQueue.main.async { proxy.scrollTo("hour-\(hour)", anchor: .top) }
    }

    private func allDayChip(_ item: CalendarScheduleItem, day: CalendarScheduleDay) -> some View {
        HStack(spacing: 2) {
            Button { open(item) } label: {
                HStack(spacing: 4) {
                    Circle().fill(item.color).frame(width: 6, height: 6)
                    if item.start < day.date { Image(systemName: "chevron.left").font(.caption2) }
                    Text(item.title).font(.caption.weight(.medium)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if item.end > day.end { Image(systemName: "chevron.right").font(.caption2) }
                }
                .foregroundStyle(.primary)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(item.accessibilityID)
            linkedControl(item)
        }
        .contextMenu { itemMenu(item) }
    }

    @ViewBuilder
    private func agenda(_ days: [CalendarScheduleDay]) -> some View {
        let occupied = days.filter { !$0.items.isEmpty }
        if occupied.isEmpty {
            VStack(spacing: 0) {
                ContentUnavailableView(calendarCopy("calendar.schedule.empty", "No Events", "일정 없음"), systemImage: "calendar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if onLoadMore != nil { agendaContinuation(days, automaticallyLoad: false).padding() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("calendar.agenda")
        } else {
            List {
                ForEach(occupied) { day in
                    Section {
                        ForEach(day.items) { item in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    if item.isAllDay {
                                        Text(calendarCopy("calendar.allDay", "All-day", "종일"))
                                    } else {
                                        Text(item.clippedStart, style: .time)
                                        Text(item.clippedEnd, style: .time).foregroundStyle(.secondary)
                                    }
                                    if item.start < day.date || item.end > day.end {
                                        Text(calendarCopy("calendar.schedule.continues", "Continues", "여러 날"))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption.monospacedDigit())
                                .frame(width: 76, alignment: .trailing)
                                itemControl(item, compact: false, showTime: false, height: nil)
                            }
                            .padding(.vertical, 3)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("calendar.agenda.row.\(item.id).\(day.date.timeIntervalSince1970)")
                        }
                    } header: {
                        Text(agendaDateTitle(day.date))
                            .textCase(nil)
                    }
                }
                if onLoadMore != nil { agendaContinuation(days, automaticallyLoad: true) }
            }
            .listStyle(.plain)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("calendar.agenda")
        }
    }

    @ViewBuilder
    private func agendaContinuation(_ days: [CalendarScheduleDay], automaticallyLoad: Bool) -> some View {
        if let end = days.last?.end {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text(calendarCopy("calendar.agenda.loadedThrough", "Loaded through", "불러온 마지막 날짜"))
                    Text(agendaDateTitle(days.last?.date ?? startDate))
                        .accessibilityIdentifier("calendar.agenda.loadedThrough")
                }
                .font(.caption).foregroundStyle(.secondary)
                if isLoadingMore {
                    ProgressView()
                        .accessibilityLabel(calendarCopy("calendar.agenda.loading", "Loading events", "일정 불러오는 중"))
                } else {
                    Button(calendarCopy("calendar.agenda.later", "Later Events", "이후 일정")) { onLoadMore?() }
                        .accessibilityIdentifier("calendar.agenda.loadMore")
                }
            }
            .frame(maxWidth: .infinity)
            .id(end)
            .onAppear {
                let latestContentDate = days.last(where: { !$0.items.isEmpty })?.date
                guard automaticallyLoad, !isLoadingMore, lastAutomaticLoadEnd != end,
                      latestContentDate != lastAutomaticContentDate else { return }
                lastAutomaticLoadEnd = end
                lastAutomaticContentDate = latestContentDate
                onLoadMore?()
            }
        }
    }

    private func agendaDateTitle(_ date: Date) -> String {
        dateLabel(date, template: "EEEEyMMMMd")
    }

    private func dateLabel(_ date: Date, template: String) -> String {
        dateFormatter.setLocalizedDateFormatFromTemplate(template)
        return dateFormatter.string(from: date)
    }

    private func itemControl(_ item: CalendarScheduleItem, compact: Bool, showTime: Bool, height: CGFloat?) -> some View {
        HStack(alignment: .top, spacing: 2) {
            Button { open(item) } label: {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: item.symbol).font(.caption2).foregroundStyle(item.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(compact ? .caption.weight(.semibold) : .body)
                            .foregroundStyle(.primary).lineLimit(compact ? 2 : nil)
                        if showTime {
                            Text("\(item.start, style: .time) – \(item.end, style: .time)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(compact ? 5 : 0)
                .frame(maxWidth: .infinity, maxHeight: height, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(item.accessibilityID)
            .modifier(TimelineResizeAccessibility(enabled: item.event != nil && !item.isAllDay) { edge, minutes in
                adjust(item, edge: edge, minutes: minutes)
            })
            linkedControl(item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { itemMenu(item) }
    }

    @ViewBuilder
    private func linkedControl(_ item: CalendarScheduleItem) -> some View {
        if let event = item.linkedEvent {
            Button { openEventEdit(event) } label: {
                Image(systemName: event.isRecurring ? "arrow.triangle.2.circlepath.circle.fill" : "calendar.circle.fill")
                    .foregroundStyle(AppTheme.accent).frame(minWidth: 30, minHeight: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(calendarCopy("calendar.editLinkedEvent", "Edit Calendar Event", "캘린더 일정 편집"))
            .accessibilityIdentifier("calendar.editLinkedEvent")
        } else if let todo = item.linkedTodo {
            Button { presentTodo(todo) } label: {
                Image(systemName: "checklist").foregroundStyle(AppTheme.accent).frame(minWidth: 30, minHeight: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(calendarCopy("calendar.openLinkedTodo", "Open Linked To-do", "연결된 할 일 열기"))
            .accessibilityIdentifier("calendar.openLinkedTodo")
        }
    }

    private func open(_ item: CalendarScheduleItem) {
        #if targetEnvironment(macCatalyst)
        if let event = item.event { openEventEdit(event); return }
        #endif
        switch item.source {
        case .event(let event): openEventEdit(event)
        case .todo(let todo): presentTodo(todo)
        }
    }

    private func presentTodo(_ todo: Todo) {
        guard presentation == nil, mutation == nil, draft == nil, resizePreview == nil else { return }
        presentation = SchedulePresentation(content: .todo(todo))
    }

    private func create(_ range: DateInterval) {
        guard presentation == nil, mutation == nil, resizePreview == nil else { return }
        presentation = SchedulePresentation(content: .event(.create(date: range.start, endDate: range.end)))
    }

    private func detail(for event: CalendarService.CalendarEventSummary) -> CalendarService.CalendarEventDetail? {
        guard CalendarService.shared.isAuthorized else {
            errorMessage = calendarCopy("calendar.timeline.noAccess", "Calendar access is unavailable. Allow access in Settings and try again.", "캘린더에 접근할 수 없습니다. 설정에서 접근을 허용한 뒤 다시 시도하세요.")
            return nil
        }
        let detail = event.isRecurring
            ? CalendarService.shared.occurrenceDetail(identifier: event.identifier, on: event.startDate)
            : CalendarService.shared.eventDetail(identifier: event.identifier)
        if detail == nil {
            errorMessage = calendarCopy("calendar.timeline.unavailable", "This event is no longer available. Refresh the calendar and try again.", "일정을 더 이상 찾을 수 없습니다. 캘린더를 새로고침한 뒤 다시 시도하세요.")
        }
        return detail
    }

    private func openEventEdit(_ event: CalendarService.CalendarEventSummary) {
        guard presentation == nil, mutation == nil, draft == nil, resizePreview == nil,
              let detail = detail(for: event) else { return }
        presentation = SchedulePresentation(content: .event(.edit(detail: detail)))
    }

    private func adjust(_ item: CalendarScheduleItem, edge: CalendarTimelineGeometry.Edge, minutes: Int) {
        guard let event = item.event, !item.isAllDay else { return }
        let delta = TimeInterval(minutes * 60)
        let minimum = min(CalendarTimelineGeometry.minimumDuration, event.endDate.timeIntervalSince(event.startDate))
        let start = edge == .start ? min(event.startDate.addingTimeInterval(delta), event.endDate.addingTimeInterval(-minimum)) : event.startDate
        let end = edge == .end ? max(event.endDate.addingTimeInterval(delta), event.startDate.addingTimeInterval(minimum)) : event.endDate
        requestResize(item, range: DateInterval(start: start, end: end))
    }

    private func requestResize(_ item: CalendarScheduleItem, range: DateInterval) {
        guard presentation == nil, mutation == nil, let event = item.event,
              range.start != event.startDate || range.end != event.endDate,
              let detail = detail(for: event) else { return }
        let pending = ScheduleMutation(detail: detail, range: range)
        if detail.isRecurring { mutation = pending } else { persist(pending, scope: .thisEvent) }
    }

    private func requestDelete(_ event: CalendarService.CalendarEventSummary) {
        guard presentation == nil, mutation == nil, let detail = detail(for: event) else { return }
        mutation = ScheduleMutation(detail: detail, range: nil)
    }

    private var mutationTitle: String {
        mutation?.isDelete == true
            ? calendarCopy("calendar.timeline.deleteScope", "Delete event? Choose which events to delete.", "일정을 삭제할까요? 삭제할 범위를 선택하세요.")
            : calendarCopy("calendar.timeline.resizeScope", "Choose which recurring events to resize", "시간을 변경할 반복 일정 범위를 선택하세요")
    }

    private func persist(_ pending: ScheduleMutation, scope: CalendarRecurrenceScope) {
        mutation = nil
        do {
            let detail = pending.detail
            let writableIDs = Set(CalendarService.shared.availableCalendars(writableOnly: true).flatMap(\.calendars).map(\.id))
            guard writableIDs.contains(detail.calendarID) else {
                errorMessage = calendarCopy("calendar.timeline.readOnly", "This calendar is read-only or unavailable. Choose a writable calendar to make changes.", "읽기 전용이거나 사용할 수 없는 캘린더입니다. 변경하려면 쓰기 가능한 캘린더를 선택하세요.")
                return
            }
            let committed: CalendarService.CommittedMutation
            if let range = pending.range {
                if detail.isRecurring {
                    committed = try CalendarService.shared.updateOccurrence(identifier: detail.identifier,
                        on: detail.occurrenceDate ?? detail.startDate, title: detail.title,
                        startDate: range.start, endDate: range.end, notes: detail.notes, scope: scope)
                } else {
                    committed = try CalendarService.shared.updateEvent(identifier: detail.identifier, title: detail.title,
                        startDate: range.start, endDate: range.end, notes: detail.notes)
                }
            } else if detail.isRecurring {
                committed = try CalendarService.shared.removeEventOccurrence(eventID: detail.identifier,
                    on: detail.occurrenceDate ?? detail.startDate, scope: scope)
            } else {
                committed = try CalendarService.shared.removeEvent(eventID: detail.identifier)
            }
            try committed.reconcileExisting(in: modelContext)
            didMutate()
        } catch { errorMessage = error.localizedDescription }
    }

    private func didMutate() {
        onDataChanged()
    }
}
