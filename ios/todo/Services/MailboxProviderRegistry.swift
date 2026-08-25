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
}
