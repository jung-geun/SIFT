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

    private func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: AppDataContainer.appSchema, configurations: [config])
    }

    private func cleanupStore(at directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }


    @Test("Existing mail stays handled while distinct new actions survive same-mail deduplication")
    func applyExtractedItemsPreservesDistinctActions() throws {
        let (container, storeDirectory) = try makeContainer()
        defer { cleanupStore(at: storeDirectory) }
        let context = ModelContext(container)

        let existing = Todo(title: "기존", source: .email, sourceRef: "msg-1")
        context.insert(existing)

        let duplicateExisting = Todo(title: "중복 기존", source: .email, sourceRef: "msg-1")
        let fresh = Todo(title: "신규", source: .email, sourceRef: "msg-2")
        let duplicateFresh = Todo(title: "신규", source: .email, sourceRef: "msg-2")
        let secondAction = Todo(title: "두 번째 처리", source: .email, sourceRef: "msg-2")

        let result = EmailService.shared.applyExtractedItems(
            todos: [duplicateExisting, fresh, duplicateFresh, secondAction],
            events: [],
            to: context,
            existingRefs: ["msg-1"]
        )

        try context.save()
        let stored = try context.fetch(FetchDescriptor<Todo>())

        #expect(result.todoCount == 2)
        #expect(stored.count == 3)
        #expect(Set(stored.filter { $0.sourceRef == "msg-2" }.map(\.title)) == ["신규", "두 번째 처리"])
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

    @Test("same message analyzed twice or across two synced stores converges on deterministic Todo IDs without duplicating or rewriting legacy random IDs")
    func deterministicConvergenceAndLegacyPreservation() async throws {
        let containerA = try makeInMemoryContainer()
        let containerB = try makeInMemoryContainer()
        let contextA = ModelContext(containerA)
        let contextB = ModelContext(containerB)

        let message = GmailMessage(
            id: "msg-converge-1",
            threadID: "thread-converge-1",
            messageID: "<converge-1@example.com>",
            subject: "Quarterly release sign-off",
            from: "Release Lead <lead@example.com>",
            snippet: "Preview",
            body: "Please verify the release checklist and confirm staging sign-off.",
            htmlBody: nil,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            labelIds: ["INBOX"],
            isBulk: false,
            provider: .gmail,
            providerMessageID: "101",
            sourceAccountNamespace: "user@gmail.com"
        )

        var modelCalls = 0
        let engine = EmailIngestionEngine(summaryProvider: { _, _, _ in
            modelCalls += 1
            return EmailSummaryResult(
                summary: "Quarterly release sign-off requested.",
                keyPoints: ["Checklist verification"],
                actionItems: ["Verify the release checklist", "Confirm staging sign-off"]
            )
        })

        // 1. Two devices with different local IMAP UIDs share the same provider-stable
        // X-GM-MSGID and an already synced complete-body analysis -> no model call, same IDs.
        func syncedEmail(uid: String) -> EmailMessage {
            let row = EmailMessage(
                id: "gmail-imap:8881", threadID: message.threadID, subject: message.subject,
                from: message.from, snippet: message.snippet, body: message.body,
                receivedAt: message.receivedAt, provider: .gmail, rawMessageID: uid,
                providerGlobalMessageID: "8881", labelIDs: ["INBOX"], isInInbox: true,
                sourceAccountNamespace: "user@gmail.com"
            )
            row.analysisState = .analyzed
            row.analysisVersion = EmailAnalysisContract.summaryContractVersion
            row.analysisSummary = "Quarterly release sign-off requested."
            row.analysisKeyPoints = ["Checklist verification"]
            row.analysisActionItems = ["Verify the release checklist", "Confirm staging sign-off"]
            row.analyzedBodyFingerprint = EmailAnalysisContract.fingerprint(subject: row.subject, body: row.body)
            return row
        }
        func device(uid: String, namespace: String) -> GmailMessage {
            GmailMessage(
                id: message.id, threadID: message.threadID, messageID: message.messageID,
                subject: message.subject, from: message.from, snippet: message.snippet,
                body: message.body, htmlBody: nil, receivedAt: message.receivedAt,
                labelIds: message.labelIds, isBulk: false, provider: .gmail,
                providerMessageID: uid, sourceAccountNamespace: namespace
            )
        }
        let messageA = device(uid: "101", namespace: "user@gmail.com")
        let messageB = device(uid: "999", namespace: "USER@GMAIL.COM")
        let analysisA = try #require(SyncedMailAnalysis(syncedEmail(uid: "101"), subject: messageA.subject, body: messageA.body))
        let analysisB = try #require(SyncedMailAnalysis(syncedEmail(uid: "999"), subject: messageB.subject, body: messageB.body))
        let firstExtractA = try await engine.extractTodos(from: messageA, existingAnalysis: analysisA)
        let secondExtractA = try await engine.extractTodos(from: messageA, existingAnalysis: analysisA)
        let extractB = try await engine.extractTodos(from: messageB, existingAnalysis: analysisB)
        #expect(modelCalls == 0)
        #expect(firstExtractA.map(\.id) == secondExtractA.map(\.id))
        #expect(firstExtractA.map(\.id) == extractB.map(\.id))
        #expect(Set(firstExtractA.map(\.id)).count == 2)
        #expect(firstExtractA.allSatisfy { $0.triage == .review && $0.sourceAccountNamespace == "user@gmail.com" })
        // Reordered actions do not change an action's identity.
        let reorderedRow = syncedEmail(uid: "101")
        reorderedRow.analysisActionItems = ["Confirm staging sign-off", "Verify the release checklist"]
        let reorderedAnalysis = try #require(SyncedMailAnalysis(reorderedRow, subject: messageA.subject, body: messageA.body))
        let reorderedSynced = try await engine.extractTodos(from: messageA, existingAnalysis: reorderedAnalysis)
        #expect(reorderedSynced.map(\.title) == firstExtractA.map(\.title).reversed())
        #expect(Set(reorderedSynced.map(\.id)) == Set(firstExtractA.map(\.id)))

        // 2. Applying twice on A stores one review Todo per action.
        let applyA1 = EmailService.shared.applyExtractedItems(todos: firstExtractA, events: [], to: contextA)
        let applyA2 = EmailService.shared.applyExtractedItems(todos: secondExtractA, events: [], to: contextA)
        try contextA.save()
        #expect(applyA1.todoCount == 2 && applyA2.todoCount == 0)
        #expect(try contextA.fetch(FetchDescriptor<Todo>()).count == 2)

        // 3. After A's Todos sync into B, B's independent extraction of the same message
        // cannot duplicate them. Truly simultaneous offline creation still publishes
        // competing payloads for FullCloudSync review rather than being back-dated to match.
        try CloudModelCodec.mergeMainStore(from: contextA, into: contextB)
        try contextB.save()
        let applyB = EmailService.shared.applyExtractedItems(todos: extractB, events: [], to: contextB)
        try contextB.save()
        #expect(applyB.todoCount == 0)
        let mergedTodos = try contextB.fetch(FetchDescriptor<Todo>())
        #expect(mergedTodos.count == 2)
        #expect(Set(mergedTodos.map(\.id)) == Set(firstExtractA.map(\.id)))
        #expect(mergedTodos.allSatisfy { $0.triage == .review })
        #expect(firstExtractA.allSatisfy { $0.createdAt > message.receivedAt })

        // 3. Existing legacy random-UUID Todo keeps its ID and suppresses duplicate insertion by provenance.
        let containerLegacy = try makeInMemoryContainer()
        let legacyContext = ModelContext(containerLegacy)
        let legacyID = UUID()
        let legacyTodo = Todo(
            id: legacyID,
            title: "Verify the release checklist",
            source: .email,
            sourceRef: message.id
        )
        legacyTodo.sourceAccountNamespace = "user@gmail.com"
        legacyTodo.sourceMessageID = message.messageID
        legacyTodo.sourceItemID = EmailAnalysisContract.actionIdentifier("Verify the release checklist")
        legacyTodo.triageStatus = TodoTriage.review.rawValue
        legacyContext.insert(legacyTodo)
        try legacyContext.save()

        let freshCandidates = try await engine.extractTodos(from: message, existingAnalysis: analysisA)
        let legacyApply = EmailService.shared.applyExtractedItems(
            todos: freshCandidates,
            events: [],
            to: legacyContext
        )
        try legacyContext.save()
        let afterLegacyApply = try legacyContext.fetch(FetchDescriptor<Todo>())
        #expect(legacyApply.todoCount == 1)
        #expect(afterLegacyApply.count == 2)
        #expect(afterLegacyApply.contains { $0.id == legacyID && $0.title == "Verify the release checklist" })
        #expect(afterLegacyApply.allSatisfy { $0.triage == .review })
    }
}
