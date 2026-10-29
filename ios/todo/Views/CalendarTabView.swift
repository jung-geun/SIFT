import SwiftUI
import SwiftData
import EventKit
import Combine

// MARK: - Notification Names
extension Notification.Name {
    static let calendarScrollToToday = Notification.Name("pieroot.todo.calendarScrollToToday")
}


// ─────────────────────────────────────────────────────────────
// MARK: - CalendarTabView
// ─────────────────────────────────────────────────────────────

struct CalendarTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.appTutorialState) private var tutorial
    @Query private var allTodos: [Todo]
    @State private var calendar = Calendar.current
    @State private var today = Calendar.current.startOfDay(for: Date())
    @State private var eventWindow = CalendarEventWindow { start, end in
        await CalendarService.shared.events(from: start, to: end)
    }
    @State private var displayMonth = CalendarTabView.currentMonthStart
    @State private var eventWindowMonth = CalendarTabView.currentMonthStart
    @State private var scrollDate = CalendarTabView.currentMonthStart
    @State private var scrollRevision = 0
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
    @AppStorage("pieroot.todo.calendar.monthDisplayStyle") private var monthStyleRaw = CalendarMonthDisplayStyle.details.rawValue
    @AppStorage("pieroot.todo.calendar.dayDisplayStyle") private var dayStyleRaw = CalendarMobileDayStyle.single.rawValue
    @State private var showsYear = false
    @State private var showsMobileDay = false
    @State private var focusedDate = Calendar.current.startOfDay(for: Date())
    @State private var visibleDates: [Date] = []
    @State private var yearCursor = Date()
    @State private var showsWeek = false
    @State private var upcoming = CalendarUpcomingEvents()
    @State private var scheduleRevision = 0
    @State private var landscapeMode = "day"
    @State private var lastLoadedRequest: CalendarMonthRequest?
    @State private var sidebarAvailable = false

    private var showsUpcomingAgenda: Bool {
        dayStyle == .list && (verticalSizeClass == .compact
            ? landscapeMode == "day" : showsMobileDay && !showsWeek)
    }

    private var monthStyle: CalendarMonthDisplayStyle {
        CalendarMonthDisplayStyle(rawValue: monthStyleRaw) ?? .details
    }

    private var dayStyle: CalendarMobileDayStyle {
        CalendarMobileDayStyle(rawValue: dayStyleRaw) ?? .single
    }

    static var currentMonthStart: Date {
        Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    }

    private var request: CalendarMonthRequest {
        CalendarMonthRequest(month: eventWindowMonth, revision: reloadRevision,
                             disabledIDs: disabledIDs, authorized: authorized,
                             calendar: calendar)
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
            #if targetEnvironment(macCatalyst)
            // Give Catalyst's native toolbar a calendar-specific navigation
            // title instead of leaving it to the app-name fallback.
            .navigationTitle("캘린더")
            #else
            .navigationTitle(horizontalSizeClass == .regular ? Text("") : Text("캘린더"))
            #endif
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if targetEnvironment(macCatalyst)
                ToolbarItem(placement: .navigationBarLeading) {
                    CatalystToolbarButton(
                        title: calendarCopy("calendar.sidebar.toggle", "Show or hide calendars", "캘린더 사이드바 표시 또는 가리기"),
                        systemImage: "sidebar.left", accessibilityIdentifier: "calendar.sidebarToggle"
                    ) { sidebarVisible.toggle() }
                    .disabled(!authorized)
                }
                #else
                toolbarItems
                #endif
            }
            .sheet(item: eventEditorSheet) { activeSheetView($0) }
            .outsideDismissSheet(item: dayDetailSheet) { activeSheetView($0) }
            #if !targetEnvironment(macCatalyst)
            .navigationDestination(isPresented: $showsMobileDay) {
                mobileDayContent
            }
            #endif
            .sheet(isPresented: $showSourceSheet) {
                CalendarSourceSheet(sources: calendarSources, disabledIDs: $disabledIDs)
            }
        }
        .task { refreshAuthorization() }
        .task(id: request) {
            let expected = request
            isLoading = expected.authorized
            defer { if request == expected { isLoading = false } }
            if expected.authorized {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard let events = await eventWindow.events(around: expected.month,
                revision: expected.revision, disabledIDs: expected.disabledIDs,
                authorized: expected.authorized, calendar: expected.calendar),
                !Task.isCancelled, request == expected else { return }
            #if DEBUG
            allEvents = events + MacPresentationQA.calendarEvents(calendar: expected.calendar)
            #else
            allEvents = events
            #endif
            lastLoadedRequest = expected
            if showsUpcomingAgenda {
                upcoming.merge(events, request: expected, startDate: focusedDate)
            }
            if expected.authorized { refreshSources() }
            if !expected.authorized { upcoming = CalendarUpcomingEvents() }
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            refreshCalendarContext()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            refreshCalendarContext()
        }
        .onChange(of: disabledIDs) { _, disabled in
            allEvents.removeAll { disabled.contains($0.calendarID) }
            resetUpcoming()
        }
        .onChange(of: displayMonth) { _, month in
            let distance = calendar.dateComponents([.month], from: eventWindowMonth, to: month).month ?? 0
            if abs(distance) >= 2 { eventWindowMonth = month }
        }
        .onAppear { tutorial?.handleCalendarTabAppeared() }
        .onChange(of: dayStyleRaw) { _, _ in
            if !showsUpcomingAgenda {
                eventWindowMonth = calendar.dateInterval(of: .month, for: focusedDate)?.start ?? focusedDate
            }
        }
        .onChange(of: focusedDate) { _, date in
            selectedDate = date
            let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
            if showsMobileDay || verticalSizeClass == .compact {
                displayMonth = month
                eventWindowMonth = month
                if showsUpcomingAgenda { prepareUpcoming() }
            }
        }
        .onChange(of: showsMobileDay) { previous, current in
            if previous && !current {
                // Stock Calendar returns to the selected day's month origin.
                navigateToMonth(containing: focusedDate)
                showsWeek = false
            }
        }
        .onChange(of: verticalSizeClass) { previous, size in
            guard authorized else { return }
            if size == .compact {
                landscapeMode = "day"
                if !showsMobileDay {
                    focusedDate = selectedDate ?? (visibleDates.contains {
                        calendar.isDate($0, inSameDayAs: today)
                    } ? today : visibleDates.first ?? displayMonth)
                }
            } else if previous == .compact {
                if landscapeMode == "day" { showsMobileDay = true }
                else if landscapeMode == "week" {
                    focusedDate = CalendarMonthGeometry.weekStart(containing: focusedDate, calendar: calendar)
                    navigateToMonth(containing: focusedDate)
                }
            }
        }
        .onChange(of: monthStyleRaw) { _, _ in
            if monthStyle == .list && selectedDate == nil {
                selectedDate = visibleDates.contains { calendar.isDate($0, inSameDayAs: today) }
                    ? today : visibleDates.first ?? displayMonth
            }
        }
        .onChange(of: landscapeMode) { _, mode in
            if mode == "year" { yearCursor = displayMonth }
            else if mode == "month" { eventWindowMonth = displayMonth }
            else { eventWindowMonth = calendar.dateInterval(of: .month, for: focusedDate)?.start ?? focusedDate }
        }
        .onChange(of: showsUpcomingAgenda) { _, active in
            if active { prepareUpcoming() }
        }
        .onChange(of: calendar) { _, _ in resetUpcoming() }
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
            #if targetEnvironment(macCatalyst)
            desktopContent
            #else
            let roomy = horizontalSizeClass == .regular && geometry.size.width >= 820
            HStack(spacing: 0) {
                if roomy && sidebarVisible && verticalSizeClass != .compact {
                    sidebar.frame(width: 336)
                    Divider()
                }
                Group {
                    if verticalSizeClass == .compact {
                        mobileLandscapeContent(height: geometry.size.height)
                    } else if showsYear {
                        mobileYearContent
                    } else {
                        mobileMonthContent(roomy: roomy, height: geometry.size.height)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    mobileTodayButton.padding(.leading, 16).padding(.bottom, 12)
                }
            }
            .environment(\.calendar, calendar)
            .onChange(of: roomy, initial: true) { _, available in sidebarAvailable = available }
            #endif
        }
    }

    private var desktopContent: some View {
        HStack(spacing: 0) {
            if sidebarVisible { sidebar.frame(width: 224); Divider() }
            VStack(spacing: 0) {
                monthHeader(desktop: true)
                CalendarContinuousGrid(month: displayMonth,
                    target: CalendarWeekScrollTarget(date: scrollDate, revision: scrollRevision),
                    selectedDate: selectedDate, calendar: calendar, today: today,
                    events: allEvents, todos: allTodos, colors: calendarColors, desktop: true,
                    onVisibleMonth: { displayMonth = $0 }, onDayTap: selectDay,
                    onDayDoubleTap: createEvent)
            }
        }
        .environment(\.calendar, calendar)
    }


    private func monthHeader(desktop: Bool) -> some View {
        HStack(spacing: 12) {
            #if !targetEnvironment(macCatalyst)
            if desktop {
                Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                    .accessibilityLabel(calendarCopy("calendar.sidebar.toggle", "Show or hide calendars", "캘린더 사이드바 표시 또는 가리기"))
                    .accessibilityIdentifier("calendar.sidebarToggle")
            }
            #endif
            Text(monthTitle(desktop: desktop))
                .lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityIdentifier("calendar.visibleMonth")
            Spacer(minLength: 0)
            if isLoading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(calendarCopy("calendar.loading", "Loading events", "일정 로딩 중"))
            }
            Button { Task { await performSync() } } label: {
                Image(systemName: "arrow.triangle.2.circlepath").frame(width: 30, height: 30)
            }
            .disabled(isSyncing)
            .accessibilityLabel(calendarCopy("calendar.sync", "Sync calendar", "캘린더 동기화"))
            .accessibilityIdentifier("calendar.sync")
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
            #if targetEnvironment(macCatalyst)
            filterButton.frame(width: 30, height: 30)
            addButton.frame(width: 30, height: 30)
            #endif
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
                            Text(source.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(source.calendars) { info in
                                Button { toggleCalendar(info.id) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: disabledIDs.contains(info.id) ? "square" : "checkmark.square.fill")
                                            .foregroundStyle(calendarColors[info.id] ?? .accentColor)
                                        Text(info.title).foregroundStyle(.primary).lineLimit(2)
                                        Spacer(minLength: 0)
                                    }
                                    #if targetEnvironment(macCatalyst)
                                    .font(.system(size: 13)).frame(minHeight: 22)
                                    #else
                                    .font(.subheadline).frame(minHeight: 44)
                                    #endif
                                    .contentShape(Rectangle())
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
        if horizontalSizeClass == .regular && sidebarAvailable {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                    .accessibilityLabel(calendarCopy("calendar.sidebar.toggle", "Show or hide calendars", "캘린더 사이드바 표시 또는 가리기"))
                    .accessibilityIdentifier("calendar.sidebarToggle")
                    .disabled(!authorized)
            }
        }
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                if !showsYear { yearCursor = displayMonth }
                showsYear.toggle()
            } label: {
                Label(displayMonth.formatted(.dateTime.year().locale(AppLanguage.current.locale)),
                    systemImage: showsYear ? "calendar" : "chevron.left")
            }
            .accessibilityLabel(calendarCopy("calendar.view.year", "Year", "연도"))
            .accessibilityIdentifier("calendar.yearButton")
            .disabled(!authorized)
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            monthViewMenu
            addButton
        }
    }

    private var monthViewMenu: some View {
        Menu {
            Picker(calendarCopy("calendar.view.month", "Month view", "월 보기"), selection: $monthStyleRaw) {
                ForEach(CalendarMonthDisplayStyle.allCases) { style in
                    Label(style.title, systemImage: style.symbol).tag(style.rawValue)
                        .accessibilityIdentifier("calendar.mode.\(style.rawValue)")
                }
            }
            Divider()
            Button(calendarCopy("calendar.view.year", "Year", "연도"), systemImage: "calendar") {
                yearCursor = displayMonth
                showsYear = true
            }
            Button(calendarCopy("calendar.view.singleDay", "Single Day", "하루"), systemImage: "rectangle") {
                openMobileDay(week: false)
            }
            Button(calendarCopy("calendar.view.week", "Week", "주"), systemImage: "rectangle.split.3x1") {
                openMobileDay(week: true)
            }
        } label: {
            Image(systemName: monthStyle.symbol).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(calendarCopy("calendar.view.choose", "Calendar view", "캘린더 보기"))
        .accessibilityIdentifier("calendar.viewMenu")
        .disabled(!authorized)
    }

    private var dayViewMenu: some View {
        Menu {
            Picker(calendarCopy("calendar.view.day", "Day view", "일 보기"), selection: Binding(
                get: { dayStyleRaw }, set: { dayStyleRaw = $0; showsWeek = false })) {
                ForEach(CalendarMobileDayStyle.allCases) { style in
                    Label(style.title, systemImage: style.symbol).tag(style.rawValue)
                        .accessibilityIdentifier("calendar.dayMode.\(style.rawValue)")
                }
            }
            Button(calendarCopy("calendar.view.week", "Week", "주"), systemImage: "rectangle.split.3x1") {
                showsWeek = true
            }
        } label: {
            Image(systemName: showsWeek ? "rectangle.split.3x1" : dayStyle.symbol)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(calendarCopy("calendar.view.choose", "Calendar view", "캘린더 보기"))
        .accessibilityIdentifier("calendar.dayViewMenu")
    }

    private var mobileTodayButton: some View {
        Button(action: goToToday) {
            Text("오늘")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityIdentifier("calendar.today")
    }

    private var mobileDayContent: some View {
        Group {
            if verticalSizeClass == .compact {
                GeometryReader { geometry in mobileLandscapeContent(height: geometry.size.height) }
            } else {
                mobileSchedule(dayCount: showsWeek ? 7 : dayStyle == .multi ? 2 : 1)
            }
        }
        .overlay(alignment: .bottomLeading) {
            mobileTodayButton.padding(.leading, 16).padding(.bottom, 12)
        }
        .environment(\.calendar, calendar)
        .navigationTitle(focusedDate.formatted(.dateTime.year().month().day().locale(AppLanguage.current.locale)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                dayViewMenu
                addButton
            }
        }
        .onAppear {
            selectedDate = focusedDate
            eventWindowMonth = calendar.dateInterval(of: .month, for: focusedDate)?.start ?? focusedDate
            if showsUpcomingAgenda { prepareUpcoming() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.dayView")
    }

    private func mobileSchedule(dayCount: Int) -> some View {
        VStack(spacing: 0) {
            if dayCount < 7 && !showsUpcomingAgenda {
                CalendarMobileWeekStrip(date: focusedDate, today: today, calendar: calendar,
                    onSelect: { focusedDate = $0 })
                    .fixedSize(horizontal: false, vertical: true)
                    .simultaneousGesture(daySwipe(step: 7))
            }
            if showsUpcomingAgenda && dayCount < 7 {
                CalendarAgendaView(startDate: focusedDate, dayCount: upcomingDayCount,
                    events: upcoming.events, todos: allTodos, calendar: calendar,
                    onDataChanged: reloadAllEvents, onLoadMore: loadLaterAgenda,
                    isLoadingMore: isLoading)
            } else {
                CalendarScheduleView(startDate: dayCount == 7
                    ? CalendarMonthGeometry.weekStart(containing: focusedDate, calendar: calendar) : focusedDate,
                    dayCount: dayCount, events: allEvents, todos: allTodos,
                    calendar: calendar, today: today, onDataChanged: reloadAllEvents)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .simultaneousGesture(daySwipe(step: dayCount == 7 ? 7 : 1))
                    .id(scheduleRevision)
            }
        }
    }

    private func daySwipe(step: Int) -> some Gesture {
        DragGesture(minimumDistance: 30).onEnded { gesture in
            // Leave the system's leading-edge back gesture uncontested.
            guard gesture.startLocation.x > 24,
                abs(gesture.translation.width) > 60,
                abs(gesture.translation.width) > abs(gesture.translation.height) * 2,
                let date = calendar.date(byAdding: .day,
                    value: gesture.translation.width < 0 ? step : -step, to: focusedDate) else { return }
            focusedDate = date
        }
    }

    private func openMobileDay(week: Bool) {
        showsYear = false
        showsWeek = week
        landscapeMode = week ? "week" : "day"
        focusedDate = selectedDate ?? (calendar.isDate(displayMonth, equalTo: today, toGranularity: .month)
            ? today : displayMonth)
        showsMobileDay = true
    }

    private var mobileYearContent: some View {
        CalendarYearOverview(date: yearCursor, calendar: calendar, onSelect: { date in
            selectedDate = date
            focusedDate = date
            navigateToMonth(containing: date)
            showsYear = false
            landscapeMode = "month"
        })
    }

    @ViewBuilder private func mobileMonthContent(roomy: Bool, height: CGFloat) -> some View {
        if monthStyle == .list && verticalSizeClass == .compact {
            HStack(spacing: 0) {
                mobileMonthGrid(roomy: false)
                Divider()
                mobileSelectedAgenda
            }
        } else {
            VStack(spacing: 0) {
                mobileMonthGrid(roomy: roomy)
                    .frame(maxHeight: monthStyle == .list ? max(240, height * 0.48) : .infinity)
                if monthStyle == .list {
                    Divider()
                    mobileSelectedAgenda
                }
            }
        }
    }

    private func mobileMonthGrid(roomy: Bool) -> some View {
        CalendarContinuousGrid(month: displayMonth,
            target: CalendarWeekScrollTarget(date: scrollDate, revision: scrollRevision),
            selectedDate: selectedDate, calendar: calendar, today: today,
            events: allEvents, todos: allTodos, colors: calendarColors, desktop: roomy,
            onVisibleMonth: { displayMonth = $0 }, onDayTap: selectDay,
            onDayDoubleTap: createEvent,
            style: monthStyle, mobileMonthSections: true,
            onVisibleDates: { visibleDates = $0 },
            onStyleChange: { monthStyleRaw = $0.rawValue })
    }

    private var mobileSelectedAgenda: some View {
        CalendarAgendaView(startDate: selectedDate ?? today, dayCount: 1,
            events: allEvents, todos: allTodos, calendar: calendar,
            onDataChanged: reloadAllEvents)
    }

    private func mobileLandscapeContent(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Picker(calendarCopy("calendar.view.choose", "Calendar view", "캘린더 보기"), selection: $landscapeMode) {
                Text(calendarCopy("calendar.view.singleDay", "Single Day", "하루")).tag("day")
                Text(calendarCopy("calendar.view.week", "Week", "주")).tag("week")
                Text(calendarCopy("calendar.view.month", "Month", "월")).tag("month")
                Text(calendarCopy("calendar.view.year", "Year", "연도")).tag("year")
            }
            .pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 4)
            .accessibilityIdentifier("calendar.landscapeViews")
            switch landscapeMode {
            case "week": mobileSchedule(dayCount: 7)
            case "month": mobileMonthContent(roomy: false, height: height)
            case "year": mobileYearContent
            default: mobileSchedule(dayCount: dayStyle == .multi ? 2 : 1)
            }
        }
    }

    private var upcomingDayCount: Int {
        let end = upcoming.through ?? calendar.date(byAdding: .month, value: 4, to: focusedDate) ?? focusedDate
        return max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: focusedDate), to: end).day ?? 1)
    }

    private func loadLaterAgenda() {
        guard !isLoading, let through = upcoming.through,
              let center = calendar.date(byAdding: .month, value: 3, to: eventWindowMonth) else { return }
        if through > focusedDate {
            isLoading = true
            eventWindowMonth = center
        }
    }

    private var filterButton: some View {
        Button { showSourceSheet = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            .accessibilityLabel(AppLanguage.localized("calendar.filter.accessibilityLabel", defaultValue: "캘린더 필터", language: .current, comment: "Calendar filter button."))
            .accessibilityIdentifier("calendar.filterButton").disabled(!authorized)
    }

    private var addButton: some View {
        Button { activeSheet = .newEvent(date: selectedDate ?? Date()) } label: { Image(systemName: "plus") }
            .accessibilityLabel(AppLanguage.localized("calendar.add.accessibilityLabel", defaultValue: "일정 추가", language: .current, comment: "Calendar add button."))
            .accessibilityIdentifier("calendar.addButton").disabled(!authorized)
    }

    private var dayDetailSheet: Binding<CalendarActiveSheet?> {
        Binding(get: {
            if case .dayDetail? = activeSheet { return activeSheet }
            return nil
        }, set: { activeSheet = $0 })
    }

    private var eventEditorSheet: Binding<CalendarActiveSheet?> {
        Binding(get: {
            if case .dayDetail? = activeSheet { return nil }
            return activeSheet
        }, set: { activeSheet = $0 })
    }

    @ViewBuilder private func activeSheetView(_ sheet: CalendarActiveSheet) -> some View {
        switch sheet {
        case .dayDetail(let date):
            DayDetailSheet(date: date, events: allEvents, todos: allTodos,
                prefersRoomyLayout: horizontalSizeClass == .regular,
                calendar: calendar, today: today) { reloadAllEvents() }
        case .newEvent(let date): EventEditSheet(mode: .create(date: date)) { reloadAllEvents() }
        case .editEvent(let detail): EventEditSheet(mode: .edit(detail: detail)) { reloadAllEvents() }
        }
    }

    private func selectDay(_ date: Date) {
        selectedDate = date
        #if targetEnvironment(macCatalyst)
        activeSheet = .dayDetail(date: date)
        #else
        focusedDate = date
        if monthStyle != .list { showsMobileDay = true }
        #endif
    }

    private func createEvent(_ date: Date) {
        selectedDate = date
        activeSheet = .newEvent(date: date)
    }

    private func selectMiniDay(_ date: Date) {
        selectedDate = date
        displayMonth = calendar.dateInterval(of: .month, for: date)?.start ?? date
        scrollDate = date
        scrollRevision += 1
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
        guard let date = calendar.date(byAdding: .month, value: offset, to: displayMonth) else { return }
        displayMonth = date
        selectedDate = nil
        scrollDate = date
        scrollRevision += 1
    }

    private func goToToday() {
        guard authorized else { return }
        #if targetEnvironment(macCatalyst)
        navigateToMonth(containing: today)
        selectedDate = today
        #else
        if verticalSizeClass == .compact && landscapeMode == "year" {
            yearCursor = today
        } else if verticalSizeClass == .compact && landscapeMode == "month" {
            selectedDate = today
            navigateToMonth(containing: today)
            scrollDate = today
        } else if showsMobileDay || verticalSizeClass == .compact {
            focusedDate = today
            selectedDate = today
            scheduleRevision += 1
        } else if !showsYear && monthStyle != .list && CalendarMobileTodayDestination.resolve(
            today: today, visibleDates: visibleDates, calendar: calendar) == .day {
            focusedDate = today
            selectedDate = today
            showsMobileDay = true
        } else {
            showsYear = false
            selectedDate = today
            navigateToMonth(containing: today)
            scrollDate = today
        }
        #endif
    }

    private func navigateToMonth(containing date: Date) {
        let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
        displayMonth = month
        eventWindowMonth = month
        scrollDate = month
        scrollRevision += 1
    }

    private func toggleCalendar(_ id: String) {
        if disabledIDs.contains(id) { disabledIDs.remove(id) } else { disabledIDs.insert(id) }
        CalendarService.shared.disabledCalendarIDs = disabledIDs
    }

    private func refreshAuthorization() {
        refreshCalendarContext()
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
            showsMobileDay = false
            showsYear = false
            isLoading = false
        }
    }

    private func refreshCalendarContext() {
        calendar = Calendar.current
        today = calendar.startOfDay(for: Date())
    }

    private func refreshSources() {
        calendarSources = CalendarService.shared.availableCalendars()
        calendarColors = Dictionary(uniqueKeysWithValues: calendarSources.flatMap(\.calendars).map {
            ($0.id, CalendarPresentation.color(forCalendarID: $0.id))
        })
    }

    func reloadAllEvents() {
        if showsUpcomingAgenda { resetUpcoming() }
        reloadRevision += 1
    }

    private func resetUpcoming() {
        if showsUpcomingAgenda {
            eventWindowMonth = upcoming.restart(around: focusedDate, calendar: calendar)
        } else {
            upcoming = CalendarUpcomingEvents()
        }
        lastLoadedRequest = nil
    }

    private func prepareUpcoming() {
        let start = calendar.startOfDay(for: focusedDate)
        if let loaded = lastLoadedRequest, loaded.revision == reloadRevision,
            loaded.disabledIDs == disabledIDs, loaded.calendar == calendar,
            loaded.authorized == authorized,
            let month = calendar.dateInterval(of: .month, for: loaded.month)?.start,
            let lower = calendar.date(byAdding: .month, value: -3, to: month),
            let upper = calendar.date(byAdding: .month, value: 4, to: month),
            start >= lower && start < upper {
            upcoming.merge(allEvents, request: loaded, startDate: start)
        } else {
            resetUpcoming()
        }
    }

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
    let calendar: Calendar
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
// MARK: - EventEditMode
// ─────────────────────────────────────────────────────────────

enum EventEditMode {
    case create(date: Date, endDate: Date? = nil)
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
    @Environment(\.modelContext) private var modelContext
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
        case .create(let date, let endDate):
            _title      = State(initialValue: "")
            _startDate  = State(initialValue: date)
            _endDate    = State(initialValue: endDate ?? date.addingTimeInterval(3600))
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
                        .accessibilityIdentifier("calendar.eventEditor.title")
                }
                Section("시간") {
                    DatePicker("시작", selection: startDateSelection,
                               displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("calendar.eventEditor.start")
                    DatePicker("종료", selection: $endDate, in: startDate...,
                               displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("calendar.eventEditor.end")
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
                #if targetEnvironment(macCatalyst)
                ToolbarItemGroup(placement: .confirmationAction) {
                    cancelButton
                    saveButton
                }
                #else
                ToolbarItem(placement: .cancellationAction) { cancelButton }
                ToolbarItem(placement: .confirmationAction) { saveButton }
                #endif
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

    private var cancelButton: some View {
        Button("취소") { dismiss() }
            .accessibilityIdentifier("calendar.eventEditor.cancel")
    }

    private var saveButton: some View {
        Button("저장") { save() }
            .fontWeight(.semibold)
            .disabled(!canSave)
            .accessibilityIdentifier("calendar.eventEditor.save")
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && endDate > startDate
    }

    private var startDateSelection: Binding<Date> {
        Binding(get: { startDate }, set: { date in
            let duration = max(60, endDate.timeIntervalSince(startDate))
            endDate = date.addingTimeInterval(duration)
            startDate = date
        })
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
        guard canSave else { return }
        guard case .edit(let detail) = mode, detail.isRecurring else {
            persistSave(scope: nil)
            return
        }
        recurrenceMutation = .save
        showRecurrenceScope = true
    }

    private func persistSave(scope: CalendarRecurrenceScope?) {
        guard canSave else { return }
        do {
            let committed: CalendarService.CommittedMutation?
            switch mode {
            case .create:
                try CalendarService.shared.createEvent(
                    title: title, startDate: startDate, endDate: endDate,
                    notes: notes, calendarID: calendarID)
                committed = nil
            case .edit(let detail):
                if detail.isRecurring {
                    committed = try CalendarService.shared.updateOccurrence(
                        identifier: detail.identifier,
                        on: detail.occurrenceDate ?? detail.startDate,
                        title: title,
                        startDate: startDate,
                        endDate: endDate,
                        notes: notes,
                        scope: scope ?? .thisEvent
                    )
                } else {
                    committed = try CalendarService.shared.updateEvent(
                        identifier: detail.identifier,
                        title: title, startDate: startDate, endDate: endDate, notes: notes)
                }
            }
            try committed?.reconcileExisting(in: modelContext)
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
            let committed: CalendarService.CommittedMutation
            if detail.isRecurring {
                committed = try CalendarService.shared.removeEventOccurrence(
                    eventID: detail.identifier,
                    on: detail.occurrenceDate ?? detail.startDate,
                    scope: scope ?? .thisEvent
                )
            } else {
                committed = try CalendarService.shared.removeEvent(eventID: detail.identifier)
            }
            try committed.reconcileExisting(in: modelContext)
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
