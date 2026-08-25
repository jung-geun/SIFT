import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Mail analysis ledger")
struct MailAnalysisLedgerTests {
    @Test("fingerprints are stable but account and message scoped")
    func fingerprintScope() {
        let key = SymmetricKey(size: .bits256)
        let first = MailAnalysisFingerprint.make(provider: "gmail-imap", canonicalAccount: "a@example.com", gmailMessageID: "1", key: key)
        let same = MailAnalysisFingerprint.make(provider: "gmail-imap", canonicalAccount: "a@example.com", gmailMessageID: "1", key: key)
        let other = MailAnalysisFingerprint.make(provider: "gmail-imap", canonicalAccount: "b@example.com", gmailMessageID: "1", key: key)
        #expect(first == same)
        #expect(first != other)
        #expect(first.digest != Data("a@example.com".utf8))
    }

    @Test("active lease blocks duplicate claims and expiry permits retry")
    func leaseSemantics() async {
        let ledger = MailAnalysisLedger()
        let fingerprint = MailAnalysisFingerprint.make(provider: "gmail-imap", canonicalAccount: "a@example.com", gmailMessageID: "1", key: SymmetricKey(size: .bits256))
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(await ledger.claim(fingerprint, revision: 1, now: now, leaseDuration: 10))
        #expect(await ledger.claim(fingerprint, revision: 1, now: now.addingTimeInterval(1), leaseDuration: 10) == false)
        #expect(await ledger.claim(fingerprint, revision: 1, now: now.addingTimeInterval(11), leaseDuration: 10))
    }

    @Test("a newer parser revision reclaims an analyzed fingerprint")
    @MainActor
    func newerRevisionReclaimsAnalyzedFingerprint() throws {
        let schema = Schema([MailAnalysisLedgerRecord.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let ledger = MailAnalysisLedgerStore(container: container)
        let fingerprint = MailAnalysisFingerprint.make(
            provider: "gmail-imap",
            canonicalAccount: "a@example.com",
            gmailMessageID: "1",
            key: SymmetricKey(size: .bits256)
        )

        #expect(try ledger.claimOutcome(fingerprint, revision: 1) == .acquired)
        try ledger.markAnalyzed(fingerprint, revision: 1)
        #expect(try ledger.claimOutcome(fingerprint, revision: 1) == .alreadyAnalyzed)
        #expect(try ledger.claimOutcome(fingerprint, revision: 2) == .acquired)
    }
}
