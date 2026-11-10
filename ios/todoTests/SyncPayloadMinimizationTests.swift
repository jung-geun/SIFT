import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Sync payload minimization and history retention")
@MainActor
struct SyncPayloadMinimizationTests {
    private func context(_ schema: Schema) throws -> ModelContext {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
        context.autosaveEnabled = false
        return context
    }

    private func mail(_ html: String?) -> EmailMessage {
        let message = EmailMessage(id: "m-1")
        message.providerRawValue = MailProvider.gmail.rawValue
        message.sourceAccountNamespace = "user@example.com"
        message.subject = "Invoice"
        message.body = "Please pay by Friday."
        message.htmlBody = html
        return message
    }

    @Test("Rendering HTML never changes the synced email payload")
    func htmlBodyIsNotSynced() throws {
        let app = try context(AppDataContainer.appSchema)
        let meeting = try context(AppDataContainer.meetingSchema)

        let withHTML = try context(AppDataContainer.emailSchema)
        withHTML.insert(mail("<html><body>" + String(repeating: "<p>x</p>", count: 500) + "</body></html>"))
        try withHTML.save()
        let plainOnly = try context(AppDataContainer.emailSchema)
        plainOnly.insert(mail(nil))
        try plainOnly.save()

        let heavy = try CloudModelCodec.capture(app: app, email: withHTML, meeting: meeting).validatedRecords()
        let light = try CloudModelCodec.capture(app: app, email: plainOnly, meeting: meeting).validatedRecords()
        #expect(heavy == light)
    }

    @Test("Repeated capture of unchanged data is byte-identical, so an idle pass writes nothing")
    func idleCaptureIsDeterministic() throws {
        let app = try context(AppDataContainer.appSchema)
        let email = try context(AppDataContainer.emailSchema)
        let meeting = try context(AppDataContainer.meetingSchema)
        email.insert(mail("<p>html</p>"))
        try email.save()
        app.insert(Todo(title: "stable", tags: ["a"]))
        try app.save()

        let first = try CloudModelCodec.capture(app: app, email: email, meeting: meeting).validatedRecords()
        let second = try CloudModelCodec.capture(app: app, email: email, meeting: meeting).validatedRecords()
        #expect(!first.isEmpty)
        #expect(first == second)
    }

    private struct PassResult { let revisionIDs: Set<UUID>; let applies: Int }

    /// Builds the envelope the previous codec wrote for an email: htmlBody carries the HTML.
    private func legacyEmailPayload(from current: Data) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
        var fields = try #require(object["fields"] as? [String: String])
        fields["htmlBody"] = Data(#""<p>local html</p>""#.utf8).base64EncodedString()
        object["fields"] = fields
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func cloudContext() throws -> ModelContext {
        let schema = Schema([CloudDataRevision.self])
        let cloud = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(cloud)
        context.autosaveEnabled = false
        return context
    }

    @Test("A peer's legacy HTML revision is adopted in one apply and never republished")
    func peerLegacyRevisionIsAdopted() async throws {
        let app = try context(AppDataContainer.appSchema)
        let email = try context(AppDataContainer.emailSchema)
        let meeting = try context(AppDataContainer.meetingSchema)
        email.insert(mail("<p>local html</p>"))
        try email.save()
        let local = try CloudModelCodec.capture(app: app, email: email, meeting: meeting).validatedRecords()
        let emailKey = try #require(local.keys.first { $0.hasPrefix("EmailMessage/") })

        let cloud = try cloudContext()
        cloud.insert(CloudDataRevision(itemKey: emailKey, clock: 1, installationID: UUID().uuidString,
                                       payload: try legacyEmailPayload(from: local[emailKey]!)))
        try cloud.save()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SIFTPeerLegacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try FullCloudSyncEngine(cloud: cloud, installationID: UUID().uuidString,
                                             journalURL: root.appendingPathComponent("journal.json"))
        let peerIDs = Set(try cloud.fetch(FetchDescriptor<CloudDataRevision>()).map(\.revisionID))
        let pass = try await runPass(engine: engine, cloud: cloud, app: app, email: email, meeting: meeting)
        let second = try await runPass(engine: engine, cloud: cloud, app: app, email: email, meeting: meeting)
        let third = try await runPass(engine: engine, cloud: cloud, app: app, email: email, meeting: meeting)
        // Measured: pass 1 adopts the peer's revision with no write; pass 2 writes one checkpoint; pass 3 is idle.
        #expect(pass.applies == 1)
        #expect(pass.revisionIDs == peerIDs)
        #expect(second.applies == 0)
        #expect(second.revisionIDs.subtracting(peerIDs).count == 1)
        #expect(third.applies == 0 && third.revisionIDs == second.revisionIDs)
    }

    @Test("This device's own pre-upgrade checkpoint republishes each HTML mail once, then converges")
    func ownLegacyCheckpointConvergesAfterOneRepublish() async throws {
        let app = try context(AppDataContainer.appSchema)
        let email = try context(AppDataContainer.emailSchema)
        let meeting = try context(AppDataContainer.meetingSchema)
        email.insert(mail("<p>local html</p>"))
        try email.save()
        let current = try CloudModelCodec.capture(app: app, email: email, meeting: meeting).validatedRecords()
        let emailKey = try #require(current.keys.first { $0.hasPrefix("EmailMessage/") })
        var previous = current
        previous[emailKey] = try legacyEmailPayload(from: current[emailKey]!)

        let cloud = try cloudContext()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SIFTOwnLegacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try FullCloudSyncEngine(cloud: cloud, installationID: UUID().uuidString,
                                             journalURL: root.appendingPathComponent("journal.json"))
        // Pre-upgrade run: this device publishes the legacy snapshot and checkpoints its digest.
        _ = try await engine.reconcile(digests: previous.mapValues(CloudFileStore.digest),
            load: { previous[$0] }, apply: { _, _ in Issue.record("Own publish must not apply") })
        try cloud.save()
        #expect(engine.journal.items[emailKey] != nil, "pre-upgrade publish must checkpoint the legacy digest")
        let beforeIDs = Set(try cloud.fetch(FetchDescriptor<CloudDataRevision>()).map(\.revisionID))
        let first = try await runPass(engine: engine, cloud: cloud, app: app, email: email, meeting: meeting)
        let second = try await runPass(engine: engine, cloud: cloud, app: app, email: email, meeting: meeting)
        let third = try await runPass(engine: engine, cloud: cloud, app: app, email: email, meeting: meeting)
        // Disclosed one-time cost: the first upgraded pass writes one replacement revision for the mail.
        #expect(first.revisionIDs.subtracting(beforeIDs).count == 1)
        #expect(first.applies == 0)
        #expect(second.revisionIDs == first.revisionIDs && second.applies == 0)
        #expect(third.revisionIDs == second.revisionIDs && third.applies == 0)
    }

    private func runPass(engine: FullCloudSyncEngine, cloud: ModelContext, app: ModelContext,
                         email: ModelContext, meeting: ModelContext) async throws -> PassResult {
        let snapshot = try CloudModelCodec.capture(app: app, email: email, meeting: meeting).validatedRecords()
        var applies = 0
        _ = try await engine.reconcile(digests: snapshot.mapValues(CloudFileStore.digest),
            load: { snapshot[$0] },
            apply: { key, payload in
                applies += 1
                try CloudModelCodec.apply(key: key, payload: payload, app: app, email: email, meeting: meeting)
                try email.save()
                try app.save()
            })
        try cloud.save()
        let ids = Set(try cloud.fetch(FetchDescriptor<CloudDataRevision>()).map(\.revisionID))
        return PassResult(revisionIDs: ids, applies: applies)
    }

    @Test("Retention prunes by analysis timestamps and keeps a long-lived task deleted recently")
    func retentionBounds() throws {
        let app = try context(AppDataContainer.appSchema)
        let now = Date()
        let day: TimeInterval = 86_400
        let todo = Todo(title: "t")
        app.insert(todo)

        for age in [200.0, 100.0, 1.0] {
            app.insert(TaskBehaviorEvent(todo: todo, type: .created, actor: .user,
                                         occurredAt: now.addingTimeInterval(-age * day)))
        }
        // Created 7 months ago but deleted 5 days ago: the deletion is what the analysis reads.
        let longLived = TaskAuditEvent(from: todo)
        longLived.createdAt = now.addingTimeInterval(-210 * day)
        longLived.deletedAt = now.addingTimeInterval(-5 * day)
        app.insert(longLived)
        // Created yesterday but deleted 200 days ago: outside the window despite the recent creation.
        let staleDeletion = TaskAuditEvent(from: todo)
        staleDeletion.createdAt = now.addingTimeInterval(-1 * day)
        staleDeletion.deletedAt = now.addingTimeInterval(-200 * day)
        app.insert(staleDeletion)
        try app.save()

        let removed = try TaskHistoryRetention.prune(in: app, now: now)
        #expect(removed == 2)
        #expect(try app.fetchCount(FetchDescriptor<TaskBehaviorEvent>()) == 2)
        let audits = try app.fetch(FetchDescriptor<TaskAuditEvent>())
        #expect(audits.count == 1)
        #expect(audits.first?.createdAt == longLived.createdAt)
    }
}
