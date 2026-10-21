import Foundation
import SwiftData
import Testing
@testable import todo

@MainActor
@Suite("Canonical main-store migration")
struct AppDataContainerMigrationTests {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Both legacy stores and default merge with complete metadata; originals remain")
    func mergesEveryMainModel() throws {
        try withStores { urls in
            let expected = richTodo()
            let persona = Persona(descriptionText: "Original persona")
            persona.personaTypeRaw = "student,future-persona-kind"
            persona.updatedAt = timestamp
            let audit = TaskAuditEvent(from: expected)
            audit.deletedAt = timestamp.addingTimeInterval(400)
            audit.tags = ["Original Tag", "future-tag"]
            let behavior = TaskBehaviorEvent(todo: expected, type: .priorityChanged, actor: .user, occurredAt: timestamp)
            behavior.beforeCompletion = false
            behavior.afterCompletion = true
            behavior.beforeDueDate = timestamp
            behavior.afterDueDate = timestamp.addingTimeInterval(120)
            behavior.beforeManualPriority = 1
            behavior.afterManualPriority = 5
            behavior.beforeComputedPriority = 0.1
            behavior.afterComputedPriority = 0.9
            let analysis = MemoryAnalysis(
                summary: "Summary", insights: ["Insight"], fastTags: ["Tag"],
                overdueRate: 0.25, productiveHour: 9, recordTitle: "Record",
                accessScopeSummary: "Scope", processorDescription: "Processor"
            )
            analysis.createdAt = timestamp
            analysis.analysisVersion = 99
            analysis.windowStart = timestamp
            analysis.windowEnd = timestamp.addingTimeInterval(500)
            analysis.sampleCount = 17
            analysis.effectiveSampleSize = 12.5
            analysis.confidenceRaw = "future-confidence"
            // Raw storage must survive even when today's decoder cannot interpret it.
            analysis.behaviorProfileData = Data([0x01, 0x02, 0x03])
            let ledger = MailAnalysisLedgerRecord(
                fingerprintData: Data([0, 1, 255]), revision: 7,
                stateRawValue: "future-ledger-state", leaseExpiresAt: timestamp,
                analyzedAt: timestamp.addingTimeInterval(30)
            )
            try withContext(at: urls.local) { context in
                context.insert(expected)
                context.insert(persona)
                context.insert(audit)
                context.insert(behavior)
                context.insert(analysis)
                context.insert(ledger)
                try context.save()
            }
            try withContext(at: urls.cloud) { context in
                context.insert(Todo(title: "Cloud-only row"))
                try context.save()
            }
            try withContext(at: urls.defaultStore) { context in
                context.insert(Persona(descriptionText: "Default-only persona"))
                try context.save()
            }

            try AppDataContainer.migrateMainStores(to: urls.primary, from: urls.sources)
            try withContext(at: urls.primary) { context in
                let todos = try context.fetch(FetchDescriptor<Todo>())
                #expect(todos.count == 2)
                let actual = try #require(todos.first { $0.id == expected.id })
                expectTodo(actual, equals: expected)

                let personas = try context.fetch(FetchDescriptor<Persona>())
                #expect(personas.count == 2)
                let actualPersona = try #require(personas.first { $0.id == persona.id })
                #expect(actualPersona.descriptionText == persona.descriptionText)
                #expect(actualPersona.personaTypeRaw == persona.personaTypeRaw)
                #expect(actualPersona.updatedAt == persona.updatedAt)

                let actualAudit = try #require(context.fetch(FetchDescriptor<TaskAuditEvent>()).only)
                #expect(actualAudit.id == audit.id)
                #expect(actualAudit.todoID == audit.todoID)
                #expect(actualAudit.createdAt == audit.createdAt)
                #expect(actualAudit.completedAt == audit.completedAt)
                #expect(actualAudit.deletedAt == audit.deletedAt)
                #expect(actualAudit.sourceType == audit.sourceType)
                #expect(actualAudit.triageType == audit.triageType)
                #expect(actualAudit.wasFixedSchedule == audit.wasFixedSchedule)
                #expect(actualAudit.hadDueDate == audit.hadDueDate)
                #expect(actualAudit.dueDate == audit.dueDate)
                #expect(actualAudit.tags == audit.tags)

                let actualBehavior = try #require(context.fetch(FetchDescriptor<TaskBehaviorEvent>()).only)
                #expect(actualBehavior.id == behavior.id)
                #expect(actualBehavior.todoID == behavior.todoID)
                #expect(actualBehavior.occurredAt == behavior.occurredAt)
                #expect(actualBehavior.eventTypeRaw == behavior.eventTypeRaw)
                #expect(actualBehavior.actorRaw == behavior.actorRaw)
                #expect(actualBehavior.sourceType == behavior.sourceType)
                #expect(actualBehavior.triageType == behavior.triageType)
                #expect(actualBehavior.wasFixedSchedule == behavior.wasFixedSchedule)
                #expect(actualBehavior.todoCreatedAt == behavior.todoCreatedAt)
                #expect(actualBehavior.beforeCompletion == behavior.beforeCompletion)
                #expect(actualBehavior.afterCompletion == behavior.afterCompletion)
                #expect(actualBehavior.beforeDueDate == behavior.beforeDueDate)
                #expect(actualBehavior.afterDueDate == behavior.afterDueDate)
                #expect(actualBehavior.beforeManualPriority == behavior.beforeManualPriority)
                #expect(actualBehavior.afterManualPriority == behavior.afterManualPriority)
                #expect(actualBehavior.beforeComputedPriority == behavior.beforeComputedPriority)
                #expect(actualBehavior.afterComputedPriority == behavior.afterComputedPriority)

                let actualAnalysis = try #require(context.fetch(FetchDescriptor<MemoryAnalysis>()).only)
                #expect(actualAnalysis.id == analysis.id)
                #expect(actualAnalysis.createdAt == analysis.createdAt)
                #expect(actualAnalysis.summary == analysis.summary)
                #expect(actualAnalysis.insights == analysis.insights)
                #expect(actualAnalysis.fastTags == analysis.fastTags)
                #expect(actualAnalysis.overdueRate == analysis.overdueRate)
                #expect(actualAnalysis.productiveHour == analysis.productiveHour)
                #expect(actualAnalysis.recordTitle == analysis.recordTitle)
                #expect(actualAnalysis.accessScopeSummary == analysis.accessScopeSummary)
                #expect(actualAnalysis.processorDescription == analysis.processorDescription)
                #expect(actualAnalysis.analysisVersion == analysis.analysisVersion)
                #expect(actualAnalysis.windowStart == analysis.windowStart)
                #expect(actualAnalysis.windowEnd == analysis.windowEnd)
                #expect(actualAnalysis.sampleCount == analysis.sampleCount)
                #expect(actualAnalysis.effectiveSampleSize == analysis.effectiveSampleSize)
                #expect(actualAnalysis.confidenceRaw == analysis.confidenceRaw)
                #expect(actualAnalysis.behaviorProfileData == analysis.behaviorProfileData)

                let actualLedger = try #require(context.fetch(FetchDescriptor<MailAnalysisLedgerRecord>()).only)
                #expect(actualLedger.fingerprintData == ledger.fingerprintData)
                #expect(actualLedger.revision == ledger.revision)
                #expect(actualLedger.stateRawValue == ledger.stateRawValue)
                #expect(actualLedger.leaseExpiresAt == ledger.leaseExpiresAt)
                #expect(actualLedger.analyzedAt == ledger.analyzedAt)
                #expect(actualLedger.syncIdentity == ledger.syncIdentity)
            }
            for source in urls.sources {
                #expect(FileManager.default.fileExists(atPath: source.path))
            }
            try withContext(at: urls.local) { context in
                expectTodo(try #require(context.fetch(FetchDescriptor<Todo>()).only), equals: expected)
                #expect(try context.fetchCount(FetchDescriptor<MailAnalysisLedgerRecord>()) == 1)
            }
            #expect(FileManager.default.fileExists(atPath: AppDataContainer.migrationCheckpointURL(for: urls.primary).path))
        }
    }

    @Test("Collisions preserve variants and event links; interrupted-commit retries deduplicate")
    func collisionsAndRetry() throws {
        try withStores { urls in
            let todoID = UUID()
            let auditID = UUID()
            let behaviorID = UUID()
            for (index, source) in urls.sources.enumerated() {
                try withContext(at: source) { context in
                    let todo = richTodo(id: todoID)
                    if index == 2 { todo.title = "Divergent title" }
                    let audit = TaskAuditEvent(from: todo)
                    audit.id = auditID
                    audit.deletedAt = timestamp
                    let behavior = TaskBehaviorEvent(todo: todo, type: .created, actor: .user, occurredAt: timestamp)
                    behavior.id = behaviorID
                    context.insert(todo)
                    context.insert(audit)
                    context.insert(behavior)
                    try context.save()
                }
            }
            try AppDataContainer.migrateMainStores(to: urls.primary, from: urls.sources)
            var firstIDs: Set<UUID> = []
            try withContext(at: urls.primary) { context in
                let todos = try context.fetch(FetchDescriptor<Todo>())
                #expect(todos.count == 2)
                firstIDs = Set(todos.map(\.id))
                #expect(firstIDs.count == 2)
                #expect(firstIDs.contains(todoID))
                #expect(Set(todos.map(\.title)) == ["Original title", "Divergent title"])
                let audits = try context.fetch(FetchDescriptor<TaskAuditEvent>())
                let behaviors = try context.fetch(FetchDescriptor<TaskBehaviorEvent>())
                #expect(audits.count == 2)
                #expect(behaviors.count == 2)
                #expect(Set(audits.map(\.todoID)) == firstIDs)
                #expect(Set(behaviors.map(\.todoID)) == firstIDs)
            }
            // Simulate termination after the database save but before receipt publication.
            try FileManager.default.removeItem(at: AppDataContainer.migrationCheckpointURL(for: urls.primary))
            try AppDataContainer.migrateMainStores(to: urls.primary, from: urls.sources)
            try withContext(at: urls.primary) { context in
                let todos = try context.fetch(FetchDescriptor<Todo>())
                let audits = try context.fetchCount(FetchDescriptor<TaskAuditEvent>())
                let behaviors = try context.fetchCount(FetchDescriptor<TaskBehaviorEvent>())
                #expect(Set(todos.map(\.id)) == firstIDs)
                #expect(todos.count == 2)
                #expect(audits == 2)
                #expect(behaviors == 2)
            }
            for source in urls.sources {
                #expect(FileManager.default.fileExists(atPath: source.path))
            }
        }
    }

    @Test("Disabling full sync keeps current rows and does not resurrect deleted legacy rows")
    func togglesKeepCanonicalRows() throws {
        try withStores { urls in
            try withContext(at: urls.local) { context in
                context.insert(Todo(title: "Delete after migration"))
                try context.save()
            }
            do {
                let full = try AppDataContainer.makePrimaryContainer(
                    primaryURL: urls.primary, legacyURLs: urls.sources
                )
                let context = ModelContext(full)
                context.autosaveEnabled = false
                for todo in try context.fetch(FetchDescriptor<Todo>()) { context.delete(todo) }
                context.insert(Todo(title: "Current canonical row"))
                try context.save()
            }
            let disabled = try AppDataContainer.makePrimaryContainer(
                primaryURL: urls.primary, legacyURLs: urls.sources
            )
            let context = ModelContext(disabled)
            #expect(try context.fetch(FetchDescriptor<Todo>()).map(\.title) == ["Current canonical row"])
            try withContext(at: urls.local) { source in
                let titles = try source.fetch(FetchDescriptor<Todo>()).map(\.title)
                #expect(titles == ["Delete after migration"])
            }
        }
    }

    @Test("Unreadable source aborts canonical selection without moving or deleting originals")
    func sourceFailurePreservesOriginals() throws {
        try withStores { urls in
            try withContext(at: urls.local) { context in
                context.insert(Todo(title: "Keep original"))
                try context.save()
            }
            let corruptBytes = Data("not a SQLite database".utf8)
            try corruptBytes.write(to: urls.cloud)
            #expect(throws: (any Error).self) {
                try AppDataContainer.makePrimaryContainer(
                    primaryURL: urls.primary, legacyURLs: urls.sources
                )
            }
            #expect(FileManager.default.fileExists(atPath: urls.local.path))
            #expect(try Data(contentsOf: urls.cloud) == corruptBytes)
            #expect(!FileManager.default.fileExists(atPath: urls.primary.path))
            #expect(!FileManager.default.fileExists(atPath: AppDataContainer.migrationCheckpointURL(for: urls.primary).path))
            try withContext(at: urls.local) { context in
                let titles = try context.fetch(FetchDescriptor<Todo>()).map(\.title)
                #expect(titles == ["Keep original"])
            }
        }
    }

    @Test("Invalid completion receipt fails closed; fixing it permits a lossless retry")
    func invalidCheckpointPreservesOriginals() throws {
        try withStores { urls in
            try withContext(at: urls.local) { context in
                context.insert(Todo(title: "Original"))
                try context.save()
            }
            // A directory cannot be accepted as a completion receipt.
            let checkpoint = AppDataContainer.migrationCheckpointURL(for: urls.primary)
            try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
            #expect(throws: (any Error).self) {
                try AppDataContainer.migrateMainStores(to: urls.primary, from: urls.sources)
            }
            #expect(FileManager.default.fileExists(atPath: urls.local.path))
            try FileManager.default.removeItem(at: checkpoint)
            try AppDataContainer.migrateMainStores(to: urls.primary, from: urls.sources)
            try withContext(at: urls.primary) { context in
                let titles = try context.fetch(FetchDescriptor<Todo>()).map(\.title)
                #expect(titles == ["Original"])
            }
        }
    }

    @Test("Missing canonical data behind a completion receipt never silently becomes an empty store")
    func missingCanonicalFailsClosed() throws {
        try withStores { urls in
            try AppDataContainer.migrateMainStores(to: urls.primary, from: [])
            // Fixture-only deletion models missing storage; production never removes these files.
            try FileManager.default.removeItem(at: urls.primary)
            #expect(throws: AppDataContainer.MainStoreMigrationError.missingCanonicalStore) {
                try AppDataContainer.migrateMainStores(to: urls.primary, from: urls.sources)
            }
            #expect(!FileManager.default.fileExists(atPath: urls.primary.path))
        }
    }

    @Test("QA import uses app schema in memory without creating its disk URL")
    func inMemoryImportDoesNotTouchDisk() throws {
        try withStores { urls in
            let importURL = urls.directory.appendingPathComponent("must-not-exist/import.store")
            let container = try AppDataContainer.makeLegacyCloudImportContainer(storeURL: importURL, inMemory: true)
            let context = ModelContext(container)
            context.insert(Todo(title: "Synthetic import"))
            context.insert(MailAnalysisLedgerRecord(fingerprintData: Data([1]), revision: 1, stateRawValue: "done"))
            try context.save()
            #expect(try context.fetchCount(FetchDescriptor<Todo>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<MailAnalysisLedgerRecord>()) == 1)
            #expect(!FileManager.default.fileExists(atPath: importURL.deletingLastPathComponent().path))
        }
    }

    @Test("Email bundle publication preserves originals and repeat-open never reinstalls stale sidecars")
    func emailBundleRepeatOpenPreservesCheckpointedDestination() throws {
        try withStores { urls in
            let legacy = urls.directory.appendingPathComponent("email_local.store")
            let destination = urls.directory.appendingPathComponent("EmailLocal/email_local.store")
            let originalMain = Data("legacy-main".utf8)
            let originalWAL = Data("legacy-WAL".utf8)
            let originalSHM = Data("legacy-SHM".utf8)
            let originals = ["": originalMain, "-wal": originalWAL, "-shm": originalSHM]
            for (suffix, data) in originals {
                try data.write(to: URL(fileURLWithPath: legacy.path + suffix))
            }
            try AppDataContainer.migrateEmailStoreBundle(from: legacy, to: destination)
            for (suffix, data) in originals {
                #expect(try Data(contentsOf: URL(fileURLWithPath: legacy.path + suffix)) == data)
                #expect(try Data(contentsOf: URL(fileURLWithPath: destination.path + suffix)) == data)
            }

            // Exercise the filesystem publication protocol directly: a later
            // SQLite checkpoint updates main and removes the destination WAL/SHM.
            // The next open must treat destination main as authoritative.
            let checkpointedMain = Data("newer-checkpointed-main".utf8)
            try checkpointedMain.write(to: destination)
            for suffix in ["-wal", "-shm"] {
                try FileManager.default.removeItem(at: URL(fileURLWithPath: destination.path + suffix))
            }
            try AppDataContainer.migrateEmailStoreBundle(from: legacy, to: destination)
            #expect(try Data(contentsOf: destination) == checkpointedMain)
            for suffix in ["-wal", "-shm"] {
                #expect(!FileManager.default.fileExists(atPath: destination.path + suffix))
            }
            for (suffix, data) in originals {
                #expect(try Data(contentsOf: URL(fileURLWithPath: legacy.path + suffix)) == data)
            }
        }
    }

    @Test("Incomplete email staging never publishes destination main or alters the source")
    func emailBundleStagingFailurePreservesOriginals() throws {
        try withStores { urls in
            let legacy = urls.directory.appendingPathComponent("email_local.store")
            let original = Data("original-source".utf8)
            try original.write(to: legacy)
            let blockedDirectory = urls.directory.appendingPathComponent("blocked")
            try Data("not a directory".utf8).write(to: blockedDirectory)
            let destination = blockedDirectory.appendingPathComponent("email_local.store")
            #expect(throws: (any Error).self) {
                try AppDataContainer.migrateEmailStoreBundle(from: legacy, to: destination)
            }
            #expect(try Data(contentsOf: legacy) == original)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    private struct StoreURLs {
        let directory: URL
        var local: URL { directory.appendingPathComponent("local_v2.store") }
        var cloud: URL { directory.appendingPathComponent("icloud_v2.store") }
        var defaultStore: URL { directory.appendingPathComponent("default.store") }
        var primary: URL { directory.appendingPathComponent("primary_v3.store") }
        var sources: [URL] { [local, cloud, defaultStore] }
    }

    private func withStores(_ body: (StoreURLs) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(StoreURLs(directory: directory))
    }

    private func withContext(at url: URL, _ body: (ModelContext) throws -> Void) throws {
        let config = ModelConfiguration(schema: AppDataContainer.appSchema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppDataContainer.appSchema, configurations: [config])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try body(context)
    }

    private func richTodo(id: UUID = UUID()) -> Todo {
        let todo = Todo(
            id: id, title: "Original title", notes: "Complete notes", startDate: timestamp,
            dueDate: timestamp.addingTimeInterval(3600), source: .calendar,
            sourceRef: "calendar-reference", tags: ["one", "two"], reminderOffsets: [-600, -3600]
        )
        todo.createdAt = timestamp.addingTimeInterval(-100)
        todo.updatedAt = timestamp.addingTimeInterval(100)
        todo.isCompleted = true
        todo.completedAt = timestamp.addingTimeInterval(200)
        todo.manualPriority = 5
        todo.computedPriorityScore = 0.8
        todo.priorityReason = "Reason"
        todo.estimatedDurationMinutes = 45
        todo.source = "future-source"
        todo.sourceSender = "Sender"
        todo.sourceMessageID = "message-id"
        todo.sourceThreadID = "thread-id"
        todo.sourceSenderEmail = "sender@example.com"
        todo.sourceAccountNamespace = "namespace"
        todo.triageStatus = "future-triage"
        todo.calendarEventID = "device-event-id"
        todo.calendarEventExternalID = "external-event-id"
        todo.calendarEventOrigin = "future-origin"
        todo.calendarSyncedTitle = "Last upstream calendar title"
        todo.memoryNotes = "Memory"
        todo.aiRecommendedTime = timestamp.addingTimeInterval(300)
        todo.aiNeedsNotification = true
        todo.aiPersonaFit = true
        todo.aiDetail = "AI detail"
        todo.aiEngine = "future-engine"
        todo.aiRequestedProvider = "future-provider"
        todo.aiFallbackReason = "Historical fallback"
        todo.isFixedSchedule = true
        return todo
    }

    private func expectTodo(_ actual: Todo, equals expected: Todo) {
        #expect(actual.id == expected.id)
        #expect(actual.title == expected.title)
        #expect(actual.notes == expected.notes)
        #expect(actual.createdAt == expected.createdAt)
        #expect(actual.updatedAt == expected.updatedAt)
        #expect(actual.startDate == expected.startDate)
        #expect(actual.dueDate == expected.dueDate)
        #expect(actual.isCompleted == expected.isCompleted)
        #expect(actual.completedAt == expected.completedAt)
        #expect(actual.manualPriority == expected.manualPriority)
        #expect(actual.computedPriorityScore == expected.computedPriorityScore)
        #expect(actual.priorityReason == expected.priorityReason)
        #expect(actual.reminderOffsets == expected.reminderOffsets)
        #expect(actual.estimatedDurationMinutes == expected.estimatedDurationMinutes)
        #expect(actual.source == expected.source)
        #expect(actual.sourceRef == expected.sourceRef)
        #expect(actual.sourceSender == expected.sourceSender)
        #expect(actual.sourceMessageID == expected.sourceMessageID)
        #expect(actual.sourceThreadID == expected.sourceThreadID)
        #expect(actual.sourceSenderEmail == expected.sourceSenderEmail)
        #expect(actual.sourceAccountNamespace == expected.sourceAccountNamespace)
        #expect(actual.triageStatus == expected.triageStatus)
        #expect(actual.tags == expected.tags)
        #expect(actual.calendarEventID == expected.calendarEventID)
        #expect(actual.calendarEventExternalID == expected.calendarEventExternalID)
        #expect(actual.calendarEventOrigin == expected.calendarEventOrigin)
        #expect(actual.calendarSyncedTitle == expected.calendarSyncedTitle)
        #expect(actual.memoryNotes == expected.memoryNotes)
        #expect(actual.aiRecommendedTime == expected.aiRecommendedTime)
        #expect(actual.aiNeedsNotification == expected.aiNeedsNotification)
        #expect(actual.aiPersonaFit == expected.aiPersonaFit)
        #expect(actual.aiDetail == expected.aiDetail)
        #expect(actual.aiEngine == expected.aiEngine)
        #expect(actual.aiRequestedProvider == expected.aiRequestedProvider)
        #expect(actual.aiFallbackReason == expected.aiFallbackReason)
        #expect(actual.isFixedSchedule == expected.isFixedSchedule)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
