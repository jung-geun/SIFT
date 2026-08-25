import Foundation
import SwiftData
import CryptoKit

nonisolated enum MailAnalysisLedgerKeyStore {
    private static let service = "pieroot.todo.mail-analysis-ledger"

    static func key() -> SymmetricKey {
        if let encoded = KeychainStore.get(service: service, account: "key"),
           let data = Data(base64Encoded: encoded),
           data.count == 32 {
            return SymmetricKey(data: data)
        }
        let data = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        KeychainStore.set(service: service, account: "key", value: data.base64EncodedString())
        return SymmetricKey(data: data)
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
