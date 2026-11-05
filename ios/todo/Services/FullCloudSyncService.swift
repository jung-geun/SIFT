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
    private var authorizationRequested = false
    private var generation = 0
    private var reconciling = false
    var isAuthorizing: Bool { state == .authorizing }
    var familyCount: Int { operations.count }

    init(operations: [Operation]) {
        self.operations = operations
        pendingFamilies = Set(operations.map(\.family))
    }

    func authorize() {
        guard authorizationTask == nil, !isAuthorizing else { return }
        guard !reconciling else { authorizationRequested = true; return }
        state = .authorizing
        let attemptGeneration = generation
        authorizationTask = Task.detached { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.reconcile(userInitiated: true)
            if attemptGeneration == self.generation { self.authorizationTask = nil }
        }
    }

    func cancelAuthorization() {
        authorizationRequested = false
        authorizationTask?.cancel()
    }

    func reset() {
        generation += 1
        authorizationTask?.cancel()
        authorizationTask = nil
        authorizationRequested = false
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
        defer {
            reconciling = false
            if authorizationRequested {
                authorizationRequested = false
                authorize()
            }
        }
        let attemptGeneration = generation
        let preserveCancellation = !userInitiated && state == .cancelled
        let waitingForExplicitRetry = userInitiated ? Set<Family>() : blockedFamilies.union(preserveCancellation ? pendingFamilies : [])
        let previousState = state
        let previousCompletedCount = completedFamilyCount
        // Polling for delayed Keychain delivery is background maintenance, not
        // another user-visible operation. Keep the last actionable outcome.
        let showsProgress = userInitiated || state == .notChecked
        if showsProgress {
            state = userInitiated ? .authorizing : .checking
            completedFamilyCount = 0
        }
        var completed = 0
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
            if showsProgress { currentFamily = operation.family }
            await Task.yield()
            try Task.checkCancellation()
            guard attemptGeneration == generation else { throw CancellationError() }
            try await operation.reconcile()
            try KeychainStore.checkAuthenticationAttempt()
            try Task.checkCancellation()
            pending.remove(operation.family)
            completed += 1
            if showsProgress { completedFamilyCount = completed }
        }

        if userInitiated {
            do {
                try await KeychainStore.withApprovedAuthentication(purpose: AppLanguage.localized(
                    "security.keychain.syncPurpose",
                    defaultValue: "Unlock saved account connections to sync them with iCloud. Cancel to leave protected connections unchanged.",
                    language: .current)) {
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
        completedFamilyCount = completed
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

/// Only a success in the failed channel can resolve that channel's error.
/// Details intentionally exclude descriptions, record identifiers and payloads.
@MainActor
struct FullCloudSyncFailureState {
    enum Store: String, Hashable { case appData, legacy }
    enum Event: String, Hashable { case setup, `import`, export }
    enum Channel: Hashable {
        case preparation, reconciliation
        case transport(Store, Event)
    }
    struct Failure: Equatable {
        let domain: String
        let code: Int
        let isIdentityConflict: Bool

        init(_ error: any Error) {
            let value = error as NSError
            domain = value.domain
            code = value.code
            if let error = error as? CloudModelCodec.CodecError, case .duplicateIdentity = error {
                isIdentityConflict = true
            } else { isIdentityConflict = false }
        }
    }

    private(set) var failures = [Channel: Failure]()

    mutating func record(_ error: any Error, channel: Channel) {
        guard !(error is CancellationError) else { return }
        failures[channel] = Failure(error)
    }

    mutating func prepared() { failures.removeValue(forKey: .preparation) }

    mutating func reconciledContent(completed: Bool) {
        // Waiting for the initial import, a recording, or held conflicting rows
        // is not evidence that a previous content failure has recovered.
        if completed { failures.removeValue(forKey: .reconciliation) }
    }

    mutating func recoveredTransport(store: Store, event: Event) {
        failures.removeValue(forKey: .transport(store, event))
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
    @Published private(set) var failureState = FullCloudSyncFailureState()
    @Published private(set) var lastCloudExport: Date?
    @Published private(set) var restoredItemCount = 0
    @Published private(set) var isRecordingDeferred = false
    @Published private(set) var hasFinishedInitialRestore = false
    @Published private(set) var conflicts = [CloudSyncConflict]()
    @Published private(set) var retainedConflicts = [CloudSyncConflict]()
    private var conflictArchive: CloudSyncConflictArchive?
    private var conflictContexts: (app: ModelContext, email: ModelContext, meeting: ModelContext)?
    private var resolvingConflict = false

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
    private var cachedModelConflicts = Set<String>()
    private var cachedModelSnapshot = CloudModelCodec.Snapshot()
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
    @Published private(set) var synchronizing = false
    private var shadowStoreID: String?
    private var legacyStoreID: String?
    private var shadowImported = false
    private var legacyImported = false
    private var queuedSequence: UInt64 = 0
    private var lastEnqueueDate: Date?
    private var exportSequences = [UUID: UInt64]()
    private var ignoredSaveContexts = Set<ObjectIdentifier>()
    private let fileStore: CloudFileStore
    private let root: URL

    private init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileStore = CloudFileStore(root: root)
        loadConflictArchive()
    }


    #if DEBUG || SIFT_QA
    /// Isolated native QA uses the actual codec, journal and resolver, never a
    /// credential bypass on persistent user stores.
    init(conflictApp: ModelContext, conflictEmail: ModelContext, conflictMeeting: ModelContext,
         engine: FullCloudSyncEngine, archiveURL: URL) {
        precondition([conflictApp, conflictEmail, conflictMeeting].allSatisfy {
            $0.container.configurations.allSatisfy(\.isStoredInMemoryOnly)
        })
        root = archiveURL.deletingLastPathComponent()
        fileStore = CloudFileStore(root: root)
        self.engine = engine
        conflictContexts = (conflictApp, conflictEmail, conflictMeeting)
        conflictArchive = CloudSyncConflictArchive(url: archiveURL)
        retainedConflicts = (try? conflictArchive?.load()) ?? []
    }
    #endif

    private func loadConflictArchive() {
        guard let account = UserDefaults.standard.string(forKey: UserCloudSyncPolicy.accountKey),
              !account.isEmpty else { return }
        let url = root.appendingPathComponent("CloudSyncConflicts", isDirectory: true)
            .appendingPathComponent(CloudFileStore.digest(Data(account.utf8)) + ".json")
        conflictArchive = CloudSyncConflictArchive(url: url)
        do { retainedConflicts = try conflictArchive!.load() }
        catch {
            // Never replace an unreadable recovery file with an empty history.
            DiagnosticRecorder.shared.record(error: error, component: "sync.fullData", operation: "readConflictHistory")
        }
    }

    private func reviewContexts() throws -> (app: ModelContext, email: ModelContext, meeting: ModelContext) {
        if let conflictContexts { return conflictContexts }
        guard UserCloudSyncPolicy.isEnabled, let data = AppDataContainer.shared,
              data.isPersistentStoreAvailable else { throw CloudSyncConflictError.syncUnavailable }
        let contexts = (app: ModelContext(data.container), email: ModelContext(data.emailContainer),
                        meeting: ModelContext(data.meetingContainer))
        for context in [contexts.app, contexts.email, contexts.meeting] { context.autosaveEnabled = false }
        return contexts
    }

    private func reviewSnapshot(_ contexts: (app: ModelContext, email: ModelContext, meeting: ModelContext)) throws -> CloudModelCodec.Snapshot {
        var snapshot = try CloudModelCodec.capture(app: contexts.app, email: contexts.email, meeting: contexts.meeting)
        if let legacyContainer, let engine {
            let legacy = try CloudModelCodec.captureMain(ModelContext(legacyContainer))
            for key in legacy.conflictingKeys where snapshot.versions[key] == nil && engine.journal.items[key] == nil {
                snapshot.conflictingKeys.insert(key)
                snapshot.versions[key] = legacy.versions[key]
                snapshot.origins[key] = .legacy
            }
        }
        return snapshot
    }

    func refreshConflicts() async throws {
        if conflictArchive == nil { loadConflictArchive() }
        if let conflictArchive { retainedConflicts = try conflictArchive.load() }
        guard let engine else { throw CloudSyncConflictError.syncUnavailable }
        guard !resolvingConflict else { throw CloudSyncConflictError.busy }
        let generation = accountGeneration
        let localVersion = modelChangeVersion
        let contexts = try reviewContexts()
        let snapshot = try reviewSnapshot(contexts)
        let reviewed = try await engine.modelConflicts(local: snapshot)
        let fresh = try reviewSnapshot(contexts)
        guard generation == accountGeneration, localVersion == modelChangeVersion,
              snapshot.versions.mapValues(Set.init) == fresh.versions.mapValues(Set.init) else {
            throw CloudSyncConflictError.staleSelection
        }
        conflicts = reviewed
        clearResolvedError()
    }

    private func retainedVersions(_ conflict: CloudSyncConflict) throws -> [CloudSyncConflictVersion] {
        var seen = Set<String>()
        var versions = [CloudSyncConflictVersion]()
        for original in conflict.versions {
            // Durable entries retain original provenance. Review identity is
            // only the item and bytes, never a recursively wrapped history ID.
            let version = try CloudModelCodec.reviewVersion(key: conflict.itemKey, payload: original.payload,
                origin: .retained, source: conflict.itemKey)
            if seen.insert(version.id).inserted { versions.append(version) }
        }
        return versions.sorted { $0.id < $1.id }
    }

    private func currentReview(key: String, retained: [CloudSyncConflictVersion] = [],
                               contexts: (app: ModelContext, email: ModelContext, meeting: ModelContext)) async throws -> CloudSyncConflict {
        guard let engine else { throw CloudSyncConflictError.syncUnavailable }
        let before = try reviewSnapshot(contexts)
        var versions = try before.versions[key, default: []].map {
            try CloudModelCodec.reviewVersion(key: key, payload: $0,
                origin: before.origins[key] ?? .local, source: before.origins[key] == .legacy ? "legacy" : "local")
        }
        if versions.isEmpty && (engine.journal.items[key] != nil || !retained.isEmpty) {
            versions.append(try CloudModelCodec.reviewVersion(key: key, payload: nil, origin: .local, source: "local"))
        }
        versions += try await engine.cloudVersions(key: key)
        let after = try reviewSnapshot(contexts)
        guard Set(before.versions[key, default: []]) == Set(after.versions[key, default: []]) else {
            throw CloudSyncConflictError.staleSelection
        }
        versions += retained
        return CloudSyncConflict(key: key, versions: versions)
    }

    func reviewRetainedConflict(_ retained: CloudSyncConflict) async throws -> CloudSyncConflict {
        guard !synchronizing, !resolvingConflict else { throw CloudSyncConflictError.busy }
        guard let saved = try conflictArchive?.load().first(where: { $0.id == retained.id }),
              saved == retained else { throw CloudSyncConflictError.versionUnavailable }
        return try await currentReview(key: saved.itemKey, retained: retainedVersions(saved), contexts: reviewContexts())
    }

    func resolveConflict(_ conflict: CloudSyncConflict, selecting versionID: String,
                         save: @MainActor (ModelContext) throws -> Void = { try $0.save() }) async throws {
        guard !synchronizing, !resolvingConflict else { throw CloudSyncConflictError.busy }
        guard !MeetingCaptureCoordinator.hasActiveCaptureForCloudSync else { throw CloudSyncConflictError.recordingActive }
        guard let engine, let conflictArchive else { throw CloudSyncConflictError.syncUnavailable }
        let generation = accountGeneration
        let localVersion = modelChangeVersion
        let contexts = try reviewContexts()
        let requestedRetained = conflict.versions.filter { $0.origin == .retained }
        let history = try conflictArchive.load()
        let availableRetained = try history.flatMap { try retainedVersions($0) }
        guard requestedRetained.allSatisfy({ availableRetained.contains($0) }) else {
            throw CloudSyncConflictError.versionUnavailable
        }
        resolvingConflict = true
        defer { resolvingConflict = false }
        let current = try await currentReview(key: conflict.itemKey, retained: requestedRetained, contexts: contexts)
        guard generation == accountGeneration, localVersion == modelChangeVersion,
              current.fingerprint == conflict.fingerprint else {
            throw CloudSyncConflictError.staleSelection
        }
        guard let selected = current.versions.first(where: { $0.id == versionID }) else {
            throw CloudSyncConflictError.versionUnavailable
        }
        // Envelope history cannot recover child audio directories destroyed by
        // a meeting tombstone. Whole-meeting deletion remains the dedicated
        // meeting flow with its drain, rollback and original-track handling.
        if selected.payload == nil, try CloudModelCodec.meetingID(for: current.itemKey) != nil {
            throw CloudSyncConflictError.dependentContentUnavailable
        }
        retainedConflicts = try conflictArchive.retain(current)
        let isAuthorized: @Sendable () -> Bool
        if conflictContexts != nil { isAuthorized = { true } }
        else { isAuthorized = UserCloudSyncPolicy.captureAuthorization() }
        let valid = {
            generation == self.accountGeneration && isAuthorized()
                && !MeetingCaptureCoordinator.hasActiveCaptureForCloudSync
        }
        let ignored = Set([contexts.app, contexts.email, contexts.meeting].map(ObjectIdentifier.init))
        ignoredSaveContexts.formUnion(ignored)
        defer { ignoredSaveContexts.subtract(ignored) }
        var canonicalCommitted = false
        do {
            try engine.resolve(key: current.itemKey, payload: selected.payload,
                expectedCloudVersions: current.versions.filter { $0.origin == .cloud }, isValid: valid,
                isApplied: { canonicalCommitted }, apply: {
                try self.applyModelRecord(key: current.itemKey, payload: selected.payload,
                    app: contexts.app, email: contexts.email, meeting: contexts.meeting,
                    isAuthorized: isAuthorized, save: { context in
                        try save(context)
                        canonicalCommitted = true
                    }, resolvingConflict: true)
            })
        } catch {
            modelDataDirty = true
            throw error
        }
        modelDataDirty = true
        modelChangeVersion += 1
        conflicts.removeAll { $0.itemKey == current.itemKey }
        cachedModelConflicts.remove(current.itemKey)
        queuedSequence &+= 1
        lastEnqueueDate = Date()
        isQueuedForCloud = true
        SettingsStore.shared.didRestoreFullCloudPreferences()
        MemoryService.shared.invalidateCache()
        NotificationCenter.default.post(name: UserCloudSyncPolicy.didRestoreNotification, object: nil)
        clearResolvedError()
        schedule()
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
        var synchronizationStarted = false
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
            synchronizationStarted = true
            try await synchronizeNow()
        } catch {
            if !synchronizationStarted, requestedGeneration == accountGeneration {
                report(error, channel: .preparation)
            }
            throw error
        }
    }

    func start() {
        guard !Self.usesSyntheticEnvironment, UserCloudSyncPolicy.isRequested, worker == nil else { return }
        let generation = accountGeneration
        eventSubscription = NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, generation == self.accountGeneration else { return }
                self.handleCloudEvent(notification)
            }
        accountSubscription = NotificationCenter.default.publisher(for: .CKAccountChanged)
            .sink { [weak self] _ in
                // Revoke the thread-safe gate at notification receipt, before
                // an asset actor or queued MainActor continuation can mutate.
                UserCloudSyncPolicy.revokeAccountAuthorization()
                Task { @MainActor [weak self] in
                    UserDefaults.standard.set(false, forKey: UserCloudSyncPolicy.syncKey)
                    self?.stop()
                    self?.conflictArchive = nil
                    self?.retainedConflicts = []
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
                // synchronizeNow publishes its failure once, with its actual phase.
                try? await self.synchronizeNow()
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
        cachedModelConflicts = []
        cachedModelSnapshot = CloudModelCodec.Snapshot()
        conflicts = []
        connectionSync.reset()
        hasFinishedInitialRestore = false
        failureState = FullCloudSyncFailureState()
        errorMessage = nil
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
            catch { /* Cancellation, or a failure already published by synchronizeNow. */ }
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
        guard UserCloudSyncPolicy.isRequested, !synchronizing, !resolvingConflict else { return }
        guard !Self.usesSyntheticEnvironment else { throw CancellationError() }
        let generation = accountGeneration
        var failureChannel = FullCloudSyncFailureState.Channel.preparation
        synchronizing = true
        defer {
            synchronizing = false
            if rerunForLocalSave {
                rerunForLocalSave = false
                if isRunning { schedule() }
            }
        }
        do {
            try await KeychainStore.withoutAuthenticationUI {
                try await prepareCloudStore()
                guard generation == accountGeneration, UserCloudSyncPolicy.isEnabled,
                      !Task.isCancelled else { throw CancellationError() }
                failureState.prepared()
                clearResolvedError()
                failureChannel = .reconciliation
                // Device approval remains independent from app-data synchronization.
                _ = await connectionSync.reconcile()
                guard generation == accountGeneration, UserCloudSyncPolicy.isEnabled,
                      !Task.isCancelled else { throw CancellationError() }
                if shadowImported && legacyImported {
                    let completed = try await reconcileContent()
                    guard generation == accountGeneration, UserCloudSyncPolicy.isEnabled,
                          !Task.isCancelled else { throw CancellationError() }
                    failureState.reconciledContent(completed: completed)
                    if completed { hasFinishedInitialRestore = true }
                }
                clearResolvedError()
            }
        } catch {
            // A suspended old-account request must not resurrect a reset error.
            if generation == accountGeneration { report(error, channel: failureChannel) }
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
        guard generation == accountGeneration, UserCloudSyncPolicy.isRequested,
              !Task.isCancelled else { throw CancellationError() }
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
        loadConflictArchive()
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
                for key in legacy.conflictingKeys where snapshot.records[key] == nil && engine.journal.items[key] == nil {
                    snapshot.conflictingKeys.insert(key)
                    if snapshot.versions[key] == nil {
                        snapshot.versions[key] = legacy.versions[key]
                        snapshot.origins[key] = .legacy
                    }
                }
                for (key, payload) in legacy.records where snapshot.records[key] == nil
                    && !snapshot.conflictingKeys.contains(key) && engine.journal.items[key] == nil {
                    try CloudModelCodec.apply(key: key, payload: payload, app: app, email: email, meeting: meeting)
                    snapshot.records[key] = payload
                    snapshot.versions[key] = [payload]
                }
                if app.hasChanges { try app.save() }
            }
            if snapshot.conflictingKeys != cachedModelConflicts, let key = snapshot.conflictingKeys.min() {
                DiagnosticRecorder.shared.record(error: CloudModelCodec.CodecError.duplicateIdentity(key),
                    component: "sync.fullData", operation: "captureConflict")
            }
            cachedModelRecords = snapshot.records
            cachedModelDigests = snapshot.records.mapValues(CloudFileStore.digest)
            cachedModelConflicts = snapshot.conflictingKeys
            cachedModelSnapshot = snapshot
            modelDataDirty = false
        }
        // Cloud envelope metadata can change without local edits. Reuse the
        // dirty-gated portable snapshot instead of re-encoding all mail bodies
        // and meeting transcripts on every maintenance pass.
        let reviewed = try await engine.modelConflicts(local: cachedModelSnapshot)
        guard modelVersion == modelChangeVersion, accountVersion == accountGeneration else { throw CancellationError() }
        conflicts = reviewed
        let heldConflictKeys = cachedModelConflicts.union(reviewed.map(\.itemKey)).union(engine.unavailableConflictKeys)
        var records = cachedModelRecords
        let preferences = try CloudPreferenceStore.capture()
        records.merge(preferences) { _, value in value }
        let routineStore = RoutineStore.shared
        // Routine acceptance must not choose an arbitrary local task version.
        let canReconcileAcceptances = !heldConflictKeys.contains { $0.hasPrefix("Todo/") }
        if canReconcileAcceptances {
            try routineStore.reconcileAcceptances(todos: app.fetch(FetchDescriptor<Todo>()))
        }
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
        let heldMeetingIDs = try Set(heldConflictKeys.compactMap { key in
            try CloudModelCodec.meetingID(for: key).map { Substring($0) }
        })
        let meetingFilePrefix = "file/Meetings/"
        let meetingFilePrefixCount = meetingFilePrefix.count
        try await engine.reconcile(digests: digests,
            temporarilyUnavailable: heldConflictKeys.union(["file/LocalRoutines/routines.json"]),
            isTemporarilyUnavailable: { key in
                guard !heldMeetingIDs.isEmpty, key.hasPrefix(meetingFilePrefix) else { return false }
                let meetingID = key.dropFirst(meetingFilePrefixCount).prefix { $0 != "/" }
                return heldMeetingIDs.contains(meetingID)
            }, isValid: {
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
        if canReconcileAcceptances {
            try routineStore.reconcileAcceptances(todos: app.fetch(FetchDescriptor<Todo>()))
        }
        return heldConflictKeys.isEmpty
    }

    func applyModelRecord(key: String, payload: Data?, app: ModelContext,
                          email: ModelContext, meeting: ModelContext,
                          meetingRootURL: URL = AppDataContainer.meetingDirectory(),
                          isAuthorized: @Sendable () -> Bool,
                          save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
                          resolvingConflict: Bool = false) throws {
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
            try CloudModelCodec.apply(key: key, payload: payload, app: app, email: email, meeting: meeting,
                resolvingConflict: resolvingConflict)
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
            } catch { /* Cancellation, or a failure already published by synchronizeNow. */ }
        }
    }

    private func handleCloudEvent(_ notification: Notification) {
        guard UserCloudSyncPolicy.isEnabled,
              let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event,
              event.storeIdentifier == shadowStoreID || event.storeIdentifier == legacyStoreID else { return }
        let store: FullCloudSyncFailureState.Store = event.storeIdentifier == shadowStoreID ? .appData : .legacy
        let eventType: FullCloudSyncFailureState.Event
        switch event.type {
        case .setup: eventType = .setup
        case .import: eventType = .import
        case .export: eventType = .export
        @unknown default: return
        }
        if event.endDate == nil {
            if event.type == .export, event.storeIdentifier == shadowStoreID {
                exportSequences[event.identifier] = queuedSequence
            }
            return
        }
        guard event.succeeded else {
            exportSequences.removeValue(forKey: event.identifier)
            report(event.error ?? CKError(.internalError), channel: .transport(store, eventType))
            return
        }
        failureState.recoveredTransport(store: store, event: eventType)
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

    private var modelConflictMessage: String {
        AppLanguage.localized("settings.sync.full.identityConflict",
            defaultValue: "내용이 다른 중복 항목의 동기화를 보류했습니다. 아래 ‘동기화 충돌’에서 버전을 비교해 사용할 내용을 선택하세요. 원본은 보존하며 다른 데이터는 계속 동기화를 시도합니다.",
            language: .current, comment: "Held identities link to the explicit version comparison below; originals and unrelated synchronization are preserved.")
    }

    private func clearResolvedError() {
        if failureState.failures.values.contains(where: { !$0.isIdentityConflict }) {
            errorMessage = AppLanguage.localized("settings.sync.full.error",
                defaultValue: "전체 iCloud 동기화를 완료하지 못했습니다. 데이터는 기기에 보존됩니다. iCloud 로그인·저장공간·키체인 상태를 확인한 후 다시 시도하세요.",
                language: .current, comment: "Full sync failure without private content or credentials.")
        } else {
            errorMessage = cachedModelConflicts.isEmpty && conflicts.isEmpty && failureState.failures.isEmpty ? nil : modelConflictMessage
        }
    }

    private func report(_ error: Error, channel: FullCloudSyncFailureState.Channel) {
        if error is CancellationError { return }
        failureState.record(error, channel: channel)
        clearResolvedError()
        let operation: String
        switch channel {
        case .preparation: operation = "prepare"
        case .reconciliation: operation = "reconcile"
        case .transport(let store, let event): operation = "transport.\(store.rawValue).\(event.rawValue)"
        }
        DiagnosticRecorder.shared.record(error: error, component: "sync.fullData", operation: operation)
    }
}
