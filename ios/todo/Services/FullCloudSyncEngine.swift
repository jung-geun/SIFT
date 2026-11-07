import CryptoKit
import Foundation
import SwiftData

/// Append-only revisions keep the payload, deletion and logical clock atomic.
/// CloudKit field-by-field conflict merging must never combine two versions.
@Model
final class CloudDataRevision {
    var revisionID: UUID = UUID()
    @Attribute(.allowsCloudEncryption) var itemKey: String = ""
    var logicalClock: Int64 = 0
    var installationID: String = ""
    // Frozen legacy wire column: CloudKit forbids renaming/removing it, and
    // PersistentModel.isDeleted makes its generated accessor unsafe to use.
    private var isDeleted: Bool = false
    var isTombstone: Bool = false
    var contentDigest: String = ""
    @Attribute(.externalStorage, .allowsCloudEncryption) var payload: Data?

    init(itemKey: String, clock: Int64, installationID: String, payload: Data?, digest: String? = nil) {
        self.itemKey = itemKey
        self.logicalClock = clock
        self.installationID = installationID
        self.isTombstone = payload == nil
        self.contentDigest = digest ?? payload.map(CloudFileStore.digest) ?? ""
        self.payload = payload
    }

    /// A store predicate reads the legacy persisted bit without invoking the
    /// conflicting getter. Exclude pending objects so SQL, not lifecycle state,
    /// determines which old rows have an explicit persisted deletion marker.
    static func persistedLegacyTombstoneIDs(in context: ModelContext) throws -> Set<PersistentIdentifier> {
        var descriptor = FetchDescriptor<CloudDataRevision>(predicate: #Predicate {
            $0.isDeleted && !$0.isTombstone
        })
        descriptor.includePendingChanges = false
        descriptor.propertiesToFetch = [\.revisionID]
        return try Set(context.fetch(descriptor).map(\.persistentModelID))
    }
}

nonisolated struct CloudSyncCheckpoint: Codable, Equatable, Sendable {
    var digest: String?
    var revisionID: UUID
    var logicalClock: Int64
    var installationID: String
}

/// Only fingerprints and revision metadata belong in the write-ahead journal;
/// audio and other payload bytes remain in their canonical stores.
nonisolated struct CloudSyncPendingApply: Codable, Sendable {
    var sourceDigest: String?
    var target: CloudSyncCheckpoint
}

nonisolated struct CloudSyncJournal: Codable, Sendable {
    var version = 1
    var items = [String: CloudSyncCheckpoint]()
    var pendingApplies = [String: CloudSyncPendingApply]()
    var pendingPublications = [String: CloudSyncCheckpoint]()

    init() {}

    private enum CodingKeys: String, CodingKey { case version, items, pendingApplies, pendingPublications }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        items = try values.decode([String: CloudSyncCheckpoint].self, forKey: .items)
        // Existing digest-only v1 journals remain valid.
        pendingApplies = try values.decodeIfPresent([String: CloudSyncPendingApply].self, forKey: .pendingApplies) ?? [:]
        pendingPublications = try values.decodeIfPresent([String: CloudSyncCheckpoint].self, forKey: .pendingPublications) ?? [:]
    }
}

nonisolated enum FullCloudSyncError: Error, CustomNSError, Equatable {
    case invalidRevision, invalidJournal, clockOverflow, persistentStoreUnavailable
    case revisionValidation(CloudRevisionValidation.Failure)

    static var errorDomain: String { "SIFT.FullCloudSync" }
    var errorCode: Int {
        switch self {
        case .invalidRevision: return 0
        case .invalidJournal: return 1
        case .clockOverflow: return 2
        case .persistentStoreUnavailable: return 3
        case .revisionValidation(let failure): return 100 + failure.rawValue
        }
    }
}

/// Validation reports only the failed invariant, never the key, bytes or IDs.
nonisolated enum CloudRevisionValidation {
    enum Failure: Int, CaseIterable, Sendable {
        case itemKeyMismatch = 1
        case logicalClockMismatch
        case installationMismatch
        case missingPayload
        case unexpectedDeletedPayload
        case digestMetadataMismatch
        case payloadDigestMismatch
    }

    static func validate(key: String, clock: Int64, installation: String,
                         isDeleted: Bool, contentDigest: String, payload: Data?,
                         expectedKey: String, expected: CloudSyncCheckpoint) throws {
        guard key == expectedKey else { throw FullCloudSyncError.revisionValidation(.itemKeyMismatch) }
        guard clock == expected.logicalClock else { throw FullCloudSyncError.revisionValidation(.logicalClockMismatch) }
        guard installation == expected.installationID else { throw FullCloudSyncError.revisionValidation(.installationMismatch) }
        if isDeleted {
            guard payload == nil else { throw FullCloudSyncError.revisionValidation(.unexpectedDeletedPayload) }
        } else {
            guard payload != nil else { throw FullCloudSyncError.revisionValidation(.missingPayload) }
        }
        guard contentDigest == (expected.digest ?? "") else {
            throw FullCloudSyncError.revisionValidation(.digestMetadataMismatch)
        }
        guard try payload.map(CloudRevisionPayloadReader.digest) == expected.digest else {
            throw FullCloudSyncError.revisionValidation(.payloadDigestMismatch)
        }
    }
}

/// Wall-clock skew cannot resurrect an older deletion.
nonisolated enum CloudRevisionOrder {
    static func isNewer(clock: Int64, installation: String, revision: UUID,
                        than other: CloudSyncCheckpoint) -> Bool {
        if clock != other.logicalClock { return clock > other.logicalClock }
        if installation != other.installationID { return installation > other.installationID }
        return revision.uuidString > other.revisionID.uuidString
    }
}

/// Constructed outside MainActor so external-storage faults and hashing use an
/// isolated background context. One revision is materialized at a time.
@ModelActor
private actor CloudRevisionPayloadReader {
    private var validated = [String: CloudSyncCheckpoint]()

    func load(id: PersistentIdentifier, key: String, revisionID: UUID,
              expected: CloudSyncCheckpoint, needsPayload: Bool) throws -> Data? {
        try Task.checkCancellation()
        if !needsPayload, validated[key] == expected { return nil }
        var descriptor = FetchDescriptor<CloudDataRevision>(predicate: #Predicate { $0.revisionID == revisionID })
        descriptor.fetchLimit = 1
        guard let revision = try modelContext.fetch(descriptor).first,
              revision.persistentModelID == id else { throw CancellationError() }
        let data = revision.payload
        try CloudRevisionValidation.validate(key: revision.itemKey, clock: revision.logicalClock,
            installation: revision.installationID, isDeleted: revision.isTombstone,
            contentDigest: revision.contentDigest, payload: data, expectedKey: key, expected: expected)
        try Task.checkCancellation()
        validated[key] = expected
        return needsPayload ? data : nil
    }

    func confirmsLegacyTombstone(id: PersistentIdentifier, key: String,
                                 expected: CloudSyncCheckpoint) throws -> Bool {
        try Task.checkCancellation()
        let revisionID = expected.revisionID
        var descriptor = FetchDescriptor<CloudDataRevision>(predicate: #Predicate { $0.revisionID == revisionID })
        descriptor.fetchLimit = 1
        guard let revision = try modelContext.fetch(descriptor).first,
              revision.persistentModelID == id, revision.itemKey == key,
              revision.logicalClock == expected.logicalClock,
              revision.installationID == expected.installationID,
              expected.digest == nil, !revision.isTombstone,
              revision.contentDigest.isEmpty else { throw CancellationError() }
        return revision.payload == nil
    }

    nonisolated static func digest(_ data: Data) throws -> String {
        try data.withUnsafeBytes { bytes in
            var hash = SHA256()
            for start in stride(from: 0, to: bytes.count, by: 256 * 1_024) {
                try Task.checkCancellation()
                let end = min(start + 256 * 1_024, bytes.count)
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
            }
            try Task.checkCancellation()
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}

@MainActor
final class FullCloudSyncEngine {
    private let cloud: ModelContext
    private let installationID: String
    private let journalURL: URL
    private var payloadReader: CloudRevisionPayloadReader?
    private(set) var journal: CloudSyncJournal
    private(set) var storeIdentifier: String?
    private(set) var didEnqueueChanges = false
    private(set) var unavailableConflictKeys = Set<String>()
    /// Skipped keys retain their journal intents; this pass is not globally complete.
    private(set) var deferredKeys = Set<String>()
    private(set) var didCompleteInventory = false
    /// Models must settle before their original-file namespaces can be reconciled.
    /// Kept for the entire pass, including after a successful model apply, so no
    /// file deletion intent can be planned from the pre-restore inventory.
    private(set) var unsettledMeetingKeys = Set<String>()
    // Acknowledged tombstones also permit the next pass's read-only inventory;
    // unsettledMeetingKeys always overrides them before file mutations.
    private(set) var settledMeetingTombstones = Set<String>()
    private var journalDirty = false

    private enum Operation {
        case apply(CloudDataRevision)
        case publish(CloudSyncCheckpoint)
        case converge(CloudDataRevision?, CloudSyncCheckpoint, Data)
        case inspect(CloudDataRevision, adopt: Bool)
    }

    init(cloud: ModelContext, installationID: String, journalURL: URL) throws {
        self.cloud = cloud
        self.installationID = installationID
        self.journalURL = journalURL
        cloud.autosaveEnabled = false
        if FileManager.default.fileExists(atPath: journalURL.path) {
            journal = try JSONDecoder().decode(CloudSyncJournal.self, from: Data(contentsOf: journalURL))
            guard journal.version == 1 else { throw FullCloudSyncError.invalidJournal }
        } else { journal = CloudSyncJournal() }
    }

    /// Review only actual competing model edits. Ordinary incoming updates and
    /// an initial cloud restore are not conflicts merely because bytes differ.
    func modelConflicts(local: CloudModelCodec.Snapshot,
                        isTemporarilyUnavailable: (String) -> Bool = { _ in false }) async throws -> [CloudSyncConflict] {
        unavailableConflictKeys = []
        var descriptor = FetchDescriptor<CloudDataRevision>()
        descriptor.propertiesToFetch = [\.revisionID, \.itemKey, \.logicalClock, \.installationID, \.isTombstone, \.contentDigest]
        let rows = try cloud.fetch(descriptor).filter { CloudModelCodec.isModelKey($0.itemKey) }
        let groups = Dictionary(grouping: rows, by: \.itemKey)
        var result = [CloudSyncConflict]()
        for key in Set(groups.keys).union(local.conflictingKeys).sorted() {
            if isTemporarilyUnavailable(key) {
                unavailableConflictKeys.insert(key)
                continue
            }
            let revisions = groups[key, default: []]
            let latest = revisions.max { newer($1, than: checkpoint($0)) }
            let baseline = journal.items[key]
            let localDigest = local.digests[key] ?? local.records[key].map(CloudFileStore.digest)
            let pending = journal.pendingPublications[key]
            let concurrent = latest.map {
                baseline != nil && localDigest != baseline?.digest && localDigest != checkpoint($0).digest
                    && newer($0, than: baseline!)
                    && (pending == nil || pending!.digest != localDigest)
            } ?? false
            let peers = latest.map { latest in
                revisions.filter { $0.logicalClock == latest.logicalClock }
            } ?? []
            let competingPeers = Set(peers.map { checkpoint($0).digest ?? "deleted" }).count > 1
                && (pending == nil || pending!.logicalClock <= (latest?.logicalClock ?? 0))
            guard local.conflictingKeys.contains(key) || concurrent || competingPeers else { continue }
            var versions = try local.versions[key, default: []].map {
                try CloudModelCodec.reviewVersion(key: key, payload: $0,
                    origin: local.origins[key] ?? .local, source: local.origins[key] == .legacy ? "legacy" : "local")
            }
            if local.versions[key] == nil && baseline != nil {
                versions.append(try CloudModelCodec.reviewVersion(key: key, payload: nil, origin: .local, source: "local"))
            }
            // All superseded remote payloads are retained before resolution,
            // not only the currently winning logical clock.
            var unavailable = false
            var relevant = concurrent ? versions.map(\.payload) : []
            for revision in revisions {
                do {
                    let payload = try await materialize(revision)
                    if revision.logicalClock == latest?.logicalClock { relevant.append(payload) }
                    versions.append(try CloudModelCodec.reviewVersion(key: key, payload: payload, origin: .cloud,
                        source: revision.installationID,
                        revision: revision.revisionID.uuidString + ":" + String(revision.logicalClock)))
                } catch FullCloudSyncError.revisionValidation(.missingPayload) {
                    // Keep this identity held while an external CloudKit asset
                    // arrives; do not starve independent records or offer a
                    // deletion placeholder for an unreadable version.
                    unavailable = true
                }
            }
            if unavailable { unavailableConflictKeys.insert(key); continue }
            if !local.conflictingKeys.contains(key) {
                do {
                    if try Set(relevant.map { try CloudModelCodec.semanticDigest(key: key, payload: $0) ?? "deleted" }).count <= 1 {
                        continue
                    }
                } catch let error as CloudModelCodec.CodecError {
                    switch error {
                    case .malformedPayload(_), .unsupportedSchema(_):
                        // A newer schema is not proof of semantic equivalence.
                        // Keep the complete readable versions reviewable and
                        // held; never let this one key starve unrelated sync.
                        DiagnosticRecorder.shared.record(error: error, component: "sync.fullData", operation: "reviewSchema")
                    default: throw error
                    }
                } catch is DecodingError {
                    DiagnosticRecorder.shared.record(error: FullCloudSyncError.invalidRevision,
                        component: "sync.fullData", operation: "reviewSchema")
                }
            }
            result.append(CloudSyncConflict(key: key, versions: versions))
        }
        return result
    }

    func cloudVersions(key: String) async throws -> [CloudSyncConflictVersion] {
        var result = [CloudSyncConflictVersion]()
        for row in try cloud.fetch(FetchDescriptor<CloudDataRevision>()).filter({ $0.itemKey == key }) {
            let payload = try await materialize(row)
            result.append(try CloudModelCodec.reviewVersion(key: key, payload: payload,
                origin: .cloud, source: row.installationID,
                revision: row.revisionID.uuidString + ":" + String(row.logicalClock)))
        }
        return result
    }

    /// The protected review archive is committed by the caller first. Write an
    /// ordinary publication intent before local apply so a cloud-save failure or
    /// restart retries the same selected version instead of restoring a loser.
    func resolve(key: String, payload: Data?, expectedCloudVersions: [CloudSyncConflictVersion],
                 isValid: () -> Bool, isApplied: () -> Bool = { false }, apply: () throws -> Void,
                 saveCloud: (ModelContext) throws -> Void = { try $0.save() }) throws {
        try checkCurrent(isValid)
        let all = try cloud.fetch(FetchDescriptor<CloudDataRevision>())
        let rows = all.filter { $0.itemKey == key }
        let observed = try rows.map { row in
            try CloudRevisionValidation.validate(key: row.itemKey, clock: row.logicalClock,
                installation: row.installationID, isDeleted: row.isTombstone, contentDigest: row.contentDigest,
                payload: row.payload, expectedKey: key, expected: checkpoint(row))
            return try CloudModelCodec.reviewVersion(key: key, payload: row.payload, origin: .cloud,
                source: row.installationID, revision: row.revisionID.uuidString + ":" + String(row.logicalClock))
        }
        guard Set(observed.map(\.id)) == Set(expectedCloudVersions.map(\.id)) else {
            throw CloudSyncConflictError.staleSelection
        }
        let maximum = (all.map(\.logicalClock) + journal.items.values.map(\.logicalClock)
            + journal.pendingPublications.values.map(\.logicalClock)
            + journal.pendingApplies.values.map { $0.target.logicalClock }).max() ?? 0
        guard maximum < Int64.max else { throw FullCloudSyncError.clockOverflow }
        let target = CloudSyncCheckpoint(digest: payload.map(CloudFileStore.digest), revisionID: UUID(),
            logicalClock: maximum + 1, installationID: installationID)
        let previousJournal = journal
        journal.pendingPublications[key] = target
        journal.pendingApplies.removeValue(forKey: key)
        journalDirty = true
        do { try persistJournal() }
        catch { journal = previousJournal; journalDirty = true; throw error }
        do {
            try checkCurrent(isValid)
            try apply()
        } catch {
            // A post-save side effect (for example clearing a meeting fence)
            // may fail after the canonical bytes committed. Preserve the
            // publication intent in that case for normal replay.
            if !isApplied() {
                journal = previousJournal
                journalDirty = true
                try persistJournal()
            }
            throw error
        }
        do {
            let revision = CloudDataRevision(itemKey: key, clock: target.logicalClock,
                installationID: installationID, payload: payload)
            revision.revisionID = target.revisionID
            cloud.insert(revision)
            for row in rows { cloud.delete(row) }
            try saveCloud(cloud)
        } catch {
            cloud.rollback()
            // Keep the selected intent: local apply already committed.
            throw error
        }
        didEnqueueChanges = true
        remember(key, target)
        journal.pendingPublications.removeValue(forKey: key)
        journalDirty = true
        try persistJournal()
    }

    /// Write intent before either store is changed. A restart can distinguish an
    /// unchanged source, an applied target, and a genuinely newer local edit.
    /// `apply` must durably save its canonical local target before returning.
    /// `didEnqueue` fires synchronously after every cloud save, even if a later
    /// operation fails; `isValid` fences mutations after asynchronous work.
    @discardableResult
    func reconcile(digests: [String: String], temporarilyUnavailable: Set<String> = [],
                   isTemporarilyUnavailable: (String) -> Bool = { _ in false },
                   isValid: () -> Bool = { true }, isKeyValid: (String) -> Bool = { _ in true },
                   didEnqueue: (() -> Void)? = nil,
                   load: (String) async throws -> Data?,
                   apply: (String, Data?) async throws -> Void) async throws -> Int {
        var preferenceUnavailable = false
        var firstItemError: (any Error)?
        var invalidKeys = Set<String>()
        func isUnavailable(_ key: String) -> Bool {
            let dependsOnPreferences = key.hasPrefix("EmailMessage/") || key.hasPrefix("MailAnalysisLedgerRecord/")
            let deferred = !isKeyValid(key) || invalidKeys.contains(key)
                || (preferenceUnavailable && dependsOnPreferences)
            if deferred {
                deferredKeys.insert(key)
                if CloudModelCodec.entityName(for: key) == "MeetingRecord" { unsettledMeetingKeys.insert(key) }
            }
            return deferred || temporarilyUnavailable.contains(key) || isTemporarilyUnavailable(key)
        }
        didEnqueueChanges = false
        deferredKeys = []
        didCompleteInventory = false
        unsettledMeetingKeys = []
        settledMeetingTombstones = []
        var missingPayloadKeys = Set<String>()
        try checkCurrent(isValid)
        var descriptor = FetchDescriptor<CloudDataRevision>()
        descriptor.propertiesToFetch = [\.revisionID, \.itemKey, \.logicalClock, \.installationID, \.isTombstone, \.contentDigest]
        let revisions = try cloud.fetch(descriptor)
        var latest = [String: CloudDataRevision]()
        var revisionsByKey = [String: [CloudDataRevision]]()
        var maximumClock: Int64 = 0
        for value in journal.items.values { maximumClock = max(maximumClock, value.logicalClock) }
        for value in journal.pendingPublications.values { maximumClock = max(maximumClock, value.logicalClock) }
        for value in journal.pendingApplies.values { maximumClock = max(maximumClock, value.target.logicalClock) }
        for revision in revisions {
            try checkCurrent(isValid)
            storeIdentifier = revision.persistentModelID.storeIdentifier
            guard revision.logicalClock > 0, UUID(uuidString: revision.installationID) != nil,
                  !revision.itemKey.isEmpty, !revision.isTombstone || revision.contentDigest.isEmpty else {
                invalidKeys.insert(revision.itemKey)
                firstItemError = firstItemError ?? FullCloudSyncError.invalidRevision
                if CloudPreferenceStore.isPreferenceKey(revision.itemKey) { preferenceUnavailable = true }
                continue
            }
            maximumClock = max(maximumClock, revision.logicalClock)
            revisionsByKey[revision.itemKey, default: []].append(revision)
            if let current = latest[revision.itemKey], !newer(revision, than: checkpoint(current)) { continue }
            latest[revision.itemKey] = revision
        }
        guard maximumClock < Int64.max else { throw FullCloudSyncError.clockOverflow }
        let nextClock = maximumClock + 1
        let meetingKeys = Set(digests.keys).union(journal.items.keys).union(latest.keys)
            .union(journal.pendingApplies.keys).union(journal.pendingPublications.keys).union(invalidKeys)
        for key in meetingKeys where CloudModelCodec.entityName(for: key) == "MeetingRecord" {
            let baseline = journal.items[key]
            let remote = latest[key].map(checkpoint)
            if isUnavailable(key) || baseline == nil || remote != baseline || digests[key] != baseline?.digest
                || journal.pendingApplies[key] != nil || journal.pendingPublications[key] != nil {
                unsettledMeetingKeys.insert(key)
            } else if baseline?.digest == nil { settledMeetingTombstones.insert(key) }
        }
        try await repairLegacyTombstones(revisions, isUnavailable: isUnavailable, isValid: isValid, didEnqueue: didEnqueue)

        var completingApplies = [String: CloudDataRevision]()
        for (key, pending) in journal.pendingApplies where !isUnavailable(key) {
            try checkCurrent(isValid)
            let local = digests[key]
            if local == pending.target.digest, let remote = latest[key], checkpoint(remote) == pending.target {
                // The target bytes committed, but apply may have failed while
                // clearing a recovery fence or another durable side effect.
                // Replay idempotently before acknowledging this same winner.
                completingApplies[key] = remote
                continue
            }
            if local == pending.target.digest || local != pending.sourceDigest {
                // Target means apply committed. A third value is a subsequent
                // user edit, including an edit on a previously joining device.
                remember(key, pending.target)
            }
            journal.pendingApplies.removeValue(forKey: key)
            journalDirty = true
        }
        for (key, pending) in journal.pendingPublications where !isUnavailable(key) {
            try checkCurrent(isValid)
            if let saved = revisionsByKey[key, default: []].first(where: { checkpoint($0) == pending }) {
                // Metadata alone does not prove that this publication's external
                // bytes are readable. Keep its durable intent until validated.
                do {
                    _ = try await materialize(saved, needsPayload: false)
                    try checkCurrent(isValid)
                    if isUnavailable(key) { continue }
                } catch FullCloudSyncError.revisionValidation(.missingPayload) {
                    if CloudPreferenceStore.isPreferenceKey(key) { preferenceUnavailable = true }
                    missingPayloadKeys.insert(key)
                    if CloudModelCodec.entityName(for: key) == "MeetingRecord" { unsettledMeetingKeys.insert(key) }
                    continue
                } catch {
                    if error is CancellationError {
                        guard !Task.isCancelled, isValid(), isUnavailable(key) else { throw error }
                    } else {
                        guard isValid(), !Task.isCancelled else { throw error }
                        firstItemError = firstItemError ?? error
                        invalidKeys.insert(key)
                    }
                    if CloudPreferenceStore.isPreferenceKey(key) { preferenceUnavailable = true }
                    continue
                }
                remember(key, pending)
                journal.pendingPublications.removeValue(forKey: key)
                journalDirty = true
            }
        }

        let allKeys = Set(digests.keys).union(journal.items.keys).union(latest.keys)
            .union(journal.pendingPublications.keys).union(invalidKeys)
        // Representation markers precede mail bodies that depend on them.
        let orderedKeys = allKeys.sorted { first, second in
            let a = CloudPreferenceStore.isPreferenceKey(first)
            let b = CloudPreferenceStore.isPreferenceKey(second)
            return a != b ? a : first < second
        }
        var operations = [String: Operation]()
        for key in orderedKeys where !isUnavailable(key) && !missingPayloadKeys.contains(key) {
            try checkCurrent(isValid)
            if let remote = completingApplies[key] {
                operations[key] = .apply(remote)
                continue
            }
            var baseline = journal.items[key]
            let local = digests[key]
            let remote = latest[key]
            if let pending = journal.pendingPublications[key] {
                if local == pending.digest {
                    if let remote, newer(remote, than: pending) {
                        remember(key, pending)
                        planApply(key, remote: remote, source: local, operations: &operations)
                        journal.pendingPublications.removeValue(forKey: key)
                        journalDirty = true
                    } else {
                        // The previous save never committed: retry the SAME ID
                        // and clock rather than manufacturing a newer echo.
                        operations[key] = .publish(pending)
                    }
                    continue
                }
                // The user changed the source after the abandoned publication.
                if baseline == nil {
                    baseline = pending
                    remember(key, pending)
                }
                journal.pendingPublications.removeValue(forKey: key)
                journalDirty = true
            }
            if key.hasPrefix("EmailMessage/"), let remote, !remote.isTombstone {
                let peers = revisionsByKey[key, default: []].filter { $0.logicalClock == remote.logicalClock }
                let hasCompetingPeers = Set(peers.map { checkpoint($0).digest ?? "deleted" }).count > 1
                let localCompetesWithRemote = local != nil && local != checkpoint(remote).digest
                    && (baseline == nil || (local != baseline?.digest && newer(remote, than: baseline!)))
                if (hasCompetingPeers || localCompetesWithRemote), peers.allSatisfy({ !$0.isTombstone }) {
                    do {
                        var candidates = [Data]()
                        var peerByDigest = [String: CloudDataRevision]()
                        let orderedPeers = [remote] + peers.filter { $0 !== remote }
                        for peer in orderedPeers {
                            if let data = try await materialize(peer) {
                                try checkCurrent(isValid)
                                if isUnavailable(key) { break }
                                candidates.append(data)
                                let digest = checkpoint(peer).digest ?? CloudFileStore.digest(data)
                                if peerByDigest[digest] == nil { peerByDigest[digest] = peer }
                            }
                        }
                        if isUnavailable(key) { continue }
                        let includeLocal = local != nil && (baseline == nil || local != baseline?.digest)
                        if includeLocal, let expectedLocalDigest = local {
                            guard let localData = try await load(key) else { throw CloudFileError.changingFile }
                            try checkCurrent(isValid)
                            if isUnavailable(key) { continue }
                            guard try CloudRevisionPayloadReader.digest(localData) == expectedLocalDigest else {
                                throw CloudFileError.changingFile
                            }
                            candidates.append(localData)
                        }
                        if let winner = CloudModelCodec.preferredEmailAnalysisPayload(key: key, candidates: candidates) {
                            let winningDigest = CloudFileStore.digest(winner)
                            if winningDigest == checkpoint(remote).digest {
                                planApply(key, remote: remote, source: local, operations: &operations)
                                continue
                            } else if winningDigest == local {
                                let intended = CloudSyncCheckpoint(digest: winningDigest, revisionID: UUID(),
                                    logicalClock: nextClock, installationID: installationID)
                                journal.pendingPublications[key] = intended
                                journalDirty = true
                                operations[key] = .publish(intended)
                                continue
                            } else if let winningPeer = peerByDigest[winningDigest] {
                                let intended = CloudSyncCheckpoint(digest: winningDigest, revisionID: UUID(),
                                    logicalClock: nextClock, installationID: installationID)
                                journal.pendingApplies[key] = CloudSyncPendingApply(
                                    sourceDigest: local, target: checkpoint(winningPeer))
                                journal.pendingPublications[key] = intended
                                journalDirty = true
                                operations[key] = .converge(winningPeer, intended, winner)
                                continue
                            }
                        }
                    } catch FullCloudSyncError.revisionValidation(.missingPayload) {
                        missingPayloadKeys.insert(key)
                        continue
                    } catch CloudFileError.changingFile {
                        deferredKeys.insert(key)
                        continue
                    } catch {
                        if error is CancellationError {
                            guard !Task.isCancelled, isValid(), isUnavailable(key) else { throw error }
                        } else {
                            guard isValid(), !Task.isCancelled else { throw error }
                            firstItemError = firstItemError ?? error
                        }
                        deferredKeys.insert(key)
                        continue
                    }
                }
            }
            if baseline == nil, let remote {
                planApply(key, remote: remote, source: local, operations: &operations)
            } else if local != baseline?.digest {
                if let remote, local == checkpoint(remote).digest {
                    operations[key] = .inspect(remote, adopt: true)
                } else {
                    let intended = CloudSyncCheckpoint(digest: local, revisionID: UUID(),
                        logicalClock: nextClock, installationID: installationID)
                    journal.pendingPublications[key] = intended
                    journalDirty = true
                    operations[key] = .publish(intended)
                }
            } else if let remote, baseline.map({ newer(remote, than: $0) }) ?? true {
                planApply(key, remote: remote, source: local, operations: &operations)
            } else if let remote {
                operations[key] = .inspect(remote, adopt: false)
            }
        }
        try checkCurrent(isValid)
        // A single bounded metadata write covers the whole pass, never assets.
        try persistJournal()
        var restored = 0
        // Per-record saves create a history transaction/export request for every
        // small preference or model. Bound both pending rows and payload bytes;
        // a single large asset still commits on its own.
        let publicationLimit = 64
        let payloadLimit = 4 * 1_024 * 1_024
        var publications = [(key: String, checkpoint: CloudSyncCheckpoint, revision: CloudDataRevision)]()
        publications.reserveCapacity(publicationLimit)
        var payloadBytes = 0
        var publicationSaveFailed = false
        func commitPublications() throws {
            guard !publications.isEmpty else { return }
            try checkCurrent(isValid)
            if publications.contains(where: { isUnavailable($0.key) }) {
                // Rebuild only the bounded uncommitted batch. Never discard an
                // independent task because another source changed while hashing.
                let valid = publications.compactMap { publication -> (String, CloudSyncCheckpoint, Data?)? in
                    guard !isUnavailable(publication.key) else { return nil }
                    return (publication.key, publication.checkpoint, publication.revision.payload)
                }
                cloud.rollback()
                publications.removeAll(keepingCapacity: true)
                payloadBytes = 0
                for (key, intended, data) in valid {
                    let revision = CloudDataRevision(itemKey: key, clock: intended.logicalClock,
                        installationID: intended.installationID, payload: data, digest: intended.digest ?? "")
                    revision.revisionID = intended.revisionID
                    cloud.insert(revision)
                    for old in revisionsByKey[key, default: []] { cloud.delete(old) }
                    publications.append((key, intended, revision))
                    payloadBytes += data?.count ?? 0
                }
                guard !publications.isEmpty else { return }
            }
            do { try cloud.save() }
            catch { publicationSaveFailed = true; throw error }
            storeIdentifier = publications.last?.revision.persistentModelID.storeIdentifier
            didEnqueueChanges = true
            didEnqueue?()
            try checkCurrent(isValid)
            for publication in publications {
                remember(publication.key, publication.checkpoint)
                journal.pendingPublications.removeValue(forKey: publication.key)
            }
            journalDirty = true
            publications.removeAll(keepingCapacity: true)
            payloadBytes = 0
        }
        do {
            for key in orderedKeys {
                try checkCurrent(isValid)
                guard !isUnavailable(key) else { continue }
                guard let operation = operations[key] else { continue }
                do {
                    switch operation {
                    case .apply(let remote):
                        try commitPublications()
                        let target = checkpoint(remote)
                        let payload = try await materialize(remote)
                        try checkCurrent(isValid)
                        if isUnavailable(key) { continue }
                        try await apply(key, payload)
                        try checkCurrent(isValid)
                        if isUnavailable(key) { continue }
                        restored += 1
                        remember(key, target)
                        journal.pendingApplies.removeValue(forKey: key)
                        journalDirty = true
                    case .publish(let intended):
                        if let remote = latest[key] {
                            _ = try await materialize(remote, needsPayload: false)
                            try checkCurrent(isValid)
                            if isUnavailable(key) { continue }
                        }
                        let data = try await load(key)
                        try checkCurrent(isValid)
                        if isUnavailable(key) { continue }
                        let hashing = Task.detached { try data.map(CloudRevisionPayloadReader.digest) }
                        let digest = try await withTaskCancellationHandler {
                            try await hashing.value
                        } onCancel: {
                            hashing.cancel()
                        }
                        try checkCurrent(isValid)
                        if isUnavailable(key) { continue }
                        guard digest == intended.digest else { throw CloudFileError.changingFile }
                        let size = data?.count ?? 0
                        if !publications.isEmpty, size > payloadLimit - payloadBytes {
                            try commitPublications()
                        }
                        let revision = CloudDataRevision(itemKey: key, clock: intended.logicalClock,
                            installationID: intended.installationID, payload: data, digest: intended.digest ?? "")
                        revision.revisionID = intended.revisionID
                        try checkCurrent(isValid)
                        cloud.insert(revision)
                        for old in revisionsByKey[key, default: []] {
                            try checkCurrent(isValid)
                            cloud.delete(old)
                        }
                        publications.append((key, intended, revision))
                        payloadBytes += size
                        if publications.count >= publicationLimit || payloadBytes >= payloadLimit {
                            try commitPublications()
                        }
                    case .converge(let winningRemote, let intended, let payload):
                        try commitPublications()
                        if let winningRemote {
                            _ = try await materialize(winningRemote, needsPayload: false)
                            try checkCurrent(isValid)
                            if isUnavailable(key) { continue }
                        }
                        try await apply(key, payload)
                        restored += 1
                        journal.pendingApplies.removeValue(forKey: key)
                        journalDirty = true
                        try checkCurrent(isValid)
                        if isUnavailable(key) { continue }
                        let size = payload.count
                        if !publications.isEmpty, size > payloadLimit - payloadBytes {
                            try commitPublications()
                        }
                        let revision = CloudDataRevision(itemKey: key, clock: intended.logicalClock,
                            installationID: intended.installationID, payload: payload, digest: intended.digest ?? "")
                        revision.revisionID = intended.revisionID
                        try checkCurrent(isValid)
                        cloud.insert(revision)
                        for old in revisionsByKey[key, default: []] {
                            try checkCurrent(isValid)
                            cloud.delete(old)
                        }
                        publications.append((key, intended, revision))
                        payloadBytes += size
                        if publications.count >= publicationLimit || payloadBytes >= payloadLimit {
                            try commitPublications()
                        }
                    case .inspect(let remote, let adopt):
                        _ = try await materialize(remote, needsPayload: false)
                        try checkCurrent(isValid)
                        if isUnavailable(key) { continue }
                        if adopt { remember(key, checkpoint(remote)) }
                    }
                } catch FullCloudSyncError.revisionValidation(.missingPayload) {
                    // An unreadable cloud asset must neither be replaced with
                    // local bytes nor starve independent keys later in the pass.
                    // Preference markers can govern decoding of subsequent mail
                    // bodies, so their failure still stops dependent work.
                    if CloudPreferenceStore.isPreferenceKey(key) { preferenceUnavailable = true }
                    missingPayloadKeys.insert(key)
                    if CloudModelCodec.entityName(for: key) == "MeetingRecord" { unsettledMeetingKeys.insert(key) }
                } catch CloudFileError.changingFile {
                    // Keep the write-ahead intent for a fresh inventory/retry.
                    // Other families can still enqueue and apply in this pass.
                    deferredKeys.insert(key)
                    if CloudModelCodec.entityName(for: key) == "MeetingRecord" { unsettledMeetingKeys.insert(key) }
                } catch {
                    // Authorization/cancellation and store failure remain global.
                    // A changed key may throw CancellationError from its actor
                    // fence without cancelling independent canonical families.
                    if error is CancellationError {
                        guard !Task.isCancelled, isValid(), isUnavailable(key) else { throw error }
                    } else {
                        guard !publicationSaveFailed, isValid(), !Task.isCancelled else { throw error }
                        firstItemError = firstItemError ?? error
                    }
                    if CloudPreferenceStore.isPreferenceKey(key) { preferenceUnavailable = true }
                    deferredKeys.insert(key)
                    if CloudModelCodec.entityName(for: key) == "MeetingRecord" { unsettledMeetingKeys.insert(key) }
                }
            }
            try commitPublications()
            for key in orderedKeys where !isUnavailable(key) && !missingPayloadKeys.contains(key)
                    && !deferredKeys.contains(key) {
                if case .publish? = operations[key] { continue }
                if case .converge? = operations[key] { continue }
                guard let remote = latest[key] else { continue }
                for old in revisionsByKey[key, default: []] where old !== remote {
                    try checkCurrent(isValid)
                    cloud.delete(old)
                }
            }
            if cloud.hasChanges {
                try checkCurrent(isValid)
                try cloud.save()
                didEnqueueChanges = true
                didEnqueue?()
            }
            try checkCurrent(isValid)
            try persistJournal()
            // Dynamic generation changes may arrive during the final suspension,
            // including for keys that needed no operation in this snapshot.
            for key in orderedKeys { _ = isUnavailable(key) }
            // Missing assets are an error, not successful reconciliation.
            deferredKeys.formUnion(missingPayloadKeys)
            didCompleteInventory = true
            if !missingPayloadKeys.isEmpty { throw FullCloudSyncError.revisionValidation(.missingPayload) }
            if let firstItemError { throw firstItemError }
            return restored
        } catch {
            // A changing/unreadable later source must not starve valid earlier
            // rows forever. Cancellation or a revoked snapshot still rolls back
            // the entire uncommitted group; never retry a failed store save.
            if !(error is CancellationError), !Task.isCancelled, isValid(), !publicationSaveFailed {
                do { try commitPublications() }
                catch { cloud.rollback(); throw error }
            }
            // The write-ahead journal intentionally remains on disk. Even if an
            // apply or save committed before throwing/cancellation, replay can
            // identify it from local fingerprints or the saved revision ID.
            cloud.rollback()
            throw error
        }
    }

    /// The frozen legacy wire field collided with PersistentModel lifecycle
    /// state. Accept only its SQL-backed true bit or an exact durable deletion
    /// checkpoint, plus absent bytes; missing data alone never proves deletion.
    private func repairLegacyTombstones(_ revisions: [CloudDataRevision], isUnavailable: (String) -> Bool,
                                        isValid: () -> Bool, didEnqueue: (() -> Void)?) async throws {
        var durable: CloudSyncJournal?
        var readDurable = false
        let legacyTombstoneIDs = try CloudDataRevision.persistedLegacyTombstoneIDs(in: cloud)
        var confirmed = [CloudDataRevision]()
        for revision in revisions where !isUnavailable(revision.itemKey)
                && !revision.isTombstone && revision.contentDigest.isEmpty {
            try checkCurrent(isValid)
            let hasPersistedDeletion = legacyTombstoneIDs.contains(revision.persistentModelID)
            if !hasPersistedDeletion && !readDurable {
                readDurable = true
                if FileManager.default.fileExists(atPath: journalURL.path) {
                    let saved = try JSONDecoder().decode(CloudSyncJournal.self, from: Data(contentsOf: journalURL))
                    guard saved.version == 1 else { throw FullCloudSyncError.invalidJournal }
                    durable = saved
                }
            }
            let key = revision.itemKey
            func provesDeletion(_ value: CloudSyncCheckpoint?) -> Bool {
                guard let value else { return false }
                return value.digest == nil && value.revisionID == revision.revisionID
                    && value.logicalClock == revision.logicalClock && value.installationID == revision.installationID
            }
            guard hasPersistedDeletion || provesDeletion(durable?.items[key])
                    || provesDeletion(durable?.pendingPublications[key])
                    || provesDeletion(durable?.pendingApplies[key]?.target) else { continue }
            let expected = CloudSyncCheckpoint(digest: nil, revisionID: revision.revisionID,
                logicalClock: revision.logicalClock, installationID: revision.installationID)
            if payloadReader == nil {
                let container = cloud.container
                payloadReader = await Task.detached { CloudRevisionPayloadReader(modelContainer: container) }.value
            }
            guard let payloadReader else { throw FullCloudSyncError.persistentStoreUnavailable }
            guard try await payloadReader.confirmsLegacyTombstone(id: revision.persistentModelID,
                key: key, expected: expected) else { continue }
            try checkCurrent(isValid)
            confirmed.append(revision)
        }
        guard !confirmed.isEmpty else { return }
        try checkCurrent(isValid)
        for revision in confirmed { revision.isTombstone = true }
        do { try cloud.save() }
        catch { cloud.rollback(); throw error }
        // This context deliberately observed the pre-repair flag. Recreate it
        // before normal payload validation rather than reuse that old snapshot.
        payloadReader = nil
        didEnqueueChanges = true
        didEnqueue?()
        try checkCurrent(isValid)
    }

    private func materialize(_ remote: CloudDataRevision, needsPayload: Bool = true) async throws -> Data? {
        if payloadReader == nil {
            let container = cloud.container
            payloadReader = await Task.detached { CloudRevisionPayloadReader(modelContainer: container) }.value
            try Task.checkCancellation()
        }
        guard let payloadReader else { throw FullCloudSyncError.persistentStoreUnavailable }
        return try await payloadReader.load(id: remote.persistentModelID, key: remote.itemKey,
            revisionID: remote.revisionID, expected: checkpoint(remote), needsPayload: needsPayload)
    }

    private func checkCurrent(_ isValid: () -> Bool) throws {
        try Task.checkCancellation()
        guard isValid() else { throw CancellationError() }
    }

    private func planApply(_ key: String, remote: CloudDataRevision, source: String?, operations: inout [String: Operation]) {
        let target = checkpoint(remote)
        if source == target.digest, CloudModelCodec.entityName(for: key) != "MeetingRecord" {
            operations[key] = .inspect(remote, adopt: true)
        } else {
            journal.pendingApplies[key] = CloudSyncPendingApply(sourceDigest: source, target: target)
            journalDirty = true
            operations[key] = .apply(remote)
        }
    }

    private func newer(_ first: CloudDataRevision, than second: CloudSyncCheckpoint) -> Bool {
        CloudRevisionOrder.isNewer(clock: first.logicalClock, installation: first.installationID,
            revision: first.revisionID, than: second)
    }

    private func checkpoint(_ revision: CloudDataRevision) -> CloudSyncCheckpoint {
        CloudSyncCheckpoint(digest: revision.isTombstone ? nil : revision.contentDigest,
            revisionID: revision.revisionID, logicalClock: revision.logicalClock, installationID: revision.installationID)
    }

    private func remember(_ key: String, _ value: CloudSyncCheckpoint) {
        if CloudModelCodec.entityName(for: key) == "MeetingRecord" {
            if value.digest == nil { settledMeetingTombstones.insert(key) }
            else { settledMeetingTombstones.remove(key) }
        }
        guard journal.items[key] != value else { return }
        journal.items[key] = value
        journalDirty = true
    }

    private func persistJournal() throws {
        guard journalDirty else { return }
        let directory = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directoryURL.setResourceValues(values)
        journalDirty = false
    }
}
