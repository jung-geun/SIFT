import Testing
@testable import todo

@Suite("Mail credential failure policy")
struct MailCredentialFailurePolicyTests {
    @Test("authentication and legacy-policy failures retain stored App Passwords")
    func retainsCredentialForRetryableFailures() {
        #expect(MailCredentialFailurePolicy.hasStoredCredential(after: GmailIMAPError.authenticationFailed))
        #expect(MailCredentialFailurePolicy.hasStoredCredential(after: GmailIMAPError.transport("offline")))
        #expect(MailCredentialFailurePolicy.hasStoredCredential(after: OutlookIMAPError.authenticationFailed))
        #expect(MailCredentialFailurePolicy.hasStoredCredential(after: OutlookIMAPError.legacyAuthUnsupported))
    }

    @Test("only confirmed missing credentials expose password entry")
    func exposesPasswordEntryOnlyWhenCredentialMissing() {
        #expect(!MailCredentialFailurePolicy.hasStoredCredential(after: GmailIMAPError.missingCredential))
        #expect(!MailCredentialFailurePolicy.hasStoredCredential(after: OutlookIMAPError.missingCredential))
    }
}
