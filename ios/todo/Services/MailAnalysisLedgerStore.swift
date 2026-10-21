import Foundation
import SwiftData
import CryptoKit

nonisolated enum MailAnalysisLedgerKeyStore {
    private static let service = "pieroot.todo.mail-analysis-ledger"
    private static let family = HMACIdentityKeyFamily(service: service, primaryAccount: "hmac-key-v1")

    /// Callers must propagate failure and stop ingestion rather than change identity.
    static func key() throws -> SymmetricKey {
        try keysChecked()[0]
    }

    /// Includes original keys from other installations for provenance matching.
    static func keysChecked() throws -> [SymmetricKey] {
        try family.keys(createIfMissing: true, legacyKeys: legacyKeys).map { SymmetricKey(data: $0) }
    }

    /// Synchronous integration point for KeychainStore.applySyncPolicy().
    /// Opt-out is a no-op: no remote deletion or identity rotation.
    static func applyFullSyncPolicy() throws {
        try family.applyFullSyncPolicy(legacyKeys: legacyKeys)
    }

    private static func legacyKeys(authorization: HMACIdentityKeyFamily.Authorization) throws -> [Data] {
        var keys: [Data] = []
        func append(_ encoded: Data) throws {
            guard let data = Data(base64Encoded: encoded), data.count == 32 else {
                throw VocabularyServiceError.invalidKey
            }
            if !keys.contains(data) { keys.append(data) }
        }
        // Read explicit scopes: SynchronizableAny could restore a cloud-only
        // legacy identity without full-policy consent.
        if let local = try KeychainStore.getDeviceOnly(service: service, account: "key") { try append(local) }
        if authorization.isEnabled {
            try authorization.requireCurrent()
            let portable = try KeychainStore.getSynchronizable(service: service, account: "key")
            try authorization.requireCurrent()
            if let portable { try append(portable) }
        }
        // Never rewrite either legacy item or change its synchronization class.
        return keys
    }
}

enum MailAnalysisClaimOutcome: Equatable {
    case acquired
    case alreadyAnalyzed
    case leased
}
@MainActor
final class MailAnalysisLedgerStore {
    static let shared = MailAnalysisLedgerStore()
    private let context: ModelContext

    init(container: ModelContainer? = nil) {
        context = ModelContext(container ?? AppDataContainer.shared.container)
    }

    func preferredFingerprint(in candidates: [MailAnalysisFingerprint], revision: Int, now: Date = Date()) throws -> MailAnalysisFingerprint {
        guard let primary = candidates.first else { throw VocabularyServiceError.invalidKey }
        let records = try context.fetch(FetchDescriptor<MailAnalysisLedgerRecord>())
        if let leased = candidates.first(where: { candidate in
            records.contains { $0.fingerprintData == candidate.digest && ($0.leaseExpiresAt ?? .distantPast) > now }
        }) { return leased }
        if let analyzed = candidates.first(where: { candidate in
            records.contains { $0.fingerprintData == candidate.digest && $0.stateRawValue == MailAnalysisLeaseState.analyzed.rawValue && $0.revision >= revision }
        }) { return analyzed }
        return candidates.first { candidate in records.contains { $0.fingerprintData == candidate.digest } } ?? primary
    }

    func claim(
        _ fingerprint: MailAnalysisFingerprint,
        revision: Int,
        now: Date = Date(),
        leaseDuration: TimeInterval = 300
    ) throws -> Bool {
        try claimOutcome(
            fingerprint,
            revision: revision,
            now: now,
            leaseDuration: leaseDuration
        ) == .acquired
    }

    func claimOutcome(
        _ fingerprint: MailAnalysisFingerprint,
        revision: Int,
        now: Date = Date(),
        leaseDuration: TimeInterval = 300
    ) throws -> MailAnalysisClaimOutcome {
        let records = try context.fetch(FetchDescriptor<MailAnalysisLedgerRecord>())
        if let existing = records.first(where: { $0.fingerprintData == fingerprint.digest }) {
            if existing.stateRawValue == MailAnalysisLeaseState.analyzed.rawValue,
               existing.revision >= revision {
                return .alreadyAnalyzed
            }
            if let lease = existing.leaseExpiresAt, lease > now {
                return .leased
            }
            existing.revision = revision
            existing.stateRawValue = MailAnalysisLeaseState.processing.rawValue
            existing.leaseExpiresAt = now.addingTimeInterval(leaseDuration)
            existing.analyzedAt = nil
        } else {
            context.insert(MailAnalysisLedgerRecord(
                fingerprintData: fingerprint.digest,
                revision: revision,
                stateRawValue: MailAnalysisLeaseState.processing.rawValue,
                leaseExpiresAt: now.addingTimeInterval(leaseDuration)
            ))
        }
        try context.save()
        return .acquired
    }

    func markAnalyzed(_ fingerprint: MailAnalysisFingerprint, revision: Int, at date: Date = Date()) throws {
        let records = try context.fetch(FetchDescriptor<MailAnalysisLedgerRecord>())
        guard let record = records.first(where: { $0.fingerprintData == fingerprint.digest }) else { return }
        record.revision = revision
        record.stateRawValue = MailAnalysisLeaseState.analyzed.rawValue
        record.leaseExpiresAt = nil
        record.analyzedAt = date
        try context.save()
    }

    func release(_ fingerprint: MailAnalysisFingerprint) throws {
        let records = try context.fetch(FetchDescriptor<MailAnalysisLedgerRecord>())
        guard let record = records.first(where: { $0.fingerprintData == fingerprint.digest }),
              record.stateRawValue == MailAnalysisLeaseState.processing.rawValue
        else {
            return
        }
        context.delete(record)
        try context.save()
    }
    
    func reset(_ fingerprint: MailAnalysisFingerprint) throws {
        let records = try context.fetch(FetchDescriptor<MailAnalysisLedgerRecord>())
        for record in records where record.fingerprintData == fingerprint.digest {
            context.delete(record)
        }
        try context.save()
    }
}
