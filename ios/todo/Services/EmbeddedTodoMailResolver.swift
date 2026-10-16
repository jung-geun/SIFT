import Foundation
import SwiftData

/// State of an email resolution attempt for an email-origin `Todo`.
enum EmbeddedMailResolutionResult: Sendable {
    case success(EmailMessage)
    case failure(EmbeddedMailError)
}

/// Typed, localized errors for embedded email opening and hydration.
enum EmbeddedMailError: LocalizedError, Equatable, Sendable {
    case missingSourceRef
    case ambiguousAccountNamespace
    case providerUnavailable(MailProvider)
    case hydrationFailed(String)
    case identityMismatch

    var errorDescription: String? {
        errorDescription(language: .current)
    }

    func errorDescription(language: AppLanguage) -> String {
        switch self {
        case .missingSourceRef:
            return AppLanguage.localized("error.mail.resolver.missingSourceRef", defaultValue: "The To-Do item does not have a valid email source reference.", language: language)
        case .ambiguousAccountNamespace:
            return AppLanguage.localized("error.mail.resolver.ambiguousAccountNamespace", defaultValue: "Multiple email accounts match this legacy message. Select an account or sync to resolve.", language: language)
        case .providerUnavailable(let provider):
            return String(format: AppLanguage.localized("error.mail.resolver.providerUnavailable", defaultValue: "%@ account is not connected or available.", language: language), locale: language.locale, String(provider == .gmail ? "Gmail" : "Outlook"))
        case .hydrationFailed(let message):
            return String(format: AppLanguage.localized("error.mail.resolver.hydrationFailed", defaultValue: "Could not load email content: %@", language: language), locale: language.locale, String(message))
        case .identityMismatch:
            return AppLanguage.localized("error.mail.resolver.identityMismatch", defaultValue: "Downloaded email content did not match the expected message identity.", language: language)
        }
    }
}

/// Parsed provider-native identity components extracted from a `Todo` or raw source reference.
struct ParsedEmailSourceRef: Equatable, Sendable {
    let provider: MailProvider
    let providerMessageID: String
    let sourceAccountNamespace: String
}

/// Handles embedded-only original email lookup, identity matching, cache-miss hydration,
/// and error handling for email-origin `Todo` items.
@MainActor
final class EmbeddedTodoMailResolver {
    static let shared = EmbeddedTodoMailResolver()

    private let resolveProviderClosure: (MailProvider) -> (any MailboxPagingProvider)?
    private let ensureReadyClosure: (MailProvider, String) async -> Bool
    private let localStore: MailboxLocalStore
    private let defaults: UserDefaults

    init(
        resolveProvider: ((MailProvider) -> (any MailboxPagingProvider)?)? = nil,
        ensureReady: ((MailProvider, String) async -> Bool)? = nil,
        localStore: MailboxLocalStore? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.resolveProviderClosure = resolveProvider ?? MailboxProviderRegistry.provider(for:)
        self.ensureReadyClosure = ensureReady ?? Self.defaultEnsureReady
        self.localStore = localStore ?? .live
        self.defaults = defaults
    }

    // MARK: - Legacy Reference Parsing

    /// Safely parses `todo.sourceRef` and namespace into a provider identity.
    /// Legacy `outlook:` prefixes map to `.outlook`; all other references infer `.gmail`.
    static func parseSourceRef(
        sourceRef: String,
        sourceAccountNamespace: String = ""
    ) -> ParsedEmailSourceRef? {
        let trimmedRef = sourceRef.trimmingCharacters(in: .whitespaces)
        guard !trimmedRef.isEmpty else { return nil }

        if trimmedRef.lowercased().hasPrefix("outlook:") {
            let rawID = String(trimmedRef.dropFirst(8))
            guard !rawID.isEmpty else { return nil }
            return ParsedEmailSourceRef(
                provider: .outlook,
                providerMessageID: rawID,
                sourceAccountNamespace: sourceAccountNamespace
            )
        } else {
            return ParsedEmailSourceRef(
                provider: .gmail,
                providerMessageID: trimmedRef,
                sourceAccountNamespace: sourceAccountNamespace
            )
        }
    }

    /// Resolves the unambiguous active account namespace for a provider from system defaults.
    static func activeAccountNamespace(
        for provider: MailProvider,
        defaults: UserDefaults = .standard
    ) -> String? {
        switch provider {
        case .gmail:
            let raw = defaults.string(forKey: "pieroot.todo.imap.account") ?? ""
            return IMAPCredentialStore.canonicalAccount(raw)
        case .outlook:
            let raw = defaults.string(forKey: "pieroot.todo.outlook.account") ?? ""
            return OutlookIMAPCredentialStore.canonicalAccount(raw)
        }
    }

    /// Default readiness strategy: ensures the service is authenticated for the target namespace.
    static func defaultEnsureReady(provider: MailProvider, namespace: String) async -> Bool {
        switch provider {
        case .gmail:
            let service = GmailIMAPService.shared
            let isAuth = await service.isAuthenticated
            let account = await service.authenticatedAccount
            if isAuth && account == namespace {
                return true
            }
            let bg = UserDefaults.standard.bool(forKey: "pieroot.todo.imap.backgroundEnabled")
            return (try? await service.authenticate(email: namespace, backgroundEnabled: bg)) != nil
        case .outlook:
            let service = OutlookIMAPService.shared
            let isAuth = await service.isAuthenticated
            let account = await service.authenticatedAccount
            if isAuth && account == namespace {
                return true
            }
            let bg = UserDefaults.standard.bool(forKey: "pieroot.todo.outlook.backgroundEnabled")
            return (try? await service.authenticate(email: namespace, backgroundEnabled: bg)) != nil
        }
    }
    // MARK: - Resolution & Hydration

    /// Resolves local `EmailMessage` by `EmailMessageKey` matching, or hydates from remote provider on miss/empty body.
    func resolveAndHydrate(
        todo: Todo,
        in context: ModelContext
    ) async -> EmbeddedMailResolutionResult {
        guard let parsed = Self.parseSourceRef(
            sourceRef: todo.sourceRef,
            sourceAccountNamespace: todo.sourceAccountNamespace
        ) else {
            return .failure(.missingSourceRef)
        }

        return await resolveAndHydrate(parsed: parsed, in: context)
    }

    /// Primary resolution logic for parsed identity.
    func resolveAndHydrate(
        parsed: ParsedEmailSourceRef,
        in context: ModelContext
    ) async -> EmbeddedMailResolutionResult {
        // 1. Query cached rows by provider and raw providerMessageID (NEVER EmailMessage.id alone).
        let providerRaw = parsed.provider.rawValue
        let rawID = parsed.providerMessageID

        let descriptor = FetchDescriptor<EmailMessage>(
            predicate: #Predicate<EmailMessage> { email in
                email.providerRawValue == providerRaw && email.rawMessageID == rawID
            }
        )

        let candidates = (try? context.fetch(descriptor)) ?? []

        // 2. Disambiguate by namespace
        let matchedEmail: EmailMessage?
        if !parsed.sourceAccountNamespace.isEmpty {
            matchedEmail = candidates.first { $0.sourceAccountNamespace == parsed.sourceAccountNamespace }
        } else {
            // Legacy empty namespace behavior: accept only an unambiguous single cached row
            if candidates.count == 1 {
                matchedEmail = candidates.first
            } else if candidates.count > 1 {
                // Ambiguous: multiple matching accounts exist for an empty namespace reference
                return .failure(.ambiguousAccountNamespace)
            } else {
                matchedEmail = nil
            }
        }

        // 3. Check if cached message exists and already has body/html content
        if let existing = matchedEmail,
           !existing.body.isEmpty || !(existing.htmlBody ?? "").isEmpty {
            return .success(existing)
        }

        // 4. Determine expected account namespace for hydration
        let expectedNamespace: String
        if !parsed.sourceAccountNamespace.isEmpty {
            expectedNamespace = parsed.sourceAccountNamespace
        } else if let cachedNS = matchedEmail?.sourceAccountNamespace, !cachedNS.isEmpty {
            expectedNamespace = cachedNS
        } else if let activeNS = Self.activeAccountNamespace(for: parsed.provider, defaults: defaults), !activeNS.isEmpty {
            expectedNamespace = activeNS
        } else {
            return .failure(.ambiguousAccountNamespace)
        }

        // 5. Authenticate/ensure readiness for expected namespace before fetching content
        guard await ensureReadyClosure(parsed.provider, expectedNamespace) else {
            return .failure(.providerUnavailable(parsed.provider))
        }

        // 6. Hydrate from provider on cache miss or missing content
        guard let providerService = resolveProviderClosure(parsed.provider) else {
            return .failure(.providerUnavailable(parsed.provider))
        }


        do {
            let content = try await providerService.fetchMessageContent(messageID: parsed.providerMessageID)

            // Strict EmailMessageKey equality verification
            let expectedKey = EmailMessageKey(
                providerRawValue: parsed.provider.rawValue,
                sourceAccountNamespace: expectedNamespace,
                providerMessageID: parsed.providerMessageID
            )
            let receivedKey = EmailMessageKey(
                providerRawValue: content.metadata.provider.rawValue,
                sourceAccountNamespace: content.metadata.sourceAccountNamespace,
                providerMessageID: content.metadata.providerMessageID
            )

            guard expectedKey == receivedKey else {
                return .failure(.identityMismatch)
            }

            // 6. Persist content atomically via MailboxLocalStore
            let targetEmail: EmailMessage
            if let existing = matchedEmail {
                targetEmail = existing
            } else {
                let newID = parsed.provider == .gmail && !content.metadata.providerGlobalMessageID.isEmpty
                    ? "gmail-imap:\(content.metadata.providerGlobalMessageID)"
                    : parsed.providerMessageID

                targetEmail = EmailMessage(
                    id: newID,
                    provider: parsed.provider,
                    rawMessageID: parsed.providerMessageID,
                    sourceAccountNamespace: expectedNamespace
                )
                context.insert(targetEmail)
            }

            try localStore.updateContent(content, for: targetEmail, in: context)
            return .success(targetEmail)
        } catch let error as EmbeddedMailError {
            return .failure(error)
        } catch {
            return .failure(.hydrationFailed(error.localizedDescription))
        }
    }
}
