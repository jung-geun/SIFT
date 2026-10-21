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
    var isDeleted: Bool = false
    var contentDigest: String = ""
    @Attribute(.externalStorage, .allowsCloudEncryption) var payload: Data?

    init(itemKey: String, clock: Int64, installationID: String, payload: Data?, digest: String? = nil) {
        self.itemKey = itemKey
        self.logicalClock = clock
        self.installationID = installationID
        self.isDeleted = payload == nil
        self.contentDigest = digest ?? payload.map(CloudFileStore.digest) ?? ""
        self.payload = payload
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

nonisolated enum FullCloudSyncError: Error {
    case invalidRevision, invalidJournal, clockOverflow, persistentStoreUnavailable
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
        guard revision.itemKey == key, revision.logicalClock == expected.logicalClock,
              revision.installationID == expected.installationID,
              revision.isDeleted == (data == nil),
              revision.contentDigest == (expected.digest ?? ""),
              try data.map(Self.digest) == expected.digest else {
            throw FullCloudSyncError.invalidRevision
        }
        try Task.checkCancellation()
        validated[key] = expected
        return needsPayload ? data : nil
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
    private var journalDirty = false

    private enum Operation {
        case apply(CloudDataRevision)
        case publish(CloudSyncCheckpoint)
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

    /// Write intent before either store is changed. A restart can distinguish an
    /// unchanged source, an applied target, and a genuinely newer local edit.
    /// `apply` must durably save its canonical local target before returning.
    /// `didEnqueue` fires synchronously after every cloud save, even if a later
    /// operation fails; `isValid` fences mutations after asynchronous work.
    @discardableResult
    func reconcile(digests: [String: String], temporarilyUnavailable: Set<String> = [],
                   isValid: () -> Bool = { true }, didEnqueue: (() -> Void)? = nil,
                   load: (String) async throws -> Data?,
                   apply: (String, Data?) async throws -> Void) async throws -> Int {
        didEnqueueChanges = false
        try checkCurrent(isValid)
        var descriptor = FetchDescriptor<CloudDataRevision>()
        descriptor.propertiesToFetch = [\.revisionID, \.itemKey, \.logicalClock, \.installationID, \.isDeleted, \.contentDigest]
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
                  !revision.itemKey.isEmpty, !revision.isDeleted || revision.contentDigest.isEmpty else {
                throw FullCloudSyncError.invalidRevision
            }
            maximumClock = max(maximumClock, revision.logicalClock)
            revisionsByKey[revision.itemKey, default: []].append(revision)
            if let current = latest[revision.itemKey], !newer(revision, than: checkpoint(current)) { continue }
            latest[revision.itemKey] = revision
        }
        guard maximumClock < Int64.max else { throw FullCloudSyncError.clockOverflow }
        let nextClock = maximumClock + 1

        var completingApplies = [String: CloudDataRevision]()
        for (key, pending) in journal.pendingApplies where !temporarilyUnavailable.contains(key) {
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
        for (key, pending) in journal.pendingPublications where !temporarilyUnavailable.contains(key) {
            try checkCurrent(isValid)
            if revisionsByKey[key, default: []].contains(where: { checkpoint($0) == pending }) {
                remember(key, pending)
                journal.pendingPublications.removeValue(forKey: key)
                journalDirty = true
            }
        }

        let allKeys = Set(digests.keys).union(journal.items.keys).union(latest.keys).union(journal.pendingPublications.keys)
        // Representation markers precede mail bodies that depend on them.
        let orderedKeys = allKeys.sorted { first, second in
            let a = CloudPreferenceStore.isPreferenceKey(first)
            let b = CloudPreferenceStore.isPreferenceKey(second)
            return a != b ? a : first < second
        }
        var operations = [String: Operation]()
        for key in orderedKeys where !temporarilyUnavailable.contains(key) {
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
        do {
            for key in orderedKeys {
                try checkCurrent(isValid)
                guard let operation = operations[key] else { continue }
                switch operation {
                case .apply(let remote):
                    let target = checkpoint(remote)
                    let payload = try await materialize(remote)
                    try checkCurrent(isValid)
                    try await apply(key, payload)
                    try checkCurrent(isValid)
                    restored += 1
                    remember(key, target)
                    journal.pendingApplies.removeValue(forKey: key)
                    journalDirty = true
                case .publish(let intended):
                    if let remote = latest[key] {
                        _ = try await materialize(remote, needsPayload: false)
                        try checkCurrent(isValid)
                    }
                    let data = try await load(key)
                    try checkCurrent(isValid)
                    let hashing = Task.detached { try data.map(CloudRevisionPayloadReader.digest) }
                    let digest = try await withTaskCancellationHandler {
                        try await hashing.value
                    } onCancel: {
                        hashing.cancel()
                    }
                    try checkCurrent(isValid)
                    guard digest == intended.digest else { throw CloudFileError.changingFile }
                    let revision = CloudDataRevision(itemKey: key, clock: intended.logicalClock,
                        installationID: intended.installationID, payload: data, digest: intended.digest ?? "")
                    revision.revisionID = intended.revisionID
                    try checkCurrent(isValid)
                    cloud.insert(revision)
                    for old in revisionsByKey[key, default: []] {
                        try checkCurrent(isValid)
                        cloud.delete(old)
                    }
                    try checkCurrent(isValid)
                    try cloud.save()
                    didEnqueueChanges = true
                    didEnqueue?()
                    try checkCurrent(isValid)
                    remember(key, intended)
                    journal.pendingPublications.removeValue(forKey: key)
                    journalDirty = true
                    storeIdentifier = revision.persistentModelID.storeIdentifier
                case .inspect(let remote, let adopt):
                    _ = try await materialize(remote, needsPayload: false)
                    try checkCurrent(isValid)
                    if adopt { remember(key, checkpoint(remote)) }
                }
            }
            for key in orderedKeys where !temporarilyUnavailable.contains(key) {
                if case .publish? = operations[key] { continue }
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
            return restored
        } catch {
            // The write-ahead journal intentionally remains on disk. Even if an
            // apply or save committed before throwing/cancellation, replay can
            // identify it from local fingerprints or the saved revision ID.
            cloud.rollback()
            throw error
        }
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
        if source == target.digest {
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
        CloudSyncCheckpoint(digest: revision.isDeleted ? nil : revision.contentDigest,
            revisionID: revision.revisionID, logicalClock: revision.logicalClock, installationID: revision.installationID)
    }

    private func remember(_ key: String, _ value: CloudSyncCheckpoint) {
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
