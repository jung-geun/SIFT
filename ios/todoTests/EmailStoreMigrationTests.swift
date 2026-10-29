import Foundation
import SwiftData
import Testing
@testable import todo

private final class EmailStoreFixtureBundleToken {}

private enum EmailStoreFixtureError: Error {
    case missingResource(String)
}

@MainActor
@Suite("Email store migration")
struct EmailStoreMigrationTests {
    @Test("App-viewed state persists when the local email store is reopened")
    func testAppViewedStateSurvivesStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("attention.store")

        do {
            let container = try AppDataContainer.makeEmailContainer(storeURL: storeURL)
            let context = ModelContext(container)
            let opened = EmailMessage(id: "opened", isInInbox: true)
            opened.hasBeenViewedInApp = false
            let unopened = EmailMessage(id: "unopened", isInInbox: true)
            unopened.hasBeenViewedInApp = false
            context.insert(opened)
            context.insert(unopened)
            try context.save()
            let defaults = try #require(UserDefaults(suiteName: "EmailStoreMigrationTests.\(UUID().uuidString)"))
            let store = MailboxLocalStore(defaults: defaults, saveContext: { try $0.save() })
            try store.markViewedInApp(opened, in: context)
        }

        let reopened = try AppDataContainer.makeEmailContainer(storeURL: storeURL)
        let context = ModelContext(reopened)
        let rows = try context.fetch(FetchDescriptor<EmailMessage>())
        #expect(rows.first { $0.id == "opened" }?.hasBeenViewedInApp == true)
        #expect(rows.first { $0.id == "unopened" }?.isNewlyImportedUnseen == true)
    }

    @Test("pre-provider metadata rows migrate without data loss")
    func testPreProviderMetadataStoreMigration() throws {
        let bundle = Bundle(for: EmailStoreFixtureBundleToken.self)
        let fixtureNames = [
            "email-local-pre-provider-metadata.store",
            "email-local-pre-provider-metadata.store-wal",
            "email-local-pre-provider-metadata.store-shm"
        ]
        let fixtureURLs = try fixtureNames.map { name in
            guard let url = bundle.url(
                forResource: name,
                withExtension: nil,
                subdirectory: "Fixtures"
            ) ?? bundle.url(forResource: name, withExtension: nil) else {
                throw EmailStoreFixtureError.missingResource(name)
            }
            return url
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        for fixtureURL in fixtureURLs {
            try FileManager.default.copyItem(
                at: fixtureURL,
                to: temporaryDirectory.appendingPathComponent(fixtureURL.lastPathComponent)
            )
        }

        let storeURL = temporaryDirectory
            .appendingPathComponent("email-local-pre-provider-metadata.store")
        let container = try AppDataContainer.makeEmailContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let messages = try context.fetch(FetchDescriptor<EmailMessage>())
        #expect(messages.count == 2)
        // Legacy cache is not newly imported merely because the app adds attention state.
        #expect(messages.allSatisfy { $0.hasBeenViewedInApp })
        #expect(messages.allSatisfy { !$0.isNewlyImportedUnseen })

        let gmail = try #require(
            messages.first { $0.providerRawValue == MailProvider.gmail.rawValue }
        )
        #expect(gmail.id == "fixture-gmail-id")
        #expect(gmail.rawMessageID == "fixture-gmail-raw")
        #expect(gmail.threadID == "fixture-gmail-thread")
        #expect(gmail.subject == "Fixture Gmail subject")
        #expect(gmail.from == "gmail-fixture@example.com")
        #expect(gmail.snippet == "Fixture Gmail snippet")
        #expect(gmail.body == "Fixture Gmail body — 고정값")
        #expect(gmail.htmlBody == "<p>Fixture Gmail HTML — 고정값</p>")
        #expect(gmail.receivedAt == Date(timeIntervalSince1970: 1_700_000_001))
        #expect(gmail.isRead)
        #expect(gmail.labelIDs == ["INBOX", "CATEGORY_PERSONAL"])
        #expect(gmail.isInInbox)
        #expect(gmail.analysisStateRaw == EmailAnalysisState.analyzed.rawValue)
        #expect(gmail.analysisSummary == "Fixture Gmail summary")
        #expect(gmail.analysisDetail == "Fixture Gmail detail")
        #expect(gmail.analysisKeyPoints == ["gmail-key-1", "gmail-key-2"])
        #expect(gmail.analysisActionItems == ["gmail-action-1", "gmail-action-2"])
        #expect(gmail.analysisError == "Fixture Gmail historical error")
        #expect(gmail.analyzedBodyFingerprint == "fixture-gmail-fingerprint")
        #expect(gmail.analyzedAt == Date(timeIntervalSince1970: 1_700_000_101))
        #expect(gmail.analysisVersion == 11)
        #expect(gmail.outlookInferenceClassificationRawValue.isEmpty)
        #expect(gmail.providerCategoryNames.isEmpty)
        #expect(gmail.providerFolderID.isEmpty)

        let outlook = try #require(
            messages.first { $0.providerRawValue == MailProvider.outlook.rawValue }
        )
        #expect(outlook.id == "fixture-outlook-id")
        #expect(outlook.rawMessageID == "fixture-outlook-raw")
        #expect(outlook.threadID == "fixture-outlook-thread")
        #expect(outlook.subject == "Fixture Outlook subject")
        #expect(outlook.from == "outlook-fixture@example.com")
        #expect(outlook.snippet == "Fixture Outlook snippet")
        #expect(outlook.body == "Fixture Outlook body — 고정값")
        #expect(outlook.htmlBody == "<div>Fixture Outlook HTML — 고정값</div>")
        #expect(outlook.receivedAt == Date(timeIntervalSince1970: 1_700_000_002))
        #expect(!outlook.isRead)
        #expect(outlook.labelIDs == ["legacy-outlook-label"])
        #expect(outlook.isInInbox)
        #expect(outlook.analysisStateRaw == EmailAnalysisState.analyzed.rawValue)
        #expect(outlook.analysisSummary == "Fixture Outlook summary")
        #expect(outlook.analysisDetail == "Fixture Outlook detail")
        #expect(outlook.analysisKeyPoints == ["outlook-key-1", "outlook-key-2"])
        #expect(outlook.analysisActionItems == ["outlook-action-1", "outlook-action-2"])
        #expect(outlook.analysisError == "Fixture Outlook historical error")
        #expect(outlook.analyzedBodyFingerprint == "fixture-outlook-fingerprint")
        #expect(outlook.analyzedAt == Date(timeIntervalSince1970: 1_700_000_102))
        #expect(outlook.analysisVersion == 22)
        #expect(outlook.outlookInferenceClassificationRawValue.isEmpty)
        #expect(outlook.providerCategoryNames.isEmpty)
        #expect(outlook.providerFolderID.isEmpty)
    }
}
