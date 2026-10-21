import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Email ingestion apply tests", .serialized)
@MainActor
struct EmailIngestionTests {
    private func makeContainer() throws -> (container: ModelContainer, storeDirectory: URL) {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("email-ingestion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )

        let storeURL = storeDirectory.appendingPathComponent("store.sqlite")
        let config = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        do {
            let container = try ModelContainer(
                for: AppDataContainer.appSchema,
                configurations: [config]
            )
            return (container, storeDirectory)
        } catch {
            try? FileManager.default.removeItem(at: storeDirectory)
            throw error
        }
    }

    private func cleanupStore(at directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }


    @Test("applyExtractedItems skips existing and same-batch duplicate refs")
    func applyExtractedItemsSkipsDuplicateSourceRefs() throws {
        let (container, storeDirectory) = try makeContainer()
        defer { cleanupStore(at: storeDirectory) }
        let context = ModelContext(container)

        let existing = Todo(title: "기존", source: .email, sourceRef: "msg-1")
        context.insert(existing)

        let duplicateExisting = Todo(title: "중복 기존", source: .email, sourceRef: "msg-1")
        let fresh = Todo(title: "신규", source: .email, sourceRef: "msg-2")
        let duplicateFresh = Todo(title: "신규 중복", source: .email, sourceRef: "msg-2")

        let result = EmailService.shared.applyExtractedItems(
            todos: [duplicateExisting, fresh, duplicateFresh],
            events: [],
            to: context,
            existingRefs: ["msg-1"]
        )

        try context.save()
        let stored = try context.fetch(FetchDescriptor<Todo>())

        #expect(result.todoCount == 1)
        #expect(stored.count == 2)
        #expect(stored.filter { $0.sourceRef == "msg-2" }.count == 1)
    }

    @Test("applyExtractedItems ignores invalid calendar event dates")
    func applyExtractedItemsIgnoresInvalidEventDates() throws {
        let (container, storeDirectory) = try makeContainer()
        defer { cleanupStore(at: storeDirectory) }
        let context = ModelContext(container)
        let invalidEvent = ExtractedEmailEvent(
            title: "잘못된 일정",
            startISO: "not-a-date",
            endISO: "",
            location: "",
            notes: "",
            isAllDay: false
        )

        let result = EmailService.shared.applyExtractedItems(
            todos: [],
            events: [(event: invalidEvent, sourceRef: "msg-3")],
            to: context,
            existingRefs: []
        )

        try context.save()
        #expect(result.eventCount == 0)
    }
    
    @Test("pending email review todos are not automatic calendar candidates")
    func pendingEmailReviewTodosAreNotAutomaticCalendarCandidates() {
        let pendingDue = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let pending = Todo(
            title: "광고성 일정 후보",
            notes: "날짜는 있지만 사용자가 등록하지 않은 메일",
            dueDate: pendingDue,
            source: .email,
            sourceRef: "msg-review"
        )
        pending.triageStatus = TodoTriage.review.rawValue

        let confirmedDue = pendingDue.addingTimeInterval(3600)
        let confirmed = Todo(
            title: "확정된 메일 할 일",
            notes: "",
            dueDate: confirmedDue,
            source: .email,
            sourceRef: "msg-todo"
        )
        confirmed.triageStatus = TodoTriage.todo.rawValue

        #expect(CalendarService.isAutomaticRegistrationCandidate(
            pending, autoEnabled: true, sourceFilter: "all"
        ) == false)
        #expect(CalendarService.isAutomaticRegistrationCandidate(
            confirmed, autoEnabled: true, sourceFilter: "all"
        ) == true)
    }

    @Test("applyExtractedItems keeps review email unlinked from calendar")
    func applyExtractedItemsKeepsReviewEmailUnlinkedFromCalendar() throws {
        let (container, storeDirectory) = try makeContainer()
        defer { cleanupStore(at: storeDirectory) }
        let context = ModelContext(container)
        let due = Date().addingTimeInterval(3600)
        let pending = Todo(
            title: "후보",
            notes: "",
            dueDate: due,
            source: .email,
            sourceRef: "msg-review"
        )
        pending.triageStatus = TodoTriage.review.rawValue
        let event = ExtractedEmailEvent(
            title: "후보",
            startISO: ISO8601DateFormatter().string(from: due),
            endISO: "",
            location: "",
            notes: "",
            isAllDay: false
        )

        let result = EmailService.shared.applyExtractedItems(
            todos: [pending],
            events: [(event: event, sourceRef: "msg-review")],
            to: context,
            existingRefs: []
        )

        try context.save()
        let stored = try #require(try context.fetch(FetchDescriptor<Todo>()).first)
        #expect(result.todoCount == 1)
        #expect(result.eventCount == 0)
        #expect(stored.triage == .review)
        #expect(stored.calendarEventID == nil)
    }
}
