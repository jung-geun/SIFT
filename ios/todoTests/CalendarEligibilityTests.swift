import Foundation
import Testing
@testable import todo

struct CalendarEligibilityTests {
    @Test("review manual, email, and meeting todos are not automatic calendar candidates")
    @MainActor
    func reviewTodosAreRejectedGlobally() {
        for source in [TodoSource.manual, .email, .meeting] {
            let todo = Todo(
                title: "Review",
                dueDate: Date(timeIntervalSinceReferenceDate: 800_000_000),
                source: source
            )
            todo.triageStatus = TodoTriage.review.rawValue

            #expect(!CalendarService.isAutomaticRegistrationCandidate(
                todo, autoEnabled: true, sourceFilter: "all"
            ))
        }
    }

    @Test("disabled automatic registration rejects every priority, including urgent and critical")
    @MainActor
    func disabledAutoRejectsEveryPriority() {
        let todo = Todo(
            title: "Scheduled",
            dueDate: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        #expect(CalendarService.isAutomaticRegistrationCandidate(
            todo, autoEnabled: true, sourceFilter: "all"
        ))
        #expect(!CalendarService.isAutomaticRegistrationCandidate(
            todo, autoEnabled: false, sourceFilter: "all"
        ))

        for priority in TodoPriority.allCases {
            todo.manualPriority = priority.rawValue
            #expect(CalendarService.isAutomaticRegistrationCandidate(
                todo, autoEnabled: true, sourceFilter: "all"
            ))
            #expect(!CalendarService.isAutomaticRegistrationCandidate(
                todo, autoEnabled: false, sourceFilter: "all"
            ))
        }
    }

    @Test("enabled automatic registration excludes imported, completed, and undated todos")
    @MainActor
    func enabledAutoRejectsIneligibleTodos() {
        let due = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let imported = Todo(title: "Imported", dueDate: due, source: .calendar)
        let completed = Todo(title: "Completed", dueDate: due)
        completed.isCompleted = true
        let undated = Todo(title: "Undated")

        for todo in [imported, completed, undated] {
            todo.manualPriority = TodoPriority.critical.rawValue
            #expect(!CalendarService.isAutomaticRegistrationCandidate(
                todo, autoEnabled: true, sourceFilter: "all"
            ))
        }
    }

    @Test("health source references are excluded by case-insensitive prefix only")
    @MainActor
    func healthPrefixIsExcluded() {
        let todo = Todo(
            title: "Health routine",
            dueDate: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        todo.manualPriority = TodoPriority.critical.rawValue
        for sourceRef in ["health:workout", "HEALTH:sleep", "HeAlTh:medication"] {
            todo.sourceRef = sourceRef
            #expect(!CalendarService.isAutomaticRegistrationCandidate(
                todo, autoEnabled: true, sourceFilter: "all"
            ))
        }
        todo.sourceRef = "message-health:workout"
        #expect(CalendarService.isAutomaticRegistrationCandidate(
            todo, autoEnabled: true, sourceFilter: "all"
        ))
    }

    @Test("durable health origin blocks automatic export when the source reference is stale")
    @MainActor
    func healthOriginIsExcludedWithoutHealthPrefix() {
        for sourceRef in ["", "sift-calendar://todo/restored"] {
            let todo = Todo(
                title: "Recovered health routine",
                dueDate: Date(timeIntervalSinceReferenceDate: 800_000_000),
                sourceRef: sourceRef
            )
            todo.calendarEventOrigin = CalendarEventOrigin.siftHealth.rawValue
            todo.manualPriority = TodoPriority.critical.rawValue
            #expect(todo.isHealthRelated)
            #expect(todo.hasLocalOnlySourceContent)
            for sourceFilter in ["all", "manual"] {
                #expect(!CalendarService.isAutomaticRegistrationCandidate(
                    todo, autoEnabled: true, sourceFilter: sourceFilter
                ))
            }
        }
    }

    @Test("enabled automatic registration honors all and exact source filters")
    @MainActor
    func sourceFilterSelectsOnlyMatchingSources() {
        for source in [TodoSource.manual, .email, .meeting] {
            let todo = Todo(
                title: "Scheduled",
                dueDate: Date(timeIntervalSinceReferenceDate: 800_000_000),
                source: source
            )
            for filter in ["all", "manual", "email", "meeting", "calendar"] {
                let expected = filter == "all" || filter == source.rawValue
                #expect(CalendarService.isAutomaticRegistrationCandidate(
                    todo, autoEnabled: true, sourceFilter: filter
                ) == expected)
            }
        }
    }

    @Test("calendar analysis is an exact ID allowlist without title or ownership exemptions")
    @MainActor
    func taskAnalysisEventsRequireExplicitCalendarSelection() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let marker = CalendarEventMarker(entity: .todo, identifier: UUID(), origin: .siftManual)
        let markers: [CalendarEventMarker?] = [nil, marker]
        for calendarTitle in ["RTX6000", "Holidays", "대한민국의 휴일", "Work"] {
            for marker in markers {
                let event = CalendarService.CalendarEventSummary(
                    title: "SIFT task from \(calendarTitle)",
                    startDate: start,
                    endDate: start.addingTimeInterval(3_600),
                    isRecurring: false,
                    isAllDay: false,
                    identifier: "event",
                    marker: marker,
                    calendarTitle: calendarTitle,
                    calendarID: "explicit-calendar"
                )
                #expect(CalendarService.isTaskAnalysisEvent(event, selectedCalendarIDs: ["explicit-calendar"]))
                #expect(!CalendarService.isTaskAnalysisEvent(event, selectedCalendarIDs: []))
                #expect(!CalendarService.isTaskAnalysisEvent(event, selectedCalendarIDs: ["other-calendar"]))
                #expect(!CalendarService.isTaskAnalysisEvent(event, selectedCalendarIDs: [calendarTitle]))
            }
        }
    }

    @Test("imported task analysis requires its observed device-local source ID, not ownership or event IDs")
    @MainActor
    func importedTaskAnalysisFailsClosedForUnselectedAndLegacySources() {
        let imported = Todo(title: "Imported", source: .calendar, sourceRef: "selected-calendar#occurrence")
        imported.calendarEventID = "selected-calendar"
        imported.calendarEventExternalID = "selected-calendar"
        imported.calendarEventOrigin = CalendarEventOrigin.siftManual.rawValue
        #expect(!CalendarService.isTaskAnalysisTodo(imported, selectedCalendarIDs: ["selected-calendar"]))

        imported.calendarSourceID = "selected-calendar"
        #expect(CalendarService.isTaskAnalysisTodo(imported, selectedCalendarIDs: ["selected-calendar"]))
        #expect(!CalendarService.isTaskAnalysisTodo(imported, selectedCalendarIDs: []))
        #expect(!CalendarService.isTaskAnalysisTodo(imported, selectedCalendarIDs: ["replacement-calendar"]))

        for source in [TodoSource.manual, .email, .meeting] {
            let independent = Todo(title: "Independent", source: source)
            independent.calendarSourceID = "excluded-calendar"
            #expect(CalendarService.isTaskAnalysisTodo(independent, selectedCalendarIDs: []))
        }
    }

    @Test("analysis opt-in persists separately from calendar display and writable export preferences")
    @MainActor
    func taskAnalysisSelectionHasIndependentPersistence() throws {
        let suiteName = "CalendarEligibilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let displayKey = "pieroot.todo.disabledCalendarIDs"
        let exportKey = "pieroot.todo.defaultCalendarID"
        let weeklyKey = "pieroot.todo.lastCalendarImportDate"
        defaults.set(["hidden-calendar"], forKey: displayKey)
        defaults.set("export-only-calendar", forKey: exportKey)
        defaults.set(123_456.0, forKey: weeklyKey)

        // Neither visible calendars nor an existing export destination imply consent.
        #expect(CalendarService.taskAnalysisCalendarIDs(defaults: defaults).isEmpty)
        #expect(defaults.object(forKey: CalendarService.taskAnalysisCalendarIDsKey) == nil)
        #expect(defaults.double(forKey: weeklyKey) == 123_456.0)
        #expect(!CloudPreferenceStore.isUserPreference(CalendarService.taskAnalysisCalendarIDsKey))

        let selected: Set<String> = ["hidden-calendar", "read-only-source", "unavailable-calendar-id"]
        CalendarService.setTaskAnalysisCalendarIDs(selected, defaults: defaults)
        #expect(CalendarService.taskAnalysisCalendarIDs(defaults: defaults) == selected)
        #expect(Set(defaults.stringArray(forKey: CalendarService.taskAnalysisCalendarIDsKey) ?? []) == selected)
        #expect(defaults.double(forKey: weeklyKey) == 0)
        #expect(defaults.stringArray(forKey: displayKey) == ["hidden-calendar"])
        #expect(defaults.string(forKey: exportKey) == "export-only-calendar")

        // Saving the same set again must not continually invalidate the weekly throttle.
        defaults.set(654_321.0, forKey: weeklyKey)
        CalendarService.setTaskAnalysisCalendarIDs(selected, defaults: defaults)
        #expect(defaults.double(forKey: weeklyKey) == 654_321.0)

        // Display and export changes do not add or remove analysis sources.
        defaults.set(["read-only-source"], forKey: displayKey)
        defaults.set(CalendarService.systemDefaultCalendarID, forKey: exportKey)
        #expect(CalendarService.taskAnalysisCalendarIDs(defaults: defaults) == selected)
        CalendarService.setTaskAnalysisCalendarIDs([], defaults: defaults)
        #expect(CalendarService.taskAnalysisCalendarIDs(defaults: defaults).isEmpty)
        #expect(defaults.double(forKey: weeklyKey) == 0)
        #expect(defaults.stringArray(forKey: displayKey) == ["read-only-source"])
        #expect(defaults.string(forKey: exportKey) == CalendarService.systemDefaultCalendarID)
    }
}
