import SwiftUI
import UIKit

/// Calendar arithmetic, including locale first-weekday and DST, is shared by
/// loading and rendering so an adjacent-month cell never lies outside the read.
struct CalendarMonthGeometry {
    let month: Date
    let days: [Date]
    let weeks: [[Date]]
    let interval: DateInterval

    static func weekStart(containing date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let leading = (calendar.component(.weekday, from: day) - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -leading, to: day) ?? day
    }

    init(month: Date, calendar: Calendar = .current) {
        self.month = calendar.dateInterval(of: .month, for: month)?.start ?? calendar.startOfDay(for: month)
        let start = Self.weekStart(containing: self.month, calendar: calendar)
        let dates = (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        days = dates
        weeks = stride(from: 0, to: dates.count, by: 7).map { Array(dates[$0..<min($0 + 7, dates.count)]) }
        interval = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 42, to: start) ?? start)
    }

    static func occupies(_ event: CalendarService.CalendarEventSummary, day: Date, calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.dateInterval(of: .day, for: day)?.end else { return false }
        return event.startDate < end && event.endDate > start
    }
}

struct CalendarMonthTodo: Equatable {
    let title: String
    let date: Date
    let eventID: String?
}

struct CalendarMonthWeekLayout {
    struct Span {
        let event: CalendarService.CalendarEventSummary
        let firstColumn: Int
        let lastColumn: Int
        let lane: Int
    }
    enum Item {
        case event(CalendarService.CalendarEventSummary)
        case todo(CalendarMonthTodo)
        var title: String {
            switch self { case .event(let event): event.title; case .todo(let todo): todo.title }
        }
        var time: Date {
            switch self { case .event(let event): event.startDate; case .todo(let todo): todo.date }
        }
    }
    let days: [Date]
    let spans: [Span]
    let items: [[Item]]

    init(days: [Date], events: [CalendarService.CalendarEventSummary], todos: [CalendarMonthTodo], calendar: Calendar = .current) {
        self.days = days
        var linkedDates: [String: [Date]] = [:]
        for todo in todos {
            if let id = todo.eventID { linkedDates[id, default: []].append(todo.date) }
        }
        var spanCandidates: [(CalendarService.CalendarEventSummary, Int, Int)] = []
        var columns = Array(repeating: [Item](), count: days.count)
        for event in events {
            let nextDay = calendar.dateInterval(of: .day, for: event.startDate)?.end ?? event.startDate
            let spansDays = event.endDate > nextDay
            // A due-date todo replaces only a single-day event. It cannot
            // represent the remaining days of a multi-day reservation.
            if !spansDays && linkedDates[event.identifier, default: []].contains(where: {
                calendar.isDate($0, inSameDayAs: event.startDate)
            }) { continue }
            let occupied = days.indices.filter { CalendarMonthGeometry.occupies(event, day: days[$0], calendar: calendar) }
            guard let first = occupied.first, let last = occupied.last else { continue }
            if event.isAllDay || spansDays {
                spanCandidates.append((event, first, last))
            } else {
                for column in occupied { columns[column].append(.event(event)) }
            }
        }
        spanCandidates.sort {
            let left = $0.2 - $0.1, right = $1.2 - $1.1
            if left != right { return left > right }
            if $0.0.startDate != $1.0.startDate { return $0.0.startDate < $1.0.startDate }
            return $0.0.identifier < $1.0.identifier
        }
        var laneEnds: [Int] = []
        var assigned: [Span] = []
        for (event, first, last) in spanCandidates {
            let lane = laneEnds.firstIndex(where: { $0 < first }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(last) } else { laneEnds[lane] = last }
            assigned.append(Span(event: event, firstColumn: first, lastColumn: last, lane: lane))
        }
        spans = assigned
        for todo in todos {
            if assigned.contains(where: {
                $0.event.identifier == todo.eventID && calendar.isDate($0.event.startDate, inSameDayAs: todo.date)
            }) { continue }
            guard let column = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: todo.date) }) else { continue }
            columns[column].append(.todo(todo))
        }
        items = columns.map { $0.sorted { $0.time < $1.time } }
    }

    func availableLanes(column: Int, capacity: Int) -> [Int] {
        let used = Set(spans.filter { $0.firstColumn <= column && $0.lastColumn >= column }.map(\.lane))
        return (0..<capacity).filter { !used.contains($0) }
    }

    func overflow(column: Int, capacity: Int) -> Int {
        let hiddenSpans = spans.filter { $0.firstColumn <= column && $0.lastColumn >= column && $0.lane >= capacity }.count
        return hiddenSpans + max(0, items[column].count - availableLanes(column: column, capacity: capacity).count)
    }

    static func dayHeaderHeight(desktop: Bool) -> CGFloat { desktop ? 29 : 27 }
    static let laneHeight: CGFloat = 18

    static func laneCapacity(height: CGFloat, desktop: Bool) -> Int {
        max(0, Int((height - dayHeaderHeight(desktop: desktop) - 19) / laneHeight))
    }

    /// Native background clicks must leave the hosted event/task buttons alone.
    /// Use the same lane geometry as the renderer, including spanning events.
    func containsEntry(at point: CGPoint, rowSize: CGSize, desktop: Bool) -> Bool {
        let width = rowSize.width / 7
        guard width > 0 else { return false }
        let dayHeight = Self.dayHeaderHeight(desktop: desktop)
        let capacity = Self.laneCapacity(height: rowSize.height, desktop: desktop)
        for span in spans where span.lane < capacity {
            let frame = CGRect(x: CGFloat(span.firstColumn) * width + 3,
                y: dayHeight + CGFloat(span.lane) * Self.laneHeight,
                width: max(0, CGFloat(span.lastColumn - span.firstColumn + 1) * width - 6),
                height: Self.laneHeight - 2)
            if frame.contains(point) { return true }
        }
        let column = min(6, max(0, Int(point.x / width)))
        for lane in availableLanes(column: column, capacity: capacity).prefix(items[column].count) {
            let frame = CGRect(x: CGFloat(column) * width + 4,
                y: dayHeight + CGFloat(lane) * Self.laneHeight,
                width: max(0, width - 8), height: Self.laneHeight - 2)
            if frame.contains(point) { return true }
        }
        return overflow(column: column, capacity: capacity) > 0
            && CGRect(x: CGFloat(column) * width + 5, y: rowSize.height - 18,
                width: max(0, width - 10), height: 18).contains(point)
    }
}


private struct CalendarWeekdayStrip: View {
    let desktop: Bool
    var centered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.calendar) private var calendar
    @ScaledMetric(relativeTo: .caption2) private var mobileHeight: CGFloat = 26

    var body: some View {
        var localizedCalendar = calendar
        localizedCalendar.locale = AppLanguage.current.locale
        let symbols = localizedCalendar.shortStandaloneWeekdaySymbols
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { index in
                let weekday = (calendar.firstWeekday - 1 + index) % 7
                Text(symbols[weekday]).font(centered ? .caption2.weight(.medium)
                    : .system(size: desktop ? 12 : 11, weight: .medium))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: centered ? .center : .trailing)
                    .padding(.trailing, centered ? 0 : desktop ? 10 : 7)
            }
        }
        .frame(height: centered ? mobileHeight : desktop ? 28 : 26)
        .background(colorScheme == .dark ? Color(.tertiarySystemBackground) : Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
    }
}

private struct CalendarWeekRow: View {
    let layout: CalendarMonthWeekLayout
    let selectedDate: Date?
    let today: Date
    let colors: [String: Color]
    let desktop: Bool
    let height: CGFloat
    var showsMonthBoundary = false
    let onDayTap: (Date) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.calendar) private var calendar

    var body: some View {
        GeometryReader { bounds in
            let width = bounds.size.width / 7
            let dayHeight = CalendarMonthWeekLayout.dayHeaderHeight(desktop: desktop)
            let laneHeight = CalendarMonthWeekLayout.laneHeight
            let capacity = CalendarMonthWeekLayout.laneCapacity(height: height, desktop: desktop)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(layout.days.indices, id: \.self) { column in
                        dayCell(layout.days[column], height: height)
                            .frame(width: width)
                            .overlay(alignment: .trailing) { Rectangle().fill(Color(.separator)).frame(width: 0.5) }
                    }
                }
                ForEach(layout.spans.indices, id: \.self) { index in
                    let span = layout.spans[index]
                    if span.lane < capacity {
                        spanView(span, days: layout.days, width: width, height: laneHeight - 2)
                            .offset(x: CGFloat(span.firstColumn) * width + 3,
                                    y: dayHeight + CGFloat(span.lane) * laneHeight)
                    }
                }
                ForEach(layout.days.indices, id: \.self) { column in
                    let lanes = layout.availableLanes(column: column, capacity: capacity)
                    let entries = Array(zip(lanes, layout.items[column]))
                    ForEach(entries.indices, id: \.self) { index in
                        itemView(entries[index].1, day: layout.days[column])
                            .frame(width: max(0, width - 8), height: laneHeight - 2)
                            .offset(x: CGFloat(column) * width + 4,
                                    y: dayHeight + CGFloat(entries[index].0) * laneHeight)
                    }
                    let overflow = layout.overflow(column: column, capacity: capacity)
                    if overflow > 0 {
                        Button { onDayTap(layout.days[column]) } label: {
                            Text("+\(overflow)").font(.system(size: desktop ? 11 : 10))
                                .foregroundStyle(.secondary).frame(width: max(0, width - 10), alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .offset(x: CGFloat(column) * width + 5, y: height - 18)
                    }
                }
            }
        }
        .frame(height: height)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
    }

    private func dayCell(_ day: Date, height: CGFloat) -> some View {
        let today = calendar.isDate(day, inSameDayAs: self.today)
        let selected = selectedDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        return Button { onDayTap(day) } label: {
            VStack(alignment: .trailing, spacing: 0) {
                HStack(spacing: 3) {
                    if showsMonthBoundary && calendar.component(.day, from: day) == 1 {
                        Text(day, format: .dateTime.month(.abbreviated).locale(AppLanguage.current.locale))
                            .font(.system(size: desktop ? 12 : 10)).foregroundStyle(.secondary)
                    }
                    Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: desktop ? 14 : 12, weight: today ? .semibold : .regular))
                    .foregroundStyle(today ? Color.white : Color.primary)
                    .frame(width: desktop ? 26 : 24, height: desktop ? 26 : 24)
                    .background { if today { Circle().fill(Color.red) } }
                    .padding(.trailing, desktop ? 6 : 3).padding(.top, 3)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .trailing).frame(height: height)
            .background(calendar.isDateInWeekend(day) ? Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.025) : Color.clear)
            .background(selected ? Color.accentColor.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if targetEnvironment(macCatalyst)
        // Pointer activation is owned by the table's single/double recognizers.
        // Keep the accessible Button action without an eager hosted click.
        .allowsHitTesting(false)
        #endif
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).year().month(.wide).day().locale(AppLanguage.current.locale)))
        .accessibilityIdentifier("calendar.day.\(calendar.component(.year, from: day))-\(calendar.component(.month, from: day))-\(calendar.component(.day, from: day))")
    }

    private func spanView(_ span: CalendarMonthWeekLayout.Span, days: [Date], width: CGFloat, height: CGFloat) -> some View {
        let color = colors[span.event.calendarID] ?? .accentColor
        let continuesBefore = span.event.startDate < days[span.firstColumn]
        let after = calendar.date(byAdding: .day, value: 1, to: days[span.lastColumn]) ?? days[span.lastColumn]
        let continuesAfter = span.event.endDate > after
        return Button { onDayTap(days[span.firstColumn]) } label: {
            HStack(spacing: 3) {
                if continuesBefore { Image(systemName: "chevron.left").font(.system(size: 8)) }
                Text(eventTitle(span.event.title)).lineLimit(1)
                Spacer(minLength: 0)
                if continuesAfter { Image(systemName: "chevron.right").font(.system(size: 8)) }
            }
            .font(.system(size: desktop ? 12 : 10, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .frame(width: max(0, CGFloat(span.lastColumn - span.firstColumn + 1) * width - 6), height: height)
            .background(color.opacity(colorScheme == .dark ? 0.25 : 0.15), in: RoundedRectangle(cornerRadius: 3))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(eventTitle(span.event.title))
    }

    private func itemView(_ item: CalendarMonthWeekLayout.Item, day: Date) -> some View {
        let color: Color = switch item { case .event(let event): colors[event.calendarID] ?? .accentColor; case .todo: .accentColor }
        return Button {
            onDayTap(day)
        } label: {
            HStack(spacing: 3) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(eventTitle(item.title)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if desktop {
                    Text(item.time, format: .dateTime.hour().minute().locale(AppLanguage.current.locale))
                        .foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                }
            }
            .font(.system(size: desktop ? 12 : 10)).foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(eventTitle(item.title)), \(item.time.formatted(.dateTime.hour().minute().locale(AppLanguage.current.locale)))")
    }

    private func eventTitle(_ title: String) -> String {
        title.isEmpty ? AppLanguage.localized("calendar.event.noTitle", defaultValue: "(No Title)", language: .current, comment: "Placeholder for a calendar event without a title.") : title
    }
}

struct CalendarWeekScrollTarget: Equatable {
    let date: Date
    let revision: Int
}

/// A bounded, calendar-arithmetic window. Its dates remain fixed until an
/// explicit distant navigation or a near-edge rebase, never a SwiftUI update.
struct CalendarWeekWindow {
    static let count = 521
    static let center = 260
    let calendar: Calendar
    let starts: [Date]
    let months: [Date]
    let end: Date

    init(centeredOn date: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        let week = CalendarMonthGeometry.weekStart(containing: date, calendar: calendar)
        let first = calendar.date(byAdding: .weekOfYear, value: -Self.center, to: week) ?? week
        starts = (0..<Self.count).map { calendar.date(byAdding: .weekOfYear, value: $0, to: first)! }
        months = starts.map { calendar.dateInterval(of: .month, for: $0)!.start }
        end = calendar.date(byAdding: .weekOfYear, value: Self.count, to: first)!
    }

    func index(containing date: Date) -> Int {
        let week = CalendarMonthGeometry.weekStart(containing: date, calendar: calendar)
        return (calendar.dateComponents([.day], from: starts[0], to: week).day ?? 0) / 7
    }

    /// Ignore a barely visible preceding row, including layout rounding at an
    /// exact week boundary, when choosing the month shown in the fixed header.
    static func headerIndex(offset: CGFloat, rowHeight: CGFloat) -> Int {
        min(count - 1, max(0, Int(floor(offset / rowHeight + 0.5))))
    }

    /// Half-open event intervals must not leak into the following week when
    /// their exclusive end is exactly the local week boundary.
    func occupiedWeekIndices(from start: Date, to end: Date) -> Range<Int> {
        guard start <= end, start < self.end, end > starts[0] else { return 0..<0 }
        if start == end {
            // Match the existing day-overlap predicate for EventKit instants:
            // a timed instant occupies its day, but midnight occupies neither.
            guard start > calendar.startOfDay(for: start) else { return 0..<0 }
            let index = index(containing: start)
            return index..<(index + 1)
        }
        let first = max(0, index(containing: start))
        let endWeek = index(containing: end)
        let endsAtBoundary = CalendarMonthGeometry.weekStart(containing: end, calendar: calendar) == end
        let upper = min(Self.count, endWeek + (endsAtBoundary ? 0 : 1))
        return first..<max(first, upper)
    }

    func days(at index: Int) -> [Date] {
        (0..<7).map { calendar.date(byAdding: .day, value: $0, to: starts[index])! }
    }
}

/// Immutable week buckets separate content changes from viewport/header changes.
/// Moving an occurrence invalidates both its old and new weeks, not the grid.
struct CalendarWeekContentIndex {
    struct EventKey: Equatable {
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let identifier: String
        let calendarID: String

        init(_ event: CalendarService.CalendarEventSummary) {
            title = event.title
            start = event.startDate
            end = event.endDate
            allDay = event.isAllDay
            identifier = event.identifier
            calendarID = event.calendarID
        }
    }

    let events: [[CalendarService.CalendarEventSummary]]
    let todos: [[CalendarMonthTodo]]
    private let keys: [[EventKey]]

    init(window: CalendarWeekWindow, events: [CalendarService.CalendarEventSummary], todos: [CalendarMonthTodo]) {
        var eventBuckets = Array(repeating: [CalendarService.CalendarEventSummary](), count: CalendarWeekWindow.count)
        var keyBuckets = Array(repeating: [EventKey](), count: CalendarWeekWindow.count)
        var todoBuckets = Array(repeating: [CalendarMonthTodo](), count: CalendarWeekWindow.count)
        for event in events {
            let key = EventKey(event)
            for index in window.occupiedWeekIndices(from: event.startDate, to: event.endDate) {
                eventBuckets[index].append(event)
                keyBuckets[index].append(key)
            }
        }
        for todo in todos where todo.date >= window.starts[0] && todo.date < window.end {
            todoBuckets[window.index(containing: todo.date)].append(todo)
        }
        self.events = eventBuckets
        self.todos = todoBuckets
        keys = keyBuckets
    }

    func changedWeeks(from previous: Self) -> [Int] {
        keys.indices.filter { keys[$0] != previous.keys[$0] || todos[$0] != previous.todos[$0] }
    }
}

/// One reusable native cell per week on both touch and wheel-driven surfaces.
/// Boundary weeks are shared rather than repeated as separate month grids.
struct CalendarContinuousGrid: View {
    let month: Date
    let target: CalendarWeekScrollTarget
    let selectedDate: Date?
    let calendar: Calendar
    let today: Date
    let events: [CalendarService.CalendarEventSummary]
    let todos: [Todo]
    let colors: [String: Color]
    let desktop: Bool
    let onVisibleMonth: (Date) -> Void
    let onDayTap: (Date) -> Void
    let onDayDoubleTap: (Date) -> Void
    var style: CalendarMonthDisplayStyle = .details
    var mobileMonthSections: Bool = false
    var onVisibleDates: ([Date]) -> Void = { _ in }
    var onStyleChange: (CalendarMonthDisplayStyle) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            CalendarWeekdayStrip(desktop: desktop, centered: mobileMonthSections)
            if mobileMonthSections {
                CalendarMobileMonthGrid(target: target, selectedDate: selectedDate,
                    calendar: calendar, today: today, events: events,
                    todos: monthTodos, colors: colors, style: style,
                    onVisibleMonth: onVisibleMonth, onVisibleDates: onVisibleDates,
                    onStyleChange: onStyleChange, onDayTap: onDayTap)
            } else {
                CalendarWeekScrollView(month: month, target: target, selectedDate: selectedDate,
                    calendar: calendar, today: today, events: events, todos: monthTodos,
                    colors: colors, desktop: desktop, onVisibleMonth: onVisibleMonth,
                    onDayTap: onDayTap, onDayDoubleTap: onDayDoubleTap)
            }
        }
        .environment(\.calendar, calendar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.monthGrid")
    }

    private var monthTodos: [CalendarMonthTodo] {
        todos.compactMap { todo in
            guard !todo.isCompleted, let date = todo.scheduleAnchor else { return nil }
            return CalendarMonthTodo(title: todo.title, date: date, eventID: todo.calendarEventID)
        }
    }
}

private struct CalendarWeekScrollView: UIViewRepresentable {
    let month: Date
    let target: CalendarWeekScrollTarget
    let selectedDate: Date?
    let calendar: Calendar
    let today: Date
    let events: [CalendarService.CalendarEventSummary]
    let todos: [CalendarMonthTodo]
    let colors: [String: Color]
    let desktop: Bool
    let onVisibleMonth: (Date) -> Void
    let onDayTap: (Date) -> Void
    let onDayDoubleTap: (Date) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeUIView(context: Context) -> WeekTableView {
        let view = WeekTableView(frame: .zero, style: .plain)
        view.separatorStyle = .none
        view.estimatedRowHeight = 0
        view.estimatedSectionHeaderHeight = 0
        view.estimatedSectionFooterHeight = 0
        view.sectionHeaderTopPadding = 0
        view.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemBackground
        }
        view.contentInsetAdjustmentBehavior = .never
        view.alwaysBounceVertical = true
        view.allowsSelection = false
        view.showsHorizontalScrollIndicator = false
        view.register(WeekCell.self, forCellReuseIdentifier: "week")
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "calendar.continuousWeeks"
        view.onResize = { [weak coordinator = context.coordinator] view in coordinator?.resize(view) }
        view.onLayout = { [weak coordinator = context.coordinator] view in coordinator?.finishLayout(view) }
        #if targetEnvironment(macCatalyst)
        let singleClick = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectDay(_:)))
        let doubleClick = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.createEvent(_:)))
        doubleClick.numberOfTapsRequired = 2
        singleClick.require(toFail: doubleClick)
        singleClick.delegate = context.coordinator
        doubleClick.delegate = context.coordinator
        view.addGestureRecognizer(singleClick)
        view.addGestureRecognizer(doubleClick)
        #endif
        return view
    }

    func updateUIView(_ view: WeekTableView, context: Context) {
        context.coordinator.update(owner: self, view: view)
    }

    static func dismantleUIView(_ view: WeekTableView, coordinator: Coordinator) {
        view.delegate = nil
        view.dataSource = nil
    }

    final class WeekTableView: UITableView {
        var onResize: ((WeekTableView) -> Void)?
        var onLayout: ((WeekTableView) -> Void)?
        private var viewportSize = CGSize.zero

        override func layoutSubviews() {
            if viewportSize != bounds.size {
                viewportSize = bounds.size
                onResize?(self)
            }
            super.layoutSubviews()
            onLayout?(self)
        }
    }

    final class WeekCell: UITableViewCell {
        var representedWeek: Date?
        var renderRevision = -1
        var contentRevision = -1
        override var canBecomeFocused: Bool { false }

        override func prepareForReuse() {
            super.prepareForReuse()
            // Retain UIKit's compatible content view while invalidating only
            // the data-cache identity for the next dequeued configuration.
            representedWeek = nil
            renderRevision = -1
            contentRevision = -1
        }

    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
        private typealias EventKey = CalendarWeekContentIndex.EventKey

        var owner: CalendarWeekScrollView
        var appliedTarget: CalendarWeekScrollTarget?
        private var window: CalendarWeekWindow
        private var eventKeys: [EventKey]
        private var content: CalendarWeekContentIndex
        private var weekRevisions = Array(repeating: 0, count: CalendarWeekWindow.count)
        private var layouts: [Int: CalendarMonthWeekLayout] = [:]
        private var rowHeight: CGFloat = 100
        private var renderRevision = 0
        private var lastReportedIndex: Int?
        private var lastReportedMonth: Date
        private var pendingMonth: Date?
        private var monthDeliveryScheduled = false
        private var localeIdentifier = AppLanguage.current.locale.identifier
        private var adjusting = false
        private var viewportPosition: CGFloat?
        private var pendingResizePosition: CGFloat?
        private var renderedSize = CGSize.zero

        init(owner: CalendarWeekScrollView) {
            self.owner = owner
            window = CalendarWeekWindow(centeredOn: owner.target.date, calendar: owner.calendar)
            eventKeys = owner.events.map { EventKey($0) }
            content = CalendarWeekContentIndex(window: window, events: owner.events, todos: owner.todos)
            lastReportedMonth = owner.month
            super.init()
        }

        #if targetEnvironment(macCatalyst)
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = gestureRecognizer.view as? UITableView else { return false }
            return backgroundDate(at: touch.location(in: view), in: view) != nil
        }

        @objc func selectDay(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view as? UITableView,
                  let date = backgroundDate(at: gesture.location(in: view), in: view) else { return }
            owner.onDayTap(date)
        }

        @objc func createEvent(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view as? UITableView,
                  let date = backgroundDate(at: gesture.location(in: view), in: view) else { return }
            owner.onDayDoubleTap(date)
        }

        private func backgroundDate(at point: CGPoint, in view: UITableView) -> Date? {
            guard view.bounds.contains(point), let path = view.indexPathForRow(at: point),
                  let layout = layouts[path.row], view.bounds.width > 0 else { return nil }
            let frame = view.rectForRow(at: path)
            let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
            guard !layout.containsEntry(at: local, rowSize: frame.size, desktop: owner.desktop) else { return nil }
            let column = min(6, max(0, Int(local.x / (frame.width / 7))))
            return layout.days[column]
        }
        #endif

        func update(owner next: CalendarWeekScrollView, view: UITableView) {
            let nextKeys = next.events.map { EventKey($0) }
            let dataChanged = eventKeys != nextKeys || owner.todos != next.todos
            let presentationChanged = owner.selectedDate != next.selectedDate
                || owner.colors != next.colors || owner.desktop != next.desktop
                || owner.today != next.today
                || localeIdentifier != AppLanguage.current.locale.identifier
            owner = next
            eventKeys = nextKeys
            localeIdentifier = AppLanguage.current.locale.identifier
            if window.calendar != next.calendar {
                let position = viewportPosition ?? view.contentOffset.y / rowHeight
                let index = min(CalendarWeekWindow.count - 1, max(0, Int(floor(position))))
                let anchor = window.starts[index]
                window = CalendarWeekWindow(centeredOn: anchor, calendar: next.calendar)
                indexContent(resetWindow: true)
                renderRevision += 1
                pendingResizePosition = CGFloat(CalendarWeekWindow.center) + position - CGFloat(index)
                lastReportedIndex = nil
                adjusting = true
                view.reloadData()
                view.setNeedsLayout()
            }
            let changedWeeks = dataChanged ? indexContent() : []
            if presentationChanged { renderRevision += 1 }
            resize(view)
            if appliedTarget != owner.target { view.setNeedsLayout() }
            let paths = presentationChanged
                ? (view.indexPathsForVisibleRows ?? [])
                : changedWeeks.map { IndexPath(row: $0, section: 0) }
            if !paths.isEmpty { view.reconfigureRows(at: paths) }
        }

        /// Build the week lookup only when source content or the bounded date
        /// window changes, not when scrolling or reporting a visible month.
        @discardableResult private func indexContent(resetWindow: Bool = false) -> [Int] {
            let next = CalendarWeekContentIndex(window: window, events: owner.events, todos: owner.todos)
            let changed = resetWindow ? Array(window.starts.indices) : next.changedWeeks(from: content)
            for index in changed {
                layouts.removeValue(forKey: index)
                weekRevisions[index] += 1
            }
            content = next
            return changed
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            CalendarWeekWindow.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "week", for: path)
            cell.backgroundColor = .clear
            cell.selectionStyle = .none
            configure(cell, at: path)
            return cell
        }

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt path: IndexPath) {
            configure(cell, at: path)
        }


        func configure(_ cell: UITableViewCell, at path: IndexPath) {
            guard let cell = cell as? WeekCell else { return }
            let start = window.starts[path.row]
            guard cell.representedWeek != start || cell.renderRevision != renderRevision
                || cell.contentRevision != weekRevisions[path.row] else { return }
            let layout: CalendarMonthWeekLayout
            if let cached = layouts[path.row] {
                layout = cached
            } else {
                layout = CalendarMonthWeekLayout(days: window.days(at: path.row),
                    events: content.events[path.row], todos: content.todos[path.row], calendar: window.calendar)
                layouts[path.row] = layout
            }
            cell.representedWeek = start
            cell.renderRevision = renderRevision
            cell.contentRevision = weekRevisions[path.row]
            cell.contentConfiguration = UIHostingConfiguration {
                CalendarWeekRow(layout: layout, selectedDate: owner.selectedDate, today: owner.today,
                    colors: owner.colors, desktop: owner.desktop, height: rowHeight,
                    showsMonthBoundary: true, onDayTap: owner.onDayTap)
                    .environment(\.calendar, window.calendar)
                    .environment(\.locale, AppLanguage.current.locale)
                    .tint(AppTheme.accent)
            }.margins(.all, 0)
        }

        func resize(_ view: UITableView) {
            guard view.bounds.width > 0, view.bounds.height > 0,
                  renderedSize != view.bounds.size else { return }
            renderedSize = view.bounds.size
            let height = max(owner.desktop ? 96 : 86, ceil(view.bounds.height / 6))
            let position = viewportPosition ?? view.contentOffset.y / rowHeight
            pendingResizePosition = position
            adjusting = true
            rowHeight = height
            renderRevision += 1
            view.rowHeight = height
            view.reloadData()
            view.setNeedsLayout()
        }

        func finishLayout(_ view: UITableView) {
            if let position = pendingResizePosition {
                pendingResizePosition = nil
                view.setContentOffset(CGPoint(x: 0, y: position * rowHeight), animated: false)
                viewportPosition = position
                adjusting = false
            }
            applyTarget(view)
        }

        func applyTarget(_ view: UITableView) {
            guard view.bounds.width > 0, view.bounds.height > 0, appliedTarget != owner.target else { return }
            var index = window.index(containing: owner.target.date)
            if !(0..<CalendarWeekWindow.count).contains(index) {
                window = CalendarWeekWindow(centeredOn: owner.target.date, calendar: window.calendar)
                index = CalendarWeekWindow.center
                indexContent(resetWindow: true)
                renderRevision += 1
                view.reloadData()
            }
            appliedTarget = owner.target
            pendingMonth = nil
            lastReportedIndex = index
            lastReportedMonth = owner.month
            adjusting = true
            view.setContentOffset(CGPoint(x: 0, y: CGFloat(index) * rowHeight), animated: false)
            viewportPosition = CGFloat(index)
            adjusting = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !adjusting, appliedTarget != nil, let view = scrollView as? UITableView,
                  view.bounds.size == renderedSize else { return }
            viewportPosition = view.contentOffset.y / rowHeight
            var index = CalendarWeekWindow.headerIndex(offset: view.contentOffset.y, rowHeight: rowHeight)
            guard index != lastReportedIndex else { return }
            // Rebase years beyond the viewport and retain the fractional week.
            if index < 52 || index > CalendarWeekWindow.count - 53 {
                let shift = index - CalendarWeekWindow.center
                window = CalendarWeekWindow(centeredOn: window.starts[index], calendar: window.calendar)
                indexContent(resetWindow: true)
                renderRevision += 1
                adjusting = true
                view.reloadData()
                view.contentOffset.y -= CGFloat(shift) * rowHeight
                viewportPosition = view.contentOffset.y / rowHeight
                adjusting = false
                index = CalendarWeekWindow.center
            }
            lastReportedIndex = index
            let month = window.months[index]
            guard month != lastReportedMonth else { return }
            lastReportedMonth = month
            pendingMonth = month
            guard !monthDeliveryScheduled else { return }
            monthDeliveryScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.monthDeliveryScheduled = false
                guard let month = self.pendingMonth else { return }
                self.pendingMonth = nil
                self.owner.onVisibleMonth(month)
            }
        }

    }
}

struct CalendarMiniMonth: View {
    let month: Date
    let selectedDate: Date?
    let onSelect: (Date) -> Void
    @Environment(\.calendar) private var calendar

    private var dayCellSize: CGFloat {
        #if targetEnvironment(macCatalyst)
        23
        #else
        44
        #endif
    }

    var body: some View {
        let geometry = CalendarMonthGeometry(month: month, calendar: calendar)
        let weekdaySymbols: [String] = {
            var localizedCalendar = calendar
            localizedCalendar.locale = AppLanguage.current.locale
            return localizedCalendar.veryShortStandaloneWeekdaySymbols
        }()
        VStack(spacing: 5) {
            Text(month.formatted(.dateTime.year().month(.wide).locale(AppLanguage.current.locale)))
                .font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    Text(weekdaySymbols[(calendar.firstWeekday - 1 + index) % 7])
                        .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            ForEach(geometry.weeks.indices, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(geometry.weeks[row], id: \.self) { day in
                        let today = calendar.isDateInToday(day)
                        let selected = selectedDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false
                        Button { onSelect(day) } label: {
                            Text("\(calendar.component(.day, from: day))")
                                .font(.caption2.weight(today || selected ? .semibold : .regular))
                                .foregroundStyle(today ? Color.white : calendar.isDate(day, equalTo: month, toGranularity: .month) ? Color.primary : Color.secondary.opacity(0.55))
                                .frame(width: dayCellSize, height: dayCellSize)
                                .background { if today { Circle().fill(Color.red) } else if selected { Circle().fill(Color.accentColor.opacity(0.15)) } }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(day.formatted(.dateTime.year().month().day().locale(AppLanguage.current.locale)))
                    }
                }
            }
        }
        .accessibilityIdentifier("calendar.miniMonth")
    }
}
