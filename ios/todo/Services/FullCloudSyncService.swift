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

/// Notifications advance this fence at receipt, before any MainActor hop.
/// The pending identifier inventory is drained before cached bytes are captured.
nonisolated final class FullCloudSaveFence: @unchecked Sendable {
    struct Version: Equatable, Sendable {
        var entities = [String: UInt64]()
        var unknown: UInt64 = 0
    }
    struct Pending: Sendable {
        var identifiers = Set<PersistentIdentifier>()
        var entities = Set<String>()
        var needsFullCapture = false
        var version = Version()
        var hasChanges: Bool { needsFullCapture || !entities.isEmpty }
    }
    private let lock = NSLock()
    private let entities: Set<String>
    private var version = Version()
    private var pending = Pending()
    private var ignored = Set<ObjectIdentifier>()

    init(entities: Set<String>) { self.entities = entities }

    func ignore(_ contexts: Set<ObjectIdentifier>) { lock.withLock { ignored.formUnion(contexts) } }
    func unignore(_ contexts: Set<ObjectIdentifier>) { lock.withLock { ignored.subtract(contexts) } }
    func isIgnored(_ notification: Notification) -> Bool {
        guard let context = notification.object as? ModelContext else { return false }
        return lock.withLock { ignored.contains(ObjectIdentifier(context)) }
    }

    @discardableResult
    func observe(_ notification: Notification) -> Bool {
        lock.withLock {
            if let context = notification.object as? ModelContext,
               ignored.contains(ObjectIdentifier(context)) { return false }
            let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
            var identifiers = Set<PersistentIdentifier>()
            var understood = false
            for key in keys {
                let value = notification.userInfo?[key] ?? notification.userInfo?[key.rawValue]
                if let ids = value as? Set<PersistentIdentifier> { identifiers.formUnion(ids); understood = true }
                else if let ids = value as? [PersistentIdentifier] { identifiers.formUnion(ids); understood = true }
                else if value != nil { understood = false; break }
            }
            let invalidated = notification.userInfo?[ModelContext.NotificationKey.invalidatedAllIdentifiers]
                ?? notification.userInfo?[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue]
            if !understood || identifiers.isEmpty || invalidated.map({ ($0 as? Bool) != false }) == true {
                if let context = notification.object as? ModelContext {
                    let changed = Set(context.container.schema.entities.map(\.name)).intersection(entities)
                    guard !changed.isEmpty else { return false }
                    for name in changed { version.entities[name, default: 0] &+= 1 }
                    pending.entities.formUnion(changed)
                } else {
                    version.unknown &+= 1
                    pending.entities.formUnion(entities)
                }
                pending.needsFullCapture = true
            } else {
                var changed = Set(identifiers.map(\.entityName)).intersection(entities)
                if changed.contains("Todo") { changed.formUnion(["TaskAuditEvent", "TaskBehaviorEvent"]) }
                guard !changed.isEmpty else { return false }
                for name in changed { version.entities[name, default: 0] &+= 1 }
                pending.identifiers.formUnion(identifiers)
                pending.entities.formUnion(changed)
            }
            return true
        }
    }

    func snapshot() -> Version { lock.withLock { version } }
    func drain() -> Pending {
        lock.withLock {
            var value = pending
            value.version = version
            pending = Pending()
            return value
        }
    }
    func isCurrent(key: String, snapshot: Version) -> Bool {
        let name = String(key.prefix { $0 != "/" })
        guard entities.contains(name) else { return true }
        return lock.withLock {
            version.unknown == snapshot.unknown
                && version.entities[name, default: 0] == snapshot.entities[name, default: 0]
        }
    }
    func reset() {
        lock.withLock {
            version.unknown &+= 1
            pending = Pending()
            ignored = []
        }
    }
}

nonisolated struct FullCloudFileScope: Sendable {
    let graph: [String: Set<String>]
    var heldMeetingIDs: Set<String>
    var modelUnavailable: Bool
    let namespaceAuthorization: @Sendable (String) -> Bool
    var deletedMeetingIDs = Set<String>()

    func authorizes(_ id: String, isFenced: Bool = false) -> Bool {
        guard !isFenced || deletedMeetingIDs.contains(id) else { return false }
        // Files alone cannot establish whether a namespace is live, deleted or
        // an unimported child. Require a model graph or settled model tombstone.
        let dependencies: Set<String>
        if let known = graph[id] { dependencies = known }
        else if deletedMeetingIDs.contains(id) { dependencies = [id] }
        else { return false }
        guard !modelUnavailable else { return false }
        return !dependencies.contains(where: { heldMeetingIDs.contains($0) || !namespaceAuthorization($0) })
    }

    func hasUnresolvedInventory(_ inventory: CloudFileInventory) -> Bool {
        !inventory.unavailableMeetingIDs.isEmpty
            || inventory.fencedMeetingIDs.contains { !authorizes($0, isFenced: true) }
    }

    @MainActor
    func holding(meetingKeys: Set<String>, deletedMeetingKeys: Set<String> = []) -> Self {
        var result = self
        for key in deletedMeetingKeys {
            do {
                guard let id = try CloudModelCodec.meetingID(for: key) else { continue }
                result.deletedMeetingIDs.insert(id)
            } catch {
                result.modelUnavailable = true
            }
        }
        for key in meetingKeys where CloudModelCodec.entityName(for: key) == "MeetingRecord" {
            do {
                guard let id = try CloudModelCodec.meetingID(for: key) else { continue }
                result.heldMeetingIDs.formUnion(graph[id] ?? [id])
            } catch {
                result.modelUnavailable = true
            }
        }
        return result
    }

    @MainActor
    static func permitsModelParent(_ parent: String?, unsettledMeetingKeys: Set<String>) -> Bool {
        guard let parent else { return true }
        for key in unsettledMeetingKeys where CloudModelCodec.entityName(for: key) == "MeetingRecord" {
            guard let id = try? CloudModelCodec.meetingID(for: key) else { return false }
            if id == parent { return false }
        }
        return true
    }
}

/// The aggregate detects task-list changes; routine generation detects reservation
/// changes. Neither signature suppresses cloud conflict, deletion or replay work.
@MainActor
struct FullCloudTaskAcceptanceCheckpoint {
    private struct Signature: Equatable {
        let taskAggregate: String
        let routineGeneration: UInt64
    }
    private var signature: Signature?

    @discardableResult
    mutating func reconcileIfChanged(taskAggregate: String, routineGeneration: () -> UInt64,
                                    reconcile: () throws -> Void) rethrows -> Bool {
        let current = Signature(taskAggregate: taskAggregate, routineGeneration: routineGeneration())
        guard signature != current else { return false }
        try reconcile()
        signature = Signature(taskAggregate: taskAggregate, routineGeneration: routineGeneration())
        return true
    }

    mutating func invalidate() { signature = nil }
}

nonisolated enum FullCloudSyncProgress {
    static let taskEntities: Set<String> = ["Todo", "TaskAuditEvent", "TaskBehaviorEvent"]

    static func tasksRestored(completedInventory: Bool, heldKeys: Set<String>, unavailableEntities: Set<String>,
                              isCurrent: (String) -> Bool) -> Bool {
        completedInventory && unavailableEntities.isDisjoint(with: taskEntities)
            && !heldKeys.contains(where: { taskEntities.contains(String($0.prefix { $0 != "/" })) })
            && taskEntities.allSatisfy { isCurrent($0 + "/") }
    }

    static func shouldContinueDependencies(enqueued: Bool, restored: Int, hasDeferredKeys: Bool) -> Bool {
        hasDeferredKeys && (enqueued || restored > 0)
    }
}

/// Save identifiers, not a process-wide epoch, fence independent model families.
/// Missing/unknown notification metadata is deliberately an all-family change.
@MainActor
struct FullCloudModelChanges {
    private(set) var generations = [String: UInt64]()

    mutating func record(_ notification: Notification, cache: CloudModelCodec.CaptureCache) -> Bool {
        if let context = notification.object as? ModelContext,
           Set(context.container.schema.entities.map(\.name)).isDisjoint(with: CloudModelCodec.entityNames) {
            return false // Shadow/transport stores are not canonical domain edits.
        }
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        var ids = Set<PersistentIdentifier>()
        var understood = false
        for key in keys {
            let value = notification.userInfo?[key] ?? notification.userInfo?[key.rawValue]
            if let values = value as? Set<PersistentIdentifier> { ids.formUnion(values); understood = true }
            else if let values = value as? [PersistentIdentifier] { ids.formUnion(values); understood = true }
            else if value != nil { understood = false; ids = []; break }
        }
        let invalidated = notification.userInfo?[ModelContext.NotificationKey.invalidatedAllIdentifiers]
            ?? notification.userInfo?[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue]
        let invalidatesAll = invalidated.map { ($0 as? Bool) != false } ?? false
        if !understood || invalidatesAll || ids.isEmpty {
            // Full recapture, but a known mail-only store cannot have changed
            // task rows. Unknown store ownership still invalidates every family.
            cache.invalidateAll()
            var names = (notification.object as? ModelContext).map {
                Set($0.container.schema.entities.map(\.name)).intersection(CloudModelCodec.entityNames)
            } ?? CloudModelCodec.entityNames
            if names.contains("Todo") { names.formUnion(["TaskAuditEvent", "TaskBehaviorEvent"]) }
            for name in names { generations[name, default: 0] &+= 1 }
            return true
        }
        cache.invalidate(identifiers: ids)
        var names = Set(ids.map(\.entityName)).intersection(CloudModelCodec.entityNames)
        if names.contains("Todo") { names.formUnion(["TaskAuditEvent", "TaskBehaviorEvent"]) }
        for name in names { generations[name, default: 0] &+= 1 }
        return !names.isEmpty
    }

    mutating func invalidateAll(cache: CloudModelCodec.CaptureCache) {
        cache.invalidateAll()
        for name in CloudModelCodec.entityNames { generations[name, default: 0] &+= 1 }
    }

    func isCurrent(key: String, snapshot: [String: UInt64]) -> Bool {
        guard let name = CloudModelCodec.entityName(for: key) else { return true }
        return generations[name, default: 0] == snapshot[name, default: 0]
    }
}

@MainActor
final class FullCloudSyncService: ObservableObject {
    static let shared = FullCloudSyncService()
    static let periodicTickInterval: Duration = .seconds(20)
    static let safetyFullPassInterval: TimeInterval = 300

    struct ReconcileObservation {
        let saveVersion: FullCloudSaveFence.Version
        let modelGenerations: [String: UInt64]
        let defaultsGeneration: UInt64
        let routineGeneration: UInt64
        let cloudGeneration: UInt64
        let meetingAuthorization: @Sendable () -> Bool
    }

    private struct CleanReconcileBaseline {
        let completedAt: Date
        let observation: ReconcileObservation
    }

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
    @Published private(set) var hasFinishedTaskRestore = false
    private(set) var taskAggregateDigest: String?
    private var taskAcceptanceCheckpoint = FullCloudTaskAcceptanceCheckpoint()
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
    private var rerunForLocalSave = false
    private var dependencyContinuation = false
    private var synchronizationPassSequence: UInt64 = 0
    private var modelChanges = FullCloudModelChanges()
    private let modelCaptureCache = CloudModelCodec.CaptureCache()
    private var cachedMeetingNamespaceGraph = [String: Set<String>]()
    private var capturedModelGenerations = [String: UInt64]()
    private var unavailableModelEntities = Set<String>()
    private var modelCaptureError: (any Error)?
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
    private var cloudChangeGeneration: UInt64 = 0
    private var activeCloudImports = Set<UUID>()
    private var defaultsChangeGeneration: UInt64 = 0
    /// Device-local defaults (retry markers, cursors) must not wake the full pass.
    private var portablePreferenceFingerprint: String?
    private var lastCleanReconcile: CleanReconcileBaseline?
    private let saveFence = FullCloudSaveFence(entities: CloudModelCodec.entityNames)
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

    func attachIsolatedObserversForTesting() {
        guard let conflictContexts, saveSubscription == nil else { return }
        shadowImported = true
        legacyImported = true
        let tracked = Set([conflictContexts.app, conflictContexts.email, conflictContexts.meeting].map(ObjectIdentifier.init))
        let saveFence = self.saveFence
        saveSubscription = NotificationCenter.default.publisher(for: ModelContext.didSave)
            .sink { [weak self, saveFence] notification in
                guard let context = notification.object as? ModelContext,
                      tracked.contains(ObjectIdentifier(context)) else { return }
                saveFence.observe(notification)
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.handleLocalSave(notification) }
                } else {
                    Task { @MainActor [weak self] in self?.handleLocalSave(notification) }
                }
            }
    }

    func recordCloudImportSignalForTesting() {
        recordCloudImportCompletion()
    }

    @discardableResult
    func runIsolatedPeriodicTickForTesting(now: Date, reconcilePassCount: inout Int) async throws -> Bool {
        try await runPeriodicTickIfNeeded(now: now) {
            reconcilePassCount += 1
            try await self.synchronizeIsolatedForTesting(now: now)
        }
    }

    private func synchronizeIsolatedForTesting(now: Date) async throws {
        guard let conflictContexts, let engine else { throw CloudSyncConflictError.syncUnavailable }
        synchronizing = true
        rerunForLocalSave = false
        dependencyContinuation = false
        defer { synchronizing = false }
        let observation = beginReconcileObservation()
        let ignored = Set([conflictContexts.app, conflictContexts.email, conflictContexts.meeting].map(ObjectIdentifier.init))
        saveFence.ignore(ignored)
        defer { saveFence.unignore(ignored) }
        let pendingSaves = saveFence.drain()
        if pendingSaves.hasChanges {
            if pendingSaves.needsFullCapture { modelCaptureCache.invalidateAll() }
            else { modelCaptureCache.invalidate(identifiers: pendingSaves.identifiers) }
            modelDataDirty = true
        }
        let modelVersions = modelChanges.generations
        if modelDataDirty {
            let changed = Set(CloudModelCodec.entityNames.filter {
                modelVersions[$0, default: 0] != capturedModelGenerations[$0, default: 0]
            }).union(unavailableModelEntities).union(pendingSaves.entities)
            let selected = modelCaptureCache.requiresFullInventory || changed.isEmpty
                ? CloudModelCodec.entityNames : changed
            let captured = CloudModelCodec.captureAvailable(
                app: conflictContexts.app, email: conflictContexts.email, meeting: conflictContexts.meeting,
                previous: cachedModelSnapshot, entities: selected, cache: modelCaptureCache)
            cachedModelRecords = captured.snapshot.records
            cachedModelDigests = captured.snapshot.digests
            cachedModelConflicts = captured.snapshot.conflictingKeys
            cachedModelSnapshot = captured.snapshot
            capturedModelGenerations = modelVersions
            unavailableModelEntities = captured.unavailableEntities
            modelCaptureError = captured.firstError
            if !unavailableModelEntities.contains("Todo") {
                taskAggregateDigest = captured.snapshot.taskAggregateDigest
            }
            modelDataDirty = !unavailableModelEntities.isEmpty
        }
        let reviewed = try await engine.modelConflicts(local: cachedModelSnapshot)
        conflicts = reviewed
        let held = cachedModelConflicts.union(reviewed.map(\.itemKey)).union(engine.unavailableConflictKeys)
        let records = cachedModelRecords
        var restored = 0
        try await engine.reconcile(
            digests: cachedModelDigests,
            temporarilyUnavailable: held,
            load: { records[$0] },
            apply: { key, payload in
                try self.applyModelRecord(
                    key: key, payload: payload,
                    app: conflictContexts.app, email: conflictContexts.email, meeting: conflictContexts.meeting,
                    meetingRootURL: self.root.appendingPathComponent("Meetings", isDirectory: true),
                    isAuthorized: { true }
                )
                restored += 1
            }
        )
        if restored > 0 { rerunForLocalSave = true }
        if FullCloudSyncProgress.shouldContinueDependencies(
            enqueued: engine.didEnqueueChanges, restored: restored, hasDeferredKeys: !engine.deferredKeys.isEmpty
        ) {
            dependencyContinuation = true
            rerunForLocalSave = true
        }
        if FullCloudSyncProgress.tasksRestored(
            completedInventory: engine.didCompleteInventory,
            heldKeys: held.union(engine.deferredKeys),
            unavailableEntities: unavailableModelEntities,
            isCurrent: { _ in true }
        ) {
            hasFinishedTaskRestore = true
        }
        if let modelCaptureError { throw modelCaptureError }
        let completed = held.isEmpty && engine.deferredKeys.isEmpty && unavailableModelEntities.isEmpty
        failureState.reconciledContent(completed: completed)
        if completed { hasFinishedInitialRestore = true }
        clearResolvedError()
        finishReconcileObservation(observation, completed: completed, now: now)
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
        let localVersions = modelChanges.generations
        let savedVersion = saveFence.snapshot()
        let contexts = try reviewContexts()
        let snapshot = try reviewSnapshot(contexts)
        let reviewed = try await engine.modelConflicts(local: snapshot)
        let fresh = try reviewSnapshot(contexts)
        guard generation == accountGeneration, reviewed.allSatisfy({ conflict in
            modelChanges.isCurrent(key: conflict.itemKey, snapshot: localVersions)
                && saveFence.isCurrent(key: conflict.itemKey, snapshot: savedVersion)
                && Set(snapshot.versions[conflict.itemKey, default: []]) == Set(fresh.versions[conflict.itemKey, default: []])
        }) else {
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
        guard !MeetingCaptureCoordinator.hasActiveMeetingWorkForCloudSync else { throw CloudSyncConflictError.recordingActive }
        guard let engine, let conflictArchive else { throw CloudSyncConflictError.syncUnavailable }
        let generation = accountGeneration
        let localVersions = modelChanges.generations
        let savedVersion = saveFence.snapshot()
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
        guard generation == accountGeneration, modelChanges.isCurrent(key: conflict.itemKey, snapshot: localVersions),
              saveFence.isCurrent(key: conflict.itemKey, snapshot: savedVersion),
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
                && self.saveFence.isCurrent(key: conflict.itemKey, snapshot: savedVersion)
                && self.modelChanges.isCurrent(key: conflict.itemKey, snapshot: localVersions)
                && !MeetingCaptureCoordinator.hasActiveMeetingWorkForCloudSync
        }
        let ignored = Set([contexts.app, contexts.email, contexts.meeting].map(ObjectIdentifier.init))
        saveFence.ignore(ignored)
        defer { saveFence.unignore(ignored) }
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
            modelChanges.invalidateAll(cache: modelCaptureCache)
            throw error
        }
        modelDataDirty = true
        modelChanges.invalidateAll(cache: modelCaptureCache)
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
            .sink { [weak self] _ in self?.handleDefaultsChange() }
        let saveFence = self.saveFence
        saveSubscription = NotificationCenter.default.publisher(for: ModelContext.didSave)
            .sink { [weak self, saveFence] notification in
                saveFence.observe(notification)
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
                _ = try? await self.runPeriodicTickIfNeeded {
                    try await self.synchronizeNow()
                }
                do { try await Task.sleep(for: Self.periodicTickInterval) }
                catch { break }
            }
        }
    }

    private func handleLocalSave(_ notification: Notification) {
        if saveFence.isIgnored(notification) {
            if let context = notification.object as? ModelContext,
               !Set(context.container.schema.entities.map(\.name)).isDisjoint(with: CloudModelCodec.entityNames) {
                modelCaptureCache.invalidateAll()
                modelDataDirty = true
            }
            return
        }
        guard modelChanges.record(notification, cache: modelCaptureCache) else { return }
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
        modelChanges.invalidateAll(cache: modelCaptureCache)
        cachedModelRecords = [:]
        cachedModelDigests = [:]
        cachedModelConflicts = []
        cachedModelSnapshot = CloudModelCodec.Snapshot()
        conflicts = []
        connectionSync.reset()
        unavailableModelEntities = []
        modelCaptureError = nil
        hasFinishedInitialRestore = false
        hasFinishedTaskRestore = false
        taskAggregateDigest = nil
        taskAcceptanceCheckpoint.invalidate()
        failureState = FullCloudSyncFailureState()
        errorMessage = nil
        exportSequences.removeAll()
        isQueuedForCloud = false
        lastCloudExport = nil
        lastEnqueueDate = nil
        saveFence.reset()
        dependencyContinuation = false
        cloudChangeGeneration = 0
        activeCloudImports.removeAll()
        defaultsChangeGeneration = 0
        portablePreferenceFingerprint = nil
        lastCleanReconcile = nil
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
                // it unwinds. Continue only actual dependency progress within
                // this same cancellable OS grant; never promise another wakeup.
                while self?.synchronizing == true { try await Task.sleep(for: .milliseconds(100)) }
                try Task.checkCancellation()
            } catch { return }
            while let self, UserCloudSyncPolicy.isRequested, !Task.isCancelled {
                let sequence = self.synchronizationPassSequence
                do { try await self.synchronizeNow() }
                catch { if error is CancellationError || Task.isCancelled { break } }
                guard identifier != .invalid, sequence != self.synchronizationPassSequence,
                      self.dependencyContinuation else { break }
                await Task.yield()
            }
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

    /// Calendar/task consumers do not depend on meeting audio or mail restore.
    func waitForTaskRestore(timeout: TimeInterval = 12) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while UserCloudSyncPolicy.isRequested, !hasFinishedTaskRestore, Date() < deadline {
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return false }
        }
        return UserCloudSyncPolicy.isEnabled && hasFinishedTaskRestore
    }

    private static func currentPortablePreferenceFingerprint() -> String? {
        guard let snapshot = try? CloudPreferenceStore.capture() else { return nil }
        var hash = Data()
        for key in snapshot.keys.sorted() {
            hash.append(Data(key.utf8)); hash.append(0)
            hash.append(Data(CloudFileStore.digest(snapshot[key]!).utf8)); hash.append(0)
        }
        return CloudFileStore.digest(hash)
    }

    /// Only a changed portable preference (or an unreadable snapshot, treated
    /// conservatively) counts as a local change and schedules a pass.
    func handleDefaultsChange() {
        let current = Self.currentPortablePreferenceFingerprint()
        if let current, current == portablePreferenceFingerprint { return }
        portablePreferenceFingerprint = current
        defaultsChangeGeneration &+= 1
        if synchronizing { rerunForLocalSave = true }
        schedule()
    }

    func beginReconcileObservation() -> ReconcileObservation {
        portablePreferenceFingerprint = Self.currentPortablePreferenceFingerprint()
        return ReconcileObservation(
            saveVersion: saveFence.snapshot(),
            modelGenerations: modelChanges.generations,
            defaultsGeneration: defaultsChangeGeneration,
            routineGeneration: RoutineStore.shared.changeGeneration,
            cloudGeneration: cloudChangeGeneration,
            meetingAuthorization: MeetingCaptureCoordinator.captureCloudSyncAuthorization()
        )
    }

    func finishReconcileObservation(_ observation: ReconcileObservation, completed: Bool, now: Date = Date()) {
        guard completed,
              !rerunForLocalSave,
              !dependencyContinuation,
              conflicts.isEmpty,
              cachedModelConflicts.isEmpty,
              failureState.failures.isEmpty,
              errorMessage == nil,
              activeCloudImports.isEmpty,
              conflictContexts != nil || connectionSync.state != .failed else {
            lastCleanReconcile = nil
            return
        }
        lastCleanReconcile = CleanReconcileBaseline(completedAt: now, observation: observation)
    }

    func shouldRunPeriodicSynchronization(now: Date = Date()) -> Bool {
        guard let baseline = lastCleanReconcile else { return true }
        let elapsed = now.timeIntervalSince(baseline.completedAt)
        guard elapsed >= 0, elapsed < Self.safetyFullPassInterval,
              cloudContainer != nil || conflictContexts != nil,
              let engine,
              shadowImported && legacyImported,
              hasFinishedInitialRestore && hasFinishedTaskRestore,
              !modelDataDirty,
              !rerunForLocalSave && !dependencyContinuation,
              unavailableModelEntities.isEmpty && modelCaptureError == nil,
              modelChanges.generations == baseline.observation.modelGenerations,
              saveFence.snapshot() == baseline.observation.saveVersion,
              defaultsChangeGeneration == baseline.observation.defaultsGeneration,
              RoutineStore.shared.changeGeneration == baseline.observation.routineGeneration,
              activeCloudImports.isEmpty && cloudChangeGeneration == baseline.observation.cloudGeneration,
              baseline.observation.meetingAuthorization(),
              !isRecordingDeferred,
              !MeetingCaptureCoordinator.hasActiveCaptureForCloudSync,
              !MeetingCaptureCoordinator.hasActiveMeetingWorkForCloudSync,
              conflicts.isEmpty && cachedModelConflicts.isEmpty,
              engine.unavailableConflictKeys.isEmpty,
              engine.journal.pendingApplies.isEmpty,
              engine.journal.pendingPublications.isEmpty,
              engine.deferredKeys.isEmpty,
              engine.unsettledMeetingKeys.isEmpty,
              failureState.failures.isEmpty && errorMessage == nil else {
            return true
        }
        if conflictContexts == nil {
            return connectionSync.state == .notChecked
                || connectionSync.state == .checking
                || connectionSync.state == .failed
        }
        return false
    }

    @discardableResult
    func runPeriodicTickIfNeeded(
        now: Date = Date(),
        perform: @MainActor () async throws -> Void
    ) async rethrows -> Bool {
        guard shouldRunPeriodicSynchronization(now: now) else { return false }
        try await perform()
        return true
    }

    func synchronizeNow() async throws {
        guard UserCloudSyncPolicy.isRequested, !synchronizing, !resolvingConflict else { return }
        guard !Self.usesSyntheticEnvironment else { throw CancellationError() }
        let generation = accountGeneration
        var failureChannel = FullCloudSyncFailureState.Channel.preparation
        dependencyContinuation = false
        synchronizationPassSequence &+= 1
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
                    let observation = beginReconcileObservation()
                    let completed = try await reconcileContent()
                    guard generation == accountGeneration, UserCloudSyncPolicy.isEnabled,
                          !Task.isCancelled else { throw CancellationError() }
                    failureState.reconciledContent(completed: completed)
                    if completed { hasFinishedInitialRestore = true }
                    clearResolvedError()
                    finishReconcileObservation(observation, completed: completed)
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
        saveFence.ignore([ObjectIdentifier(cloudContext)])
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
        let app = ModelContext(data.container)
        let email = ModelContext(data.emailContainer)
        let meeting = ModelContext(data.meetingContainer)
        let restoreContextIDs = Set([app, email, meeting].map(ObjectIdentifier.init))
        saveFence.ignore(restoreContextIDs)
        defer { saveFence.unignore(restoreContextIDs) }
        for context in [app, email, meeting] {
            context.autosaveEnabled = false
            context.author = "SIFTFullCloudRestore"
        }
        let pendingSaves = saveFence.drain()
        if pendingSaves.hasChanges {
            if pendingSaves.needsFullCapture { modelCaptureCache.invalidateAll() }
            else { modelCaptureCache.invalidate(identifiers: pendingSaves.identifiers) }
            modelDataDirty = true
        }
        let savedVersion = pendingSaves.version
        let modelVersions = modelChanges.generations
        let initialProtectedIDs = MeetingCaptureCoordinator.cloudSyncProtectedMeetingIDs()
        let initialUnscopedCapture = MeetingCaptureCoordinator.hasUnscopedCaptureForCloudSync
        let fileCaptureAuthorization = MeetingCaptureCoordinator.captureCloudSyncAuthorization()
        let namespaceAuthorization = MeetingCaptureCoordinator.captureCloudSyncNamespaceAuthorization()
        let accountVersion = accountGeneration
        let isAuthorized = UserCloudSyncPolicy.captureAuthorization()
        if modelDataDirty {
            let changed = Set(CloudModelCodec.entityNames.filter {
                modelVersions[$0, default: 0] != capturedModelGenerations[$0, default: 0]
            }).union(unavailableModelEntities).union(pendingSaves.entities)
            let selected = modelCaptureCache.requiresFullInventory || changed.isEmpty
                ? CloudModelCodec.entityNames : changed
            let captured = CloudModelCodec.captureAvailable(app: app, email: email, meeting: meeting,
                previous: cachedModelSnapshot, entities: selected, cache: modelCaptureCache)
            var snapshot = captured.snapshot
            unavailableModelEntities = captured.unavailableEntities
            modelCaptureError = captured.firstError
            if let legacyContainer {
                do {
                    let legacy = try CloudModelCodec.captureMain(ModelContext(legacyContainer))
                    for key in legacy.conflictingKeys where snapshot.records[key] == nil && engine.journal.items[key] == nil {
                        guard let entity = CloudModelCodec.entityName(for: key),
                              !unavailableModelEntities.contains(entity) else { continue }
                        snapshot.conflictingKeys.insert(key)
                        if snapshot.versions[key] == nil {
                            snapshot.versions[key] = legacy.versions[key]
                            snapshot.origins[key] = .legacy
                        }
                    }
                    for (key, payload) in legacy.records where snapshot.records[key] == nil
                        && !snapshot.conflictingKeys.contains(key) && engine.journal.items[key] == nil {
                        guard let entity = CloudModelCodec.entityName(for: key),
                              !unavailableModelEntities.contains(entity) else { continue }
                        try CloudModelCodec.apply(key: key, payload: payload, app: app, email: email, meeting: meeting)
                        snapshot.records[key] = payload
                        snapshot.versions[key] = [payload]
                        snapshot.digests[key] = CloudFileStore.digest(payload)
                    }
                    if app.hasChanges { try app.save() }
                } catch {
                    app.rollback()
                    // An unreadable initial legacy inventory cannot authorize
                    // main-store deletions or claim task restore completion.
                    unavailableModelEntities.formUnion(["Todo", "TaskAuditEvent", "TaskBehaviorEvent",
                        "Persona", "MemoryAnalysis", "MailAnalysisLedgerRecord"])
                    modelCaptureError = modelCaptureError ?? error
                }
            }
            if snapshot.conflictingKeys != cachedModelConflicts, let key = snapshot.conflictingKeys.min() {
                DiagnosticRecorder.shared.record(error: CloudModelCodec.CodecError.duplicateIdentity(key),
                    component: "sync.fullData", operation: "captureConflict")
            }
            cachedModelRecords = snapshot.records
            cachedModelDigests = snapshot.digests
            cachedModelConflicts = snapshot.conflictingKeys
            if selected.contains("MeetingRecord") {
                cachedMeetingNamespaceGraph = try CloudModelCodec.meetingNamespaceGraph(snapshot)
            }
            cachedModelSnapshot = snapshot
            capturedModelGenerations = modelVersions
            if !unavailableModelEntities.contains("Todo") {
                taskAggregateDigest = snapshot.taskAggregateDigest
            }
            modelDataDirty = !unavailableModelEntities.isEmpty
        }
        let namespaceGraph = cachedMeetingNamespaceGraph
        // Cloud envelope metadata can change without local edits. Reuse the
        // dirty-gated portable snapshot instead of re-encoding all mail bodies
        // and meeting transcripts on every maintenance pass.
        let reviewed = try await engine.modelConflicts(local: cachedModelSnapshot, isTemporarilyUnavailable: { key in
            CloudModelCodec.entityName(for: key).map { self.unavailableModelEntities.contains($0) } == true
                || !self.modelChanges.isCurrent(key: key, snapshot: modelVersions)
                || !self.saveFence.isCurrent(key: key, snapshot: savedVersion)
        })
        guard accountVersion == accountGeneration, isAuthorized() else { throw CancellationError() }
        conflicts = reviewed
        let heldConflictKeys = cachedModelConflicts.union(reviewed.map(\.itemKey)).union(engine.unavailableConflictKeys)
        let heldMeetingIDs = try Set(heldConflictKeys.flatMap { key -> Set<String> in
            guard let id = try CloudModelCodec.meetingID(for: key) else { return [] }
            return namespaceGraph[id] ?? [id]
        })
        // File presence/absence is not model ownership. Unknown namespaces wait
        // for an authoritative graph; settled model tombstones still authorize
        // real deletion propagation without accepting refused live assets.
        let fileScope = FullCloudFileScope(graph: namespaceGraph, heldMeetingIDs: heldMeetingIDs,
            modelUnavailable: unavailableModelEntities.contains("MeetingRecord"),
            namespaceAuthorization: namespaceAuthorization)
            .holding(meetingKeys: [], deletedMeetingKeys: engine.settledMeetingTombstones)
        let fileScopeAuthorization: @Sendable (String) -> Bool = { fileScope.authorizes($0) }
        var records = cachedModelRecords
        let preferences = try CloudPreferenceStore.capture()
        records.merge(preferences) { _, value in value }
        let routineStore = RoutineStore.shared
        func reconcileAcceptancesIfChanged(in context: ModelContext) throws {
            guard let aggregate = self.taskAggregateDigest else { return }
            try self.taskAcceptanceCheckpoint.reconcileIfChanged(taskAggregate: aggregate,
                routineGeneration: { routineStore.changeGeneration }) {
                try routineStore.reconcileAcceptances(todos: context.fetch(FetchDescriptor<Todo>()))
            }
        }
        // Routine acceptance must not choose an arbitrary local task version.
        let canReconcileAcceptances = !heldConflictKeys.contains { $0.hasPrefix("Todo/") }
            && modelChanges.isCurrent(key: "Todo/", snapshot: modelVersions)
            && saveFence.isCurrent(key: "Todo/", snapshot: savedVersion)
            && !unavailableModelEntities.contains("Todo")
        if canReconcileAcceptances {
            try reconcileAcceptancesIfChanged(in: app)
        }
        var routineRecords = try routineStore.captureCloudRecords()
        var routineGeneration = routineStore.changeGeneration
        var fileInventory = CloudFileInventory()
        var fileInventoryUnavailable = false
        var fileCaptureError: (any Error)?
        do {
            fileInventory = try await fileStore.captureInventory(isAuthorized: isAuthorized,
                isMeetingAuthorized: fileScopeAuthorization)
            fileCaptureError = fileInventory.firstError
        } catch {
            guard isAuthorized(), !Task.isCancelled else { throw CancellationError() }
            fileInventoryUnavailable = true
            fileCaptureError = error
        }
        let files = fileInventory.files
        var meetingGraphChanged = false
        var runtimeUnavailableFileIDs = Set<String>()
        var dependencyKeys = Set<String>()
        var deletionKeys = Set<String>()
        var dependencyScope = fileScope
        func currentFileScope() -> FullCloudFileScope {
            if dependencyKeys != engine.unsettledMeetingKeys || deletionKeys != engine.settledMeetingTombstones {
                dependencyKeys = engine.unsettledMeetingKeys
                deletionKeys = engine.settledMeetingTombstones
                dependencyScope = fileScope.holding(meetingKeys: dependencyKeys, deletedMeetingKeys: deletionKeys)
            }
            return dependencyScope
        }
        func hasUnresolvedFileInventory() -> Bool {
            if fileInventoryUnavailable || !fileInventory.unavailableMeetingIDs.isEmpty
                || !runtimeUnavailableFileIDs.isEmpty { return true }
            return currentFileScope().hasUnresolvedInventory(fileInventory)
        }
        let modelSourceFence = self.saveFence
        let fileDataAuthorized: @Sendable () -> Bool = {
            isAuthorized() && modelSourceFence.isCurrent(key: "MeetingRecord/", snapshot: savedVersion)
        }
        func isKeyCurrent(_ key: String) -> Bool {
            self.modelChanges.isCurrent(key: key, snapshot: modelVersions)
                && self.saveFence.isCurrent(key: key, snapshot: savedVersion)
                && !(CloudModelCodec.entityName(for: key).map { self.unavailableModelEntities.contains($0) } ?? false)
                && (!RoutineStore.isCloudRecordKey(key) || routineGeneration == routineStore.changeGeneration)
        }
        func isCaptureProtected(_ key: String) -> Bool {
            if key.hasPrefix(CloudFileStore.prefix) {
                guard let id = CloudFileStore.meetingID(for: key) else {
                    return fileInventoryUnavailable || meetingGraphChanged
                }
                let dependencyScope = currentFileScope()
                if dependencyScope.deletedMeetingIDs.contains(id), files[key] != nil { return true }
                return fileInventoryUnavailable || meetingGraphChanged
                    || !self.modelChanges.isCurrent(key: "MeetingRecord/", snapshot: modelVersions)
                    || !self.saveFence.isCurrent(key: "MeetingRecord/", snapshot: savedVersion)
                    || fileInventory.unavailableMeetingIDs.contains(id) || runtimeUnavailableFileIDs.contains(id)
                    || !dependencyScope.authorizes(id, isFenced: fileInventory.fencedMeetingIDs.contains(id))
                    || fileInventory.namespaceDependencies[id, default: []].contains(where: { !dependencyScope.authorizes($0) })
            }
            let active = initialUnscopedCapture || MeetingCaptureCoordinator.hasUnscopedCaptureForCloudSync
            if let id = try? CloudModelCodec.meetingID(for: key) {
                let dependencies = namespaceGraph[id] ?? [id]
                return active || dependencies.contains(where: {
                    initialProtectedIDs.contains($0) || !namespaceAuthorization($0)
                }) || (namespaceGraph[id] == nil && !fileCaptureAuthorization())
            }
            // Derived meeting-wide vocabularies/observations have no root key.
            let meetingFamilies: Set<String> = ["MeetingGlossaryTerm", "VocabularyStoreMetadata",
                "VocabularySourceState", "VocabularyObservation"]
            return CloudModelCodec.entityName(for: key).map { meetingFamilies.contains($0) } == true
                && (!fileCaptureAuthorization() || MeetingCaptureCoordinator.hasActiveMeetingWorkForCloudSync)
        }
        guard UserCloudSyncPolicy.isEnabled, !Task.isCancelled else { throw CancellationError() }
        var digests = cachedModelDigests
        digests.merge(preferences.mapValues(CloudFileStore.digest)) { _, value in value }
        digests.merge(routineRecords.mapValues(CloudFileStore.digest)) { _, value in value }
        digests.merge(files.mapValues(\.digest)) { _, value in value }
        var restored = 0
        var restoredTodoRecords = false
        var postRestoreTasksUnavailable = false
        defer {
            if isAuthorized(), !Task.isCancelled, accountVersion == accountGeneration {
                dependencyContinuation = FullCloudSyncProgress.shouldContinueDependencies(
                    enqueued: engine.didEnqueueChanges, restored: restored,
                    hasDeferredKeys: !engine.deferredKeys.isEmpty || hasUnresolvedFileInventory())
                if dependencyContinuation { rerunForLocalSave = true }
            }
            if !postRestoreTasksUnavailable, isAuthorized(), !Task.isCancelled, accountVersion == accountGeneration,
               FullCloudSyncProgress.tasksRestored(completedInventory: engine.didCompleteInventory,
                   heldKeys: heldConflictKeys.union(engine.deferredKeys), unavailableEntities: unavailableModelEntities,
                   isCurrent: {
                       modelChanges.isCurrent(key: $0, snapshot: modelVersions)
                           && saveFence.isCurrent(key: $0, snapshot: savedVersion)
                   }) {
                hasFinishedTaskRestore = true
            }
            if restored > 0 {
                restoredItemCount += restored
                rerunForLocalSave = true
                SettingsStore.shared.didRestoreFullCloudPreferences()
                MemoryService.shared.invalidateCache()
                NotificationCenter.default.post(name: UserCloudSyncPolicy.didRestoreNotification, object: nil)
            }
        }
        let heldFileMeetingIDs = heldMeetingIDs
        let meetingFilePrefix = "file/Meetings/"
        let meetingFilePrefixCount = meetingFilePrefix.count
        try await engine.reconcile(digests: digests,
            temporarilyUnavailable: heldConflictKeys.union(["file/LocalRoutines/routines.json"]),
            isTemporarilyUnavailable: { key in
                guard !heldMeetingIDs.isEmpty, key.hasPrefix(meetingFilePrefix) else { return false }
                let meetingID = key.dropFirst(meetingFilePrefixCount).prefix { $0 != "/" }
                return heldFileMeetingIDs.contains(String(meetingID))
            }, isValid: {
            UserCloudSyncPolicy.isEnabled && isAuthorized() && accountVersion == self.accountGeneration
        }, isKeyValid: { key in
            isKeyCurrent(key) && !isCaptureProtected(key)
        }, didEnqueue: {
            self.queuedSequence &+= 1
            self.lastEnqueueDate = Date()
            self.isQueuedForCloud = true
        }, load: { key in
            guard UserCloudSyncPolicy.isEnabled, isAuthorized(), !Task.isCancelled,
                  accountVersion == self.accountGeneration else { throw CancellationError() }
            if let file = files[key] {
                let payload: Data
                do {
                    let scope = currentFileScope()
                    payload = try await self.fileStore.load(file, isAuthorized: fileDataAuthorized,
                        isMeetingAuthorized: { scope.authorizes($0) })
                } catch CloudFileError.changingFile {
                    if let id = CloudFileStore.meetingID(for: key) { runtimeUnavailableFileIDs.insert(id) }
                    throw CloudFileError.changingFile
                }
                guard UserCloudSyncPolicy.isEnabled, isAuthorized(), !Task.isCancelled,
                      accountVersion == self.accountGeneration else { throw CancellationError() }
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
            if let info = try CloudModelCodec.meetingNamespaceInfo(key: key, payload: records[key]),
               !FullCloudFileScope.permitsModelParent(info.parent, unsettledMeetingKeys: engine.unsettledMeetingKeys) {
                throw CloudFileError.changingFile
            }
            return records[key]
        }, apply: { key, payload in
            guard UserCloudSyncPolicy.isEnabled, isAuthorized(), !Task.isCancelled,
                  accountVersion == self.accountGeneration else { throw CancellationError() }
            if RoutineStore.isCloudRecordKey(key) {
                try routineStore.applyCloudRecord(key: key, payload: payload)
                routineGeneration = routineStore.changeGeneration
                routineRecords = try routineStore.captureCloudRecords()
                self.rerunForLocalSave = true
            } else if CloudPreferenceStore.isPreferenceKey(key) {
                try CloudPreferenceStore.apply(key: key, payload: payload, expectedDigest: digests[key])
            } else if key.hasPrefix(CloudFileStore.prefix) {
                guard !isCaptureProtected(key) else { throw CancellationError() }
                do {
                    let scope = currentFileScope()
                    if let id = CloudFileStore.meetingID(for: key), payload != nil,
                       scope.deletedMeetingIDs.contains(id) { throw CloudFileError.changingFile }
                    let result = try await self.fileStore.apply(key: key, payload: payload, expectedDigest: files[key]?.digest,
                        isAuthorized: fileDataAuthorized, isMeetingAuthorized: { scope.authorizes($0) })
                    guard result == .applied else { throw CloudFileError.changingFile }
                } catch CloudFileError.changingFile {
                    if let id = CloudFileStore.meetingID(for: key) { runtimeUnavailableFileIDs.insert(id) }
                    throw CloudFileError.changingFile
                }
            } else {
                if let info = try CloudModelCodec.meetingNamespaceInfo(key: key, payload: payload ?? records[key]),
                   (!FullCloudFileScope.permitsModelParent(info.parent, unsettledMeetingKeys: engine.unsettledMeetingKeys)
                    || info.ids.contains(where: { !namespaceAuthorization($0) })) {
                    throw CloudFileError.changingFile
                }
                try self.applyModelRecord(key: key, payload: payload, app: app, email: email, meeting: meeting,
                    isAuthorized: isAuthorized)
                if try CloudModelCodec.meetingID(for: key) != nil { meetingGraphChanged = true }
            }
            if key.hasPrefix("Todo/") {
                restoredTodoRecords = true
                self.taskAcceptanceCheckpoint.invalidate()
            }
            restored += 1
        })
        if canReconcileAcceptances, modelChanges.isCurrent(key: "Todo/", snapshot: modelVersions),
           saveFence.isCurrent(key: "Todo/", snapshot: savedVersion) {
            var acceptanceContext = app
            if restoredTodoRecords {
                postRestoreTasksUnavailable = true
                // Remote task changes happened after the first aggregate capture.
                // Re-read the complete task inventory before marking its signature.
                let fresh = ModelContext(data.container)
                fresh.autosaveEnabled = false
                let tasks = try CloudModelCodec.capture(app: fresh, email: email, meeting: meeting, entities: ["Todo"])
                if tasks.conflictingKeys.isEmpty,
                   modelChanges.isCurrent(key: "Todo/", snapshot: modelVersions),
                   saveFence.isCurrent(key: "Todo/", snapshot: savedVersion) {
                    taskAggregateDigest = tasks.taskAggregateDigest
                    acceptanceContext = fresh
                    postRestoreTasksUnavailable = false
                } else {
                    modelDataDirty = true
                    rerunForLocalSave = true
                }
            }
            if !postRestoreTasksUnavailable { try reconcileAcceptancesIfChanged(in: acceptanceContext) }
        }
        if let fileCaptureError { throw fileCaptureError }
        if let modelCaptureError { throw modelCaptureError }
        return !postRestoreTasksUnavailable && heldConflictKeys.isEmpty && engine.deferredKeys.isEmpty
            && !isRecordingDeferred && !hasUnresolvedFileInventory() && fileCaptureAuthorization()
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
        modelCaptureCache.invalidateAll()
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
        guard pendingRun == nil else { return }
        pendingRun = Task.detached { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(750))
                self?.pendingRun = nil
                try await self?.synchronizeNow()
            } catch { /* Cancellation, or a failure already published by synchronizeNow. */ }
        }
    }

    private func recordCloudImportCompletion() {
        cloudChangeGeneration &+= 1
        modelDataDirty = true
        modelChanges.invalidateAll(cache: modelCaptureCache)
        if synchronizing { rerunForLocalSave = true }
        schedule()
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
            if event.type == .import {
                activeCloudImports.insert(event.identifier)
                cloudChangeGeneration &+= 1
            }
            return
        }
        activeCloudImports.remove(event.identifier)
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
            recordCloudImportCompletion()
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
