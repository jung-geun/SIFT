import Foundation
import SwiftData

@Model
final class MailAnalysisLedgerRecord {
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
