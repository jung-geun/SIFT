import SwiftUI
import UIKit

/// A month owns only its dates. Boundary weeks therefore become two partial
/// rows, each aligned to the calendar's first weekday, never repeated dates.
struct CalendarMobileMonthGeometry {
    struct Week {
        let days: [Date]
        let firstColumn: Int
    }
    let month: Date
    let weeks: [Week]
    let end: Date

    init(month: Date, calendar: Calendar) {
        let interval = calendar.dateInterval(of: .month, for: month)!
        self.month = interval.start
        end = interval.end
        var weeks: [Week] = []
        var day = interval.start
        while day < interval.end {
            let column = (calendar.component(.weekday, from: day) - calendar.firstWeekday + 7) % 7
            var days: [Date] = []
            for _ in column..<7 where day < interval.end {
                days.append(day)
                day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: day)!)
            }
            weeks.append(Week(days: days, firstColumn: column))
        }
        self.weeks = weeks
    }
}

struct CalendarMobileMonthWindow {
    static let radius = 30
    static let headerHeight: CGFloat = 40
    struct Anchor: Equatable {
        let date: Date
        let fraction: CGFloat
        let isHeader: Bool
    }
    let calendar: Calendar
    let months: [CalendarMobileMonthGeometry]
    let rowStarts: [Int]
    let rowCount: Int
    var start: Date { months[0].month }
    var end: Date { months[months.count - 1].end }

    init(centeredOn date: Date, calendar: Calendar) {
        self.calendar = calendar
        let month = calendar.dateInterval(of: .month, for: date)!.start
        months = (-Self.radius...Self.radius).map {
            CalendarMobileMonthGeometry(month: calendar.date(byAdding: .month, value: $0, to: month)!, calendar: calendar)
        }
        var starts: [Int] = []
        var count = 0
        for month in months { starts.append(count); count += month.weeks.count }
        rowStarts = starts
        rowCount = count
    }

    func section(containing date: Date) -> Int? {
        // Calendar month ordinals also work for leap months in non-Gregorian calendars.
        months.firstIndex { date >= $0.month && date < $0.end }
    }

    func path(containing date: Date) -> IndexPath? {
        guard let section = section(containing: date),
              let row = months[section].weeks.firstIndex(where: { week in
                  let end = calendar.dateInterval(of: .day, for: week.days.last!)!.end
                  return date >= week.days[0] && date < end
              }) else { return nil }
        return IndexPath(row: row + 1, section: section)
    }

    func sectionOffset(_ section: Int, rowHeight: CGFloat) -> CGFloat {
        CGFloat(section) * Self.headerHeight + CGFloat(rowStarts[section]) * rowHeight
    }

    func offset(for anchor: Anchor, rowHeight: CGFloat) -> CGFloat? {
        guard let path = path(containing: anchor.date) else { return nil }
        let start = sectionOffset(path.section, rowHeight: rowHeight)
        if anchor.isHeader { return start + anchor.fraction * Self.headerHeight }
        return start + Self.headerHeight + (CGFloat(path.row - 1) + anchor.fraction) * rowHeight
    }

    func navigationOffset(to date: Date, rowHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat? {
        guard let path = path(containing: date) else { return nil }
        let monthStart = sectionOffset(path.section, rowHeight: rowHeight)
        let rowStart = monthStart + Self.headerHeight + CGFloat(path.row - 1) * rowHeight
        // Keep the month origin when it fits, but never hide the requested date
        // below the viewport (or its number above it at accessibility sizes).
        return min(rowStart, max(monthStart, rowStart + rowHeight - viewportHeight))
    }

    func anchor(at offset: CGFloat, rowHeight: CGFloat) -> Anchor {
        let offset = max(0, offset)
        let section = months.indices.last(where: { sectionOffset($0, rowHeight: rowHeight) <= offset }) ?? 0
        let local = offset - sectionOffset(section, rowHeight: rowHeight)
        if local < Self.headerHeight {
            return Anchor(date: months[section].month, fraction: local / Self.headerHeight, isHeader: true)
        }
        let position = (local - Self.headerHeight) / rowHeight
        let row = min(months[section].weeks.count - 1, max(0, Int(floor(position))))
        return Anchor(date: months[section].weeks[row].days[0], fraction: min(1, max(0, position - CGFloat(row))), isHeader: false)
    }
}

/// Shares the existing overlap, recurrence and linked-task rules with desktop,
/// but indexes layouts by partial month week rather than whole calendar week.
struct CalendarMobileMonthContentIndex {
    let events: [[CalendarService.CalendarEventSummary]]
    let todos: [[CalendarMonthTodo]]
    private let keys: [[CalendarWeekContentIndex.EventKey]]

    init(window: CalendarMobileMonthWindow, events: [CalendarService.CalendarEventSummary], todos: [CalendarMonthTodo]) {
        var eventBuckets = Array(repeating: [CalendarService.CalendarEventSummary](), count: window.rowCount)
        var keyBuckets = Array(repeating: [CalendarWeekContentIndex.EventKey](), count: window.rowCount)
        var todoBuckets = Array(repeating: [CalendarMonthTodo](), count: window.rowCount)
        for event in events where event.startDate <= event.endDate && event.startDate < window.end && event.endDate > window.start {
            let firstDate = max(window.start, event.startDate)
            let lastDate: Date
            if event.endDate == window.calendar.startOfDay(for: event.endDate) {
                lastDate = window.calendar.date(byAdding: .day, value: -1, to: event.endDate)!
            } else { lastDate = event.endDate }
            guard let first = window.path(containing: firstDate),
                  let last = window.path(containing: min(lastDate, window.calendar.date(byAdding: .day, value: -1, to: window.end)!)) else { continue }
            let lower = window.rowStarts[first.section] + first.row - 1
            let upper = window.rowStarts[last.section] + last.row - 1
            guard lower <= upper else { continue }
            for row in lower...upper {
                eventBuckets[row].append(event)
                keyBuckets[row].append(CalendarWeekContentIndex.EventKey(event))
            }
        }
        for todo in todos {
            guard let path = window.path(containing: todo.date) else { continue }
            todoBuckets[window.rowStarts[path.section] + path.row - 1].append(todo)
        }
        self.events = eventBuckets
        self.todos = todoBuckets
        keys = keyBuckets
    }

    func changedRows(from previous: Self) -> [Int] {
        keys.indices.filter { keys[$0] != previous.keys[$0] || todos[$0] != previous.todos[$0] }
    }
}

private struct CalendarMobileMonthRow: View {
    let week: CalendarMobileMonthGeometry.Week
    let layout: CalendarMonthWeekLayout
    let calendar: Calendar
    let today: Date
    let selectedDate: Date?
    let colors: [String: Color]
    let style: CalendarMonthDisplayStyle
    let height: CGFloat
    let onDayTap: (Date) -> Void
    @ScaledMetric(relativeTo: .body) private var numberSize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 30
    @ScaledMetric(relativeTo: .caption) private var eventSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var laneHeight: CGFloat = 18

    private var detailed: Bool { style == .details }
    private var dayHeight: CGFloat { badgeSize + 4 }
    private var capacity: Int { max(1, Int((height - dayHeight - 18) / laneHeight)) }

    var body: some View {
        GeometryReader { bounds in
            let width = bounds.size.width / 7
            ZStack(alignment: .topLeading) {
                ForEach(week.days.indices, id: \.self) { index in
                    dayCell(index: index)
                        .frame(width: width, height: height)
                        .offset(x: CGFloat(index + week.firstColumn) * width)
                }
                if detailed {
                    ForEach(layout.spans.indices, id: \.self) { index in
                        let span = layout.spans[index]
                        if span.lane < capacity {
                            Text(span.event.title)
                                .font(.system(size: eventSize, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 3)
                                .frame(width: max(0, CGFloat(span.lastColumn - span.firstColumn + 1) * width - 4), height: laneHeight - 2, alignment: .leading)
                                .background((colors[span.event.calendarID] ?? .accentColor).opacity(0.22), in: RoundedRectangle(cornerRadius: 3))
                                .offset(x: CGFloat(span.firstColumn + week.firstColumn) * width + 2, y: dayHeight + CGFloat(span.lane) * laneHeight)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    ForEach(week.days.indices, id: \.self) { column in
                        let lanes = layout.availableLanes(column: column, capacity: capacity)
                        let entries = Array(zip(lanes, layout.items[column]))
                        ForEach(entries.indices, id: \.self) { index in
                            let item = entries[index].1
                            HStack(spacing: 2) {
                                Capsule().fill(color(for: item)).frame(width: 2)
                                Text(item.title).font(.system(size: eventSize)).lineLimit(1)
                            }
                            .frame(width: max(0, width - 6), height: laneHeight - 2, alignment: .leading)
                            .offset(x: CGFloat(column + week.firstColumn) * width + 3, y: dayHeight + CGFloat(entries[index].0) * laneHeight)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                        let overflow = layout.overflow(column: column, capacity: capacity)
                        if overflow > 0 {
                            Text("+\(overflow)").font(.system(size: 10)).foregroundStyle(.secondary)
                                .offset(x: CGFloat(column + week.firstColumn) * width + 4, y: height - 16)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .frame(height: height)
        // Keep cross-cell multitouch in the native table, not separate hosting views.
        .allowsHitTesting(false)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
    }

    private func dayCell(index: Int) -> some View {
        let day = week.days[index]
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let selected = selectedDate.map { calendar.isDate(day, inSameDayAs: $0) } ?? false
        let spans = layout.spans.filter { $0.firstColumn <= index && $0.lastColumn >= index }
        let itemColors = spans.map { colors[$0.event.calendarID] ?? .accentColor } + layout.items[index].map { color(for: $0) }
        let titles = spans.map { $0.event.title } + layout.items[index].map(\.title)
        return VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: numberSize, weight: isToday || selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color(.systemBackground) : isToday ? Color.white : Color.primary)
                    .frame(width: badgeSize, height: badgeSize)
                    .background {
                        if selected { Circle().fill(Color(.label)) }
                        else if isToday { Circle().fill(Color.red) }
                    }
                if !detailed {
                    if style == .stacked {
                        let count = CGFloat(max(1, itemColors.count))
                        let spacing = min(3, (height - dayHeight - 5) / (count * 2))
                        let indicatorHeight = min(3, (height - dayHeight - 5 - spacing * (count - 1)) / count)
                        VStack(spacing: spacing) {
                            ForEach(itemColors.indices, id: \.self) { index in
                                Capsule().fill(itemColors[index]).frame(height: indicatorHeight)
                            }
                        }
                        .padding(.horizontal, 8)
                    } else if let color = itemColors.first {
                        Circle().fill(color).frame(width: 5, height: 5)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onDayTap(day) }
        .accessibilityLabel(day.formatted(Date.FormatStyle(date: .complete, time: .omitted,
            locale: AppLanguage.current.locale, calendar: calendar, timeZone: calendar.timeZone)))
        .accessibilityValue(titles.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("calendar.day.\(calendar.component(.year, from: day))-\(calendar.component(.month, from: day))-\(calendar.component(.day, from: day))")
    }

    private func color(for item: CalendarMonthWeekLayout.Item) -> Color {
        switch item {
        case .event(let event): colors[event.calendarID] ?? .accentColor
        case .todo: .accentColor
        }
    }
}

struct CalendarMobileMonthGrid: UIViewRepresentable {
    let target: CalendarWeekScrollTarget
    let selectedDate: Date?
    let calendar: Calendar
    let today: Date
    let events: [CalendarService.CalendarEventSummary]
    let todos: [CalendarMonthTodo]
    let colors: [String: Color]
    let style: CalendarMonthDisplayStyle
    let onVisibleMonth: (Date) -> Void
    let onVisibleDates: ([Date]) -> Void
    let onStyleChange: (CalendarMonthDisplayStyle) -> Void
    let onDayTap: (Date) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeUIView(context: Context) -> MonthTableView {
        let view = MonthTableView(frame: .zero, style: .plain)
        view.separatorStyle = .none
        view.backgroundColor = .systemBackground
        view.estimatedRowHeight = 0
        view.estimatedSectionHeaderHeight = 0
        view.estimatedSectionFooterHeight = 0
        view.sectionHeaderTopPadding = 0
        view.contentInsetAdjustmentBehavior = .never
        view.alwaysBounceVertical = true
        view.allowsSelection = false
        view.register(MonthCell.self, forCellReuseIdentifier: "monthWeek")
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "calendar.continuousWeeks"
        view.onResize = { [weak coordinator = context.coordinator] in coordinator?.resize($0) }
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.finishLayout($0) }
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: MonthTableView, _: UITraitCollection) in
            view.onResize?(view)
        }
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.cancelsTouchesInView = true
        view.addGestureRecognizer(pinch)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: pinch)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: MonthTableView, context: Context) { context.coordinator.update(self, view: view) }
    static func dismantleUIView(_ view: MonthTableView, coordinator: Coordinator) {
        view.delegate = nil
        view.dataSource = nil
        view.onResize = nil
        view.onLayout = nil
    }

    final class MonthTableView: UITableView {
        var onResize: ((MonthTableView) -> Void)?
        var onLayout: ((MonthTableView) -> Void)?
        private var viewport = CGSize.zero
        override func layoutSubviews() {
            if viewport != bounds.size { viewport = bounds.size; onResize?(self) }
            super.layoutSubviews()
            onLayout?(self)
        }
    }

    final class MonthCell: UITableViewCell {
        var representedDate: Date?
        var revision = -1
        var contentRevision = -1
        override func prepareForReuse() {
            super.prepareForReuse()
            representedDate = nil
            revision = -1
            contentRevision = -1
        }
    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        var owner: CalendarMobileMonthGrid
        private var window: CalendarMobileMonthWindow
        private var content: CalendarMobileMonthContentIndex
        private var keys: [CalendarWeekContentIndex.EventKey]
        private var layouts: [Int: CalendarMonthWeekLayout] = [:]
        private var contentRevisions: [Int]
        private var revision = 0
        private var rowHeight: CGFloat = 118
        private var renderedSize = CGSize.zero
        private var appliedTarget: CalendarWeekScrollTarget?
        private var position: CalendarMobileMonthWindow.Anchor?
        private var pendingAnchor: CalendarMobileMonthWindow.Anchor?
        private var adjusting = false
        private var reportingScheduled = false
        private var lastMonth: Date?
        private var lastDates: [Date] = []
        private var localeIdentifier = AppLanguage.current.locale.identifier
        private var pinchStyle: CalendarMonthDisplayStyle?

        init(owner: CalendarMobileMonthGrid) {
            self.owner = owner
            let window = CalendarMobileMonthWindow(centeredOn: owner.target.date, calendar: owner.calendar)
            self.window = window
            content = CalendarMobileMonthContentIndex(window: window, events: owner.events, todos: owner.todos)
            contentRevisions = Array(repeating: 0, count: window.rowCount)
            keys = owner.events.map { CalendarWeekContentIndex.EventKey($0) }
            super.init()
        }

        func update(_ next: CalendarMobileMonthGrid, view: UITableView) {
            let nextKeys = next.events.map { CalendarWeekContentIndex.EventKey($0) }
            let calendarChanged = owner.calendar != next.calendar
            let dataChanged = nextKeys != keys || owner.todos != next.todos
            let styleChanged = owner.style != next.style
            let presentationChanged = owner.selectedDate != next.selectedDate || owner.colors != next.colors
                || owner.today != next.today || localeIdentifier != AppLanguage.current.locale.identifier
            owner = next
            keys = nextKeys
            localeIdentifier = AppLanguage.current.locale.identifier
            if calendarChanged {
                let anchor = position ?? window.anchor(at: view.contentOffset.y, rowHeight: rowHeight)
                window = CalendarMobileMonthWindow(centeredOn: anchor.date, calendar: next.calendar)
                resetContent()
                pendingAnchor = anchor
            } else if dataChanged {
                let nextContent = CalendarMobileMonthContentIndex(window: window, events: next.events, todos: next.todos)
                for row in nextContent.changedRows(from: content) {
                    layouts.removeValue(forKey: row)
                    contentRevisions[row] += 1
                }
                content = nextContent
            }
            if styleChanged || calendarChanged {
                pendingAnchor = pendingAnchor ?? position ?? window.anchor(at: view.contentOffset.y, rowHeight: rowHeight)
                rowHeight = height(for: view)
                revision += 1
                adjusting = true
                view.reloadData()
                view.setNeedsLayout()
            } else if presentationChanged || dataChanged {
                if presentationChanged { revision += 1 }
                for path in view.indexPathsForVisibleRows ?? [] {
                    if let cell = view.cellForRow(at: path) { configure(cell, at: path) }
                }
            }
            resize(view)
            if appliedTarget != next.target { view.setNeedsLayout() }
        }

        private func resetContent() {
            content = CalendarMobileMonthContentIndex(window: window, events: owner.events, todos: owner.todos)
            contentRevisions = Array(repeating: 0, count: window.rowCount)
            layouts.removeAll(keepingCapacity: true)
            revision += 1
        }

        private func height(for view: UITableView) -> CGFloat {
            let base: CGFloat
            switch owner.style {
            case .compact: base = 69
            case .list: base = 51
            case .stacked: base = 89
            case .details: base = 119
            }
            return ceil(UIFontMetrics.default.scaledValue(for: base, compatibleWith: view.traitCollection))
        }

        func numberOfSections(in tableView: UITableView) -> Int { window.months.count }
        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { window.months[section].weeks.count + 1 }
        func tableView(_ tableView: UITableView, heightForRowAt path: IndexPath) -> CGFloat {
            path.row == 0 ? CalendarMobileMonthWindow.headerHeight : rowHeight
        }
        func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { .leastNormalMagnitude }
        func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { .leastNormalMagnitude }
        func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "monthWeek", for: path)
            cell.backgroundColor = .clear
            cell.selectionStyle = .none
            configure(cell, at: path)
            return cell
        }
        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt path: IndexPath) { configure(cell, at: path) }

        private func configure(_ candidate: UITableViewCell, at path: IndexPath) {
            guard let cell = candidate as? MonthCell else { return }
            let month = window.months[path.section]
            if path.row == 0 {
                guard cell.representedDate != month.month || cell.revision != revision || cell.contentRevision != -2 else { return }
                cell.representedDate = month.month
                cell.revision = revision
                cell.contentRevision = -2
                cell.contentConfiguration = UIHostingConfiguration {
                    Text(month.month.formatted(Date.FormatStyle(date: .omitted, time: .omitted,
                        locale: AppLanguage.current.locale, calendar: window.calendar,
                        timeZone: window.calendar.timeZone).month(.wide)))
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("calendar.visibleMonth")
                }.margins(.all, 0)
                return
            }
            let week = month.weeks[path.row - 1]
            let index = window.rowStarts[path.section] + path.row - 1
            guard cell.representedDate != week.days[0] || cell.revision != revision || cell.contentRevision != contentRevisions[index] else { return }
            let layout: CalendarMonthWeekLayout
            if let cached = layouts[index] { layout = cached }
            else {
                layout = CalendarMonthWeekLayout(days: week.days, events: content.events[index], todos: content.todos[index], calendar: window.calendar)
                layouts[index] = layout
            }
            cell.representedDate = week.days[0]
            cell.revision = revision
            cell.contentRevision = contentRevisions[index]
            cell.contentConfiguration = UIHostingConfiguration {
                CalendarMobileMonthRow(week: week, layout: layout, calendar: window.calendar,
                    today: owner.today, selectedDate: owner.selectedDate, colors: owner.colors,
                    style: owner.style, height: rowHeight, onDayTap: owner.onDayTap)
                    .environment(\.calendar, window.calendar)
                    .environment(\.locale, AppLanguage.current.locale)
                    .tint(AppTheme.accent)
            }.margins(.all, 0)
        }

        func resize(_ view: UITableView) {
            guard view.bounds.width > 0, view.bounds.height > 0,
                  renderedSize != view.bounds.size || rowHeight != height(for: view) else { return }
            pendingAnchor = pendingAnchor ?? position ?? window.anchor(at: view.contentOffset.y, rowHeight: rowHeight)
            renderedSize = view.bounds.size
            rowHeight = height(for: view)
            revision += 1
            adjusting = true
            view.reloadData()
            view.setNeedsLayout()
        }

        func finishLayout(_ view: UITableView) {
            if let anchor = pendingAnchor {
                pendingAnchor = nil
                if let offset = window.offset(for: anchor, rowHeight: rowHeight) {
                    view.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    position = anchor
                }
                adjusting = false
            }
            if view.bounds.width > 0, view.bounds.height > 0, appliedTarget != owner.target {
                if window.section(containing: owner.target.date) == nil {
                    window = CalendarMobileMonthWindow(centeredOn: owner.target.date, calendar: owner.calendar)
                    resetContent()
                    view.reloadData()
                }
                if let offset = window.navigationOffset(to: owner.target.date,
                    rowHeight: rowHeight, viewportHeight: view.bounds.height) {
                    appliedTarget = owner.target
                    adjusting = true
                    view.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    position = window.anchor(at: offset, rowHeight: rowHeight)
                    adjusting = false
                }
            }
            scheduleReport(view)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !adjusting, appliedTarget != nil, let view = scrollView as? UITableView,
                  renderedSize == view.bounds.size else { return }
            let anchor = window.anchor(at: view.contentOffset.y, rowHeight: rowHeight)
            position = anchor
            if let section = window.section(containing: anchor.date), section < 6 || section > window.months.count - 7 {
                window = CalendarMobileMonthWindow(centeredOn: anchor.date, calendar: owner.calendar)
                resetContent()
                pendingAnchor = anchor
                adjusting = true
                view.reloadData()
                view.setNeedsLayout()
            }
            scheduleReport(view)
        }

        private func scheduleReport(_ view: UITableView) {
            guard !reportingScheduled, appliedTarget != nil, !adjusting else { return }
            reportingScheduled = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                self.reportingScheduled = false
                guard let view, !self.adjusting else { return }
                let viewport = CGRect(origin: view.contentOffset, size: view.bounds.size)
                let paths = (view.indexPathsForVisibleRows ?? []).sorted { $0.section == $1.section ? $0.row < $1.row : $0.section < $1.section }
                let visible = paths.filter { $0.row > 0 && view.rectForRow(at: $0).intersection(viewport).height > 0.5 }
                let dates = visible.flatMap { self.window.months[$0.section].weeks[$0.row - 1].days }
                if let first = dates.first, let section = self.window.section(containing: first) {
                    let month = self.window.months[section].month
                    if self.lastMonth != month { self.lastMonth = month; self.owner.onVisibleMonth(month) }
                }
                if dates != self.lastDates { self.lastDates = dates; self.owner.onVisibleDates(dates) }
            }
        }


        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let table = recognizer.view as? UITableView else { return }
            let point = recognizer.location(in: table)
            guard let path = table.indexPathForRow(at: point), path.row > 0 else { return }
            let week = window.months[path.section].weeks[path.row - 1]
            let column = Int(point.x / (table.bounds.width / 7)) - week.firstColumn
            guard week.days.indices.contains(column) else { return }
            owner.onDayTap(week.days[column])
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard owner.style != .list else { return }
            if recognizer.state == .began { pinchStyle = owner.style }
            guard recognizer.state == .changed, let initial = pinchStyle else { return }
            let change = recognizer.scale > 1.18 ? 1 : recognizer.scale < 0.85 ? -1 : 0
            guard change != 0 else { return }
            let next: CalendarMonthDisplayStyle
            switch initial {
            case .compact: next = change > 0 ? .stacked : .compact
            case .stacked: next = change > 0 ? .details : .compact
            case .details: next = change > 0 ? .details : .stacked
            case .list: return
            }
            pinchStyle = next
            recognizer.scale = 1
            if next != owner.style { owner.onStyleChange(next) }
        }
    }
}
