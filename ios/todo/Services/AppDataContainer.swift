import Foundation
import SwiftData
import Combine

// MARK: - AppDataContainer

/// Owns the canonical local containers and retries failed local migrations.
/// Full iCloud transport uses a separate revision store; toggling sync never
/// replaces this container or exposes its health-derived rows to CloudKit.
final class AppDataContainer: ObservableObject {

    /// todoApp @StateObject 생성 시 설정되는 전역 접근자.
    static private(set) var shared: AppDataContainer!

    /// SwiftUI 뷰 트리에 주입되는 현재 컨테이너. 변경 시 @Query 자동 갱신.
    @Published private(set) var container: ModelContainer

    /// rebuild() 호출마다 1씩 증가 — Equatable 불가한 container 대신 onChange 트리거에 사용.
    @Published private(set) var rebuildID: Int = 0
    var isPersistentStoreAvailable: Bool {
        Self.usesInMemoryUITestStore
            || !container.configurations.contains(where: \.isStoredInMemoryOnly)
    }


    // MARK: - Init

    init() {
        if Self.usesInMemoryUITestStore {
            self.container = Self.buildInMemoryContainer()
        } else {
            self.container = AppDataContainer.buildContainer()
        }
        AppDataContainer.shared = self
    }

    // MARK: - Rebuild (동적 전환)

    /// Retry local persistence without switching data sets or synchronization policy.
    func rebuild() {
        HealthRoutineStore.shared.cancelRefresh()
        if Self.usesInMemoryUITestStore {
            rebuildID += 1
            return
        }
        do {
            // A failed save or migration must not replace the currently visible rows.
            try container.mainContext.save()
            container = try Self.makePrimaryContainer()
            rebuildID += 1
        } catch {
            Self.recordMigrationFailure(error, operation: "containerRebuild")
        }
    }

    // MARK: - Store URL

    nonisolated static func getStoreURL(name: String) -> URL {
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if !fileManager.fileExists(atPath: appSupportURL.path) {
            try? fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        }
        return appSupportURL.appendingPathComponent(name)
    }

    // MARK: - Container Builder

    private static var usesInMemoryUITestStore: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ui-test-in-memory-store")
        #else
        false
        #endif
    }

    private static func buildInMemoryContainer() -> ModelContainer {
        let config = ModelConfiguration(schema: appSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try! ModelContainer(for: appSchema, configurations: [config])
    }

    /// A single canonical local store survives every sync preference and consent state.
    static func buildContainer() -> ModelContainer {
        if usesInMemoryUITestStore { return buildInMemoryContainer() }
        do {
            return try makePrimaryContainer()
        } catch {
            recordMigrationFailure(error, operation: "containerInitFallback")
            return buildInMemoryContainer()
        }
    }

    private static func makePrimaryContainer() throws -> ModelContainer {
        let primaryURL = getStoreURL(name: "primary_v3.store")
        let defaultURL = ModelConfiguration(schema: appSchema, cloudKitDatabase: .none).url
        return try makePrimaryContainer(
            primaryURL: primaryURL,
            legacyURLs: [getStoreURL(name: "local_v2.store"),
                         getStoreURL(name: "icloud_v2.store"), defaultURL]
        )
    }

    static func makePrimaryContainer(
        primaryURL: URL,
        legacyURLs: [URL]
    ) throws -> ModelContainer {
        if usesInMemoryUITestStore { return buildInMemoryContainer() }
        try migrateMainStores(to: primaryURL, from: legacyURLs)
        let config = ModelConfiguration(
            schema: appSchema,
            url: primaryURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: appSchema, configurations: [config])
    }

    private static var legacyCloudContainerIdentifier: String {
        "iCloud.\(Bundle.main.bundleIdentifier ?? "pieroot.sift-todo")"
    }

    /// Explicitly requested legacy downloads use a separate store. Full-sync's
    /// canonical primary never acquires an automatic CloudKit attachment.
    func makeLegacyCloudImportContainer() throws -> ModelContainer {
        try Self.makeLegacyCloudImportContainer()
    }

    static func makeLegacyCloudImportContainer() throws -> ModelContainer {
        try Self.makeLegacyCloudImportContainer(
            storeURL: Self.usesInMemoryUITestStore ? nil : Self.getStoreURL(name: "legacy_cloud_import_v3.store"),
            inMemory: Self.usesInMemoryUITestStore
        )
    }

    static func makeLegacyCloudImportContainer(storeURL: URL?, inMemory: Bool) throws -> ModelContainer {
        let config: ModelConfiguration
        if inMemory || usesInMemoryUITestStore {
            config = ModelConfiguration(schema: appSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else if let storeURL {
            config = ModelConfiguration(
                schema: appSchema,
                url: storeURL,
                cloudKitDatabase: .private(legacyCloudContainerIdentifier)
            )
        } else {
            throw MainStoreMigrationError.missingImportURL
        }
        return try ModelContainer(for: appSchema, configurations: [config])
    }

    // MARK: - Schema

    static let appSchema = Schema([
        Todo.self,
        Persona.self,
        TaskAuditEvent.self,
        TaskBehaviorEvent.self,
        MemoryAnalysis.self,
        MailAnalysisLedgerRecord.self
    ])

    // MARK: - Email Container (local storage, no automatic CloudKit mirror)

    /// Email rows stay in a separate local schema. Explicit full-scope transport
    /// uses CloudModelCodec, never SwiftData's automatic CloudKit integration.
    static let emailSchema = Schema([EmailMessage.self])

    static func makeEmailContainer(storeURL: URL) throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: emailSchema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: emailSchema, configurations: [config])
    }

    /// iCloud 설정과 무관하게 항상 로컬(cloudKitDatabase: .none)로 고정되는 컨테이너.
    /// MailTabView 서브트리에만 주입 — 메인 appSchema에 EmailMessage 포함 금지.
    lazy var emailContainer: ModelContainer = {
        if Self.usesInMemoryUITestStore {
            let config = ModelConfiguration(
                schema: Self.emailSchema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            return try! ModelContainer(for: Self.emailSchema, configurations: [config])
        }
        do {
            return try AppDataContainer.makeEmailContainer(
                storeURL: AppDataContainer.emailStoreURL()
            )
        } catch {
            DiagnosticRecorder.shared.record(
                error: error,
                component: "storage.swiftdata",
                operation: "emailContainerFallback"
            )
            print("[EmailContainer] 초기화 실패: \(error). 메모리 전용 모드로 실행.")
            let fallback = ModelConfiguration(
                schema: AppDataContainer.emailSchema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            return try! ModelContainer(for: AppDataContainer.emailSchema, configurations: [fallback])
        }
    }()

    nonisolated static func emailDirectory() throws -> URL {
        let directory = getStoreURL(name: "EmailLocal")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableDirectory.setResourceValues(values)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        return directory
    }

    nonisolated static func emailStoreURL() throws -> URL {
        let directory = try emailDirectory()
        let storeURL = directory.appendingPathComponent("email_local.store")
        let legacyURL = getStoreURL(name: "email_local.store")
        try migrateEmailStoreBundle(from: legacyURL, to: storeURL)
        return storeURL
    }

    nonisolated private static let emailMigrationLock = NSLock()

    /// Publish a complete legacy SQLite bundle only before the destination has
    /// ever opened. Once its main database exists, retained legacy WAL/SHM files
    /// must never be copied back after SQLite checkpoints or removes its WAL.
    nonisolated static func migrateEmailStoreBundle(from legacyURL: URL, to storeURL: URL) throws {
        emailMigrationLock.lock()
        defer { emailMigrationLock.unlock() }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: storeURL.path),
              fileManager.fileExists(atPath: legacyURL.path) else { return }

        let directory = storeURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".email-migration-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        let stagedStore = staging.appendingPathComponent(storeURL.lastPathComponent)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: legacyURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let copy = URL(fileURLWithPath: stagedStore.path + suffix)
            try fileManager.copyItem(at: source, to: copy)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: copy.path
            )
        }

        guard !fileManager.fileExists(atPath: storeURL.path) else { return }
        // A failed earlier publication may have left sidecars without a main
        // database. Replace that incomplete bundle, then publish main last.
        for suffix in ["-wal", "-shm"] {
            let destination = URL(fileURLWithPath: storeURL.path + suffix)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            let copy = URL(fileURLWithPath: stagedStore.path + suffix)
            if fileManager.fileExists(atPath: copy.path) {
                try fileManager.moveItem(at: copy, to: destination)
            }
        }
        try fileManager.moveItem(at: stagedStore, to: storeURL)
    }

    // MARK: - Meeting Container (local-only, protected)

    /// Meeting and vocabulary rows never attach an automatic CloudKit mirror.
    /// Explicit full-scope transport uses CloudModelCodec over these local rows.
    static let meetingSchema = Schema([
        MeetingRecord.self,
        MeetingGlossaryTerm.self,
        VocabularyStoreMetadata.self,
        VocabularySourceState.self,
        VocabularyObservation.self
    ])

    lazy var meetingContainer: ModelContainer = {
        if Self.usesInMemoryUITestStore {
            let config = ModelConfiguration(
                schema: Self.meetingSchema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            return try! ModelContainer(for: Self.meetingSchema, configurations: [config])
        }
        let directory = AppDataContainer.meetingDirectory()
        AppDataContainer.excludeFromBackup(directory)
        AppDataContainer.setProtection(.complete, at: directory)
        let url = directory.appendingPathComponent("meeting_local.store")
        let config = ModelConfiguration(
            schema: AppDataContainer.meetingSchema,
            url: url,
            cloudKitDatabase: .none
        )
        do {
            let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: [config])
            AppDataContainer.protectMeetingStoreContents(at: directory)
            return container
        } catch {
            DiagnosticRecorder.shared.record(
                error: error,
                component: "storage.swiftdata",
                operation: "meetingContainerFallback"
            )
            print("[MeetingContainer] initialization failed: \(error). Falling back to memory-only storage.")
            let fallback = ModelConfiguration(
                schema: AppDataContainer.meetingSchema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            return try! ModelContainer(for: AppDataContainer.meetingSchema, configurations: [fallback])
        }
    }()

    nonisolated static func meetingDirectory() -> URL {
        let directory = getStoreURL(name: "Meetings")
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Active capture is opened before lock and remains writable while open.
    /// On Stop, callers must close the handle, then call finalizeMeetingAudio(at:).
    static func activeMeetingAudioDirectory(meetingID: String) -> URL {
        let directory = meetingDirectory()
            .appendingPathComponent(meetingID, isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)
        setProtection(.completeUnlessOpen, at: directory)
        return directory
    }

    nonisolated static func finalizeMeetingAudio(at file: URL) {
        setProtection(.complete, at: file)
    }

    private static func protectMeetingStoreContents(at directory: URL) {
        for path in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard path.lastPathComponent.hasPrefix("meeting_local.store") else { continue }
            excludeFromBackup(path)
            setProtection(.complete, at: path)
        }
    }

    private static func excludeFromBackup(_ path: URL) {
        var path = path
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? path.setResourceValues(values)
    }

    private nonisolated static func setProtection(_ protection: FileProtectionType, at path: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: path.path
        )
    }

    // MARK: - Main-store migration

    enum MainStoreMigrationError: Error, Equatable {
        case missingImportURL
        case invalidCheckpoint
        case missingCanonicalStore
    }

    static func migrationCheckpointURL(for primaryURL: URL) -> URL {
        primaryURL.appendingPathExtension("legacy-merge-v1")
    }

    /// Merges every existing legacy main store before the canonical store may be
    /// selected. URLs are injectable so migration tests never use app storage.
    ///
    /// All reads and merges must succeed; fetch errors are not empty snapshots.
    /// Autosave is disabled and a single explicit save commits the merged rows.
    /// The atomic receipt is written only after that save. Until the receipt is
    /// durable callers must not expose the canonical store to user edits.
    /// A crash between save and receipt is safe: codec merge deduplicates retries.
    /// Once selected, the receipt prevents retained originals from resurrecting
    /// subsequent hard deletions, including after synchronization is toggled.
    /// Original stores and their sidecars are never moved or deleted.
    static func migrateMainStores(to primaryURL: URL, from legacyURLs: [URL]) throws {
        guard !usesInMemoryUITestStore else { return }
        let fileManager = FileManager.default
        let checkpointURL = migrationCheckpointURL(for: primaryURL)
        let checkpoint = Data("sift-main-store-merge-v1\n".utf8)
        if fileManager.fileExists(atPath: checkpointURL.path) {
            guard try Data(contentsOf: checkpointURL) == checkpoint else {
                throw MainStoreMigrationError.invalidCheckpoint
            }
            guard fileManager.fileExists(atPath: primaryURL.path) else {
                throw MainStoreMigrationError.missingCanonicalStore
            }
            return
        }

        var snapshots: [CloudModelCodec.MainStoreSnapshot] = []
        var visited: Set<URL> = [primaryURL.standardizedFileURL.resolvingSymlinksInPath()]
        for legacyURL in legacyURLs {
            let normalizedURL = legacyURL.standardizedFileURL.resolvingSymlinksInPath()
            guard visited.insert(normalizedURL).inserted,
                  fileManager.fileExists(atPath: legacyURL.path) else { continue }
            let configuration = ModelConfiguration(schema: appSchema, url: legacyURL, cloudKitDatabase: .none)
            let source = try ModelContainer(for: appSchema, configurations: [configuration])
            let context = ModelContext(source)
            context.autosaveEnabled = false
            snapshots.append(try CloudModelCodec.snapshotMainStore(from: context))
        }

        let configuration = ModelConfiguration(schema: appSchema, url: primaryURL, cloudKitDatabase: .none)
        let destination = try ModelContainer(for: appSchema, configurations: [configuration])
        let context = ModelContext(destination)
        context.autosaveEnabled = false
        do {
            for snapshot in snapshots {
                try CloudModelCodec.mergeMainStore(snapshot, into: context)
            }
            try context.save()
            try checkpoint.write(to: checkpointURL, options: .atomic)
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func recordMigrationFailure(_ error: Error, operation: String) {
        DiagnosticRecorder.shared.record(error: error, component: "storage.swiftdata", operation: operation)
        print("[SwiftData] Store migration/open failed; originals and current rows retained: \(error)")
    }
}
