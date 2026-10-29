#if DEBUG
import SwiftUI
import SwiftData

/// Explicit in-memory QA data; never accesses the user's production stores.
@MainActor
enum MacPresentationQA {
    static var isEnabled: Bool {
        Bundle.main.bundleIdentifier == "pieroot.sift-todo.qa"
            && ProcessInfo.processInfo.arguments.contains("-ui-test-in-memory-store")
            && ProcessInfo.processInfo.arguments.contains("-ui-test-mac-presentation")
    }

    static var colorScheme: ColorScheme? {
        guard isEnabled else { return nil }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-ui-test-appearance-dark") { return .dark }
        if args.contains("-ui-test-appearance-light") { return .light }
        return nil
    }

    static func seed(into container: ModelContainer) {
        guard isEnabled else { return }
        let context = container.mainContext
        let now = Date()
        let active = Todo(title: "발표 자료 검토", notes: "수정안과 일정 확인", dueDate: now.addingTimeInterval(86_400))
        let overdue = Todo(title: "보고서 보내기", dueDate: now.addingTimeInterval(-86_400))
        let review = Todo(title: "다음 회의 준비", dueDate: now.addingTimeInterval(3 * 86_400))
        review.triageStatus = TodoTriage.review.rawValue
        for todo in [active, overdue, review] { context.insert(todo) }
        do { try context.save() }
        catch { assertionFailure("Presentation QA fixture failed") }
    }

    /// Display-only, never a persistence backend or a simulated EventKit success.
    static func calendarEvents(calendar: Calendar) -> [CalendarService.CalendarEventSummary] {
        guard isEnabled, ProcessInfo.processInfo.arguments.contains("-ui-test-calendar-interaction-display") else { return [] }
        let day = calendar.startOfDay(for: Date())
        return [(10, 0, 45, "QA 시간 가장자리"), (11, 0, 60, "QA 우클릭 옵션"), (23, 55, 5, "QA 자정 경계")].map { hour, minute, duration, title in
            let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
            return CalendarService.CalendarEventSummary(title: title, startDate: start,
                endDate: start.addingTimeInterval(Double(duration * 60)), isRecurring: false, isAllDay: false,
                identifier: "qa-timeline-\(hour)", calendarTitle: "Display-only QA", calendarID: "qa-timeline")
        }
    }

}
#endif
