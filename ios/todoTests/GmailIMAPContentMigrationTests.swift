import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Gmail IMAP content migration", .serialized)
@MainActor
struct GmailIMAPContentMigrationTests {
    @Test("parser migration decodes local rows once and clears legacy discovery cursors")
    func parserMigration() throws {
        let account = "ingest@example.com"
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let defaults = UserDefaults(suiteName: "GmailContentMigration-\(UUID().uuidString)")!
        MailboxUpdateCursorStore(defaults: defaults).setCursor("42:1", for: .gmail, namespace: account)
        let legacyKey = "pieroot.todo.gmailIMAP.ingestionCursor.\(account)"
        defaults.set("42:1", forKey: legacyKey)
        let row = EmailMessage(
            id: "uid-1", subject: "=?UTF-8?B?67O07JWIIA==?= =?UTF-8?B?7JWM66a8?=",
            from: "=?UTF-8?B?7ZWc7J2066y8?= <sender@example.com>", body: "old raw MIME",
            provider: .gmail, rawMessageID: "1", sourceAccountNamespace: account
        )
        row.bodyContentVersion = 1
        row.analysisState = .analyzed
        row.analysisSummary = "old summary"
        context.insert(row)
        let other = EmailMessage(id: "other", body: "Other account original body", sourceAccountNamespace: "other@example.com")
        other.bodyContentVersion = 1
        context.insert(other)
        try context.save()

        #expect(try GmailIMAPContentMigration.migrateIfNeeded(account: account, context: context, defaults: defaults))
        #expect(MailboxUpdateCursorStore(defaults: defaults).cursor(for: .gmail, namespace: account) == nil)
        #expect(defaults.string(forKey: legacyKey) == nil)
        #expect(row.subject == "보안 알림")
        #expect(row.from.contains("<sender@example.com>"))
        #expect(row.body.isEmpty && row.bodyContentVersion == 0)
        #expect(row.analysisState == .unanalyzed)
        #expect(row.analysisSummary.isEmpty)
        #expect(other.body == "Other account original body" && other.bodyContentVersion == 1)
        row.body = "Newly hydrated complete body"
        row.bodyContentVersion = 1
        try context.save()
        #expect(try !GmailIMAPContentMigration.migrateIfNeeded(account: account, context: context, defaults: defaults))
        #expect(row.body == "Newly hydrated complete body" && row.bodyContentVersion == 1)
    }
}
