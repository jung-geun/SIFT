import Foundation

extension Notification.Name {
    static let appTutorialRequested = Notification.Name("pieroot.todo.appTutorialRequested")
    static let settingsRequested = Notification.Name("pieroot.todo.settingsRequested")
    static let settingsDismissRequested = Notification.Name("pieroot.todo.settingsDismissRequested")
    static let calendarAuthorizationChanged = Notification.Name("pieroot.todo.calendarAuthorizationChanged")
    static let calendarTaskAnalysisSourcesChanged = Notification.Name("pieroot.todo.calendarTaskAnalysisSourcesChanged")
    static let tutorialRunPrioritizeRequested = Notification.Name("pieroot.todo.tutorialRunPrioritizeRequested")
}
