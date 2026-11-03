import Foundation

/// Canonical registry for resolving live `MailboxPagingProvider` implementations.
///
/// Use this registry instead of hardcoding `GmailIMAPService.shared` or creating
/// private provider resolvers. Inject custom resolvers in tests.
@MainActor
enum MailboxProviderRegistry {
    /// Overridable provider resolver closure for testing/stubbing.
    /// When nil, falls back to `defaultProvider(for:)`.
    nonisolated(unsafe) static var customResolver: ((MailProvider) -> (any MailboxPagingProvider)?)? = nil

    /// Resolves the paging provider for the specified mail provider.
    static func provider(for provider: MailProvider) -> any MailboxPagingProvider {
        if let custom = customResolver, let resolved = custom(provider) {
            return resolved
        }
        return defaultProvider(for: provider)
    }

    /// Default resolution strategy for production.
    static func defaultProvider(for provider: MailProvider) -> any MailboxPagingProvider {
        switch provider {
        case .gmail:
            return GmailIMAPService.shared
        case .outlook:
            return OutlookIMAPService.shared
        }
    }

    /// Uses only the selected account's existing credential and access policy.
    /// A failed command is never replayed here; the next explicit operation can
    /// establish a new session after the transport discarded the old connection.
    static func ensureReady(
        for provider: MailProvider,
        namespace: String,
        backgroundOnly: Bool = false
    ) async throws {
        if backgroundOnly {
            try await KeychainStore.withoutAuthenticationUI {
                try await ensureSession(for: provider, namespace: namespace, backgroundOnly: true)
            }
        } else {
            try await ensureSession(for: provider, namespace: namespace, backgroundOnly: false)
        }
    }

    private static func ensureSession(
        for provider: MailProvider,
        namespace: String,
        backgroundOnly: Bool
    ) async throws {
        try Task.checkCancellation()
        try requireSelectedAccount(provider, namespace: namespace, backgroundOnly: backgroundOnly)
        switch provider {
        case .gmail:
            guard !IMAPCredentialStore.isCredentialRejected(for: namespace) else {
                throw GmailIMAPError.credentialRejected
            }
            let connectedAccount = await GmailIMAPService.shared.authenticatedAccount
            if connectedAccount != namespace {
                do {
                    try await GmailIMAPService.shared.ensureAuthenticated(
                        email: namespace,
                        backgroundEnabled: UserDefaults.standard.bool(forKey: "pieroot.todo.imap.backgroundEnabled")
                    )
                } catch GmailIMAPError.credentialRejected {
                    IMAPCredentialStore.markCredentialRejected(for: namespace)
                    throw GmailIMAPError.credentialRejected
                }
            }
        case .outlook:
            let connectedAccount = await OutlookIMAPService.shared.authenticatedAccount
            if connectedAccount != namespace {
                try await OutlookIMAPService.shared.ensureAuthenticated(
                    email: namespace,
                    backgroundEnabled: UserDefaults.standard.bool(forKey: "pieroot.todo.outlook.backgroundEnabled")
                )
            }
        }
        try Task.checkCancellation()
        try requireSelectedAccount(provider, namespace: namespace, backgroundOnly: backgroundOnly)
    }

    private static func requireSelectedAccount(
        _ provider: MailProvider,
        namespace: String,
        backgroundOnly: Bool
    ) throws {
        let defaults = UserDefaults.standard
        let selected: String?
        let backgroundEnabled: Bool
        switch provider {
        case .gmail:
            selected = IMAPCredentialStore.canonicalAccount(defaults.string(forKey: "pieroot.todo.imap.account") ?? "")
            backgroundEnabled = defaults.bool(forKey: "pieroot.todo.imap.backgroundEnabled")
        case .outlook:
            selected = OutlookIMAPCredentialStore.canonicalAccount(defaults.string(forKey: "pieroot.todo.outlook.account") ?? "")
            backgroundEnabled = defaults.bool(forKey: "pieroot.todo.outlook.backgroundEnabled")
        }
        guard selected == namespace, !backgroundOnly || backgroundEnabled else {
            throw CancellationError()
        }
    }
}
