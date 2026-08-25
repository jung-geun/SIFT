import Foundation

/// Determines whether the saved App Password should remain available after a
/// reconnect attempt fails. Connection failures never imply that a credential
/// was intentionally removed; only a confirmed missing Keychain item does.
nonisolated enum MailCredentialFailurePolicy {
    static func hasStoredCredential(after error: Error) -> Bool {
        switch error {
        case GmailIMAPError.missingCredential, OutlookIMAPError.missingCredential:
            return false
        default:
            return true
        }
    }
}
