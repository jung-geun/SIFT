import CloudKit
import Combine
import CoreData
import Foundation
import SwiftData
import UIKit

/// Only the dedicated action opens a bounded interactive credential attempt.
@MainActor
final class FullCloudConnectionSync: ObservableObject {
    enum Family: String, CaseIterable {
        case gmailIMAP, outlookIMAP, google, mailIdentity, vocabulary, openAI
    }
    enum State: Equatable {
        case notChecked, checking, authorizing, prepared, awaitingApproval, cancelled, failed
    }
    struct Operation {
        let family: Family
        let reconcile: @MainActor () async throws -> Void

        @MainActor static func openAI(_ connection: OpenAIConnection) -> Self {
            .init(family: .openAI) {
                try connection.refreshCredentialsChecked()
                try KeychainStore.checkAuthenticationAttempt()
                if let issue = connection.synchronizationIssue { throw issue }
            }
        }
    }

    @Published private(set) var state: State = .notChecked
    @Published private(set) var currentFamily: Family?
    @Published private(set) var pendingFamilies: Set<Family>
    @Published private(set) var blockedFamilies = Set<Family>()
    @Published private(set) var completedFamilyCount = 0
    private let operations: [Operation]
    private var authorizationTask: Task<Void, Never>?
    private var generation = 0
    private var reconciling = false
    var isAuthorizing: Bool { state == .authorizing }
    var familyCount: Int { operations.count }

    init(operations: [Operation]) {
        self.operations = operations
        pendingFamilies = Set(operations.map(\.family))
    }

    func authorize() {
        guard authorizationTask == nil, !reconciling, !isAuthorizing else { return }
        state = .authorizing
        let attemptGeneration = generation
        authorizationTask = Task.detached { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.reconcile(userInitiated: true)
            if attemptGeneration == self.generation { self.authorizationTask = nil }
        }
    }

    func cancelAuthorization() { authorizationTask?.cancel() }

    func reset() {
        generation += 1
        authorizationTask?.cancel()
        authorizationTask = nil
        state = .notChecked
        currentFamily = nil
        pendingFamilies = Set(operations.map(\.family))
        blockedFamilies = []
        completedFamilyCount = 0
    }

    /// Injected operations exercise this same production loop without reading user secrets.
    func reconcile(userInitiated: Bool = false) async -> (any Error)? {
        guard !reconciling, userInitiated || !isAuthorizing else { return nil }
        reconciling = true
        defer { reconciling = false }
        let attemptGeneration = generation
        let preserveCancellation = !userInitiated && state == .cancelled
        let waitingForExplicitRetry = userInitiated ? Set<Family>() : blockedFamilies.union(preserveCancellation ? pendingFamilies : [])
        let previousState = state
        let previousCompletedCount = completedFamilyCount
        state = userInitiated ? .authorizing : .checking
        completedFamilyCount = 0
        var pending = Set(operations.map(\.family))
        var blocked = Set<Family>()
        var firstError: (any Error)?
        var cancelled = false
        var activeFamily: Family?

        func run(_ operation: Operation) async throws {
            try Task.checkCancellation()
            try KeychainStore.checkAuthenticationAttempt()
            guard attemptGeneration == generation else { throw CancellationError() }
            activeFamily = operation.family
            currentFamily = operation.family
            await Task.yield()
            try Task.checkCancellation()
            guard attemptGeneration == generation else { throw CancellationError() }
            try await operation.reconcile()
            try KeychainStore.checkAuthenticationAttempt()
            try Task.checkCancellation()
            pending.remove(operation.family)
            completedFamilyCount += 1
        }

        if userInitiated {
            do {
                try await KeychainStore.withUserInitiatedCredentialSync {
                    for operation in self.operations {
                        do { try await run(operation) }
                        catch {
                            if Self.isAuthenticationIssue(error) || error is CancellationError { throw error }
                            firstError = firstError ?? error
                        }
                    }
                }
            } catch {
                if let activeFamily, Self.isAuthenticationIssue(error) { blocked.insert(activeFamily) }
                cancelled = error is CancellationError || (error as? KeychainStoreError) == .authenticationCancelled
                if !Self.isAuthenticationIssue(error) && !(error is CancellationError) { firstError = firstError ?? error }
            }
        } else {
            for operation in operations {
                if waitingForExplicitRetry.contains(operation.family) {
                    if blockedFamilies.contains(operation.family) { blocked.insert(operation.family) }
                    continue
                }
                do { try await KeychainStore.withoutAuthenticationUI { try await run(operation) } }
                catch {
                    if error is CancellationError || Task.isCancelled {
                        // Backgrounding aborts this pass, not the user's device
                        // approval. Preserve even blocks not yet visited here.
                        if attemptGeneration == generation {
                            currentFamily = nil
                            state = previousState
                            completedFamilyCount = previousCompletedCount
                        }
                        return CancellationError()
                    }
                    if Self.isAuthenticationIssue(error) { blocked.insert(operation.family) }
                    else { firstError = firstError ?? error }
                }
            }
        }
        guard attemptGeneration == generation else { return firstError }
        currentFamily = nil
        pendingFamilies = pending
        blockedFamilies = blocked
        if let firstError {
            DiagnosticRecorder.shared.record(error: firstError, component: "sync.accountConnections", operation: "reconcile")
        }
        if cancelled || preserveCancellation { state = .cancelled }
        else if !blocked.isEmpty { state = .awaitingApproval }
        else if firstError != nil { state = .failed }
        else { state = .prepared }
        return firstError
    }

    private static func isAuthenticationIssue(_ error: any Error) -> Bool {
        guard let error = error as? KeychainStoreError else { return false }
        return error == .authenticationRequired || error == .authenticationCancelled
    }
}

@MainActor
final class FullCloudSyncService: ObservableObject {
    static let shared = FullCloudSyncService()
    private static let usesSyntheticEnvironment: Bool = {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["SIFT_UI_TESTING"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-ui-test-in-memory-store")
            || NSClassFromString("XCTestCase") != nil
        #else
        return false
        #endif
    }()
    @Published private(set) var isRunning = false
    @Published private(set) var isQueuedForCloud = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastCloudExport: Date?
    @Published private(set) var restoredItemCount = 0
    @Published private(set) var isRecordingDeferred = false
    @Published private(set) var hasFinishedInitialRestore = false

    private var cloudContainer: ModelContainer?
    private var legacyContainer: ModelContainer?
    private var engine: FullCloudSyncEngine?
    private var vocabularyService: UserVocabularyService?
    private var worker: Task<Void, Never>?
    private var backgroundDrain: Task<Void, Never>?
    private var pendingRun: Task<Void, Never>?
    private var eventSubscription: AnyCancellable?
    private var accountSubscription: AnyCancellable?
    private var defaultsSubscription: AnyCancellable?
    private var saveSubscription: AnyCancellable?
    private var routineSubscription: AnyCancellable?
    private var modelDataDirty = true
    private var cachedModelRecords = [String: Data]()
    private var cachedModelDigests = [String: String]()
    private var modelChangeVersion = 0
    private var rerunForLocalSave = false
    lazy var connectionSync = FullCloudConnectionSync(operations: [
        .init(family: .gmailIMAP) { Self.restoreSelection(try IMAPCredentialStore.applyFullSyncPolicy()) },
        .init(family: .outlookIMAP) { Self.restoreSelection(try OutlookIMAPCredentialStore.applyFullSyncPolicy()) },
        .init(family: .google) { try KeychainStore.applyFullSyncPolicyChecked() },
        .init(family: .mailIdentity) { try MailAnalysisLedgerKeyStore.applyFullSyncPolicy() },
        .init(family: .vocabulary) { [weak self] in try await self?.vocabularyService?.applyFullSyncPolicy() },
        .openAI(.shared)
    ])
    private var accountGeneration = 0
    private var synchronizing = false
    private var shadowStoreID: String?
    private var legacyStoreID: String?
    private var shadowImported = false
    private var legacyImported = false
    private var reconciliationFailed = false
    private var transportFailures = Set<String>()
    private var queuedSequence: UInt64 = 0
    private var lastEnqueueDate: Date?
    private var exportSequences = [UUID: UInt64]()
    private var ignoredSaveContexts = Set<ObjectIdentifier>()
    private let fileStore: CloudFileStore
    private let root: URL

    private init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileStore = CloudFileStore(root: root)
    }

    func configure(vocabulary: UserVocabularyService) { vocabularyService = vocabulary }

    /// Storage consent neither installs models nor grants OS or external-AI access.
    func setEnabled(_ enabled: Bool) async throws {
        guard SettingsStore.supportsICloud else { return }
        let defaults = UserDefaults.standard
        accountGeneration += 1
        let requestedGeneration = accountGeneration
        if !enabled {
            defaults.set(false, forKey: UserCloudSyncPolicy.syncKey)
            stop()
            return
        }
        guard !Self.usesSyntheticEnvironment else { throw CancellationError() }
        do {
            // Bind this explicit choice to the account visible now. If identity
            // cannot be established, do not enable an unbound future upload.
            let (_, account) = try await resolveAccount()
            try Task.checkCancellation()
            guard requestedGeneration == accountGeneration else { throw CancellationError() }
            defaults.set(account, forKey: UserCloudSyncPolicy.accountKey)
            defaults.set(UserCloudSyncPolicy.consentVersion, forKey: UserCloudSyncPolicy.consentKey)
            defaults.set(true, forKey: UserCloudSyncPolicy.syncKey)
            UserCloudSyncPolicy.authorizeAccount(account)
            SettingsStore.shared.adoptFullCloudPolicy()
            start()
            try await synchronizeNow()
        } catch {
            report(error)
            throw error
        }
    }

    func start() {
        guard !Self.usesSyntheticEnvironment, UserCloudSyncPolicy.isRequested, worker == nil else { return }
        eventSubscription = NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in self?.handleCloudEvent(notification) }
        accountSubscription = NotificationCenter.default.publisher(for: .CKAccountChanged)
            .sink { [weak self] _ in
                // Revoke the thread-safe gate at notification receipt, before
                // an asset actor or queued MainActor continuation can mutate.
                UserCloudSyncPolicy.revokeAccountAuthorization()
                Task { @MainActor [weak self] in
                    UserDefaults.standard.set(false, forKey: UserCloudSyncPolicy.syncKey)
                    self?.stop()
                }
            }
        defaultsSubscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.schedule() }
        saveSubscription = NotificationCenter.default.publisher(for: ModelContext.didSave)
            .sink { [weak self] notification in
                if Thread.isMainThread {
                    // Observe MainActor edits before a suspended restore resumes.
                    MainActor.assumeIsolated { self?.handleLocalSave(notification) }
                } else {
                    Task { @MainActor [weak self] in self?.handleLocalSave(notification) }
                }
            }
        routineSubscription = NotificationCenter.default.publisher(for: RoutineStore.didChangeNotification, object: RoutineStore.shared)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.synchronizing { self.rerunForLocalSave = true }
                self.schedule()
            }
        isRunning = true
        worker = Task.detached { @MainActor [weak self] in
            while let self, !Task.isCancelled, UserCloudSyncPolicy.isRequested {
                do { try await self.synchronizeNow() }
                catch { self.report(error) }
                do { try await Task.sleep(for: .seconds(20)) }
                catch { break }
            }
        }
    }

    private func handleLocalSave(_ notification: Notification) {
        if let context = notification.object as? ModelContext,
           ignoredSaveContexts.contains(ObjectIdentifier(context)) { return }
        modelChangeVersion += 1
        modelDataDirty = true
        if synchronizing { rerunForLocalSave = true }
        schedule()
    }

    private func pause() {
        connectionSync.cancelAuthorization()
        pendingRun?.cancel()
        pendingRun = nil
        worker?.cancel()
        worker = nil
        isRunning = false
    }

    func stop() {
        pause()
        accountGeneration += 1
        UserCloudSyncPolicy.revokeAccountAuthorization()
        backgroundDrain?.cancel()
        eventSubscription = nil
        accountSubscription = nil
        defaultsSubscription = nil
        saveSubscription = nil
        routineSubscription = nil
        engine = nil
        cloudContainer = nil
        legacyContainer = nil
        shadowStoreID = nil
        legacyStoreID = nil
        shadowImported = false
        legacyImported = false
        modelDataDirty = true
        cachedModelRecords = [:]
        cachedModelDigests = [:]
        connectionSync.reset()
        hasFinishedInitialRestore = false
        transportFailures.removeAll()
        exportSequences.removeAll()
        isQueuedForCloud = false
        lastCloudExport = nil
        lastEnqueueDate = nil
        ignoredSaveContexts.removeAll()
        // No key downgrade, shared deletion, signout or empty alternate store.
    }

    func enterForeground() {
        guard UserCloudSyncPolicy.isRequested else { return }
        start()
        schedule()
    }

    func enterBackground() {
        pause()
        guard UserCloudSyncPolicy.isRequested, backgroundDrain == nil else { return }
        // Keep observers, including source-save invalidation, alive during the
        // bounded drain. Background mail writes must not race a stale restore.
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "SIFT full data enqueue") { [weak self] in
            Task { @MainActor in self?.backgroundDrain?.cancel() }
        }
        backgroundDrain = Task.detached { @MainActor [weak self] in
            defer {
                if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
                self?.backgroundDrain = nil
            }
            do {
                // The cancelled foreground pass still owns its contexts until
                // it unwinds. Do not silently skip the one background drain.
                while self?.synchronizing == true { try await Task.sleep(for: .milliseconds(100)) }
                try Task.checkCancellation()
                try await self?.synchronizeNow()
            }
            catch { self?.report(error) }
        }
    }

    /// Returns false on timeout; callers must not treat waiting as successful
    /// import and create duplicate calendar/persona data ahead of the restore.
    func waitForInitialRestore(timeout: TimeInterval = 12) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while UserCloudSyncPolicy.isRequested, !hasFinishedInitialRestore, Date() < deadline {
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return false }
        }
        return UserCloudSyncPolicy.isEnabled && hasFinishedInitialRestore
    }

    func synchronizeNow() async throws {
        try await KeychainStore.withoutAuthenticationUI { try await synchronizeWithoutAuthenticationUI() }
    }

    private func synchronizeWithoutAuthenticationUI() async throws {
        guard UserCloudSyncPolicy.isRequested, !synchronizing else { return }
        guard !Self.usesSyntheticEnvironment else { throw CancellationError() }
        synchronizing = true
        defer {
            synchronizing = false
            if rerunForLocalSave {
                rerunForLocalSave = false
                if isRunning { schedule() }
            }
        }
        do {
            try await prepareCloudStore()
            guard UserCloudSyncPolicy.isEnabled, !Task.isCancelled else { throw CancellationError() }
            // Keychain failures are visible, but must not strand unrelated tasks,
            // saved mail or recordings behind an unavailable credential item.
            _ = await connectionSync.reconcile()
            guard UserCloudSyncPolicy.isEnabled, !Task.isCancelled else { throw CancellationError() }
            if shadowImported && legacyImported {
                if try await reconcileContent() { hasFinishedInitialRestore = true }
            }
            reconciliationFailed = false
            clearResolvedError()
        } catch {
            report(error)
            throw error
        }
    }

    func authorizeAccountConnectionSync() {
        guard UserCloudSyncPolicy.isEnabled, UIApplication.shared.applicationState == .active else { return }
        connectionSync.authorize()
    }

    private static func restoreSelection(_ accounts: [IMAPRestoredAccount]) {
        for restored in accounts where UserDefaults.standard.string(forKey: restored.preferenceKey) == nil {
            UserDefaults.standard.set(restored.account, forKey: restored.preferenceKey)
        }
    }

    private func resolveAccount() async throws -> (CKContainer, String) {
        let container = CKContainer(identifier: "iCloud.\(Bundle.main.bundleIdentifier ?? "pieroot.sift-todo")")
        guard try await container.accountStatus() == .available else { throw CKError(.notAuthenticated) }
        let user = try await container.userRecordID()
        return (container, CloudFileStore.digest(Data(user.recordName.utf8)))
    }

    private func prepareCloudStore() async throws {
        guard cloudContainer == nil else { return }
        let generation = accountGeneration
        let identifier = "iCloud.\(Bundle.main.bundleIdentifier ?? "pieroot.sift-todo")"
        let (container, account) = try await resolveAccount()
        guard UserDefaults.standard.string(forKey: UserCloudSyncPolicy.accountKey) == account else {
            UserDefaults.standard.set(false, forKey: UserCloudSyncPolicy.syncKey)
            stop()
            throw CKError(.notAuthenticated)
        }
        let zones = try await container.privateCloudDatabase.allRecordZones()
        guard generation == accountGeneration, UserCloudSyncPolicy.isRequested, !Task.isCancelled else { throw CancellationError() }
        UserCloudSyncPolicy.authorizeAccount(account)
        SettingsStore.shared.adoptFullCloudPolicy()
        let schema = Schema([CloudDataRevision.self])
        let configuration = ModelConfiguration("SIFTFullData", schema: schema,
            url: root.appendingPathComponent("full_cloud_\(account).store"), cloudKitDatabase: .private(identifier))
        let model = try ModelContainer(for: schema, configurations: [configuration])
        let journalURL = root.appendingPathComponent("CloudSyncState", isDirectory: true).appendingPathComponent("\(account).json")
        let cloudContext = ModelContext(model)
        let reconciliation = try FullCloudSyncEngine(cloud: cloudContext,
            installationID: CloudPreferenceStore.installationID(), journalURL: journalURL)
        let shadowID = try Self.storeIdentifier(model)
        let canResume = zones.isEmpty || !reconciliation.journal.items.isEmpty
        let legacy: ModelContainer?
        let importID: String?
        if zones.isEmpty { legacy = nil; importID = nil }
        else {
            let imported = try AppDataContainer.makeLegacyCloudImportContainer()
            importID = try Self.storeIdentifier(imported)
            legacy = imported
        }
        shadowStoreID = shadowID
        legacyStoreID = importID
        engine = reconciliation
        cloudContainer = model
        legacyContainer = legacy
        ignoredSaveContexts.insert(ObjectIdentifier(cloudContext))
        modelDataDirty = true
        // Do not publish fresh defaults ahead of an initial import. A durable
        // prior reconciliation permits offline edits on an established device.
        shadowImported = canResume
        legacyImported = canResume
    }

    private static func storeIdentifier(_ model: ModelContainer) throws -> String? {
        guard let configuration = model.configurations.first else { return nil }
        if #available(iOS 27.0, *) { return model.storeIdentifier(forConfigurationNamed: configuration.name) }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType,
            at: configuration.url, options: [NSReadOnlyPersistentStoreOption: true])
        return metadata[NSStoreUUIDKey] as? String
    }

    private func reconcileContent() async throws -> Bool {
        guard UserCloudSyncPolicy.isEnabled, let engine, let data = AppDataContainer.shared,
              data.isPersistentStoreAvailable,
              !data.emailContainer.configurations.contains(where: \.isStoredInMemoryOnly),
              !data.meetingContainer.configurations.contains(where: \.isStoredInMemoryOnly) else {
            throw FullCloudSyncError.persistentStoreUnavailable
        }
        isRecordingDeferred = MeetingCaptureCoordinator.hasActiveCaptureForCloudSync
        guard !isRecordingDeferred else { return false }
        let app = ModelContext(data.container)
        let email = ModelContext(data.emailContainer)
        let meeting = ModelContext(data.meetingContainer)
        let restoreContextIDs = Set([app, email, meeting].map(ObjectIdentifier.init))
        ignoredSaveContexts.formUnion(restoreContextIDs)
        defer { ignoredSaveContexts.subtract(restoreContextIDs) }
        for context in [app, email, meeting] {
            context.autosaveEnabled = false
            context.author = "SIFTFullCloudRestore"
        }
        let modelVersion = modelChangeVersion
        let accountVersion = accountGeneration
        let isAuthorized = UserCloudSyncPolicy.captureAuthorization()
        if modelDataDirty {
            var snapshot = try CloudModelCodec.capture(app: app, email: email, meeting: meeting)
            if let legacyContainer {
                let legacy = try CloudModelCodec.captureMain(ModelContext(legacyContainer))
                for (key, payload) in legacy where snapshot[key] == nil && engine.journal.items[key] == nil {
                    try CloudModelCodec.apply(key: key, payload: payload, app: app, email: email, meeting: meeting)
                    snapshot[key] = payload
                }
                if app.hasChanges { try app.save() }
            }
            cachedModelRecords = snapshot
            cachedModelDigests = snapshot.mapValues(CloudFileStore.digest)
            modelDataDirty = false
        }
        var records = cachedModelRecords
        let preferences = try CloudPreferenceStore.capture()
        records.merge(preferences) { _, value in value }
        let routineStore = RoutineStore.shared
        try routineStore.reconcileAcceptances(todos: app.fetch(FetchDescriptor<Todo>()))
        var routineRecords = try routineStore.captureCloudRecords()
        var routineGeneration = routineStore.changeGeneration
        let files = try await fileStore.capture(isAuthorized: isAuthorized)
        guard UserCloudSyncPolicy.isEnabled, !Task.isCancelled else { throw CancellationError() }
        var digests = cachedModelDigests
        digests.merge(preferences.mapValues(CloudFileStore.digest)) { _, value in value }
        digests.merge(routineRecords.mapValues(CloudFileStore.digest)) { _, value in value }
        digests.merge(files.mapValues(\.digest)) { _, value in value }
        var restored = 0
        defer {
            if restored > 0 {
                restoredItemCount += restored
                rerunForLocalSave = true
                SettingsStore.shared.didRestoreFullCloudPreferences()
                MemoryService.shared.invalidateCache()
                NotificationCenter.default.post(name: UserCloudSyncPolicy.didRestoreNotification, object: nil)
            }
        }
        try await engine.reconcile(digests: digests,
            temporarilyUnavailable: ["file/LocalRoutines/routines.json"], isValid: {
            UserCloudSyncPolicy.isEnabled && modelVersion == self.modelChangeVersion
                && accountVersion == self.accountGeneration
                && routineGeneration == routineStore.changeGeneration
                && !MeetingCaptureCoordinator.hasActiveCaptureForCloudSync
        }, didEnqueue: {
            self.queuedSequence &+= 1
            self.lastEnqueueDate = Date()
            self.isQueuedForCloud = true
        }, load: { key in
            guard UserCloudSyncPolicy.isEnabled, !Task.isCancelled,
                  modelVersion == self.modelChangeVersion, accountVersion == self.accountGeneration,
                  routineGeneration == routineStore.changeGeneration else { throw CancellationError() }
            if let file = files[key] {
                let payload = try await self.fileStore.load(file, isAuthorized: isAuthorized)
                guard UserCloudSyncPolicy.isEnabled, !Task.isCancelled,
                      modelVersion == self.modelChangeVersion, accountVersion == self.accountGeneration,
                      routineGeneration == routineStore.changeGeneration else { throw CancellationError() }
                return payload
            }
            if RoutineStore.isCloudRecordKey(key) {
                let payload = routineRecords[key]
                guard payload.map(CloudFileStore.digest) == digests[key] else { throw CancellationError() }
                return payload
            }
            if CloudPreferenceStore.isPreferenceKey(key) {
                try CloudPreferenceStore.validateSnapshot(key: key, expectedDigest: digests[key])
            }
            return records[key]
        }, apply: { key, payload in
            guard UserCloudSyncPolicy.isEnabled, !Task.isCancelled,
                  modelVersion == self.modelChangeVersion, accountVersion == self.accountGeneration,
                  routineGeneration == routineStore.changeGeneration else { throw CancellationError() }
            if RoutineStore.isCloudRecordKey(key) {
                try routineStore.applyCloudRecord(key: key, payload: payload)
                routineGeneration = routineStore.changeGeneration
                routineRecords = try routineStore.captureCloudRecords()
                self.rerunForLocalSave = true
            } else if CloudPreferenceStore.isPreferenceKey(key) {
                try CloudPreferenceStore.apply(key: key, payload: payload, expectedDigest: digests[key])
            } else if key.hasPrefix(CloudFileStore.prefix) {
                guard !MeetingCaptureCoordinator.hasActiveCaptureForCloudSync else { throw CancellationError() }
                try await self.fileStore.apply(key: key, payload: payload, expectedDigest: files[key]?.digest,
                    isAuthorized: isAuthorized)
            } else {
                try self.applyModelRecord(key: key, payload: payload, app: app, email: email, meeting: meeting,
                    isAuthorized: isAuthorized)
            }
            restored += 1
        })
        try routineStore.reconcileAcceptances(todos: app.fetch(FetchDescriptor<Todo>()))
        return true
    }

    func applyModelRecord(key: String, payload: Data?, app: ModelContext,
                          email: ModelContext, meeting: ModelContext,
                          meetingRootURL: URL = AppDataContainer.meetingDirectory(),
                          isAuthorized: @Sendable () -> Bool,
                          save: @MainActor (ModelContext) throws -> Void = { try $0.save() }) throws {
        let meetingID = try CloudModelCodec.meetingID(for: key)
        var deletedIDs = Set<String>()
        var newlyFenced = [String]()
        do {
            guard isAuthorized() else { throw CancellationError() }
            if payload == nil, let id = meetingID {
                deletedIDs.insert(id)
                let descriptor = FetchDescriptor<MeetingRecord>(predicate: #Predicate {
                    $0.meetingID == id || $0.parentMeetingID == id
                })
                for row in try meeting.fetch(descriptor) {
                    deletedIDs.insert(row.meetingID)
                    deletedIDs.formUnion(row.audioTrackIDs)
                }
                for id in deletedIDs where (try? MeetingCanonicalID.validateMeetingID(id)) != nil {
                    if try !MeetingDeletionFence.isDeleted(meetingID: id, rootURL: meetingRootURL) { newlyFenced.append(id) }
                    try MeetingDeletionFence.recordDeletion(meetingID: id, rootURL: meetingRootURL,
                        isAuthorized: isAuthorized)
                }
            }
            try CloudModelCodec.apply(key: key, payload: payload, app: app, email: email, meeting: meeting)
            guard isAuthorized() else { throw CancellationError() }
            if app.hasChanges { try save(app) }
            if email.hasChanges { try save(email) }
            if meeting.hasChanges { try save(meeting) }
        } catch {
            app.rollback(); email.rollback(); meeting.rollback()
            var rollbackError: (any Error)?
            for id in newlyFenced {
                do { try MeetingDeletionFence.recordAuthoritativeRestore(meetingID: id, rootURL: meetingRootURL) }
                catch { rollbackError = rollbackError ?? error }
            }
            throw rollbackError ?? error
        }
        // Also invalidate when later protected-file cleanup fails. A committed
        // remote row must never be re-published from the pre-restore cache.
        modelDataDirty = true
        for id in deletedIDs where (try? MeetingCanonicalID.validateMeetingID(id)) != nil {
            try MeetingDeletionFence.removeDeletedContent(meetingID: id, rootURL: meetingRootURL,
                isAuthorized: isAuthorized)
        }
        if payload != nil, let id = meetingID,
           (try? MeetingCanonicalID.validateMeetingID(id)) != nil {
            let descriptor = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == id })
            if let row = try meeting.fetch(descriptor).first {
                let parentIsDeleted: Bool
                if let parent = row.parentMeetingID, (try? MeetingCanonicalID.validateMeetingID(parent)) != nil {
                    parentIsDeleted = try MeetingDeletionFence.isDeleted(meetingID: parent, rootURL: meetingRootURL)
                } else { parentIsDeleted = false }
                if parentIsDeleted {
                    // A late child row supplies the relationship missing from an
                    // audio-only asset key. Fence it before any later blob arrives.
                    try MeetingDeletionFence.recordDeletion(meetingID: id, rootURL: meetingRootURL,
                        isAuthorized: isAuthorized)
                    try MeetingDeletionFence.removeDeletedContent(meetingID: id, rootURL: meetingRootURL,
                        isAuthorized: isAuthorized)
                } else {
                    guard isAuthorized() else { throw CancellationError() }
                    try MeetingDeletionFence.recordAuthoritativeRestore(meetingID: id, rootURL: meetingRootURL)
                }
            }
        }
    }

    private func schedule() {
        guard UserCloudSyncPolicy.isRequested, isRunning, !synchronizing else { return }
        pendingRun?.cancel()
        pendingRun = Task.detached { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(750))
                try await self?.synchronizeNow()
            } catch is CancellationError { }
            catch { self?.report(error) }
        }
    }

    private func handleCloudEvent(_ notification: Notification) {
        guard UserCloudSyncPolicy.isEnabled,
              let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event,
              event.storeIdentifier == shadowStoreID || event.storeIdentifier == legacyStoreID else { return }
        let failureKey = event.storeIdentifier + "/" + String(event.type.rawValue)
        if event.endDate == nil {
            if event.type == .export, event.storeIdentifier == shadowStoreID {
                exportSequences[event.identifier] = queuedSequence
            }
            return
        }
        guard event.succeeded else {
            exportSequences.removeValue(forKey: event.identifier)
            transportFailures.insert(failureKey)
            report(event.error ?? CKError(.internalError), reconciliation: false)
            return
        }
        transportFailures.remove(failureKey)
        clearResolvedError()
        if event.type == .export, event.storeIdentifier == shadowStoreID {
            lastCloudExport = event.endDate
            // An export which started before newer writes cannot acknowledge them.
            if let sequence = exportSequences.removeValue(forKey: event.identifier), sequence == queuedSequence,
               lastEnqueueDate.map({ $0 <= event.startDate }) ?? true {
                isQueuedForCloud = false
            }
        } else if event.type == .import {
            if event.storeIdentifier == shadowStoreID { shadowImported = true }
            if event.storeIdentifier == legacyStoreID { legacyImported = true }
            modelDataDirty = true
            schedule()
        }
    }

    private func clearResolvedError() {
        if !reconciliationFailed && transportFailures.isEmpty { errorMessage = nil }
    }

    private func report(_ error: Error, reconciliation: Bool = true) {
        if error is CancellationError { return }
        if reconciliation { reconciliationFailed = true }
        errorMessage = AppLanguage.localized("settings.sync.full.error",
            defaultValue: "전체 iCloud 동기화를 완료하지 못했습니다. 데이터는 기기에 보존됩니다. iCloud 로그인·저장공간·키체인 상태를 확인한 후 다시 시도하세요.",
            language: .current, comment: "Full sync failure without private content or credentials.")
        DiagnosticRecorder.shared.record(error: error, component: "sync.fullData", operation: "reconcile")
    }
}
