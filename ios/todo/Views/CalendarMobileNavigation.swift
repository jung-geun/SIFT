import SwiftUI

// Month density and day presentation are independent, as in the system Calendar.
enum CalendarMonthDisplayStyle: String, CaseIterable, Identifiable {
    case compact, stacked, details, list
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: calendarCopy("calendar.view.compact", "Compact", "간략히")
        case .stacked: calendarCopy("calendar.view.stacked", "Stacked", "스택")
        case .details: calendarCopy("calendar.view.details", "Details", "세부사항")
        case .list: calendarCopy("calendar.view.list", "List", "목록")
        }
    }
    var symbol: String {
        switch self {
        case .compact: "rectangle.compress.vertical"
        case .stacked: "rectangle.stack"
        case .details: "rectangle.expand.vertical"
        case .list: "list.bullet.below.rectangle"
        }
    }
}

enum CalendarMobileDayStyle: String, CaseIterable, Identifiable {
    case single, multi, list
    var id: String { rawValue }
    var title: String {
        switch self {
        case .single: calendarCopy("calendar.view.singleDay", "Single Day", "하루")
        case .multi: calendarCopy("calendar.view.multiDay", "Multi Day", "여러 날")
        case .list: calendarCopy("calendar.view.list", "List", "목록")
        }
    }
    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .multi: "rectangle.split.3x1"
        case .list: "list.bullet"
        }
    }
}

enum CalendarMobileTodayDestination: Equatable {
    case month, day

    static func resolve(today: Date, visibleDates: [Date], calendar: Calendar) -> Self {
        visibleDates.contains { calendar.isDate($0, inSameDayAs: today) } ? .day : .month
    }
}

struct CalendarMobileWeekStrip: View {
    let date: Date
    let today: Date
    let calendar: Calendar
    let onSelect: (Date) -> Void
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 32

    var body: some View {
        let start = CalendarMonthGeometry.weekStart(containing: date, calendar: calendar)
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { offset in
                if let day = calendar.date(byAdding: .day, value: offset, to: start) {
                    Button { onSelect(day) } label: {
                        VStack(spacing: 4) {
                            Text(day.formatted(.dateTime.weekday(.narrow).locale(AppLanguage.current.locale)))
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("\(calendar.component(.day, from: day))")
                                .font(.body.weight(calendar.isDate(day, inSameDayAs: date) ? .semibold : .regular))
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .foregroundStyle(calendar.isDate(day, inSameDayAs: date) ? Color.white
                                    : calendar.isDate(day, inSameDayAs: today) ? Color.red : Color.primary)
                                .frame(width: min(badgeSize, 44), height: min(badgeSize, 44))
                                .background {
                                    if calendar.isDate(day, inSameDayAs: date) {
                                        Circle().fill(calendar.isDate(day, inSameDayAs: today) ? Color.red : Color.accentColor)
                                    }
                                }
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day().locale(AppLanguage.current.locale)))
                    .accessibilityAddTraits(calendar.isDate(day, inSameDayAs: date) ? .isSelected : [])
                    .accessibilityIdentifier("calendar.weekday.\(calendar.component(.year, from: day))-\(calendar.component(.month, from: day))-\(calendar.component(.day, from: day))")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.dayWeekStrip")
    }
}

struct CalendarYearOverview: View {
    let date: Date
    let calendar: Calendar
    let onSelect: (Date) -> Void

    static func months(inYearContaining date: Date, calendar: Calendar) -> [Date] {
        guard let interval = calendar.dateInterval(of: .year, for: date) else { return [] }
        var result: [Date] = []
        var month = interval.start
        while month < interval.end {
            result.append(month)
            guard let next = calendar.date(byAdding: .month, value: 1, to: month), next > month else { break }
            month = next
        }
        return result
    }

    var body: some View {
        let year = calendar.dateInterval(of: .year, for: date)?.start ?? date
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(-100...100, id: \.self) { offset in
                        if let sectionYear = calendar.date(byAdding: .year, value: offset, to: year) {
                            yearSection(sectionYear).id(sectionYear)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
            .task(id: year) { proxy.scrollTo(year, anchor: .top) }
        }
        .accessibilityIdentifier("calendar.yearOverview")
    }

    private func yearSection(_ year: Date) -> some View {
        let months = Self.months(inYearContaining: year, calendar: calendar)
        return VStack(alignment: .leading, spacing: 16) {
            Text(year.formatted(.dateTime.year().locale(AppLanguage.current.locale)))
                .font(.largeTitle.bold())
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 24) {
                ForEach(months, id: \.self) { month in
                        Button { onSelect(month) } label: {
                            CalendarYearMonthThumbnail(month: month, calendar: calendar)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(month.formatted(.dateTime.year().month(.wide).locale(AppLanguage.current.locale)))
                        .accessibilityIdentifier("calendar.yearMonth.\(calendar.component(.year, from: month))-\(calendar.component(.month, from: month))")
                }
            }
        }
    }
}

private struct CalendarYearMonthThumbnail: View {
    let month: Date
    let calendar: Calendar

    var body: some View {
        let geometry = CalendarMonthGeometry(month: month, calendar: calendar)
        VStack(alignment: .leading, spacing: 6) {
            Text(month.formatted(.dateTime.month(.abbreviated).locale(AppLanguage.current.locale)))
                .font(.headline).foregroundStyle(.red)
            VStack(spacing: 2) {
                ForEach(geometry.weeks.indices, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(geometry.weeks[row], id: \.self) { day in
                            Text(calendar.isDate(day, equalTo: month, toGranularity: .month)
                                ? "\(calendar.component(.day, from: day))" : " ")
                                .font(.caption2.monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 16)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
