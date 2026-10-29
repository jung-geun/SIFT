import SwiftUI
import EventKit

// 5. 캘린더 설정
struct CalendarDetailView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var settings = SettingsStore.shared
    @State private var isAuthorized = false
    @State private var defaultCalendarID = ""
    @State private var selectedCalendar: CalendarService.CalendarInfo?
    @State private var destinationError: CalendarError?
    @State private var isRequestingAccess = false
    @State private var taskAnalysisCalendarIDs: Set<String> = []

    var body: some View {
        Form {
            permissionSection
            taskAnalysisCalendarSection
            Section {
                Toggle(isOn: Binding(
                    get: { CalendarAutoPolicy.isAuto },
                    set: { CalendarAutoPolicy.setValue(auto: $0) }
                )) {
                    Text(copy("calendar.settings.autoRegister", fallback: "Automatically Export Deadlines"))
                }
                .accessibilityIdentifier("calendar.autoRegister.toggle")

                Picker(copy("calendar.settings.sources", fallback: "Automatic Export Sources"), selection: Binding(
                    get: { CalendarAutoPolicy.sourceFilter },
                    set: { CalendarAutoPolicy.sourceFilter = $0 }
                )) {
                    Text(copy("calendar.source.all", fallback: "All To-Dos")).tag("all")
                    Text(copy("calendar.source.manual", fallback: "Manually Added To-Dos")).tag("manual")
                    Text(copy("calendar.source.email", fallback: "Email To-Dos")).tag("email")
                    Text(copy("calendar.source.meeting", fallback: "Meeting To-Dos")).tag("meeting")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("calendar.sourceFilter.picker")
            } footer: {
                Text(copy("calendar.settings.autoRegisterFooter", fallback: "Only active to-dos with a deadline from the selected sources are exported automatically. To-dos awaiting review, calendar-sourced to-dos, and health routines are excluded. Urgent and highest-priority to-dos also require this consent. Calendar access and a writable destination are required; turning this off does not remove existing events."))
            }

            Section {
                Picker(copy("calendar.settings.completionAction", fallback: "When a To-Do Is Completed"), selection: Binding(
                    get: {
                        CalendarCompletionAction(rawValue: settings.get("pieroot.todo.calendarCompletionAction", defaultValue: "silence")) ?? .silence
                    },
                    set: { settings.set("pieroot.todo.calendarCompletionAction", value: $0.rawValue) }
                )) {
                    Text(copy("calendar.action.keep", fallback: "Keep Event")).tag(CalendarCompletionAction.keep)
                    Text(copy("calendar.action.silence", fallback: "Silence Alerts")).tag(CalendarCompletionAction.silence)
                    Text(copy("calendar.action.remove", fallback: "Remove Event")).tag(CalendarCompletionAction.remove)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("calendar.completionAction.picker")
            } footer: {
                Text(copy("calendar.settings.completionFooter", fallback: "These actions affect only events SIFT created for the to-do, not original external events."))
            }

            destinationCalendarSection
        }
        .appFormStyle()
        .navigationTitle(copy("calendar.settings.title", fallback: "Calendar Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refreshState)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshState() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .calendarAuthorizationChanged)) { _ in
            refreshState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            refreshState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .calendarTaskAnalysisSourcesChanged)) { _ in
            refreshState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshState()
        }
    }

    private var taskAnalysisCalendarSection: some View {
        Section {
            NavigationLink(destination: TaskAnalysisCalendarPickerView()) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy("calendar.taskAnalysis.title", fallback: "Task Analysis Calendars"))
                    Text(taskAnalysisCalendarIDs.isEmpty
                         ? copy("calendar.taskAnalysis.none", fallback: "None selected — automatic import and analysis are off")
                         : copy("calendar.taskAnalysis.manage", fallback: "Manage selected calendars"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("calendar.taskAnalysis.row")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(copy("calendar.taskAnalysis.consent", fallback: "Only calendars you explicitly select are used for automatic calendar-to-task import and analysis. Select none to turn both off. This selection is saved only on this device and does not change calendar display or the export destination. Read-only and subscribed calendars can also be selected."))
                Text(copy("calendar.taskAnalysis.deselection", fallback: "Deselecting stops new imports and updates to suggestions awaiting review. Approved tasks keep their existing calendar synchronization, including upstream edits and deletions when the source is available on this device. Deselecting never removes external calendar events."))
            }
        }
    }

    private var destinationCalendarSection: some View {
        Section {
            NavigationLink(destination: DefaultCalendarPickerView()) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy("calendar.destination.title", fallback: "Destination Calendar"))
                    if let selectedCalendar {
                        Label {
                            Text("\(selectedCalendar.sourceTitle) · \(selectedCalendar.title)")
                        } icon: {
                            Circle()
                                .fill(CalendarPresentation.color(forCalendarID: selectedCalendar.id))
                                .frame(width: 10, height: 10)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(!isAuthorized
                             ? copy("calendar.permission.needed", fallback: "Calendar access is required")
                             : defaultCalendarID.isEmpty
                                ? copy("calendar.destination.unselected", fallback: "Choose a calendar")
                                : copy("calendar.destination.unavailable", fallback: "Selected calendar is unavailable"))
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    if defaultCalendarID == CalendarService.systemDefaultCalendarID {
                        Text(copy("calendar.destination.systemDefault", fallback: "System Default Calendar"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("calendar.destination.row")

            if let destinationError, isAuthorized {
                Label(destinationError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("calendar.destination.error")
            }
        } footer: {
            Text(copy("calendar.destination.footer", fallback: "Choose a writable calendar before exporting events. This choice is saved only on this device. No calendar is chosen automatically; System Default must also be selected explicitly. Open the row above to choose or replace an unavailable calendar."))
        }
    }

    private var permissionSection: some View {
        Section {
            Label(isAuthorized
                  ? copy("calendar.permission.granted", fallback: "Calendar access is allowed")
                  : copy("calendar.permission.needed", fallback: "Calendar access is required"),
                  systemImage: isAuthorized ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(isAuthorized ? Color.secondary : Color.orange)
                .accessibilityIdentifier("calendar.permission.status")
            if !isAuthorized {
                Button(copy("calendar.permission.request", fallback: "Request Calendar Access")) {
                    isRequestingAccess = true
                    Task { @MainActor in
                        _ = await CalendarService.shared.requestAccess()
                        isRequestingAccess = false
                        refreshState()
                    }
                }
                .disabled(isRequestingAccess)
                .accessibilityIdentifier("calendar.permission.request")
            }
            Link(copy("calendar.permission.openSettings", fallback: "Open App Settings"), destination: URL(string: UIApplication.openSettingsURLString)!)
                .accessibilityIdentifier("calendar.permission.openSettings")
        } header: {
            Text(copy("calendar.permission.section", fallback: "Calendar Access and Accounts"))
        } footer: {
            Text(copy("calendar.permission.accountNotice", fallback: "Add Google, iCloud, or Exchange accounts in your device's system Calendar account settings. SIFT uses those calendars through system permission and does not offer a separate calendar OAuth sign-in. If access was denied, allow it in App Settings."))
        }
    }

    private func refreshState() {
        let service = CalendarService.shared
        service.restoreAuthorizationIfGranted()
        isAuthorized = service.isAuthorized
        defaultCalendarID = service.defaultCalendarID
        taskAnalysisCalendarIDs = service.taskAnalysisCalendarIDs
        if isAuthorized, let calendar = service.preferredDefaultCalendar {
            selectedCalendar = CalendarService.CalendarInfo(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                sourceTitle: calendar.source.title
            )
        } else {
            selectedCalendar = nil
        }
        destinationError = isAuthorized ? service.destinationError : nil
    }

    private func copy(_ key: String, fallback: String) -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "Calendar settings copy.")
    }
}

private struct TaskAnalysisCalendarPickerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedIDs: Set<String> = []
    @State private var sources: [CalendarService.CalendarSourceGroup] = []
    @State private var isAuthorized = false

    private var unavailableSelectedIDs: [String] {
        let availableIDs = Set(sources.flatMap(\.calendars).map(\.id))
        return selectedIDs.subtracting(availableIDs).sorted()
    }

    var body: some View {
        List {
            Section {
                Text(copy("calendar.taskAnalysis.consent", fallback: "Only calendars you explicitly select are used for automatic calendar-to-task import and analysis. Select none to turn both off. This selection is saved only on this device and does not change calendar display or the export destination. Read-only and subscribed calendars can also be selected."))
                    .font(.subheadline)
                if selectedIDs.isEmpty {
                    Text(copy("calendar.taskAnalysis.none", fallback: "None selected — automatic import and analysis are off"))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("calendar.taskAnalysis.none")
                }
            } footer: {
                Text(copy("calendar.taskAnalysis.deselection", fallback: "Deselecting stops new imports and updates to suggestions awaiting review. Approved tasks keep their existing calendar synchronization, including upstream edits and deletions when the source is available on this device. Deselecting never removes external calendar events."))
            }

            if !isAuthorized {
                Section {
                    Label(copy("calendar.permission.needed", fallback: "Calendar access is required"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Link(copy("calendar.permission.openSettings", fallback: "Open App Settings"), destination: URL(string: UIApplication.openSettingsURLString)!)
                }
            } else if sources.isEmpty {
                Section {
                    ContentUnavailableView(copy("calendar.taskAnalysis.empty", fallback: "No Calendars Available"), systemImage: "calendar.badge.exclamationmark")
                }
            }

            ForEach(sources) { source in
                Section(source.title) {
                    ForEach(source.calendars) { calendar in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(CalendarPresentation.color(forCalendarID: calendar.id))
                                .frame(width: 12, height: 12)
                                .accessibilityHidden(true)
                            Toggle(calendar.title, isOn: Binding(
                                get: { selectedIDs.contains(calendar.id) },
                                set: { setCalendar(calendar.id, selected: $0) }
                            ))
                            .accessibilityIdentifier("calendar.taskAnalysis.toggle.\(calendar.id)")
                        }
                    }
                }
            }

            if !unavailableSelectedIDs.isEmpty {
                Section {
                    ForEach(unavailableSelectedIDs, id: \.self) { id in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button(copy("calendar.taskAnalysis.remove", fallback: "Remove Selection")) {
                                setCalendar(id, selected: false)
                            }
                            .accessibilityIdentifier("calendar.taskAnalysis.remove.\(id)")
                        }
                    }
                } header: {
                    Text(copy("calendar.taskAnalysis.unavailable", fallback: "Unavailable Selected Calendars"))
                } footer: {
                    Text(copy("calendar.taskAnalysis.unavailableFooter", fallback: "These saved calendar IDs are not currently accessible. They remain selected unless you remove them explicitly. Restore permission or the calendar account to make them available again; no replacement is selected automatically."))
                }
            }
        }
        .appListStyle()
        .navigationTitle(copy("calendar.taskAnalysis.title", fallback: "Task Analysis Calendars"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refreshCalendars)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshCalendars() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .calendarAuthorizationChanged)) { _ in
            refreshCalendars()
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            refreshCalendars()
        }
        .onReceive(NotificationCenter.default.publisher(for: .calendarTaskAnalysisSourcesChanged)) { _ in
            refreshCalendars()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshCalendars()
        }
    }

    private func setCalendar(_ id: String, selected: Bool) {
        let service = CalendarService.shared
        var ids = service.taskAnalysisCalendarIDs
        if selected { ids.insert(id) }
        else { ids.remove(id) }
        service.taskAnalysisCalendarIDs = ids
        selectedIDs = ids
    }

    private func refreshCalendars() {
        let service = CalendarService.shared
        service.restoreAuthorizationIfGranted()
        isAuthorized = service.isAuthorized
        selectedIDs = service.taskAnalysisCalendarIDs
        sources = service.availableCalendars(writableOnly: false)
    }

    private func copy(_ key: String, fallback: String) -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "Explicit opt-in calendar-to-task analysis settings. Calendar names and saved IDs remain unchanged.")
    }
}
