import Foundation
import SwiftData

@Model
final class MailAnalysisLedgerRecord {
    /// Empty uses the immutable fingerprint as the portable natural identity.
    /// A deterministic override retains a divergent legacy version during merge.
    var syncIdentity: String = ""
    var fingerprintData: Data = Data()
    var revision: Int = 0
    var stateRawValue: String = ""
    var leaseExpiresAt: Date?
    var analyzedAt: Date?

    init(
        fingerprintData: Data,
        revision: Int,
        stateRawValue: String,
        leaseExpiresAt: Date? = nil,
        analyzedAt: Date? = nil
    ) {
        self.fingerprintData = fingerprintData
        self.revision = revision
        self.stateRawValue = stateRawValue
        self.leaseExpiresAt = leaseExpiresAt
        self.analyzedAt = analyzedAt
    }
}
