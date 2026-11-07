import Foundation
import SwiftData
import Testing
@testable import todo

@MainActor
@Suite("Portable cloud domain codec")
struct CloudModelCodecTests {
    @MainActor
    private final class Stores {
        let app: ModelContext
        let email: ModelContext
        let meeting: ModelContext

        init() throws {
            func context(_ schema: Schema) throws -> ModelContext {
                let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
                context.autosaveEnabled = false
                return context
            }
            app = try context(AppDataContainer.appSchema)
            email = try context(AppDataContainer.emailSchema)
            meeting = try context(AppDataContainer.meetingSchema)
        }

        func capture() throws -> [String: Data] {
            try CloudModelCodec.capture(app: app, email: email, meeting: meeting).validatedRecords()
        }

        func apply(_ key: String, _ payload: Data?) throws {
            try CloudModelCodec.apply(key: key, payload: payload, app: app, email: email, meeting: meeting)
        }

        func apply(_ payloads: [String: Data]) throws {
            for key in payloads.keys.sorted() { try apply(key, payloads[key]) }
        }

        func save() throws {
            try app.save()
            try email.save()
            try meeting.save()
        }
    }
    @Test("Identifier-level capture preserves wire bytes and task aggregate across mail edits, but tracks every task field and deletion")
    func incrementalInventoriesPreserveUnchangedFamilies() throws {
        let stores = try Stores()
        let records = seed(stores)
        try stores.save()
        let cache = CloudModelCodec.CaptureCache()
        var snapshot = try CloudModelCodec.capture(app: stores.app, email: stores.email,
            meeting: stores.meeting, cache: cache)
        #expect(snapshot.records == (try stores.capture()))
        #expect(snapshot.digests == snapshot.records.mapValues(CloudFileStore.digest))
        let initialAggregate = snapshot.taskAggregateDigest
        let originalTasks = snapshot.records.filter { $0.key.hasPrefix("Todo/") }
        let oldTaskDate = records.todo.updatedAt

        records.email.body = "Only the independently saved mail body changes"
        try stores.email.save()
        cache.invalidate(identifiers: [records.email.persistentModelID])
        let mailInventory = try CloudModelCodec.capture(app: stores.app, email: stores.email,
            meeting: stores.meeting, entities: ["EmailMessage"], cache: cache)
        snapshot.replace(entities: ["EmailMessage"], with: mailInventory)
        #expect(snapshot.taskAggregateDigest == initialAggregate)
        #expect(snapshot.records.filter { $0.key.hasPrefix("Todo/") } == originalTasks)
        #expect(snapshot.records == (try stores.capture()))

        // No updatedAt heuristic: a changed domain field alone invalidates the hash.
        records.todo.notes = "Task detail edited without changing its timestamp"
        try stores.app.save()
        #expect(records.todo.updatedAt == oldTaskDate)
        cache.invalidate(identifiers: [records.todo.persistentModelID])
        let taskInventory = try CloudModelCodec.capture(app: stores.app, email: stores.email,
            meeting: stores.meeting, entities: ["Todo", "TaskAuditEvent", "TaskBehaviorEvent"], cache: cache)
        snapshot.replace(entities: ["Todo", "TaskAuditEvent", "TaskBehaviorEvent"], with: taskInventory)
        #expect(snapshot.taskAggregateDigest != initialAggregate)
        #expect(snapshot.records == (try stores.capture()))

        let key = "Todo/" + records.todo.id.uuidString.lowercased()
        let deletedID = records.todo.persistentModelID
        stores.app.delete(records.todo)
        try stores.app.save()
        cache.invalidate(identifiers: [deletedID])
        let deletedInventory = try CloudModelCodec.capture(app: stores.app, email: stores.email,
            meeting: stores.meeting, entities: ["Todo", "TaskAuditEvent", "TaskBehaviorEvent"], cache: cache)
        snapshot.replace(entities: ["Todo", "TaskAuditEvent", "TaskBehaviorEvent"], with: deletedInventory)
        #expect(snapshot.records[key] == nil)
        #expect(snapshot.digests[key] == nil)
        #expect(snapshot.records == (try stores.capture()))
    }

    @Test("Incremental duplicate inventories hold all versions and recover only after authoritative duplicate removal")
    func incrementalDuplicateInventoriesRetainConflicts() throws {
        let stores = try Stores()
        let original = Todo(title: "Original task")
        stores.app.insert(original)
        try stores.save()
        let cache = CloudModelCodec.CaptureCache()
        let first = try CloudModelCodec.capture(app: stores.app, email: stores.email,
            meeting: stores.meeting, cache: cache)
        let duplicate = Todo(title: "Different version")
        duplicate.id = original.id
        stores.app.insert(duplicate)
        try stores.app.save()
        cache.invalidate(identifiers: [duplicate.persistentModelID])
        let conflicted = try CloudModelCodec.capture(app: stores.app, email: stores.email,
            meeting: stores.meeting, cache: cache)
        let key = "Todo/" + original.id.uuidString.lowercased()
        #expect(conflicted.records[key] == nil)
        #expect(conflicted.digests[key] == nil)
        #expect(conflicted.conflictingKeys == [key])
        #expect(conflicted.versions[key]?.count == 2)
        #expect(conflicted.taskAggregateDigest != first.taskAggregateDigest)
        let duplicateID = duplicate.persistentModelID
        stores.app.delete(duplicate)
        try stores.app.save()
        cache.invalidate(identifiers: [duplicateID])
        let recovered = try CloudModelCodec.capture(app: stores.app, email: stores.email,
            meeting: stores.meeting, cache: cache)
        #expect(recovered.conflictingKeys.isEmpty)
        #expect(recovered.records == first.records)
        #expect(recovered.taskAggregateDigest == first.taskAggregateDigest)
    }

    @Test("Unknown save metadata invalidates every cached family instead of trusting stale task bytes")
    func unknownNotificationFallsBackToFullCapture() throws {
        let stores = try Stores()
        let records = seed(stores)
        try stores.save()
        let cache = CloudModelCodec.CaptureCache()
        let before = try CloudModelCodec.capture(app: stores.app, email: stores.email,
            meeting: stores.meeting, cache: cache)
        var changes = FullCloudModelChanges()
        let generation = changes.generations
        records.todo.title = "Edit whose notification format is unknown"
        try stores.app.save()
        let recorded = changes.record(Notification(name: ModelContext.didSave, object: stores.app,
            userInfo: ["unrecognized": "metadata"]), cache: cache)
        #expect(recorded)
        #expect(cache.requiresFullInventory)
        #expect(!changes.isCurrent(key: "Todo/", snapshot: generation))
        let after = try CloudModelCodec.capture(app: stores.app, email: stores.email,
            meeting: stores.meeting, cache: cache)
        #expect(after.records == (try stores.capture()))
        #expect(after.taskAggregateDigest != before.taskAggregateDigest)
    }

    @Test("Task health changes invalidate linked event caches rather than exporting excluded cached bytes")
    func incrementalHealthExclusionRefreshesLinkedEvents() throws {
        let stores = try Stores()
        let records = seed(stores)
        try stores.save()
        let cache = CloudModelCodec.CaptureCache()
        let before = try CloudModelCodec.capture(app: stores.app, email: stores.email,
            meeting: stores.meeting, cache: cache)
        records.todo.sourceRef = "health:private-source"
        try stores.app.save()
        cache.invalidate(identifiers: [records.todo.persistentModelID])
        let after = try CloudModelCodec.capture(app: stores.app, email: stores.email,
            meeting: stores.meeting, cache: cache)
        #expect(after.records == (try stores.capture()))
        #expect(after.records.count == before.records.count - 3)
        #expect(!after.records.keys.contains { $0.hasPrefix("Todo/") || $0.hasPrefix("TaskAuditEvent/")
            || $0.hasPrefix("TaskBehaviorEvent/") })
    }

    @Test("Meeting namespace graph links root manifests, child-only parents and every held duplicate version")
    func meetingNamespaceGraphRetainsWholeOriginalFamily() throws {
        let stores = try Stores()
        let rootID = UUID().uuidString.lowercased()
        let childID = UUID().uuidString.lowercased()
        let manifestOnlyID = UUID().uuidString.lowercased()
        let alternateParentID = UUID().uuidString.lowercased()
        let unrelatedID = UUID().uuidString.lowercased()
        let root = MeetingRecord()
        root.meetingID = rootID
        root.audioTrackIDs = [manifestOnlyID]
        let child = MeetingRecord()
        child.meetingID = childID
        child.parentMeetingID = rootID
        let duplicate = MeetingRecord()
        duplicate.meetingID = childID
        duplicate.parentMeetingID = alternateParentID
        let unrelated = MeetingRecord()
        unrelated.meetingID = unrelatedID
        for row in [root, child, duplicate, unrelated] { stores.meeting.insert(row) }
        try stores.save()
        let snapshot = try CloudModelCodec.capture(app: stores.app, email: stores.email, meeting: stores.meeting)
        #expect(snapshot.conflictingKeys.count == 1)
        let graph = try CloudModelCodec.meetingNamespaceGraph(snapshot)
        let family: Set<String> = [rootID, childID, manifestOnlyID, alternateParentID]
        for id in family { #expect(graph[id] == family) }
        #expect(graph[unrelatedID] == [unrelatedID])
        let authorization = MeetingCaptureCoordinator.captureCloudSyncNamespaceAuthorization()
        let scope = MeetingCloudSyncProtection.begin(meetingIDs: [rootID])
        defer { MeetingCloudSyncProtection.end(scope) }
        for id in family {
            #expect(graph[id]?.allSatisfy(authorization) == false)
        }
        #expect(graph[unrelatedID]?.allSatisfy(authorization) == true)
    }

    @Test("An invalid mail inventory remains unavailable with its old bytes while a valid task family advances")
    func failedFamilyCaptureNeverMeansDeletion() throws {
        let stores = try Stores()
        let records = seed(stores)
        try stores.save()
        let cache = CloudModelCodec.CaptureCache()
        let before = try CloudModelCodec.capture(app: stores.app, email: stores.email,
            meeting: stores.meeting, cache: cache)
        let taskKey = try #require(before.records.keys.first { $0.hasPrefix("Todo/") })
        let mailKey = try #require(before.records.keys.first { $0.hasPrefix("EmailMessage/") })
        let validMailID = records.email.id
        records.email.id = ""
        records.todo.notes = "Independent task edit survives malformed mail identity"
        try stores.save()
        cache.invalidate(identifiers: [records.email.persistentModelID, records.todo.persistentModelID])
        let captured = CloudModelCodec.captureAvailable(app: stores.app, email: stores.email,
            meeting: stores.meeting, previous: before, entities: CloudModelCodec.entityNames, cache: cache)
        #expect(captured.unavailableEntities == ["EmailMessage"])
        #expect(captured.firstError != nil)
        #expect(captured.snapshot.records[mailKey] == before.records[mailKey])
        #expect(captured.snapshot.digests[mailKey] == before.digests[mailKey])
        #expect(captured.snapshot.records[taskKey] != before.records[taskKey])
        #expect(captured.snapshot.taskAggregateDigest != before.taskAggregateDigest)
        #expect(CloudModelCodec.captureFamilies.reduce(into: Set<String>(), { $0.formUnion($1) })
            == CloudModelCodec.entityNames)
        records.email.id = validMailID
        try stores.email.save()
        cache.invalidate(identifiers: [records.email.persistentModelID])
        let recovered = CloudModelCodec.captureAvailable(app: stores.app, email: stores.email,
            meeting: stores.meeting, previous: captured.snapshot, entities: ["EmailMessage"], cache: cache)
        #expect(recovered.unavailableEntities.isEmpty)
        #expect(recovered.firstError == nil)
        #expect(recovered.snapshot.records == (try stores.capture()))
    }

    @Test("Actual SQL batch deletion plus metadata save recaptures the complete vocabulary family")
    func batchDeletionKeepsMembershipAuthoritative() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SIFTBatchInventory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let schema = AppDataContainer.meetingSchema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: root.appendingPathComponent("meeting.store"), cloudKitDatabase: .none)])
        let meeting = ModelContext(container)
        meeting.autosaveEnabled = false
        let term = MeetingGlossaryTerm(canonical: "retained until authoritative delete")
        let source = VocabularySourceState()
        source.sourceKey = "source-key"
        let observation = VocabularyObservation()
        let metadata = VocabularyStoreMetadata()
        metadata.storeKey = "metadata-key"
        meeting.insert(term); meeting.insert(source); meeting.insert(observation); meeting.insert(metadata)
        try meeting.save()
        let stores = try Stores()
        let cache = CloudModelCodec.CaptureCache()
        let before = try CloudModelCodec.capture(app: stores.app, email: stores.email, meeting: ModelContext(container), cache: cache)
        let deletedKeys = Set(before.records.keys.filter { !$0.hasPrefix("VocabularyStoreMetadata/") })
        #expect(deletedKeys.count == 3)
        let fence = FullCloudSaveFence(entities: CloudModelCodec.entityNames)
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave,
            object: meeting, queue: nil) { note in fence.observe(note) }
        defer { NotificationCenter.default.removeObserver(observer) }
        try meeting.delete(model: VocabularyObservation.self)
        try meeting.delete(model: VocabularySourceState.self)
        try meeting.delete(model: MeetingGlossaryTerm.self)
        metadata.lastCompletedBackfillAt = Date()
        try meeting.save()
        let pending = fence.drain()
        #expect(pending.hasChanges)
        #expect(pending.entities.contains("VocabularyStoreMetadata"))
        if pending.needsFullCapture { cache.invalidateAll() }
        else { cache.invalidate(identifiers: pending.identifiers) }
        let captured = CloudModelCodec.captureAvailable(app: stores.app, email: stores.email,
            meeting: ModelContext(container), previous: before, entities: pending.entities, cache: cache)
        #expect(captured.unavailableEntities.isEmpty)
        #expect(captured.firstError == nil)
        #expect(deletedKeys.isDisjoint(with: captured.snapshot.records.keys))
        #expect(captured.snapshot.records.count == 1)
        #expect(captured.snapshot.records.keys.first?.hasPrefix("VocabularyStoreMetadata/") == true)
    }

    @Test("The task aggregate actually gates acceptance work without skipping task edits, deletion, routine changes or failed retries")
    func aggregateDrivesAcceptanceChangeDetection() throws {
        enum ExpectedFailure: Error { case interrupted }
        let stores = try Stores()
        let todo = Todo(title: "Tracked task")
        let mail = EmailMessage(id: "independent-mail")
        stores.app.insert(todo)
        stores.email.insert(mail)
        try stores.save()
        func aggregate() throws -> String {
            try CloudModelCodec.capture(app: stores.app, email: stores.email, meeting: stores.meeting).taskAggregateDigest
        }
        var checkpoint = FullCloudTaskAcceptanceCheckpoint()
        var routineGeneration: UInt64 = 0
        var scans = 0
        let initial = try aggregate()
        #expect(checkpoint.reconcileIfChanged(taskAggregate: initial, routineGeneration: { routineGeneration }) {
            scans += 1
            routineGeneration &+= 1 // Reconciliation itself may save routine state.
        })
        #expect(!checkpoint.reconcileIfChanged(taskAggregate: initial, routineGeneration: { routineGeneration }) {
            scans += 1
        })
        mail.body = "A mail-only save must not rescan every task"
        try stores.email.save()
        let mailOnly = try aggregate()
        #expect(mailOnly == initial)
        #expect(!checkpoint.reconcileIfChanged(taskAggregate: mailOnly, routineGeneration: { routineGeneration }) {
            scans += 1
        })
        todo.notes = "Changed task details without an updatedAt heuristic"
        try stores.app.save()
        let edited = try aggregate()
        #expect(edited != initial)
        #expect(checkpoint.reconcileIfChanged(taskAggregate: edited, routineGeneration: { routineGeneration }) {
            scans += 1
        })
        routineGeneration &+= 1
        #expect(checkpoint.reconcileIfChanged(taskAggregate: edited, routineGeneration: { routineGeneration }) {
            scans += 1
        })
        stores.app.delete(todo)
        try stores.app.save()
        let deleted = try aggregate()
        #expect(deleted != edited)
        #expect(throws: ExpectedFailure.interrupted) {
            try checkpoint.reconcileIfChanged(taskAggregate: deleted, routineGeneration: { routineGeneration }) {
                throw ExpectedFailure.interrupted
            }
        }
        #expect(checkpoint.reconcileIfChanged(taskAggregate: deleted, routineGeneration: { routineGeneration }) {
            scans += 1
        })
        #expect(scans == 4)
        checkpoint.invalidate() // A remote Todo apply invalidates the prior source signature.
        #expect(checkpoint.reconcileIfChanged(taskAggregate: deleted, routineGeneration: { routineGeneration }) {
            scans += 1
        })
        #expect(scans == 5)
    }


    @Test("Invalid content-version metadata holds real mail and ledger restores until the migration marker is valid",
          arguments: ["clock", "installation", "tombstone"])
    func invalidPreferenceMetadataHoldsDependentMail(mode: String) async throws {
        let source = try Stores(), target = try Stores()
        let records = seed(source)
        let account = "synthetic-migration-account"
        records.email.providerRawValue = MailProvider.gmail.rawValue
        records.email.sourceAccountNamespace = account
        records.email.body = "Complete remote original body"
        records.email.htmlBody = "<p>Complete remote original body</p>"
        records.email.analysisStateRaw = EmailAnalysisState.analyzed.rawValue
        records.email.analysisSummary = "Remote analysis must not be reset by an obsolete migration"
        try source.save()
        let portable = try source.capture()
        let emailKey = try #require(portable.keys.first { $0.hasPrefix("EmailMessage/") })
        let ledgerKey = try #require(portable.keys.first { $0.hasPrefix("MailAnalysisLedgerRecord/") })
        let taskKey = "Todo/" + records.todo.id.uuidString.lowercased()
        let local = EmailMessage(id: records.email.id)
        local.providerRawValue = MailProvider.gmail.rawValue
        local.sourceAccountNamespace = account
        local.body = "Existing local original must stay untouched"
        local.htmlBody = "<p>Existing local original</p>"
        local.analysisSummary = "Existing local analysis"
        target.email.insert(local)
        let ledger = MailAnalysisLedgerRecord(fingerprintData: records.ledger.fingerprintData,
            revision: 0, stateRawValue: "local-ledger-must-stay")
        ledger.syncIdentity = records.ledger.syncIdentity
        target.app.insert(ledger)
        try target.save()
        let suite = "SIFT-InvalidMarker-\(UUID())"
        let sourceDefaults = try #require(UserDefaults(suiteName: suite + "-source"))
        let targetDefaults = try #require(UserDefaults(suiteName: suite + "-target"))
        defer {
            sourceDefaults.removePersistentDomain(forName: suite + "-source")
            targetDefaults.removePersistentDomain(forName: suite + "-target")
        }
        let versionKey = "pieroot.todo.gmailIMAP.contentVersion." + account
        sourceDefaults.set(GmailIMAPContentMigration.currentVersion, forKey: versionKey)
        let preferenceKey = CloudPreferenceStore.prefix + versionKey
        let marker = try #require(CloudPreferenceStore.capture(defaults: sourceDefaults)[preferenceKey])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SIFTInvalidMarker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema([CloudDataRevision.self])
        let cloud = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(cloud)
        context.autosaveEnabled = false
        let installation = UUID().uuidString
        let revision = CloudDataRevision(itemKey: preferenceKey, clock: 5, installationID: installation, payload: marker)
        switch mode {
        case "clock": revision.logicalClock = 0
        case "installation": revision.installationID = "invalid-installation"
        default: revision.isTombstone = true // Live bytes/digest cannot be a tombstone.
        }
        context.insert(revision)
        for item in [emailKey, ledgerKey, taskKey] {
            context.insert(CloudDataRevision(itemKey: item, clock: 1, installationID: installation, payload: portable[item]))
        }
        try context.save()
        let journalURL = root.appendingPathComponent("journal.json")
        var engine = try FullCloudSyncEngine(cloud: ModelContext(cloud), installationID: UUID().uuidString, journalURL: journalURL)
        var restoredMail = Set<String>()
        func reconcile() async throws {
            let snapshot = try target.capture()
            let preferences = try CloudPreferenceStore.capture(defaults: targetDefaults)
            var local = snapshot
            local.merge(preferences) { _, value in value }
            try await engine.reconcile(digests: local.mapValues(CloudFileStore.digest), load: { local[$0] },
                apply: { item, payload in
                    if CloudPreferenceStore.isPreferenceKey(item) {
                        try CloudPreferenceStore.apply(key: item, payload: payload,
                            expectedDigest: preferences[item].map(CloudFileStore.digest), defaults: targetDefaults)
                    } else {
                        if item == emailKey || item == ledgerKey {
                            #expect(targetDefaults.integer(forKey: versionKey) == GmailIMAPContentMigration.currentVersion)
                            restoredMail.insert(item)
                        }
                        try target.apply(item, payload)
                        try target.save()
                    }
                })
        }
        await #expect(throws: FullCloudSyncError.invalidRevision) { try await reconcile() }
        #expect(targetDefaults.integer(forKey: versionKey) != GmailIMAPContentMigration.currentVersion)
        #expect(local.body == "Existing local original must stay untouched")
        #expect(local.htmlBody == "<p>Existing local original</p>")
        #expect(local.analysisSummary == "Existing local analysis")
        #expect(ledger.stateRawValue == "local-ledger-must-stay")
        #expect(restoredMail.isEmpty)
        #expect(engine.journal.items[emailKey] == nil && engine.journal.items[ledgerKey] == nil)
        #expect(engine.journal.pendingApplies[emailKey] == nil && engine.journal.pendingApplies[ledgerKey] == nil)
        #expect(engine.journal.items[taskKey] != nil)
        #expect(try target.app.fetch(FetchDescriptor<Todo>()).first?.title == records.todo.title)
        revision.logicalClock = 5
        revision.installationID = installation
        revision.isTombstone = false
        try context.save()
        engine = try FullCloudSyncEngine(cloud: ModelContext(cloud), installationID: UUID().uuidString, journalURL: journalURL)
        try await reconcile()
        #expect(restoredMail == [emailKey, ledgerKey])
        #expect(local.body == records.email.body && local.htmlBody == records.email.htmlBody)
        #expect(local.analysisSummary == records.email.analysisSummary)
        #expect(ledger.stateRawValue == records.ledger.stateRawValue)
        // This call returns at the version guard, before any Keychain/ledger access.
        #expect(try !GmailIMAPContentMigration.migrateIfNeeded(account: account, context: target.email, defaults: targetDefaults))
        #expect(local.body == records.email.body && local.analysisSummary == records.email.analysisSummary)
    }

    private struct Records {
        let todo: Todo
        let persona: Persona
        let audit: TaskAuditEvent
        let behavior: TaskBehaviorEvent
        let analysis: MemoryAnalysis
        let ledger: MailAnalysisLedgerRecord
        let email: EmailMessage
        let meeting: MeetingRecord
        let glossary: MeetingGlossaryTerm
        let metadata: VocabularyStoreMetadata
        let source: VocabularySourceState
        let observation: VocabularyObservation
    }

    private let date = Date(timeIntervalSinceReferenceDate: 800_000_000.123456)

    private func seed(_ stores: Stores) -> Records {
        let todo = Todo(title: "Edited calendar task", notes: "Full notes 한글", startDate: date,
            dueDate: date.addingTimeInterval(7200), source: .email, sourceRef: "message/ref",
            tags: ["work", "ordered", "work"], reminderOffsets: [-3600, -61.25, 0])
        todo.createdAt = date.addingTimeInterval(-500)
        todo.updatedAt = date
        todo.isCompleted = true
        todo.completedAt = date.addingTimeInterval(600)
        todo.manualPriority = 3
        todo.computedPriorityScore = 0.8125
        todo.priorityReason = "Raw reason"
        todo.estimatedDurationMinutes = 75
        todo.sourceSender = "Sender"
        todo.sourceMessageID = "<message@example.com>"
        todo.sourceThreadID = "thread"
        todo.sourceSenderEmail = "sender@example.com"
        todo.sourceAccountNamespace = "account"
        todo.sourceItemID = "durable-action-identity"
        todo.triageStatus = "future-triage-value"
        todo.calendarEventID = "event"
        todo.calendarEventExternalID = "external"
        todo.calendarEventOrigin = "future-origin"
        todo.calendarSyncedTitle = "Upstream title before local edit"
        todo.memoryNotes = "Pattern notes"
        todo.aiRecommendedTime = date.addingTimeInterval(50)
        todo.aiNeedsNotification = true
        todo.aiPersonaFit = true
        todo.aiDetail = "Detailed response"
        todo.aiEngine = "future-engine"
        todo.aiRequestedProvider = "requested-provider"
        todo.aiFallbackReason = "raw-fallback"
        todo.isFixedSchedule = true
        stores.app.insert(todo)

        let persona = Persona(descriptionText: "Personal values")
        persona.personaTypeRaw = "student,future-persona"
        persona.updatedAt = date
        stores.app.insert(persona)

        let audit = TaskAuditEvent(from: todo)
        audit.deletedAt = date.addingTimeInterval(800)
        stores.app.insert(audit)
        let behavior = TaskBehaviorEvent(todo: todo, type: .created, actor: .system, occurredAt: date)
        behavior.eventTypeRaw = "future-event"
        behavior.actorRaw = "future-actor"
        behavior.beforeCompletion = false
        behavior.afterCompletion = true
        behavior.beforeDueDate = date
        behavior.afterDueDate = date.addingTimeInterval(7200)
        behavior.beforeManualPriority = 1
        behavior.afterManualPriority = 3
        behavior.beforeComputedPriority = 0.125
        behavior.afterComputedPriority = 0.8125
        stores.app.insert(behavior)

        let analysis = MemoryAnalysis(summary: "Raw summary", insights: ["first", "second"], fastTags: ["tag"],
            overdueRate: 0.125, productiveHour: 17, recordTitle: "Record title",
            accessScopeSummary: "All selected sources", processorDescription: "Raw processor metadata")
        analysis.createdAt = date
        analysis.analysisVersion = 99
        analysis.windowStart = date.addingTimeInterval(-10_000)
        analysis.windowEnd = date
        analysis.sampleCount = 71
        analysis.effectiveSampleSize = 63.25
        analysis.confidenceRaw = "future-confidence"
        // Deliberately not a currently decodable BehaviorProfile: transport must
        // preserve the stored bytes, not recompute metadata via its computed getter.
        analysis.behaviorProfileData = Data([0, 255, 7, 12])
        stores.app.insert(analysis)

        let ledger = MailAnalysisLedgerRecord(fingerprintData: Data([0, 1, 255, 17]), revision: 23,
            stateRawValue: "future-state", leaseExpiresAt: date, analyzedAt: date.addingTimeInterval(-20))
        stores.app.insert(ledger)

        let email = EmailMessage(id: "same/id:punctuation", threadID: "thread", subject: "Subject",
            from: "Sender <sender@example.com>", snippet: "Snippet", body: "Body\n원문",
            htmlBody: "<p>Original HTML</p>", receivedAt: date, isRead: true, provider: .gmail,
            rawMessageID: "provider-native", providerGlobalMessageID: "global-message",
            labelIDs: ["INBOX", "CATEGORY_PERSONAL"], isInInbox: true,
            outlookInferenceClassificationRawValue: "other", providerCategoryNames: ["Red", "Blue"],
            providerFolderID: "folder/id", sourceAccountNamespace: "account:a/b")
        email.bodyContentVersion = 1
        email.analysisStateRaw = "future-analysis-state"
        email.analysisSummary = "Summary"
        email.analysisDetail = "Detail"
        email.analysisKeyPoints = ["point A", "point B"]
        email.analysisActionItems = ["action A"]
        email.analysisError = "Historical error"
        email.analysisFailureReasonRaw = "raw-failure"
        email.analyzedBodyFingerprint = "body-fingerprint"
        email.analyzedAt = date
        email.analysisVersion = 51
        email.analysisTodoCandidate = false
        email.analysisTodoCandidateFingerprint = "candidate-fingerprint"
        stores.email.insert(email)

        let meeting = MeetingRecord(meetingID: "source-track", languageTag: "ko-KR",
            automaticLanguageDetection: true, timezoneIdentifier: "Asia/Seoul", summaryLanguageTag: "fr-FR")
        meeting.parentMeetingID = "parent-group"
        meeting.audioTrackIDs = ["microphone", "app-audio"]
        meeting.audioTrackKindRaw = "future-track-kind"
        meeting.audioTrackSourceLabel = "App audio"
        meeting.audioTrackStartSample = 9_007_199_254_740_991
        meeting.createdAt = date.addingTimeInterval(-100)
        meeting.updatedAt = date
        meeting.modeRaw = "future-mode"
        meeting.summaryKindRaw = "future-summary-kind"
        meeting.summaryEngineLabel = "raw-summary-engine"
        meeting.summaryFallbackReasonRaw = "raw-summary-fallback"
        meeting.summaryResultLanguageTag = "fr-FR"
        meeting.summaryFormat = .interview
        meeting.summaryCustomInstructions = "Keep exact quotations"
        meeting.statusRaw = "future-status"
        meeting.transcriptRevision = 31
        meeting.resultData = Data([0, 1, 2, 255])
        meeting.rawResultData = Data([3, 4, 5])
        meeting.appleRawResultData = Data([6, 7, 8])
        meeting.asrSourceRaw = "future-ASR"
        meeting.asrModelRevision = "pinned-revision"
        meeting.asrDetectedLanguages = ["ko", "en", "ko"]
        meeting.offlineASRFailureRaw = "raw-offline-failure"
        meeting.diarizationData = Data([9, 10, 11, 255])
        meeting.refinementEngineLabel = "raw-refinement-engine"
        meeting.refinementFallbackReasonRaw = "raw-refinement-fallback"
        meeting.manifestData = Data([12, 13, 14])
        meeting.retentionUntil = date.addingTimeInterval(100_000)
        meeting.confirmedTodoIDs = [todo.id.uuidString, "another-todo"]
        meeting.disclosureVersionID = "consent-version"
        meeting.importedAudioFileName = "録音.wav"
        stores.meeting.insert(meeting)

        let glossary = MeetingGlossaryTerm(canonical: "Edited spelling", variants: ["variant A", "variant B"],
            category: "project", frequency: 12, source: "editDiff")
        glossary.reverted = true
        glossary.createdAt = date.addingTimeInterval(-100)
        glossary.updatedAt = date
        glossary.lastSeenAt = date.addingTimeInterval(-5)
        glossary.canonicalKey = "edited-spelling"
        glossary.userSpeechAliases = ["speech alias"]
        glossary.userCanonicalizationAliases = ["rewrite alias"]
        glossary.confirmedLegacy = true
        glossary.userConfirmedAt = date
        glossary.rejectedAt = date.addingTimeInterval(10)
        glossary.redirectCanonicalKey = "redirect"
        glossary.exactEvidenceGroupCount = 13
        glossary.highConfidenceExactEvidenceGroupCount = 8
        glossary.correctionEvidenceGroupCount = 4
        glossary.automaticMaxConfidence = 0.9375
        glossary.observedSourceKinds = ["email", "manual"]
        glossary.isDisplayUserEdited = true
        glossary.isCategoryUserEdited = true
        stores.meeting.insert(glossary)

        let metadata = VocabularyStoreMetadata()
        metadata.schemaRepairVersion = 14
        metadata.hmacVerifier = "opaque-verifier"
        metadata.lastCompletedBackfillAt = date
        metadata.lastCompletedBackfillExtractorVersion = 15
        stores.meeting.insert(metadata)
        let source = VocabularySourceState()
        source.sourceKey = "opaque-source-key"
        source.evidenceGroupKey = "opaque-group-key"
        source.sourceKindRaw = "future-source-kind"
        source.contentFingerprint = "opaque-fingerprint"
        source.extractorVersion = 16
        source.enrichmentVersion = 17
        source.enrichmentStatusRaw = "future-status"
        source.lastEnrichmentAttemptAt = date
        source.enrichmentFailureCount = 3
        source.updatedAt = date
        stores.meeting.insert(source)
        let observation = VocabularyObservation()
        observation.canonicalKey = glossary.canonicalKey
        observation.canonicalDisplay = glossary.canonical
        observation.sourceKey = source.sourceKey
        observation.sourceGeneration = source.generation
        observation.evidenceGroupKey = source.evidenceGroupKey
        observation.surfaceKey = "surface-key"
        observation.surfaceDisplay = "Surface spelling"
        observation.roleRaw = "future-role"
        observation.evidenceKindRaw = "future-evidence"
        observation.categoryRaw = "future-category"
        observation.confidence = 0.875
        observation.observedAt = date
        stores.meeting.insert(observation)
        return Records(todo: todo, persona: persona, audit: audit, behavior: behavior, analysis: analysis,
            ledger: ledger, email: email, meeting: meeting, glossary: glossary, metadata: metadata,
            source: source, observation: observation)
    }

    @Test("Calendar source provenance stays local, migrates locally, and old payloads fail closed")
    func calendarSourceProvenanceIsDeviceLocal() throws {
        let source = try Stores(), remote = try Stores(), local = try Stores()
        let task = Todo(title: "Imported", source: .calendar)
        task.calendarSourceID = "device-a-calendar"
        source.app.insert(task)
        let payloads = try source.capture()
        let key = try #require(payloads.keys.first { $0.hasPrefix("Todo/") })
        let payload = try #require(payloads[key])
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let fields = try #require(object["fields"] as? [String: String])
        let sourceData = try #require(fields["calendarSourceID"].flatMap { Data(base64Encoded: $0) })
        #expect(try JSONDecoder().decode(String.self, from: sourceData).isEmpty)

        try remote.apply(key, payload)
        let restored = try #require(remote.app.fetch(FetchDescriptor<Todo>()).first)
        #expect(restored.calendarSourceID.isEmpty)
        restored.calendarSourceID = "previous-local-observation"
        let foreign = try editPayload(payload) { object in
            var fields = try #require(object["fields"] as? [String: String])
            fields["calendarSourceID"] = try JSONEncoder().encode("foreign-calendar").base64EncodedString()
            object["fields"] = fields
        }
        try remote.apply(key, foreign)
        #expect(restored.calendarSourceID.isEmpty)

        let legacy = try editPayload(payload) { object in
            var fields = try #require(object["fields"] as? [String: String])
            fields.removeValue(forKey: "calendarSourceID")
            object["fields"] = fields
        }
        restored.calendarSourceID = "previous-local-observation"
        try remote.apply(key, legacy)
        #expect(restored.calendarSourceID.isEmpty)

        try CloudModelCodec.mergeMainStore(from: source.app, into: local.app)
        let migrated = try #require(local.app.fetch(FetchDescriptor<Todo>()).first)
        #expect(migrated.calendarSourceID == "device-a-calendar")
        #expect(task.calendarSourceID == "device-a-calendar")
    }

    @Test("Pre-action-identity Todos restore without losing their source or blocking updates", arguments: [false, true])
    func legacyTodoSourceItemIdentityCompatibility(updating: Bool) throws {
        let source = try Stores(), destination = try Stores()
        let rows = seed(source)
        let payloads = try source.capture()
        let key = "Todo/" + rows.todo.id.uuidString.lowercased()
        let payload = try #require(payloads[key])
        if updating {
            try destination.apply(key, payload)
            try destination.save()
        }
        let legacy = try editPayload(payload) { object in
            var fields = try #require(object["fields"] as? [String: String])
            fields.removeValue(forKey: "sourceItemID")
            object["fields"] = fields
        }
        try destination.apply(key, legacy)
        try destination.save()
        let context = ModelContext(destination.app.container)
        let saved = try context.fetch(FetchDescriptor<Todo>())
        #expect(saved.count == 1)
        let restored = try #require(saved.first)
        #expect(restored.id == rows.todo.id)
        #expect(restored.title == rows.todo.title && restored.notes == rows.todo.notes)
        #expect(restored.sourceRef == rows.todo.sourceRef)
        #expect(restored.sourceMessageID == rows.todo.sourceMessageID)
        #expect(restored.sourceItemID.isEmpty)
    }

    @Test("Legacy-default tasks and fetched mail retain the published 1.0.14 wire field contract", arguments: [0, 1])
    func legacyDefaultEnvelopeCompatibility(bodyVersion: Int) throws {
        let stores = try Stores()
        let rows = seed(stores)
        rows.todo.sourceItemID = ""
        rows.email.bodyContentVersion = bodyVersion
        let payloads = try stores.capture()
        let publishedFields: [String: Set<String>] = [
            "Todo": [
                "id", "title", "notes", "createdAt", "updatedAt", "dueDate", "startDate",
                "isCompleted", "completedAt", "manualPriority", "computedPriorityScore", "priorityReason",
                "reminderOffsets", "estimatedDurationMinutes", "source", "sourceRef", "sourceSender",
                "sourceMessageID", "sourceThreadID", "sourceSenderEmail", "sourceAccountNamespace",
                "triageStatus", "tags", "calendarEventID", "calendarEventExternalID", "calendarSourceID",
                "calendarEventOrigin", "calendarSyncedTitle", "memoryNotes", "aiRecommendedTime",
                "aiNeedsNotification", "aiPersonaFit", "aiDetail", "aiEngine", "aiRequestedProvider",
                "aiFallbackReason", "isFixedSchedule"
            ],
            "EmailMessage": [
                "id", "threadID", "subject", "from", "snippet", "body", "htmlBody", "receivedAt",
                "isRead", "providerRawValue", "rawMessageID", "providerGlobalMessageID", "labelIDs",
                "isInInbox", "outlookInferenceClassificationRawValue", "providerCategoryNames",
                "providerFolderID", "sourceAccountNamespace", "analysisStateRaw", "analysisSummary",
                "analysisDetail", "analysisKeyPoints", "analysisActionItems", "analysisError",
                "analysisFailureReasonRaw", "analyzedBodyFingerprint", "analyzedAt", "analysisVersion",
                "analysisTodoCandidate", "analysisTodoCandidateFingerprint"
            ]
        ]
        for (entity, expected) in publishedFields {
            let payload = try #require(payloads.first { $0.key.hasPrefix(entity + "/") }?.value)
            let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let fields = try #require(object["fields"] as? [String: String])
            #expect(Set(fields.keys) == expected)
        }
        let restored = try Stores()
        try restored.apply(payloads)
        #expect(try restored.capture() == payloads)
    }

    @Test("Every domain property roundtrips deterministically, including opaque metadata and raw blobs")
    func completeRoundtrip() throws {
        let source = try Stores(), destination = try Stores()
        _ = seed(source)
        try source.save()
        let payloads = try source.capture()
        #expect(payloads.count == 12)
        #expect(Set(payloads.keys.map { String($0.prefix(while: { $0 != "/" })) }) == Set([
            "Todo", "Persona", "TaskAuditEvent", "TaskBehaviorEvent", "MemoryAnalysis", "MailAnalysisLedgerRecord",
            "EmailMessage", "MeetingRecord", "MeetingGlossaryTerm", "VocabularyStoreMetadata", "VocabularySourceState",
            "VocabularyObservation"
        ]))
        #expect(try source.capture() == payloads)
        try destination.apply(payloads)
        #expect(try destination.capture() == payloads)
        try destination.save()
        #expect(try destination.capture() == payloads)
        try destination.apply(payloads)
        #expect(try destination.capture() == payloads)
        let restored = try #require(destination.app.fetch(FetchDescriptor<Todo>()).first)
        #expect(restored.calendarSyncedTitle == "Upstream title before local edit")
        let analysis = try #require(destination.app.fetch(FetchDescriptor<MemoryAnalysis>()).first)
        #expect(analysis.analysisVersion == 99 && analysis.sampleCount == 71)
        #expect(analysis.behaviorProfileData == Data([0, 255, 7, 12]))
    }

    @Test("Mail app attention stays device-local across cloud restores")
    func mailAttentionStaysDeviceLocal() throws {
        let source = try Stores(), destination = try Stores()
        let rows = seed(source)
        rows.email.hasBeenViewedInApp = false
        let unseenPayload = try source.capture()
        rows.email.hasBeenViewedInApp = true
        #expect(try source.capture() == unseenPayload)
        let mailKey = try #require(unseenPayload.keys.first { $0.hasPrefix("EmailMessage/") })
        let mailData = try #require(unseenPayload[mailKey])
        let envelope = try #require(JSONSerialization.jsonObject(with: mailData) as? [String: Any])
        let fields = try #require(envelope["fields"] as? [String: Any])
        #expect(fields["hasBeenViewedInApp"] == nil)
        try destination.apply(unseenPayload)
        let restored = try #require(destination.email.fetch(FetchDescriptor<EmailMessage>()).first)
        #expect(restored.hasBeenViewedInApp)
        restored.hasBeenViewedInApp = false
        rows.email.subject = "Remote subject update"
        try destination.apply(source.capture())
        #expect(restored.subject == "Remote subject update")
        #expect(!restored.hasBeenViewedInApp)
    }

    @Test("Cloud metadata keeps identical local complete-body evidence, but changed bodies invalidate it", arguments: [false, true])
    func completeBodyProvenanceCompatibility(resolvingConflict: Bool) throws {
        let source = try Stores(), destination = try Stores()
        let rows = seed(source)
        #expect(rows.email.hasCompleteBody)
        let payloads = try source.capture()
        let key = try #require(payloads.keys.first { $0.hasPrefix("EmailMessage/") })
        let payload = try #require(payloads[key])
        try destination.apply(key, payload)
        let restored = try #require(destination.email.fetch(FetchDescriptor<EmailMessage>()).first)
        #expect(!restored.hasCompleteBody)
        #expect(restored.body == rows.email.body)
        restored.bodyContentVersion = 1
        #expect(restored.hasCompleteBody)
        rows.email.isRead.toggle()
        let metadataPayload = try #require(source.capture()[key])
        try CloudModelCodec.apply(key: key, payload: metadataPayload, app: destination.app,
            email: destination.email, meeting: destination.meeting, resolvingConflict: resolvingConflict)
        #expect(restored.hasCompleteBody)
        #expect(restored.isRead == rows.email.isRead)
        rows.email.body = "Changed cloud body without this device's fetch"
        let updatedPayload = try #require(source.capture()[key])
        try CloudModelCodec.apply(key: key, payload: updatedPayload, app: destination.app,
            email: destination.email, meeting: destination.meeting, resolvingConflict: resolvingConflict)
        #expect(!restored.hasCompleteBody)
        #expect(restored.body == rows.email.body)
        #expect(rows.email.hasCompleteBody)
    }

    @Test("A device without a provider fetch reuses synced complete-body analysis without publishing a failure")
    func verifiedSyncedAnalysisSurvivesUnavailableProvider() async throws {
        let source = try Stores(), destination = try Stores()
        let rows = seed(source)
        rows.email.analysisState = .analyzed
        rows.email.analysisVersion = EmailAnalysisContract.summaryContractVersion
        rows.email.analysisFailureReasonRaw = nil
        rows.email.analyzedBodyFingerprint = EmailAnalysisContract.fingerprint(
            subject: rows.email.subject, body: rows.email.body)
        rows.email.analysisSummary = "Synced complete-body summary"
        rows.email.analysisActionItems = ["Review the complete message"]
        let payloads = try source.capture()
        let key = try #require(payloads.keys.first { $0.hasPrefix("EmailMessage/") })
        let payload = try #require(payloads[key])
        try destination.apply(key, payload)
        try destination.save()
        let restored = try #require(destination.email.fetch(FetchDescriptor<EmailMessage>()).first)
        #expect(!restored.hasCompleteBody)
        #expect(EmailAnalysisContract.currentActionItems(for: restored) == ["Review the complete message"])
        #expect(mailboxAnalysisCandidates(from: [restored], lookbackDays: 7,
            now: restored.receivedAt).isEmpty)
        let before = try destination.capture()
        let unavailable = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: { _, _, _, _ in throw URLError(.notConnectedToInternet) },
            foundationModelsEnabledProvider: { true }, foundationModelsAvailabilityProvider: { true })
        try await unavailable.analyze(restored, context: destination.email)
        #expect(try destination.capture() == before)
        #expect(restored.analysisState == .analyzed)
        #expect(restored.analysisSummary == "Synced complete-body summary")
        #expect(EmailAnalysisContract.todoCandidate(for: restored) == true)
    }

    @Test("body-attempt rotation remains device-local and survives remote mail updates")
    func bodyAttemptRotationIsDeviceLocal() throws {
        let source = try Stores(), destination = try Stores()
        let rows = seed(source)
        let before = try source.capture()
        rows.email.lastBodyFetchAttemptAt = Date(timeIntervalSince1970: 1234)
        #expect(try source.capture() == before)
        try destination.apply(before)
        let restored = try #require(destination.email.fetch(FetchDescriptor<EmailMessage>()).first)
        #expect(restored.lastBodyFetchAttemptAt == .distantPast)
        let localAttempt = Date(timeIntervalSince1970: 5678)
        restored.lastBodyFetchAttemptAt = localAttempt
        rows.email.subject = "Updated mail metadata"
        try destination.apply(source.capture())
        #expect(restored.lastBodyFetchAttemptAt == localAttempt)
    }

    @Test("Upsert clears optional values and arrays instead of keeping stale destination values")
    func clearsNilsAndArrays() throws {
        let source = try Stores(), destination = try Stores()
        let rows = seed(source)
        try destination.apply(source.capture())
        rows.todo.startDate = nil
        rows.todo.dueDate = nil
        rows.todo.completedAt = nil
        rows.todo.manualPriority = nil
        rows.todo.calendarEventID = nil
        rows.todo.aiRecommendedTime = nil
        rows.todo.tags = []
        rows.todo.reminderOffsets = []
        rows.audit.completedAt = nil
        rows.audit.dueDate = nil
        rows.audit.tags = []
        rows.behavior.todoCreatedAt = nil
        rows.behavior.beforeCompletion = nil
        rows.behavior.afterCompletion = nil
        rows.behavior.beforeDueDate = nil
        rows.behavior.afterDueDate = nil
        rows.behavior.beforeManualPriority = nil
        rows.behavior.afterManualPriority = nil
        rows.behavior.beforeComputedPriority = nil
        rows.behavior.afterComputedPriority = nil
        rows.analysis.productiveHour = nil
        rows.analysis.windowStart = nil
        rows.analysis.windowEnd = nil
        rows.analysis.insights = []
        rows.analysis.fastTags = []
        rows.ledger.leaseExpiresAt = nil
        rows.ledger.analyzedAt = nil
        rows.email.htmlBody = nil
        rows.email.analysisTodoCandidate = nil
        rows.email.analysisFailureReasonRaw = nil
        rows.email.analyzedAt = nil
        rows.email.labelIDs = []
        rows.email.providerCategoryNames = []
        rows.email.analysisKeyPoints = []
        rows.email.analysisActionItems = []
        rows.meeting.parentMeetingID = nil
        rows.meeting.audioTrackKindRaw = nil
        rows.meeting.audioTrackSourceLabel = nil
        rows.meeting.summaryKindRaw = nil
        rows.meeting.summaryFallbackReasonRaw = nil
        rows.meeting.summaryResultLanguageTag = nil
        rows.meeting.rawResultData = nil
        rows.meeting.appleRawResultData = nil
        rows.meeting.asrModelRevision = nil
        rows.meeting.offlineASRFailureRaw = nil
        rows.meeting.diarizationData = nil
        rows.meeting.refinementFallbackReasonRaw = nil
        rows.meeting.retentionUntil = nil
        rows.meeting.importedAudioFileName = nil
        rows.meeting.audioTrackIDs = []
        rows.meeting.asrDetectedLanguages = []
        rows.meeting.automaticLanguageDetection = false
        rows.meeting.confirmedTodoIDs = []
        rows.glossary.userConfirmedAt = nil
        rows.glossary.rejectedAt = nil
        rows.glossary.variants = []
        rows.glossary.userSpeechAliases = []
        rows.glossary.userCanonicalizationAliases = []
        rows.glossary.observedSourceKinds = []
        rows.metadata.lastCompletedBackfillAt = nil
        rows.source.lastEnrichmentAttemptAt = nil
        let cleared = try source.capture()
        try destination.apply(cleared)
        #expect(try destination.capture() == cleared)
    }

    @Test("Tombstones delete every supported entity without saving other contexts")
    func tombstonesAndNoImplicitSave() throws {
        let stores = try Stores()
        _ = seed(stores)
        try stores.save()
        let keys = try stores.capture().keys.sorted()
        let unsaved = Todo(title: "Unrelated pending edit")
        stores.app.insert(unsaved)
        for key in keys { try stores.apply(key, nil) }
        #expect(try stores.capture().count == 1)
        let persisted = ModelContext(stores.app.container)
        #expect(try persisted.fetch(FetchDescriptor<Todo>()).count == 1)
        #expect(try persisted.fetch(FetchDescriptor<Todo>()).first?.title == "Edited calendar task")
        let persistedEmail = ModelContext(stores.email.container)
        #expect(try persistedEmail.fetch(FetchDescriptor<EmailMessage>()).count == 1)
        let persistedMeeting = ModelContext(stores.meeting.container)
        #expect(try persistedMeeting.fetch(FetchDescriptor<MeetingRecord>()).count == 1)
    }

    private func editPayload(_ payload: Data, _ edit: (inout [String: Any]) throws -> Void) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        try edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @Test("legacy meeting payloads default to manual and upserts replace automatic mode without changing locales")
    func legacyMeetingDefaultsManual() throws {
        let source = try Stores(), destination = try Stores()
        _ = seed(source)
        let payloads = try source.capture()
        let key = try #require(payloads.keys.first { $0.hasPrefix("MeetingRecord/") })
        let payload = try #require(payloads[key])
        try destination.apply(key, payload)
        let saved = try #require(destination.meeting.fetch(FetchDescriptor<MeetingRecord>()).first)
        #expect(saved.automaticLanguageDetection)
        let legacy = try editPayload(payload) { object in
            var fields = try #require(object["fields"] as? [String: String])
            fields.removeValue(forKey: "automaticLanguageDetection")
            fields.removeValue(forKey: "summaryFormatRaw")
            fields.removeValue(forKey: "summaryCustomInstructions")
            object["fields"] = fields
        }
        try destination.apply(key, legacy)
        try destination.save()
        let restoredContext = ModelContext(destination.meeting.container)
        let restored = try #require(restoredContext.fetch(FetchDescriptor<MeetingRecord>()).first)
        #expect(!restored.automaticLanguageDetection)
        #expect(restored.languageTag == "ko-KR")
        #expect(restored.summaryLanguageTag == "fr-FR")
        #expect(restored.summaryFormat == .minutes)
        #expect(restored.summaryCustomInstructions.isEmpty)
        #expect(restored.asrDetectedLanguages == ["ko", "en", "ko"])
        #expect(restored.resultData == Data([0, 1, 2, 255]))
        let recaptured = try #require(destination.capture()[key])
        let fields = try #require((JSONSerialization.jsonObject(with: recaptured) as? [String: Any])?["fields"] as? [String: String])
        let encodedMode = try #require(fields["automaticLanguageDetection"].flatMap { Data(base64Encoded: $0) })
        #expect(try JSONDecoder().decode(Bool.self, from: encodedMode) == false)
    }

    @Test("Malformed, unknown, wrong-identity and future-version payloads fail before mutation")
    func malformedInputsAreAtomic() throws {
        let stores = try Stores()
        _ = seed(stores)
        let original = try stores.capture()
        let key = try #require(original.keys.first(where: { $0.hasPrefix("Todo/") }))
        let payload = try #require(original[key])
        let missing = try editPayload(payload) { object in
            var fields = try #require(object["fields"] as? [String: String])
            fields.removeValue(forKey: "title")
            object["fields"] = fields
        }
        let extra = try editPayload(payload) { object in
            var fields = try #require(object["fields"] as? [String: String])
            fields["futureUnsupportedProperty"] = Data("[]".utf8).base64EncodedString()
            object["fields"] = fields
        }
        let wrongType = try editPayload(payload) { object in
            var fields = try #require(object["fields"] as? [String: String])
            fields["isCompleted"] = Data("\"not a bool\"".utf8).base64EncodedString()
            object["fields"] = fields
        }
        let version = try editPayload(payload) { $0["version"] = 999 }
        let identity = try editPayload(payload) { $0["identity"] = UUID().uuidString.lowercased() }
        for malformed in [missing, extra, wrongType, version, identity, Data("not JSON".utf8)] {
            #expect(throws: (any Error).self) { try stores.apply(key, malformed) }
            #expect(try stores.capture() == original)
        }
        for invalidKey in ["UnknownEntity/id", "Todo/", "Todo/not-a-uuid", key + "/extra"] {
            #expect(throws: (any Error).self) { try stores.apply(invalidKey, nil) }
            #expect(try stores.capture() == original)
        }
    }

    @Test("Health content and known linked audit/behavior events never leave capture or accept restore")
    func healthExclusionAndRestoreProtection() throws {
        let stores = try Stores()
        let ordinary = seed(stores)
        let normalPayloads = try stores.capture()
        let todoKey = "Todo/" + ordinary.todo.id.uuidString.lowercased()
        let todoPayload = try #require(normalPayloads[todoKey])
        let healthPayload = try editPayload(todoPayload) { object in
            var fields = try #require(object["fields"] as? [String: String])
            fields["sourceRef"] = try JSONEncoder().encode("HeAlTh:private-origin").base64EncodedString()
            object["fields"] = fields
        }
        #expect(throws: CloudModelCodec.CodecError.healthDataExcluded) { try stores.apply(todoKey, healthPayload) }
        #expect(try stores.capture() == normalPayloads)
        // The original calendar provenance is also a health boundary without a health: prefix.
        ordinary.todo.calendarEventOrigin = CalendarEventOrigin.siftHealth.rawValue
        #expect(try stores.capture().count == normalPayloads.count - 3)
        #expect(try stores.capture()[todoKey] == nil)
        #expect(throws: CloudModelCodec.CodecError.healthDataExcluded) { try stores.apply(todoKey, todoPayload) }
        #expect(throws: CloudModelCodec.CodecError.healthDataExcluded) { try stores.apply(todoKey, nil) }
        for prefix in ["TaskAuditEvent/", "TaskBehaviorEvent/"] {
            let key = try #require(normalPayloads.keys.first(where: { $0.hasPrefix(prefix) }))
            #expect(throws: CloudModelCodec.CodecError.healthDataExcluded) { try stores.apply(key, normalPayloads[key]) }
            #expect(throws: CloudModelCodec.CodecError.healthDataExcluded) { try stores.apply(key, nil) }
        }
        #expect(try stores.app.fetch(FetchDescriptor<Todo>()).count == 1)
    }

    @Test("Provider/account mail identities do not collide, glossary edits keep their durable IDs")
    func portableIdentities() throws {
        let source = try Stores(), destination = try Stores()
        let records = seed(source)
        let sameProviderID = EmailMessage(id: records.email.id, sourceAccountNamespace: "second-account")
        let differentProvider = EmailMessage(id: records.email.id, provider: .outlook,
            sourceAccountNamespace: records.email.sourceAccountNamespace)
        source.email.insert(sameProviderID)
        source.email.insert(differentProvider)
        let original = try source.capture()
        #expect(original.keys.filter { $0.hasPrefix("EmailMessage/") }.count == 3)
        let glossaryKey = try #require(original.keys.first(where: { $0.hasPrefix("MeetingGlossaryTerm/") }))
        let observationKey = try #require(original.keys.first(where: { $0.hasPrefix("VocabularyObservation/") }))
        let ledgerKey = try #require(original.keys.first(where: { $0.hasPrefix("MailAnalysisLedgerRecord/") }))
        records.glossary.canonical = "User edited spelling again"
        records.glossary.canonicalKey = "new-normalization"
        records.observation.surfaceDisplay = "Corrected surface"
        records.ledger.revision += 1
        records.ledger.stateRawValue = "analyzed"
        let edited = try source.capture()
        #expect(edited[glossaryKey] != nil && edited[observationKey] != nil && edited[ledgerKey] != nil)
        try destination.apply(edited)
        #expect(try destination.capture() == edited)
    }
    @Test("Legacy ledger natural identity is identical across independent stores")
    func ledgerNaturalIdentityAcrossStores() throws {
        let first = try Stores(), second = try Stores()
        let fingerprint = Data([3, 1, 4, 1, 5, 9])
        first.app.insert(MailAnalysisLedgerRecord(fingerprintData: fingerprint, revision: 1, stateRawValue: "processing"))
        second.app.insert(MailAnalysisLedgerRecord(fingerprintData: fingerprint, revision: 9, stateRawValue: "analyzed"))
        let firstPayloads = try first.capture(), secondPayloads = try second.capture()
        #expect(Set(firstPayloads.keys) == Set(secondPayloads.keys))
        #expect(firstPayloads != secondPayloads)
    }

    @Test("Equivalent physical duplicates export once and every local copy accepts remote updates")
    func equivalentDuplicatesMakeForwardProgressWithoutDeletingRows() throws {
        let stores = try Stores(), remote = try Stores()
        let first = seed(stores)
        let original = try stores.capture()
        let second = seed(stores)
        // Recreate all twelve portable identities, not SwiftData object identities.
        // Every other seeded field is deterministic, including raw blobs/metadata.
        second.todo.id = first.todo.id
        second.persona.id = first.persona.id
        second.audit.id = first.audit.id
        second.audit.todoID = first.todo.id
        second.behavior.id = first.behavior.id
        second.behavior.todoID = first.todo.id
        second.analysis.id = first.analysis.id
        second.meeting.confirmedTodoIDs = first.meeting.confirmedTodoIDs
        second.glossary.id = first.glossary.id
        second.source.generation = first.source.generation
        second.observation.id = first.observation.id
        second.observation.sourceGeneration = first.source.generation
        first.email.hasBeenViewedInApp = false
        second.email.hasBeenViewedInApp = true
        try stores.save()

        #expect(try stores.capture() == original)
        #expect(!stores.app.hasChanges && !stores.email.hasChanges && !stores.meeting.hasChanges)
        try remote.apply(stores.capture())
        #expect(try remote.capture() == original)
        let remoteTodo = try #require(remote.app.fetch(FetchDescriptor<Todo>()).first)
        let remoteEmail = try #require(remote.email.fetch(FetchDescriptor<EmailMessage>()).first)
        let remoteMetadata = try #require(remote.meeting.fetch(FetchDescriptor<VocabularyStoreMetadata>()).first)
        remoteTodo.title = "Remote updated task"
        remoteTodo.notes = "Complete new notes"
        remoteTodo.updatedAt = date.addingTimeInterval(100)
        remoteEmail.subject = "Remote updated subject"
        remoteMetadata.hmacVerifier = "updated-opaque-verifier"
        remoteMetadata.lastCompletedBackfillAt = nil
        let updated = try remote.capture()
        try stores.apply(updated)
        #expect(first.todo.title == remoteTodo.title && second.todo.title == remoteTodo.title)
        #expect(first.todo.notes == remoteTodo.notes && second.todo.notes == remoteTodo.notes)
        #expect(first.metadata.hmacVerifier == remoteMetadata.hmacVerifier)
        #expect(second.metadata.hmacVerifier == remoteMetadata.hmacVerifier)
        #expect(first.metadata.lastCompletedBackfillAt == nil && second.metadata.lastCompletedBackfillAt == nil)
        #expect(first.email.subject == remoteEmail.subject && second.email.subject == remoteEmail.subject)
        #expect(!first.email.hasBeenViewedInApp && second.email.hasBeenViewedInApp)
        #expect(try stores.capture() == updated)
        try stores.apply(updated)
        try stores.save()
        #expect(try stores.capture() == updated)
        #expect(try stores.app.fetchCount(FetchDescriptor<Todo>()) == 2)
        #expect(try stores.app.fetchCount(FetchDescriptor<Persona>()) == 2)
        #expect(try stores.app.fetchCount(FetchDescriptor<TaskAuditEvent>()) == 2)
        #expect(try stores.app.fetchCount(FetchDescriptor<TaskBehaviorEvent>()) == 2)
        #expect(try stores.app.fetchCount(FetchDescriptor<MemoryAnalysis>()) == 2)
        #expect(try stores.app.fetchCount(FetchDescriptor<MailAnalysisLedgerRecord>()) == 2)
        #expect(try stores.email.fetchCount(FetchDescriptor<EmailMessage>()) == 2)
        #expect(try stores.meeting.fetchCount(FetchDescriptor<MeetingRecord>()) == 2)
        #expect(try stores.meeting.fetchCount(FetchDescriptor<MeetingGlossaryTerm>()) == 2)
        #expect(try stores.meeting.fetchCount(FetchDescriptor<VocabularyStoreMetadata>()) == 2)
        #expect(try stores.meeting.fetchCount(FetchDescriptor<VocabularySourceState>()) == 2)
        #expect(try stores.meeting.fetchCount(FetchDescriptor<VocabularyObservation>()) == 2)
    }

    @Test("A divergent identity holds its versions and recovery state while a healthy edit syncs",
          arguments: ["checkpoint", "pendingApply", "pendingPublication"])
    func conflictingIdentityDoesNotStarveHealthyData(recovery: String) async throws {
        let stores = try Stores()
        let conflicted = Todo(title: "Original conflicted task")
        let healthy = Todo(title: "Original healthy task")
        stores.app.insert(conflicted)
        stores.app.insert(healthy)
        try stores.save()
        let conflictKey = "Todo/" + conflicted.id.uuidString.lowercased()
        let healthyKey = "Todo/" + healthy.id.uuidString.lowercased()
        let baseline = try stores.capture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SIFTConflictHold-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cloudSchema = Schema([CloudDataRevision.self])
        let cloud = try ModelContainer(for: cloudSchema, configurations: [
            ModelConfiguration(schema: cloudSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(cloud)
        let installation = UUID().uuidString
        let journalURL = root.appendingPathComponent("journal.json")
        let initial = try FullCloudSyncEngine(cloud: context, installationID: installation, journalURL: journalURL)
        try await initial.reconcile(digests: baseline.mapValues(CloudFileStore.digest),
            load: { baseline[$0] }, apply: { _, _ in Issue.record("Initial local records must publish") })
        let checkpoint = try #require(initial.journal.items[conflictKey])
        let remote = CloudDataRevision(itemKey: conflictKey, clock: checkpoint.logicalClock + 1,
            installationID: UUID().uuidString, payload: baseline[conflictKey])
        context.insert(remote)
        try context.save()
        let remoteCheckpoint = CloudSyncCheckpoint(digest: checkpoint.digest, revisionID: remote.revisionID,
            logicalClock: remote.logicalClock, installationID: remote.installationID)
        var journal = initial.journal
        if recovery == "pendingApply" {
            journal.pendingApplies[conflictKey] = CloudSyncPendingApply(sourceDigest: checkpoint.digest,
                target: remoteCheckpoint)
        } else if recovery == "pendingPublication" {
            journal.pendingPublications[conflictKey] = CloudSyncCheckpoint(digest: checkpoint.digest,
                revisionID: UUID(), logicalClock: remote.logicalClock + 1, installationID: installation)
        }
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        let heldRevisions = try context.fetch(FetchDescriptor<CloudDataRevision>()).filter { $0.itemKey == conflictKey }
        let heldIDs = Set(heldRevisions.map(\.revisionID))
        let second = Todo(id: conflicted.id, title: "Different local version")
        let third = Todo(id: conflicted.id, title: "Third local version")
        stores.app.insert(second)
        stores.app.insert(third)
        healthy.title = "Healthy edit must reach the cloud"
        try stores.save()
        let snapshot = try CloudModelCodec.capture(app: stores.app, email: stores.email, meeting: stores.meeting)
        #expect(snapshot.conflictingKeys == [conflictKey])
        #expect(snapshot.records[conflictKey] == nil)
        let held = try FullCloudSyncEngine(cloud: context, installationID: installation, journalURL: journalURL)
        for _ in 0..<2 {
            try await held.reconcile(digests: snapshot.records.mapValues(CloudFileStore.digest),
                temporarilyUnavailable: snapshot.conflictingKeys, load: { key in
                    #expect(key != conflictKey)
                    return snapshot.records[key]
                }, apply: { _, _ in Issue.record("A conflicted local version must not be restored over") })
        }
        let after = try context.fetch(FetchDescriptor<CloudDataRevision>())
        let conflictRevisions = after.filter { $0.itemKey == conflictKey }
        #expect(Set(conflictRevisions.map(\.revisionID)) == heldIDs)
        #expect(conflictRevisions.allSatisfy { !$0.isTombstone && $0.payload == baseline[conflictKey] })
        #expect(after.first { $0.itemKey == healthyKey }?.payload == snapshot.records[healthyKey])
        #expect(conflicted.title == "Original conflicted task")
        #expect(second.title == "Different local version" && third.title == "Third local version")
        #expect(try stores.app.fetchCount(FetchDescriptor<Todo>()) == 4)
        let restarted = try FullCloudSyncEngine(cloud: ModelContext(cloud), installationID: installation, journalURL: journalURL)
        #expect(restarted.journal.items[conflictKey] == checkpoint)
        #expect(restarted.journal.pendingApplies[conflictKey]?.sourceDigest == journal.pendingApplies[conflictKey]?.sourceDigest)
        #expect(restarted.journal.pendingApplies[conflictKey]?.target == journal.pendingApplies[conflictKey]?.target)
        #expect(restarted.journal.pendingPublications[conflictKey] == journal.pendingPublications[conflictKey])
        // Only an explicit local resolution releases the held identity.
        stores.app.delete(second)
        stores.app.delete(third)
        try stores.save()
        let resolved = try CloudModelCodec.capture(app: stores.app, email: stores.email, meeting: stores.meeting)
        #expect(resolved.conflictingKeys.isEmpty)
        try await restarted.reconcile(digests: resolved.records.mapValues(CloudFileStore.digest),
            temporarilyUnavailable: resolved.conflictingKeys, load: { resolved.records[$0] }, apply: { key, payload in
                try stores.apply(key, payload)
                try stores.save()
            })
        #expect(restarted.journal.pendingApplies[conflictKey] == nil)
        #expect(restarted.journal.pendingPublications[conflictKey] == nil)
        #expect(try stores.app.fetchCount(FetchDescriptor<Todo>()) == 2)
        #expect(healthy.title == "Healthy edit must reach the cloud")
    }

    @Test("Different metadata values fail closed before capture or restore can choose a winner",
        arguments: ["schemaRepairVersion", "hmacVerifier", "lastCompletedBackfillAt", "lastCompletedBackfillExtractorVersion"])
    func conflictingMetadataRemainsExplicit(field: String) throws {
        let stores = try Stores()
        let first = VocabularyStoreMetadata()
        stores.meeting.insert(first)
        let original = try stores.capture()
        let key = try #require(original.keys.first)
        let second = VocabularyStoreMetadata()
        switch field {
        case "schemaRepairVersion": second.schemaRepairVersion = 1
        case "hmacVerifier": second.hmacVerifier = "different-opaque-verifier"
        case "lastCompletedBackfillAt": second.lastCompletedBackfillAt = date
        default: second.lastCompletedBackfillExtractorVersion = 1
        }
        stores.meeting.insert(second)
        try stores.save()
        let expected = CloudModelCodec.CodecError.duplicateIdentity(key)
        #expect(throws: expected) { try stores.capture() }
        // Even a payload equal to one local version cannot erase the other.
        #expect(throws: expected) { try stores.apply(key, original[key]) }
        #expect(try stores.meeting.fetchCount(FetchDescriptor<VocabularyStoreMetadata>()) == 2)
        #expect(first.schemaRepairVersion == 0 && first.hmacVerifier.isEmpty)
        #expect(first.lastCompletedBackfillAt == nil && first.lastCompletedBackfillExtractorVersion == 0)
        switch field {
        case "schemaRepairVersion": #expect(second.schemaRepairVersion == 1)
        case "hmacVerifier": #expect(second.hmacVerifier == "different-opaque-verifier")
        case "lastCompletedBackfillAt": #expect(second.lastCompletedBackfillAt == date)
        default: #expect(second.lastCompletedBackfillExtractorVersion == 1)
        }
        #expect(!stores.meeting.hasChanges)
    }

    @Test("Duplicate portable identities are reported rather than silently dropping a row")
    func duplicateIdentityFailsClosed() throws {
        let stores = try Stores()
        let first = Todo(title: "First version")
        stores.app.insert(first)
        let original = try stores.capture()
        let key = try #require(original.keys.first)
        let second = Todo(id: first.id, title: "Different version")
        stores.app.insert(second)
        try stores.save()
        #expect(throws: CloudModelCodec.CodecError.duplicateIdentity(key)) { try stores.capture() }
        #expect(throws: CloudModelCodec.CodecError.duplicateIdentity(key)) { try stores.apply(key, original[key]) }
        #expect(first.title == "First version" && second.title == "Different version")
        #expect(try stores.app.fetch(FetchDescriptor<Todo>()).count == 2)
        #expect(!stores.app.hasChanges)
    }
    @Test("Divergent natural-key ledger versions are retained with deterministic import identities")
    func ledgerConflictMergeIsLosslessAndIdempotent() throws {
        let source = try Stores(), destination = try Stores()
        let fingerprint = Data([2, 7, 1, 8])
        source.app.insert(MailAnalysisLedgerRecord(fingerprintData: fingerprint, revision: 2,
            stateRawValue: "source-state", leaseExpiresAt: date, analyzedAt: nil))
        destination.app.insert(MailAnalysisLedgerRecord(fingerprintData: fingerprint, revision: 7,
            stateRawValue: "destination-state", leaseExpiresAt: nil, analyzedAt: date))
        let originalSource = try source.capture()
        try CloudModelCodec.mergeMainStore(from: source.app, into: destination.app)
        let firstMerge = try destination.capture()
        #expect(firstMerge.count == 2)
        let ledgers = try destination.app.fetch(FetchDescriptor<MailAnalysisLedgerRecord>())
        #expect(Set(ledgers.map(\.revision)) == [2, 7])
        #expect(ledgers.filter { !$0.syncIdentity.isEmpty }.count == 1)
        let restoredSource = try #require(ledgers.first { $0.revision == 2 })
        #expect(restoredSource.leaseExpiresAt == date && restoredSource.analyzedAt == nil)
        #expect(restoredSource.stateRawValue == "source-state")
        try CloudModelCodec.mergeMainStore(from: source.app, into: destination.app)
        #expect(try destination.capture() == firstMerge)
        #expect(try source.capture() == originalSource)
    }

    @Test("Local migration retains health rows even though the cloud boundary excludes them")
    func healthRowsRemainInLocalMerge() throws {
        let source = try Stores(), destination = try Stores()
        let health = Todo(title: "Local health content", sourceRef: "health:private-source")
        let audit = TaskAuditEvent(from: health)
        let behavior = TaskBehaviorEvent(todo: health, type: .created, actor: .system, occurredAt: date)
        source.app.insert(health)
        source.app.insert(audit)
        source.app.insert(behavior)
        #expect(try source.capture().isEmpty)
        try CloudModelCodec.mergeMainStore(from: source.app, into: destination.app)
        let migrated = try #require(destination.app.fetch(FetchDescriptor<Todo>()).first)
        #expect(migrated.id == health.id && migrated.sourceRef == health.sourceRef)
        #expect(try destination.app.fetch(FetchDescriptor<TaskAuditEvent>()).first?.todoID == health.id)
        #expect(try destination.app.fetch(FetchDescriptor<TaskBehaviorEvent>()).first?.todoID == health.id)
        #expect(try destination.capture().isEmpty)
        #expect(try source.app.fetch(FetchDescriptor<Todo>()).count == 1)
    }
}
