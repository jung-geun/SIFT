import Foundation
import SwiftData

extension CalendarService {
    /// The selected occurrence before a user action and the identity actually committed by EventKit.
    struct CommittedMutation {
        let original: CalendarEventSummary
        let saved: CalendarEventSummary?
        let scope: CalendarRecurrenceScope
        let calendar: Calendar

        init(original: CalendarEventSummary, saved: CalendarEventSummary?, scope: CalendarRecurrenceScope,
             calendar: Calendar = .current) {
            self.original = original
            self.saved = saved
            self.scope = scope
            self.calendar = calendar
        }

        @MainActor
        func reconcileExisting(in context: ModelContext) throws {
            let identifier = original.identifier
            let sourceID = original.calendarID
            let descriptor = FetchDescriptor<Todo>(predicate: #Predicate {
                $0.calendarEventID == identifier && ($0.calendarSourceID.isEmpty || $0.calendarSourceID == sourceID)
            })
            let todos = try context.fetch(descriptor)
            let iso = ISO8601DateFormatter()
            for todo in todos {
                guard todo.calendarEventID == original.identifier,
                      todo.calendarSourceID.isEmpty || todo.calendarSourceID == original.calendarID else { continue }
                let recordedStart = todo.sourceRef.split(separator: "#").last.flatMap { iso.date(from: String($0)) }
                let occurrenceStart = todo.todoSource == .calendar ? recordedStart ?? todo.scheduleAnchor : todo.scheduleAnchor
                if original.isRecurring {
                    guard let occurrenceStart else { continue }
                    switch scope {
                    case .thisEvent: guard abs(occurrenceStart.timeIntervalSince(original.startDate)) < 1 else { continue }
                    case .futureEvents: guard occurrenceStart >= original.startDate.addingTimeInterval(-1) else { continue }
                    case .allEvents: break
                    }
                }
                guard let saved else {
                    if todo.todoSource == .calendar && !todo.isCompleted {
                        TaskBehaviorRecorder.recordDeletion(of: todo, actor: .calendarSync, in: context)
                        context.delete(todo)
                    } else {
                        todo.calendarEventID = nil
                        if todo.todoSource == .calendar {
                            todo.calendarEventExternalID = ""
                        } else if todo.calendarEventExternalID.isEmpty {
                            // A deleted export is not a never-exported task. The
                            // durable UID keeps ordinary sync from recreating it.
                            todo.calendarEventExternalID = original.externalIdentifier
                        }
                        todo.calendarSourceID = ""
                        todo.calendarSyncedTitle = ""
                    }
                    continue
                }
                let start: Date
                let end: Date
                if original.isRecurring, scope != .thisEvent, let occurrenceStart,
                   abs(occurrenceStart.timeIntervalSince(original.startDate)) >= 1 {
                    let range = CalendarService.shiftedSeriesRange(seriesStart: occurrenceStart, seriesEnd: occurrenceStart,
                        occurrenceStart: original.startDate, occurrenceEnd: original.startDate,
                        newStart: saved.startDate, newEnd: saved.endDate, calendar: calendar)
                    start = original.startDate == saved.startDate ? todo.startDate ?? range.start : range.start
                    end = original.endDate == saved.endDate ? todo.dueDate ?? range.end : range.end
                } else {
                    start = saved.startDate
                    end = saved.endDate
                }
                let previousDueDate = todo.dueDate
                let window = todo.todoSource == .calendar
                    ? CalendarService.todoWindow(eventStart: start, eventEnd: end, isAllDay: saved.isAllDay)
                    : CalendarService.adoptedTodoWindow(todoStart: todo.startDate, todoDue: todo.dueDate,
                        eventStart: start, eventEnd: end, isAllDay: saved.isAllDay)
                if let window {
                    todo.startDate = window.startDate
                    todo.dueDate = window.dueDate
                }
                if CalendarService.shouldAdoptCalendarTitle(todoTitle: todo.title,
                    syncedBaseline: todo.calendarSyncedTitle, eventTitle: saved.title) {
                    todo.title = saved.title
                }
                todo.calendarSyncedTitle = saved.title
                todo.calendarEventID = saved.identifier
                todo.calendarEventExternalID = saved.externalIdentifier
                todo.calendarSourceID = saved.calendarID
                todo.isFixedSchedule = saved.isRecurring
                if todo.todoSource == .calendar {
                    let key = saved.externalIdentifier.isEmpty ? saved.identifier : saved.externalIdentifier
                    todo.sourceRef = "\(key)#\(iso.string(from: start))"
                }
                todo.updatedAt = Date()
                if previousDueDate != todo.dueDate {
                    TaskBehaviorRecorder.recordDueDateChange(of: todo, from: previousDueDate, to: todo.dueDate,
                        actor: original.isRecurring ? .recurrence : .calendarSync, in: context)
                }
            }
            try context.save()
        }
    }
}
