import Testing
@testable import todo

@Suite("App tutorial flow")
struct AppTutorialFlowTests {
    @Test("sequence omits optional steps when features are unavailable")
    func sequenceWithoutOptionalSteps() {
        let steps = AppTutorialStep.sequence(calendarEnabled: false, mailEnabled: false)

        #expect(steps.contains(.calendarEnabled) == false)
        #expect(steps.contains(.mailEnabled) == false)
        #expect(steps.last == .autoSort)
    }

    @Test("sequence inserts calendar before mail and keeps auto sort last")
    func sequenceWithOptionalSteps() {
        let steps = AppTutorialStep.sequence(calendarEnabled: true, mailEnabled: true)

        let calendarIndex = steps.firstIndex(of: .calendarEnabled)
        let mailIndex = steps.firstIndex(of: .mailEnabled)
        #expect(calendarIndex != nil)
        #expect(mailIndex != nil)
        if let calendarIndex, let mailIndex {
            #expect(calendarIndex < mailIndex)
        }
        #expect(steps.last == .autoSort)
    }

    @Test("tab clamping falls back to todo when hidden")
    func clampedWhenOnlyTodoVisible() {
        let visibility = AppTabVisibility(calendarVisible: false, mailVisible: false)

        #expect(visibility.clamped(0) == 0)
        #expect(visibility.clamped(1) == 0)
        #expect(visibility.clamped(2) == 0)
    }

    @Test("tab clamping keeps calendar but hides mail when needed")
    func clampedWhenCalendarVisibleOnly() {
        let visibility = AppTabVisibility(calendarVisible: true, mailVisible: false)

        #expect(visibility.clamped(1) == 1)
        #expect(visibility.clamped(2) == 0)
    }

    @Test("tab clamping keeps mail but hides calendar when needed")
    func clampedWhenMailVisibleOnly() {
        let visibility = AppTabVisibility(calendarVisible: false, mailVisible: true)

        #expect(visibility.clamped(1) == 0)
        #expect(visibility.clamped(2) == 2)
    }
    @Test("legacy search tab selection falls back to to-do")
    func clampedLegacySearchTabFallsBackToTodo() {
        let visibilityNoOptional = AppTabVisibility(calendarVisible: false, mailVisible: false)
        let visibilityAllOptional = AppTabVisibility(calendarVisible: true, mailVisible: true)

        #expect(visibilityNoOptional.clamped(4) == AppTabID.todo.rawValue)
        #expect(visibilityAllOptional.clamped(4) == AppTabID.todo.rawValue)
    }

    @Test("mail tutorial advances after viewing mail then returning to todo")
    @MainActor
    func mailTutorialAdvancesAfterReturningToTodo() {
        let tutorial = AppTutorialState()
        tutorial.start(tabVisibility: AppTabVisibility(calendarVisible: true, mailVisible: true))

        tutorial.handleAddTodoDismissed()
        tutorial.handlePersonaDetailClosed()
        tutorial.handlePriorityRulesDetailClosed()
        tutorial.handleEmailDetailClosed()
        tutorial.handlePermissionsClosed()
        #expect(tutorial.currentStep == .calendarEnabled)

        tutorial.handleCalendarTabAppeared()
        tutorial.handleTodoListAppeared()
        #expect(tutorial.currentStep == .mailEnabled)

        tutorial.handleMailTabAppeared()
        tutorial.handleTodoListAppeared()
        #expect(tutorial.currentStep == .autoSort)
    }

    @Test("calendar tutorial advances after viewing calendar then returning to todo")
    @MainActor
    func calendarTutorialAdvancesAfterReturningToTodo() {
        let tutorial = AppTutorialState()
        tutorial.start(tabVisibility: AppTabVisibility(calendarVisible: true, mailVisible: false))

        tutorial.handleAddTodoDismissed()
        tutorial.handlePersonaDetailClosed()
        tutorial.handlePriorityRulesDetailClosed()
        tutorial.handleEmailDetailClosed()
        tutorial.handlePermissionsClosed()
        #expect(tutorial.currentStep == .calendarEnabled)

        tutorial.handleCalendarTabAppeared()
        tutorial.handleTodoListAppeared()
        #expect(tutorial.currentStep == .autoSort)
    }
    @Test("closing shared to-do settings does not skip priority rules")
    @MainActor
    func closingTodoSettingsDoesNotSkipPriorityRules() {
        let tutorial = AppTutorialState()
        tutorial.start(tabVisibility: AppTabVisibility(calendarVisible: false, mailVisible: false))
        tutorial.handleAddTodoDismissed()
        tutorial.handlePersonaDetailClosed()

        #expect(tutorial.currentStep == .priorityRules)
        tutorial.handlePermissionsClosed()
        #expect(tutorial.currentStep == .priorityRules)
        tutorial.handlePriorityRulesDetailClosed()
        #expect(tutorial.currentStep == .emailOptional)
    }

    @Test("notification permission remains optional in to-do settings")
    @MainActor
    func notificationsCanBeSkippedInTodoSettings() {
        let tutorial = AppTutorialState()
        tutorial.start(tabVisibility: AppTabVisibility(calendarVisible: false, mailVisible: false))
        tutorial.handleAddTodoDismissed()
        tutorial.handlePersonaDetailClosed()
        tutorial.handlePriorityRulesDetailClosed()
        tutorial.handleEmailDetailClosed()

        #expect(tutorial.currentStep == .permissions)
        tutorial.handlePermissionsClosed()
        #expect(tutorial.currentStep == .autoSort)
        #expect(tutorial.isActive)
    }
}
