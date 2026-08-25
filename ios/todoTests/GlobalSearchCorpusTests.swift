import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("GlobalSearchCorpusBuilder corpus construction and privacy allowlists")
@MainActor
struct GlobalSearchCorpusTests {
    private func makeAppContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: AppDataContainer.appSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: AppDataContainer.appSchema, configurations: [config])
    }

    private func makeEmailContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: AppDataContainer.emailSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: AppDataContainer.emailSchema, configurations: [config])
    }

    private func makeMeetingContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: AppDataContainer.meetingSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: AppDataContainer.meetingSchema, configurations: [config])
    }

    // MARK: - 1. Todo Corpus Allowlists & Non-Matching Fields

    @Test("build includes Todo allowed fields and excludes opaque references")
    func buildTodoCorpusAllowlist() throws {
        let appContainer = try makeAppContainer()
        let emailContainer = try makeEmailContainer()
        let meetingContainer = try makeMeetingContainer()

        let todo = Todo(
            title: "Contract Renewal Task",
            notes: "Review clause 4 with legal team",
            dueDate: Date(timeIntervalSince1970: 1_700_000_000),
            tags: ["legal", "contract"]
        )
        todo.sourceSender = "alice@company.com"
        // Set opaque ref / sourceRef to test that it is NOT indexed
        todo.sourceRef = "opaque-source-ref-9999"
        appContainer.mainContext.insert(todo)
        try appContainer.mainContext.save()

        let docs = try GlobalSearchCorpusBuilder.build(
            appContainer: appContainer,
            emailContainer: emailContainer,
            meetingContainer: meetingContainer,
            mailAccess: nil
        )

        #expect(docs.count == 1)
        let doc = docs[0]

        #expect(doc.key == .todo(todo.id))
        #expect(doc.source == .todo)
        #expect(doc.title == "Contract Renewal Task")
        #expect(doc.subtitle.contains("alice@company.com"))
        #expect(doc.content.contains("Review clause 4 with legal team"))
        #expect(doc.content.contains("legal"))
        #expect(doc.content.contains("contract"))
        #expect(doc.content.contains("alice@company.com"))

        // Opaque sourceRef must not appear in search content or subtitle
        #expect(!doc.subtitle.contains("opaque-source-ref-9999"))
        #expect(!doc.content.contains("opaque-source-ref-9999"))

        // Pure search assertion: searching for title/notes/tags matches, opaque sourceRef does NOT match
        let titleMatch = GlobalSearchService.search(query: "Contract Renewal", documents: docs)
        #expect(titleMatch.count == 1)

        let notesMatch = GlobalSearchService.search(query: "clause 4", documents: docs)
        #expect(notesMatch.count == 1)

        let tagMatch = GlobalSearchService.search(query: "legal", documents: docs)
        #expect(tagMatch.count == 1)

        let senderMatch = GlobalSearchService.search(query: "alice@company.com", documents: docs)
        #expect(senderMatch.count == 1)

        let opaqueRefMatch = GlobalSearchService.search(query: "opaque-source-ref-9999", documents: docs)
        #expect(opaqueRefMatch.isEmpty)
    }

    // MARK: - 2. Local Mail Corpus, Inbox-Only & Access Restrictions

    @Test("build mail corpus requires mailAccess, active namespace, and isInInbox == true; excludes body and HTML")
    func buildMailCorpusRestrictions() throws {
        let appContainer = try makeAppContainer()
        let emailContainer = try makeEmailContainer()
        let meetingContainer = try makeMeetingContainer()

        let inboxMail = EmailMessage(
            id: "msg-inbox-1",
            threadID: "th-1",
            subject: "Q3 Budget Review",
            from: "finance@company.com",
            snippet: "Attached is the budget breakdown snippet",
            body: "CONFIDENTIAL SECRET EMAIL BODY DO NOT INDEX",
            htmlBody: "<html>CONFIDENTIAL HTML BODY</html>",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        inboxMail.isInInbox = true
        inboxMail.providerRawValue = MailProvider.gmail.rawValue
        inboxMail.sourceAccountNamespace = "user@gmail.com"
        inboxMail.analysisSummary = "Budget allocation summary"
        inboxMail.analysisKeyPoints = ["Key Point: Increase AI investment"]
        inboxMail.analysisActionItems = ["Action Item: Approve Q3 budget"]

        let archivedMail = EmailMessage(
            id: "msg-archived-2",
            subject: "Old Newsletter",
            from: "news@company.com",
            snippet: "Old archived snippet",
            body: "Archived body",
            receivedAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        archivedMail.isInInbox = false
        archivedMail.providerRawValue = MailProvider.gmail.rawValue
        archivedMail.sourceAccountNamespace = "user@gmail.com"

        let staleAccountMail = EmailMessage(
            id: "msg-stale-account-3",
            subject: "Stale Account Secret",
            from: "stale@company.com",
            snippet: "This active-looking row belongs to a disconnected account",
            receivedAt: Date(timeIntervalSince1970: 1_710_000_000)
        )
        staleAccountMail.isInInbox = true
        staleAccountMail.providerRawValue = MailProvider.gmail.rawValue
        staleAccountMail.sourceAccountNamespace = "stale@gmail.com"

        emailContainer.mainContext.insert(inboxMail)
        emailContainer.mainContext.insert(archivedMail)
        emailContainer.mainContext.insert(staleAccountMail)
        try emailContainer.mainContext.save()

        // 1) mailAccess == nil -> no mail documents built
        let noAccessDocs = try GlobalSearchCorpusBuilder.build(
            appContainer: appContainer,
            emailContainer: emailContainer,
            meetingContainer: meetingContainer,
            mailAccess: nil
        )
        #expect(noAccessDocs.filter { $0.source == .mail }.isEmpty)

        // 2) mailAccess with mismatched active namespace -> mail document excluded
        let mismatchedAccess = MailboxCachedProviderAccess(
            activeGmailNamespace: "other@gmail.com",
            activeOutlookNamespace: ""
        )
        let mismatchedDocs = try GlobalSearchCorpusBuilder.build(
            appContainer: appContainer,
            emailContainer: emailContainer,
            meetingContainer: meetingContainer,
            mailAccess: mismatchedAccess
        )
        #expect(mismatchedDocs.filter { $0.source == .mail }.isEmpty)

        // 3) mailAccess with matching active namespace -> builds inbox mail document only (archived excluded)
        let validAccess = MailboxCachedProviderAccess(
            activeGmailNamespace: "user@gmail.com",
            activeOutlookNamespace: ""
        )
        let docs = try GlobalSearchCorpusBuilder.build(
            appContainer: appContainer,
            emailContainer: emailContainer,
            meetingContainer: meetingContainer,
            mailAccess: validAccess
        )

        #expect(docs.count == 1)
        let mailDoc = docs[0]
        #expect(mailDoc.key == .mail(EmailMessageKey(inboxMail)))
        #expect(mailDoc.source == .mail)
        #expect(mailDoc.title == "Q3 Budget Review")
        #expect(mailDoc.subtitle == "finance@company.com")
        #expect(mailDoc.content.contains("Attached is the budget breakdown snippet"))
        #expect(mailDoc.content.contains("Budget allocation summary"))
        #expect(mailDoc.content.contains("Key Point: Increase AI investment"))
        #expect(mailDoc.content.contains("Action Item: Approve Q3 budget"))

        // Body, HTML, and account namespace must NOT be indexed
        #expect(!mailDoc.content.contains { $0.contains("CONFIDENTIAL SECRET EMAIL BODY") })
        #expect(!mailDoc.content.contains { $0.contains("CONFIDENTIAL HTML BODY") })
        #expect(!mailDoc.content.contains { $0.contains("user@gmail.com") })

        // Search assertions
        let summaryMatch = GlobalSearchService.search(query: "AI investment", documents: docs)
        #expect(summaryMatch.count == 1)

        let bodyMatch = GlobalSearchService.search(query: "CONFIDENTIAL SECRET", documents: docs)
        #expect(bodyMatch.isEmpty)

        let archivedMatch = GlobalSearchService.search(query: "Old Newsletter", documents: docs)
        #expect(archivedMatch.isEmpty)

        let staleAccountMatch = GlobalSearchService.search(query: "Stale Account Secret", documents: docs)
        #expect(staleAccountMatch.isEmpty)
    }

    // MARK: - 3. Meeting Corpus & Decoded Outcome Requirements

    @Test("build meeting corpus requires valid result and non-empty outcome; excludes raw transcript/audio")
    func buildMeetingCorpusOutcomeMatching() throws {
        let appContainer = try makeAppContainer()
        let emailContainer = try makeEmailContainer()
        let meetingContainer = try makeMeetingContainer()

        // Valid meeting with outcome fields
        let meeting1 = MeetingRecord(meetingID: "meeting-valid-1")
        let result1 = MeetingResult(
            transcriptRevision: 1,
            title: "Product Roadmap Sync",
            summary: "Quarterly planning discussion",
            decisions: ["Adopt Swift Testing framework"],
            unresolvedQuestions: ["Who leads the migration?"],
            segments: [
                MeetingSegment(startMs: 0, endMs: 5000, text: "RAW TRANSCRIPT AUDIO TEXT DO NOT INDEX")
            ],
            actionDrafts: [
                MeetingActionDraft(title: "Write unit tests", notes: "Coverage for global search", assignee: "Dave")
            ]
        )
        try meeting1.update(result: result1, status: .ready)

        // Invalid meeting 1: resultData is corrupt JSON
        let meetingCorrupt = MeetingRecord(meetingID: "meeting-corrupt-2")
        meetingCorrupt.resultData = Data("INVALID JSON DATA".utf8)

        // Invalid meeting 2: empty outcome fields
        let meetingEmpty = MeetingRecord(meetingID: "meeting-empty-3")
        let emptyResult = MeetingResult(
            transcriptRevision: 1,
            title: "",
            summary: "",
            decisions: [],
            unresolvedQuestions: [],
            segments: [MeetingSegment(startMs: 0, endMs: 1000, text: "Segment text only")],
            actionDrafts: []
        )
        try meetingEmpty.update(result: emptyResult, status: .ready)

        meetingContainer.mainContext.insert(meeting1)
        meetingContainer.mainContext.insert(meetingCorrupt)
        meetingContainer.mainContext.insert(meetingEmpty)
        try meetingContainer.mainContext.save()

        let docs = try GlobalSearchCorpusBuilder.build(
            appContainer: appContainer,
            emailContainer: emailContainer,
            meetingContainer: meetingContainer,
            mailAccess: nil
        )

        // Only meeting1 is included
        #expect(docs.count == 1)
        let meetingDoc = docs[0]
        #expect(meetingDoc.key == .meeting("meeting-valid-1"))
        #expect(meetingDoc.source == .meeting)
        #expect(meetingDoc.title == "Product Roadmap Sync")
        #expect(meetingDoc.subtitle == "Quarterly planning discussion")

        #expect(meetingDoc.content.contains("Quarterly planning discussion"))
        #expect(meetingDoc.content.contains("Adopt Swift Testing framework"))
        #expect(meetingDoc.content.contains("Who leads the migration?"))
        #expect(meetingDoc.content.contains("Write unit tests"))
        #expect(meetingDoc.content.contains("Coverage for global search"))
        #expect(meetingDoc.content.contains("Dave"))

        // Raw transcript text must NOT be indexed
        #expect(!meetingDoc.content.contains { $0.contains("RAW TRANSCRIPT AUDIO TEXT") })

        // Search assertions
        let decisionSearch = GlobalSearchService.search(query: "Swift Testing", documents: docs)
        #expect(decisionSearch.count == 1)

        let actionSearch = GlobalSearchService.search(query: "Dave search", documents: docs)
        #expect(actionSearch.count == 1)

        let transcriptSearch = GlobalSearchService.search(query: "RAW TRANSCRIPT", documents: docs)
        #expect(transcriptSearch.isEmpty)
    }

    // MARK: - 4. Typed Record Key Resolution & Deletion Path

    @Test("resolve returns correct resolved record and returns nil after record deletion")
    func recordResolutionAndDeletion() throws {
        let appContainer = try makeAppContainer()
        let emailContainer = try makeEmailContainer()
        let meetingContainer = try makeMeetingContainer()

        // 1. Todo resolution
        let todo = Todo(title: "Resolvable Todo Task")
        appContainer.mainContext.insert(todo)

        // 2. Mail resolution
        let mail = EmailMessage(
            id: "resolve-msg-1",
            subject: "Resolvable Mail",
            receivedAt: Date()
        )
        mail.providerRawValue = MailProvider.gmail.rawValue
        mail.sourceAccountNamespace = "user@domain.com"
        mail.isInInbox = true
        emailContainer.mainContext.insert(mail)

        // 3. Meeting resolution
        let meeting = MeetingRecord(meetingID: "resolve-meeting-1")
        meetingContainer.mainContext.insert(meeting)

        try appContainer.mainContext.save()
        try emailContainer.mainContext.save()
        try meetingContainer.mainContext.save()

        let todoKey = GlobalSearchRecordKey.todo(todo.id)
        let mailKey = GlobalSearchRecordKey.mail(EmailMessageKey(mail))
        let meetingKey = GlobalSearchRecordKey.meeting("resolve-meeting-1")
        let matchingMailAccess = MailboxCachedProviderAccess(
            activeGmailNamespace: "user@domain.com",
            activeOutlookNamespace: ""
        )

        // Assert all resolve to active records
        let resolvedTodo = try GlobalSearchCorpusBuilder.resolve(
            todoKey,
            appContainer: appContainer,
            emailContainer: emailContainer,
            meetingContainer: meetingContainer,
            mailAccess: nil
        )
        if case .todo(let fetchedTodo) = resolvedTodo {
            #expect(fetchedTodo.id == todo.id)
            #expect(fetchedTodo.title == "Resolvable Todo Task")
        } else {
            Issue.record("Expected .todo resolved record")
        }

        let resolvedMail = try GlobalSearchCorpusBuilder.resolve(
            mailKey,
            appContainer: appContainer,
            emailContainer: emailContainer,
            meetingContainer: meetingContainer,
            mailAccess: matchingMailAccess
        )
        if case .mail(let fetchedMail) = resolvedMail {
            #expect(EmailMessageKey(fetchedMail) == EmailMessageKey(mail))
            #expect(fetchedMail.subject == "Resolvable Mail")
        } else {
            Issue.record("Expected .mail resolved record")
        }

        let switchedAccountResolved = try GlobalSearchCorpusBuilder.resolve(
            mailKey,
            appContainer: appContainer,
            emailContainer: emailContainer,
            meetingContainer: meetingContainer,
            mailAccess: MailboxCachedProviderAccess(
                activeGmailNamespace: "other@domain.com",
                activeOutlookNamespace: ""
            )
        )
        #expect(switchedAccountResolved == nil)

        mail.isInInbox = false
        try emailContainer.mainContext.save()
        let archivedMailResolved = try GlobalSearchCorpusBuilder.resolve(
            mailKey,
            appContainer: appContainer,
            emailContainer: emailContainer,
            meetingContainer: meetingContainer,
            mailAccess: matchingMailAccess
        )
        #expect(archivedMailResolved == nil)
        mail.isInInbox = true
        try emailContainer.mainContext.save()

        let resolvedMeeting = try GlobalSearchCorpusBuilder.resolve(
            meetingKey,
            appContainer: appContainer,
            emailContainer: emailContainer,
            meetingContainer: meetingContainer,
            mailAccess: nil
        )
        if case .meeting(let fetchedMeeting) = resolvedMeeting {
            #expect(fetchedMeeting.meetingID == "resolve-meeting-1")
        } else {
            Issue.record("Expected .meeting resolved record")
        }

        // Delete seeded models from their respective containers and save
        appContainer.mainContext.delete(todo)
        emailContainer.mainContext.delete(mail)
        meetingContainer.mainContext.delete(meeting)

        try appContainer.mainContext.save()
        try emailContainer.mainContext.save()
        try meetingContainer.mainContext.save()

        // Assert resolution returns nil after deletion
        let deletedTodoResolved = try GlobalSearchCorpusBuilder.resolve(
            todoKey,
            appContainer: appContainer,
            emailContainer: emailContainer,
            meetingContainer: meetingContainer,
            mailAccess: nil
        )
        #expect(deletedTodoResolved == nil)

        let deletedMailResolved = try GlobalSearchCorpusBuilder.resolve(
            mailKey,
            appContainer: appContainer,
            emailContainer: emailContainer,
            meetingContainer: meetingContainer,
            mailAccess: matchingMailAccess
        )
        #expect(deletedMailResolved == nil)

        let deletedMeetingResolved = try GlobalSearchCorpusBuilder.resolve(
            meetingKey,
            appContainer: appContainer,
            emailContainer: emailContainer,
            meetingContainer: meetingContainer,
            mailAccess: nil
        )
        #expect(deletedMeetingResolved == nil)
    }
}
