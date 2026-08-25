import CryptoKit
import Foundation

/// Opaque, account-scoped identifier for synchronizing analysis state without
/// syncing a mailbox address, message ID, subject, or body.
nonisolated struct MailAnalysisFingerprint: Codable, Hashable, Sendable {
    let version: Int
    let digest: Data

    static func make(
        provider: String,
        canonicalAccount: String,
        gmailMessageID: String,
        key: SymmetricKey
    ) -> Self {
        let input = "v1\u{1F}\(provider)\u{1F}\(canonicalAccount)\u{1F}\(gmailMessageID)"
        return MailAnalysisFingerprint(
            version: 1,
            digest: Data(HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: key))
        )
    }
}

nonisolated enum MailAnalysisLeaseState: String, Codable, Sendable {
    case processing
    case analyzed
}

nonisolated struct MailAnalysisLedgerEntry: Codable, Hashable, Sendable {
    let fingerprint: MailAnalysisFingerprint
    let analysisRevision: Int
    let state: MailAnalysisLeaseState
    let leaseExpiresAt: Date?
    let analyzedAt: Date?

    func blocksAnalysis(now: Date) -> Bool {
        switch state {
        case .analyzed:
            true
        case .processing:
            (leaseExpiresAt ?? .distantPast) > now
        }
    }
}
actor MailAnalysisLedger {
    static let shared = MailAnalysisLedger()
    private var entries: [MailAnalysisFingerprint: MailAnalysisLedgerEntry] = [:]

    func claim(
        _ fingerprint: MailAnalysisFingerprint,
        revision: Int,
        now: Date = Date(),
        leaseDuration: TimeInterval = 300
    ) -> Bool {
        if let existing = entries[fingerprint], existing.blocksAnalysis(now: now) {
            return false
        }
        entries[fingerprint] = MailAnalysisLedgerEntry(
            fingerprint: fingerprint,
            analysisRevision: revision,
            state: .processing,
            leaseExpiresAt: now.addingTimeInterval(leaseDuration),
            analyzedAt: nil
        )
        return true
    }

    func markAnalyzed(
        _ fingerprint: MailAnalysisFingerprint,
        revision: Int,
        at date: Date = Date()
    ) {
        entries[fingerprint] = MailAnalysisLedgerEntry(
            fingerprint: fingerprint,
            analysisRevision: revision,
            state: .analyzed,
            leaseExpiresAt: nil,
            analyzedAt: date
        )
    }

    func entry(for fingerprint: MailAnalysisFingerprint) -> MailAnalysisLedgerEntry? {
        entries[fingerprint]
    }
}
