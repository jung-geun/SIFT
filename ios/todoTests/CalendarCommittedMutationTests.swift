import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Explicit calendar mutation links")
@MainActor
struct CalendarCommittedMutationTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func context() throws -> ModelContext {
        let configuration = ModelConfiguration(schema: AppDataContainer.appSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppDataContainer.appSchema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }
    private func event(id: String = "original", start: Date, recurring: Bool = false) -> CalendarService.CalendarEventSummary {
        .init(title: "Original", startDate: start, endDate: start.addingTimeInterval(3600),
              isRecurring: recurring, isAllDay: false, identifier: id, externalIdentifier: "uid", calendarTitle: "Synthetic", calendarID: "source")
    }
    private func imported(start: Date, recurring: Bool = false) -> Todo {
        let todo = Todo(title: "Local title", notes: "Local notes", startDate: start, dueDate: start.addingTimeInterval(3600), source: .calendar)
        todo.calendarEventID = "original"
        todo.calendarSourceID = "source"
        todo.calendarEventExternalID = "uid"
        todo.calendarSyncedTitle = "Original"
        todo.sourceRef = "uid#\(ISO8601DateFormatter().string(from: start))"
        todo.isFixedSchedule = recurring
        todo.triageStatus = TodoTriage.review.rawValue
        return todo
    }

    @Test("Past imported tasks update immediately, retain local fields, and do not create new imports")
    func pastResizeAndNoNewImport() throws {
        let context = try context()
        let linked = imported(start: base)
        linked.tags = ["keep"]
        context.insert(linked)
        try context.save()
        let original = event(start: base)
        let saved = event(id: "detached", start: base.addingTimeInterval(1800))
        try CalendarService.CommittedMutation(original: original, saved: saved, scope: .thisEvent).reconcileExisting(in: context)
        #expect(linked.startDate == saved.startDate)
        #expect(linked.dueDate == saved.endDate)
        #expect(linked.calendarEventID == "detached")
        #expect(linked.title == "Local title" && linked.notes == "Local notes" && linked.tags == ["keep"])
        #expect(linked.triage == .review && !linked.isCompleted)
        let unrelated = event(id: "not-linked", start: base)
        try CalendarService.CommittedMutation(original: unrelated, saved: unrelated, scope: .thisEvent).reconcileExisting(in: context)
        #expect(try context.fetch(FetchDescriptor<Todo>()).map(\.id) == [linked.id])
    }

    @Test("Deleting an imported past event removes its block but preserves manual tasks and completed history")
    func deletePreservesIndependentWork() throws {
        let context = try context()
        let imported = imported(start: base)
        let completed = self.imported(start: base)
        completed.isCompleted = true
        let manual = Todo(title: "Independent", startDate: base, dueDate: base.addingTimeInterval(3600))
        manual.calendarEventID = "original"
        for todo in [imported, completed, manual] { context.insert(todo) }
        try context.save()
        try CalendarService.CommittedMutation(original: event(start: base), saved: nil, scope: .thisEvent).reconcileExisting(in: context)
        let remaining = try context.fetch(FetchDescriptor<Todo>())
        #expect(Set(remaining.map(\.id)) == [completed.id, manual.id])
        #expect(completed.isCompleted && completed.calendarEventID == nil)
        #expect(manual.title == "Independent" && manual.calendarEventID == nil && manual.startDate == base)
    }

    @Test("Explicit deletion retains the durable reference so automatic export cannot recreate the event",
          arguments: [TodoSource.manual, TodoSource.email], [true, false])
    func deletedEventCannotBecomeANewExport(source: TodoSource, hadStoredUID: Bool) throws {
        let context = try context()
        let todo = Todo(title: "Keep independent task", notes: "Keep notes", startDate: base,
            dueDate: base.addingTimeInterval(3600), source: source)
        todo.calendarEventID = "original"
        todo.calendarEventExternalID = hadStoredUID ? "uid" : ""
        context.insert(todo)
        try context.save()
        #expect(CalendarService.isAutomaticRegistrationCandidate(todo, autoEnabled: true, sourceFilter: "all"))
        try CalendarService.CommittedMutation(original: event(start: base), saved: nil, scope: .thisEvent)
            .reconcileExisting(in: context)
        #expect(todo.calendarEventID == nil)
        #expect(todo.calendarEventExternalID == "uid")
        #expect(throws: CalendarError.ownershipNotVerified) {
            try CalendarService.selectOwnedEvent(for: todo, candidates: [])
        }
        #expect(todo.title == "Keep independent task" && todo.notes == "Keep notes")
        #expect(todo.dueDate == base.addingTimeInterval(3600) && !todo.isCompleted)
    }

    @Test("Occurrence scope uses recorded provenance despite locally edited task dates and isolates other calendars")
    func exactOccurrenceAndSource() throws {
        let context = try context()
        let previous = imported(start: base, recurring: true)
        let selected = imported(start: base.addingTimeInterval(86400), recurring: true)
        selected.startDate = base.addingTimeInterval(7 * 86400)
        let next = imported(start: base.addingTimeInterval(2 * 86400), recurring: true)
        let otherSource = imported(start: base.addingTimeInterval(86400), recurring: true)
        otherSource.calendarSourceID = "other-source"
        for todo in [previous, selected, next, otherSource] { context.insert(todo) }
        try context.save()
        let original = event(start: base.addingTimeInterval(86400), recurring: true)
        let saved = event(id: "detached", start: original.startDate.addingTimeInterval(900))
        try CalendarService.CommittedMutation(original: original, saved: saved, scope: .thisEvent).reconcileExisting(in: context)
        #expect(selected.startDate == saved.startDate && selected.calendarEventID == "detached")
        #expect(previous.startDate == base && previous.calendarEventID == "original")
        #expect(next.startDate == base.addingTimeInterval(2 * 86400) && next.calendarEventID == "original")
        #expect(otherSource.calendarEventID == "original" && otherSource.startDate == original.startDate)
    }

    @Test("Future scope deletes only existing selected and later links without touching earlier occurrences")
    func futureScope() throws {
        let context = try context()
        let previous = imported(start: base, recurring: true)
        let selected = imported(start: base.addingTimeInterval(86400), recurring: true)
        let next = imported(start: base.addingTimeInterval(2 * 86400), recurring: true)
        for todo in [previous, selected, next] { context.insert(todo) }
        try context.save()
        try CalendarService.CommittedMutation(original: event(start: selected.startDate!, recurring: true), saved: nil, scope: .futureEvents).reconcileExisting(in: context)
        #expect(try context.fetch(FetchDescriptor<Todo>()).map(\.id) == [previous.id])
    }

    @Test("All-series linked updates retain both requested civil endpoints across the spring DST gap")
    func allSeriesDaylightSavingEndpoints() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func date(_ month: Int, _ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }
        let context = try context()
        let linked = imported(start: date(1, 1, 1), recurring: true)
        linked.dueDate = date(1, 1, 4)
        context.insert(linked)
        try context.save()
        let original = CalendarService.CalendarEventSummary(title: "Original", startDate: date(3, 8, 1),
            endDate: date(3, 8, 4), isRecurring: true, isAllDay: false,
            identifier: "original", calendarTitle: "Synthetic", calendarID: "source")
        let saved = CalendarService.CalendarEventSummary(title: "Original", startDate: date(3, 8, 3),
            endDate: date(3, 8, 4), isRecurring: true, isAllDay: false,
            identifier: "original", calendarTitle: "Synthetic", calendarID: "source")
        try CalendarService.CommittedMutation(original: original, saved: saved, scope: .allEvents,
            calendar: calendar).reconcileExisting(in: context)
        #expect(linked.startDate == date(1, 1, 3))
        #expect(linked.dueDate == date(1, 1, 4))
    }

    @Test("Metadata-only whole-series edits preserve the selected occurrence's exact repeated-hour endpoint",
          arguments: ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z"])
    func selectedRepeatedHourMetadata(endText: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let iso = ISO8601DateFormatter()
        let start = iso.date(from: "2026-11-01T05:00:00Z")!
        let end = iso.date(from: endText)!
        let context = try context()
        let linked = imported(start: start, recurring: true)
        linked.dueDate = end
        context.insert(linked)
        try context.save()
        let original = CalendarService.CalendarEventSummary(title: "Original", startDate: start, endDate: end,
            isRecurring: true, isAllDay: false, identifier: "original", calendarTitle: "Synthetic", calendarID: "source")
        let saved = CalendarService.CalendarEventSummary(title: "Renamed", startDate: start, endDate: end,
            isRecurring: true, isAllDay: false, identifier: "original", calendarTitle: "Synthetic", calendarID: "source")
        try CalendarService.CommittedMutation(original: original, saved: saved, scope: .allEvents,
            calendar: calendar).reconcileExisting(in: context)
        #expect(linked.startDate == start)
        #expect(linked.dueDate == end)
        #expect(linked.title == "Renamed")
    }
}
