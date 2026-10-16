import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Calendar service", .serialized)
struct CalendarServiceTests {
    @Test("unresolvable email artifacts preserve the cross-device identifier")
    @MainActor
    func unresolvableEmailArtifactsPreserveExternalIdentifier() {
        let todo = Todo(
            title: "CalendarServiceTests",
            source: .email,
            sourceRef: "CalendarServiceTests.\(UUID().uuidString)"
        )
        todo.calendarEventExternalID = "external.\(UUID().uuidString)"

        #expect(!CalendarService.shared.removeEmailCalendarArtifacts(for: todo))
        #expect(todo.calendarEventID == nil)
        #expect(todo.calendarEventExternalID.hasPrefix("external."))
    }

    @Test("stale local email identifiers preserve all calendar references")
    @MainActor
    func staleLocalEmailIdentifiersDoNotClearReferences() {
        let todo = Todo(
            title: "CalendarServiceTests",
            source: .email,
            sourceRef: "CalendarServiceTests.\(UUID().uuidString)"
        )
        let staleEventID = UUID().uuidString
        let externalID = "external.\(UUID().uuidString)"
        todo.calendarEventID = staleEventID
        todo.calendarEventExternalID = externalID

        #expect(!CalendarService.shared.removeEmailCalendarArtifacts(for: todo))
        #expect(todo.calendarEventID == staleEventID)
        #expect(todo.calendarEventExternalID == externalID)
    }

    @Test("email mapping reconciliation removes stale identifiers and stores replacements")
    func emailMappingReconciliationUpdatesOnlyTargetReference() {
        let mapping = ["message-1": "stale-event", "message-2": "active-event"]

        let removed = CalendarService.reconciledEmailEventMapping(
            mapping,
            for: "message-1",
            resolvedIdentifier: nil
        )
        let replaced = CalendarService.reconciledEmailEventMapping(
            removed,
            for: "message-1",
            resolvedIdentifier: "current-event"
        )

        #expect(removed["message-1"] == nil)
        #expect(removed["message-2"] == "active-event")
        #expect(replaced["message-1"] == "current-event")
        #expect(replaced["message-2"] == "active-event")
    }

    @Test("versioned SIFT event marker preserves ownership across installations")
    func versionedMarkerRoundTripsOwnership() {
        let identifier = UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A")!
        let url = CalendarEventMarker.url(
            entity: .todo,
            identifier: identifier,
            origin: .siftRecommendation
        )
        let marker = CalendarEventMarker.parse(url)

        #expect(marker?.entity == .todo)
        #expect(marker?.identifier == identifier)
        #expect(marker?.origin == .siftRecommendation)
    }

    @Test("legacy SIFT marker is restored as SIFT-owned rather than external")
    func legacyMarkerRetainsOwnership() {
        let identifier = UUID(uuidString: "B31BE1ED-BC94-49B0-BD8F-B389D16457E1")!
        let url = URL(string: "sift-todo://todo/\(identifier.uuidString)")

        let marker = CalendarEventMarker.parse(url)

        #expect(marker?.entity == .todo)
        #expect(marker?.identifier == identifier)
        #expect(marker?.origin == .siftManual)
    }

    @Test("calendar origin preserves external import and explicit SIFT recommendation")
    @MainActor
    func calendarOriginUsesStoredOrSafeInferredValue() {
        let imported = Todo(title: "Imported", source: .calendar)
        imported.aiRecommendedTime = Date()
        let recommended = Todo(title: "Recommended")
        recommended.aiRecommendedTime = Date()
        let recovered = Todo(title: "Recovered")
        recovered.calendarEventOrigin = CalendarEventOrigin.siftMeeting.rawValue

        #expect(imported.calendarOrigin == .externalCalendar)
        #expect(recommended.calendarOrigin == .siftRecommendation)
        #expect(recovered.calendarOrigin == .siftMeeting)
    }

    @Test("Firebase snapshot keeps calendar event provenance")
    @MainActor
    func firebaseSnapshotRoundTripsCalendarProvenance() throws {
        let sourceConfiguration = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let sourceContainer = try ModelContainer(
            for: AppDataContainer.appSchema,
            configurations: [sourceConfiguration]
        )
        let sourceContext = ModelContext(sourceContainer)
        let todo = Todo(title: "Recommendation")
        todo.calendarEventOrigin = CalendarEventOrigin.siftRecommendation.rawValue
        todo.calendarSyncedTitle = "Synced calendar title"
        sourceContext.insert(todo)
        try sourceContext.save()

        let json = try FirebaseSnapshotStore.exportJSON(context: sourceContext)

        let targetConfiguration = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let targetContainer = try ModelContainer(
            for: AppDataContainer.appSchema,
            configurations: [targetConfiguration]
        )
        let targetContext = ModelContext(targetContainer)
        try FirebaseSnapshotStore.importJSON(json, context: targetContext)

        let restored = try #require(
            targetContext.fetch(FetchDescriptor<Todo>()).first
        )
        #expect(restored.calendarOrigin == .siftRecommendation)
        #expect(restored.calendarSyncedTitle == "Synced calendar title")
    }

    @Test("Calendar title adoption respects the local rename baseline")
    func calendarTitleAdoptionRespectsBaseline() {
        // 사용자가 로컬에서 이름을 바꿨고 이벤트는 그대로 → 덮어쓰지 않는다
        #expect(CalendarService.shouldAdoptCalendarTitle(todoTitle: "내 이름", syncedBaseline: "정기 미팅", eventTitle: "정기 미팅") == false)
        // 캘린더 쪽이 실제로 바뀜 → 채택
        #expect(CalendarService.shouldAdoptCalendarTitle(todoTitle: "내 이름", syncedBaseline: "정기 미팅", eventTitle: "정기 미팅(변경)") == true)
        // 이미 같은 값 → 변경 없음
        #expect(CalendarService.shouldAdoptCalendarTitle(todoTitle: "정기 미팅", syncedBaseline: "정기 미팅", eventTitle: "정기 미팅") == false)
        // 기준선 없는 이전 버전 데이터 → 1회 채택
        #expect(CalendarService.shouldAdoptCalendarTitle(todoTitle: "내 이름", syncedBaseline: "", eventTitle: "정기 미팅") == true)
    }

    @Test("deleted imported occurrence removes only its active calendar Todo")
    @MainActor
    func missingImportedOccurrenceReconciliationIsScoped() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let kept = Todo(
            title: "Kept",
            dueDate: now.addingTimeInterval(3_600),
            source: .calendar,
            sourceRef: "calendar-id#kept"
        )
        let missing = Todo(
            title: "Missing",
            dueDate: now.addingTimeInterval(7_200),
            source: .calendar,
            sourceRef: "calendar-id#missing"
        )
        let completed = Todo(
            title: "Completed",
            dueDate: now.addingTimeInterval(10_800),
            source: .calendar,
            sourceRef: "calendar-id#completed"
        )
        completed.isCompleted = true
        let outsideWindow = Todo(
            title: "Later",
            dueDate: now.addingTimeInterval(31 * 86_400),
            source: .calendar,
            sourceRef: "calendar-id#later"
        )
        let pastOccurrence = Todo(
            title: "Still Active in Calendar",
            dueDate: now.addingTimeInterval(-3_600),
            source: .calendar,
            sourceRef: "calendar-id#past"
        )
        let manual = Todo(
            title: "Manual",
            dueDate: now.addingTimeInterval(7_200),
            source: .manual,
            sourceRef: "calendar-id#manual"
        )

        let missingIDs = CalendarService.missingImportedTodoIDs(
            from: [kept, missing, completed, outsideWindow, pastOccurrence, manual],
            observedOccurrenceRefs: [kept.sourceRef],
            now: now
        )

        #expect(missingIDs == Set([missing.id]))
    }

    @Test("deleted imported occurrence preserves items whose external ID is still observed on other devices")
    @MainActor
    func missingImportedOccurrencePreservesCrossDeviceExternalIDs() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let crossDeviceTodo = Todo(
            title: "Created on macOS",
            dueDate: now.addingTimeInterval(3_600),
            source: .calendar,
            sourceRef: "macos-device-local-id#2026-09-18"
        )
        crossDeviceTodo.calendarEventExternalID = "shared-caldav-guid-123"

        // On iOS, the local occurrence ref is "ios-device-local-id#2026-09-18", but the CalDAV external ID matches
        let missingIDs = CalendarService.missingImportedTodoIDs(
            from: [crossDeviceTodo],
            observedOccurrenceRefs: ["ios-device-local-id#2026-09-18"],
            observedExternalIDs: ["shared-caldav-guid-123"],
            now: now
        )

        #expect(missingIDs.isEmpty)
    }

    @Test("todoWindow maps timed events to a start/deadline pair and collapses all-day or zero-length events")
    func todoWindowMapsEventTimeInformation() {
        let start = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let end = start.addingTimeInterval(3_600)

        let timed = CalendarService.todoWindow(eventStart: start, eventEnd: end, isAllDay: false)
        #expect(timed.startDate == start)
        #expect(timed.dueDate == end)

        let allDay = CalendarService.todoWindow(eventStart: start, eventEnd: end, isAllDay: true)
        #expect(allDay.startDate == nil)
        #expect(allDay.dueDate == start)

        let zeroLength = CalendarService.todoWindow(eventStart: start, eventEnd: start, isAllDay: false)
        #expect(zeroLength.startDate == nil)
        #expect(zeroLength.dueDate == start)
    }

    @Test("eventWindow projects a Todo's start/deadline onto a calendar range")
    func eventWindowProjectsTodoSchedule() {
        let start = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let due = start.addingTimeInterval(7_200)

        let ranged = CalendarService.eventWindow(todoStart: start, todoDue: due)
        #expect(ranged?.start == start)
        #expect(ranged?.end == due)

        let legacy = CalendarService.eventWindow(todoStart: nil, todoDue: start)
        #expect(legacy?.start == start)
        #expect(legacy?.end == start.addingTimeInterval(CalendarService.defaultTodoEventDuration))

        let invalidPair = CalendarService.eventWindow(todoStart: due, todoDue: start)
        #expect(invalidPair?.start == start)
        #expect(invalidPair?.end == start.addingTimeInterval(CalendarService.defaultTodoEventDuration))

        #expect(CalendarService.eventWindow(todoStart: start, todoDue: nil) == nil)
    }

    @Test("adoptedTodoWindow only adopts upstream calendar changes that move a Todo's projected range")
    func adoptedTodoWindowSkipsUnchangedProjectionsAndAdoptsRealMoves() {
        let due = Date(timeIntervalSinceReferenceDate: 900_000_000)

        // 마감만 있는 기존 to-do의 1시간 투영과 이벤트가 일치 → 채택하지 않는다
        let unchanged = CalendarService.adoptedTodoWindow(
            todoStart: nil,
            todoDue: due,
            eventStart: due,
            eventEnd: due.addingTimeInterval(3_600),
            isAllDay: false
        )
        #expect(unchanged == nil)

        // 이벤트 종료가 실제로 옮겨짐 → 채택
        let changedEnd = CalendarService.adoptedTodoWindow(
            todoStart: nil,
            todoDue: due,
            eventStart: due,
            eventEnd: due.addingTimeInterval(5_400),
            isAllDay: false
        )
        #expect(changedEnd?.startDate == due)
        #expect(changedEnd?.dueDate == due.addingTimeInterval(5_400))

        // 이벤트 시작이 실제로 옮겨짐 → 채택
        let movedStart = due.addingTimeInterval(7_200)
        let changedStart = CalendarService.adoptedTodoWindow(
            todoStart: nil,
            todoDue: due,
            eventStart: movedStart,
            eventEnd: movedStart.addingTimeInterval(3_600),
            isAllDay: false
        )
        #expect(changedStart?.startDate == movedStart)
        #expect(changedStart?.dueDate == movedStart.addingTimeInterval(3_600))

        // 구간이 있는 to-do 대비 0.4초 왕복 오차만 있는 이벤트 → 허용 오차 내이므로 채택하지 않는다
        let rangedStart = due
        let rangedDue = due.addingTimeInterval(7_200)
        let withinTolerance = CalendarService.adoptedTodoWindow(
            todoStart: rangedStart,
            todoDue: rangedDue,
            eventStart: rangedStart.addingTimeInterval(0.4),
            eventEnd: rangedDue.addingTimeInterval(0.4),
            isAllDay: false
        )
        #expect(withinTolerance == nil)

        // 구간이 있는 to-do 대비 종일 이벤트로 바뀜 → 종료 시각 의도가 사라지므로 채택
        let becameAllDay = CalendarService.adoptedTodoWindow(
            todoStart: rangedStart,
            todoDue: rangedDue,
            eventStart: rangedStart,
            eventEnd: rangedDue,
            isAllDay: true
        )
        #expect(becameAllDay?.startDate == nil)
        #expect(becameAllDay?.dueDate == rangedStart)
    }

    @Test("Firebase snapshot keeps a Todo's start time alongside its deadline")
    @MainActor
    func firebaseSnapshotRoundTripsStartDate() throws {
        let sourceConfiguration = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let sourceContainer = try ModelContainer(
            for: AppDataContainer.appSchema,
            configurations: [sourceConfiguration]
        )
        let sourceContext = ModelContext(sourceContainer)
        let start = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let due = start.addingTimeInterval(3_600)
        let todo = Todo(title: "Ranged", startDate: start, dueDate: due)
        sourceContext.insert(todo)
        try sourceContext.save()

        let json = try FirebaseSnapshotStore.exportJSON(context: sourceContext)

        let targetConfiguration = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let targetContainer = try ModelContainer(
            for: AppDataContainer.appSchema,
            configurations: [targetConfiguration]
        )
        let targetContext = ModelContext(targetContainer)
        try FirebaseSnapshotStore.importJSON(json, context: targetContext)

        let restored = try #require(
            targetContext.fetch(FetchDescriptor<Todo>()).first
        )
        #expect(restored.startDate == start)
        #expect(restored.dueDate == due)
    }

    @Test("Todo.scheduleAnchor and scheduledRange derive from start/deadline pairing")
    @MainActor
    func scheduleAnchorAndScheduledRangeReflectStartDeadlinePairing() {
        let start = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let due = start.addingTimeInterval(3_600)

        let ranged = Todo(title: "Ranged", startDate: start, dueDate: due)
        #expect(ranged.scheduleAnchor == start)
        #expect(ranged.scheduledRange?.start == start)
        #expect(ranged.scheduledRange?.end == due)

        let deadlineOnly = Todo(title: "Deadline only", dueDate: due)
        #expect(deadlineOnly.scheduleAnchor == due)
        #expect(deadlineOnly.scheduledRange == nil)

        let invalidPairing = Todo(title: "Invalid pairing", startDate: due, dueDate: start)
        #expect(invalidPairing.scheduleAnchor == due)
        #expect(invalidPairing.scheduledRange == nil)
    }
}
