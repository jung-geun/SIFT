import SwiftUI
#if targetEnvironment(macCatalyst)
import UIKit
#endif

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
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
        return event.startDate < end && event.endDate > start
    }
}

struct CalendarMonthTodo {
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
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: event.startDate)) ?? event.startDate
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
}

struct CalendarMonthGrid: View {
    let month: Date
    let selectedDate: Date?
    let events: [CalendarService.CalendarEventSummary]
    let todos: [Todo]
    let colors: [String: Color]
    let desktop: Bool
    let onDayTap: (Date) -> Void
    @Environment(\.colorScheme) private var colorScheme
    private let calendar = Calendar.current

    var body: some View {
        let geometry = CalendarMonthGeometry(month: month)
        let visibleTodos = todos.compactMap { todo -> CalendarMonthTodo? in
            guard !todo.isCompleted, let date = todo.scheduleAnchor,
                  date >= geometry.interval.start, date < geometry.interval.end else { return nil }
            return CalendarMonthTodo(title: todo.title, date: date, eventID: todo.calendarEventID)
        }
        let weeks = geometry.weeks.map { CalendarMonthWeekLayout(days: $0, events: events, todos: visibleTodos) }
        VStack(spacing: 0) {
            CalendarWeekdayStrip(desktop: desktop)
            GeometryReader { bounds in
                let rowHeight = max(desktop ? 96 : 86, bounds.size.height / CGFloat(weeks.count))
                if desktop && bounds.size.height >= rowHeight * CGFloat(weeks.count) - 1 {
                    weekRows(weeks, height: rowHeight)
                } else {
                    ScrollView { weekRows(weeks, height: rowHeight) }
                        .scrollBounceBehavior(.always)
                }
            }
        }
        .background(colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemBackground))
        .accessibilityIdentifier("calendar.monthGrid")
    }


    private func weekRows(_ weeks: [CalendarMonthWeekLayout], height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(weeks.indices, id: \.self) { index in
                CalendarWeekRow(layout: weeks[index], month: month, selectedDate: selectedDate,
                                colors: colors, desktop: desktop, height: height, onDayTap: onDayTap)
            }
        }
    }

}

private struct CalendarWeekdayStrip: View {
    let desktop: Bool
    @Environment(\.colorScheme) private var colorScheme
    private let calendar = Calendar.current

    var body: some View {
        var localizedCalendar = calendar
        localizedCalendar.locale = AppLanguage.current.locale
        let symbols = localizedCalendar.shortStandaloneWeekdaySymbols
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { index in
                let weekday = (calendar.firstWeekday - 1 + index) % 7
                Text(symbols[weekday]).font(.system(size: desktop ? 12 : 11, weight: .medium))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, desktop ? 10 : 7)
            }
        }
        .frame(height: desktop ? 28 : 26)
        .background(colorScheme == .dark ? Color(.tertiarySystemBackground) : Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
    }
}

private struct CalendarWeekRow: View {
    let layout: CalendarMonthWeekLayout
    let month: Date
    let selectedDate: Date?
    let colors: [String: Color]
    let desktop: Bool
    let height: CGFloat
    var showsMonthBoundary = false
    let onDayTap: (Date) -> Void
    @Environment(\.colorScheme) private var colorScheme
    private let calendar = Calendar.current

    var body: some View {
        GeometryReader { bounds in
            let width = bounds.size.width / 7
            let dayHeight: CGFloat = desktop ? 29 : 27
            let laneHeight: CGFloat = 18
            let capacity = max(0, Int((height - dayHeight - 19) / laneHeight))
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
        let today = calendar.isDateInToday(day)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
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
                    .foregroundStyle(today ? Color.white : inMonth ? Color.primary : Color.secondary.opacity(0.65))
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

#if targetEnvironment(macCatalyst)
struct CalendarWeekScrollTarget: Equatable {
    let date: Date
    let revision: Int
}

/// A single native scrolling surface, with one reusable cell per week. Adjacent
/// months share their boundary week rather than repeating six-week month grids.
struct CalendarContinuousGrid: View {
    let month: Date
    let target: CalendarWeekScrollTarget
    let selectedDate: Date?
    let events: [CalendarService.CalendarEventSummary]
    let todos: [Todo]
    let colors: [String: Color]
    let desktop: Bool
    let onVisibleMonth: (Date) -> Void
    let onDayTap: (Date) -> Void

    var body: some View {
        VStack(spacing: 0) {
            CalendarWeekdayStrip(desktop: desktop)
            CalendarWeekScrollView(month: month, target: target, selectedDate: selectedDate,
                events: events, todos: todos.compactMap { todo in
                    guard !todo.isCompleted, let date = todo.scheduleAnchor else { return nil }
                    return CalendarMonthTodo(title: todo.title, date: date, eventID: todo.calendarEventID)
                }, colors: colors, desktop: desktop, onVisibleMonth: onVisibleMonth, onDayTap: onDayTap)
        }
        .accessibilityIdentifier("calendar.monthGrid")
    }
}

private struct CalendarWeekScrollView: UIViewRepresentable {
    let month: Date
    let target: CalendarWeekScrollTarget
    let selectedDate: Date?
    let events: [CalendarService.CalendarEventSummary]
    let todos: [CalendarMonthTodo]
    let colors: [String: Color]
    let desktop: Bool
    let onVisibleMonth: (Date) -> Void
    let onDayTap: (Date) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeUIView(context: Context) -> WeekCollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        let view = WeekCollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemBackground
        }
        view.contentInsetAdjustmentBehavior = .never
        view.alwaysBounceVertical = true
        view.allowsSelection = false
        view.showsHorizontalScrollIndicator = false
        view.register(WeekCell.self, forCellWithReuseIdentifier: "week")
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "calendar.continuousWeeks"
        view.onResize = { [weak coordinator = context.coordinator] view in coordinator?.resize(view) }
        view.onLayout = { [weak coordinator = context.coordinator] view in coordinator?.applyTarget(view) }
        return view
    }

    func updateUIView(_ view: WeekCollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.owner = self
        coordinator.resize(view)
        if coordinator.appliedTarget != target { view.setNeedsLayout() }
        for path in view.indexPathsForVisibleItems {
            if let cell = view.cellForItem(at: path) { coordinator.configure(cell, at: path) }
        }
    }

    final class WeekCollectionView: UICollectionView {
        var onResize: ((WeekCollectionView) -> Void)?
        var onLayout: ((WeekCollectionView) -> Void)?
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

    final class WeekCell: UICollectionViewCell {
        private var hostedContent: (UIView & UIContentView)?
        override var canBecomeFocused: Bool { false }

        func setContent(_ configuration: any UIContentConfiguration) {
            // Keep one hosting view for the reusable cell's lifetime. Updating
            // a week must not replace its displayed view during a scroll.
            if let hostedContent {
                hostedContent.configuration = configuration
            } else {
                let content = configuration.makeContentView()
                content.backgroundColor = .clear
                content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                contentView.addSubview(content)
                hostedContent = content
            }
            hostedContent?.frame = contentView.bounds
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            hostedContent?.frame = contentView.bounds
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var owner: CalendarWeekScrollView
        var appliedTarget: CalendarWeekScrollTarget?
        private let calendar = Calendar.current
        private let weekCount = 521
        private var baseWeek: Date
        private var rowHeight: CGFloat = 100
        private var lastReportedMonth: Date
        private var adjusting = false

        init(owner: CalendarWeekScrollView) {
            self.owner = owner
            let week = CalendarMonthGeometry.weekStart(containing: owner.target.date)
            baseWeek = Calendar.current.date(byAdding: .weekOfYear, value: -260, to: week) ?? week
            lastReportedMonth = owner.month
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { weekCount }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "week", for: path)
            configure(cell, at: path)
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt path: IndexPath) {
            // UIKit may prepare an offscreen cell before an async event read
            // completes. Refresh it when it actually enters the viewport.
            configure(cell, at: path)
        }

        func configure(_ cell: UICollectionViewCell, at path: IndexPath) {
            guard let cell = cell as? WeekCell,
                  let start = calendar.date(byAdding: .weekOfYear, value: path.item, to: baseWeek),
                  let end = calendar.date(byAdding: .day, value: 7, to: start) else { return }
            let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            let layout = CalendarMonthWeekLayout(days: days,
                events: owner.events.filter { $0.startDate < end && $0.endDate > start },
                todos: owner.todos.filter { $0.date >= start && $0.date < end })
            cell.setContent(UIHostingConfiguration {
                CalendarWeekRow(layout: layout, month: owner.month, selectedDate: owner.selectedDate,
                    colors: owner.colors, desktop: owner.desktop, height: rowHeight,
                    showsMonthBoundary: true, onDayTap: owner.onDayTap)
                    .environment(\.locale, AppLanguage.current.locale)
                    .tint(AppTheme.accent)
            }.margins(.all, 0))
        }

        func resize(_ view: UICollectionView) {
            guard view.bounds.width > 0, view.bounds.height > 0,
                  let layout = view.collectionViewLayout as? UICollectionViewFlowLayout else { return }
            let height = max(owner.desktop ? 96 : 86, view.bounds.height / 6)
            let size = CGSize(width: view.bounds.width, height: height)
            guard layout.itemSize != size else { return }
            let position = view.contentOffset.y / rowHeight
            rowHeight = height
            layout.itemSize = size
            layout.invalidateLayout()
            adjusting = true
            view.contentOffset.y = position * rowHeight
            adjusting = false
            for path in view.indexPathsForVisibleItems {
                if let cell = view.cellForItem(at: path) { configure(cell, at: path) }
            }
        }

        func applyTarget(_ view: UICollectionView) {
            guard view.bounds.width > 0, view.bounds.height > 0, appliedTarget != owner.target else { return }
            let week = CalendarMonthGeometry.weekStart(containing: owner.target.date)
            var index = calendar.dateComponents([.weekOfYear], from: baseWeek, to: week).weekOfYear ?? 260
            if !(0..<weekCount).contains(index) {
                baseWeek = calendar.date(byAdding: .weekOfYear, value: -260, to: week) ?? week
                index = 260
                view.reloadData()
            }
            appliedTarget = owner.target
            lastReportedMonth = calendar.dateInterval(of: .month, for: owner.target.date)?.start ?? owner.target.date
            adjusting = true
            view.setContentOffset(CGPoint(x: 0, y: CGFloat(index) * rowHeight), animated: false)
            adjusting = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !adjusting, appliedTarget != nil, let view = scrollView as? UICollectionView else { return }
            var index = min(weekCount - 1, max(0, Int(floor(view.contentOffset.y / rowHeight))))
            // Rebase far beyond the viewport; preserve the fractional week and
            // keep both scroll directions available without an ever-growing list.
            if index < 52 || index > weekCount - 53 {
                let shift = index - 260
                if let start = calendar.date(byAdding: .weekOfYear, value: shift, to: baseWeek) {
                    baseWeek = start
                    adjusting = true
                    view.reloadData()
                    view.contentOffset.y -= CGFloat(shift) * rowHeight
                    adjusting = false
                    index = 260
                }
            }
            guard let week = calendar.date(byAdding: .weekOfYear, value: index, to: baseWeek),
                  let lastDay = calendar.date(byAdding: .day, value: 6, to: week),
                  let month = calendar.dateInterval(of: .month, for: lastDay)?.start,
                  month != lastReportedMonth else { return }
            lastReportedMonth = month
            let onVisibleMonth = owner.onVisibleMonth
            DispatchQueue.main.async { onVisibleMonth(month) }
        }
    }
}
#endif

struct CalendarMiniMonth: View {
    let month: Date
    let selectedDate: Date?
    let onSelect: (Date) -> Void
    private let calendar = Calendar.current

    var body: some View {
        let geometry = CalendarMonthGeometry(month: month)
        let weekdaySymbols: [String] = {
            var localizedCalendar = calendar
            localizedCalendar.locale = AppLanguage.current.locale
            return localizedCalendar.veryShortStandaloneWeekdaySymbols
        }()
        VStack(spacing: 5) {
            Text(month.formatted(.dateTime.year().month(.wide).locale(AppLanguage.current.locale)))
                .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    Text(weekdaySymbols[(calendar.firstWeekday - 1 + index) % 7])
                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            ForEach(geometry.weeks.indices, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(geometry.weeks[row], id: \.self) { day in
                        let today = calendar.isDateInToday(day)
                        let selected = selectedDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false
                        Button { onSelect(day) } label: {
                            Text("\(calendar.component(.day, from: day))")
                                .font(.system(size: 11, weight: today || selected ? .semibold : .regular))
                                .foregroundStyle(today ? Color.white : calendar.isDate(day, equalTo: month, toGranularity: .month) ? Color.primary : Color.secondary.opacity(0.55))
                                .frame(width: 23, height: 23)
                                .background { if today { Circle().fill(Color.red) } else if selected { Circle().fill(Color.accentColor.opacity(0.15)) } }
                                .frame(maxWidth: .infinity)
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
