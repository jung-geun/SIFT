import Foundation
import SwiftData
import AuthenticationServices
import MSAL
import UIKit

final class OutlookMailService: NSObject {
    static let shared = OutlookMailService()

    private override init() {}

    var session: URLSession = .shared

    #if DEBUG
    var testAccessTokenProvider: (() async throws -> String)?
    #endif

    private let scopes = [
        "https://graph.microsoft.com/User.Read",
        "https://graph.microsoft.com/Mail.ReadWrite",
        "offline_access"
    ]

    var isFeatureEnabled: Bool {
        clientID != nil && hasRedirectScheme
    }

    var isConfigured: Bool {
        isFeatureEnabled
    }

    var isAuthenticated: Bool {
        guard isConfigured else { return false }
        do {
            return try application().allAccounts().isEmpty == false
        } catch {
            return false
        }
    }

    func canAccessMailSilently() async -> Bool {
        guard isConfigured else { return false }
        do {
            _ = try await accessToken()
            return true
        } catch {
            return false
        }
    }

    @MainActor
    func authenticate() async throws {
        let app = try application()
        let viewController = try authPresentationViewController()
        let webParameters = MSALWebviewParameters(authPresentationViewController: viewController)
        let parameters = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webParameters)
        parameters.promptType = .selectAccount

        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MSALResult, Error>) in
            app.acquireToken(with: parameters) { result, error in
                if let result {
                    continuation.resume(returning: result)
                    return
                }
                continuation.resume(throwing: error ?? OutlookMailError.invalidResponse)
            }
        }

        NotificationCenter.default.post(name: .outlookAuthChanged, object: true)
    }

    func signOut() {
        guard let app = try? application() else {
            NotificationCenter.default.post(name: .outlookAuthChanged, object: false)
            return
        }

        let accounts = (try? app.allAccounts()) ?? []
        for account in accounts {
            _ = try? app.remove(account)
        }

        NotificationCenter.default.post(name: .outlookAuthChanged, object: false)
    }

    @MainActor
    @discardableResult
    func syncRecentMessageCache(emailContext: ModelContext, todoContext: ModelContext) async throws -> EmailCacheSyncResult {
        let lookbackDays = recentMessageLookbackDays(fallback: 7)
        let snapshot = try await fetchRecentMessageSyncSnapshot(lookbackDays: lookbackDays)
        let providerRawValue = MailProvider.outlook.rawValue
        let existingDescriptor = FetchDescriptor<EmailMessage>(
            predicate: #Predicate<EmailMessage> { email in
                email.providerRawValue == providerRawValue
            }
        )
        let existing = (try? emailContext.fetch(existingDescriptor)) ?? []
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.providerMessageID, $0) })

        var upsertedMessageCount = 0
        for message in snapshot.messages {
            let body = normalizedBody(from: message)
            let sender = senderDisplay(from: message.from)
            let receivedAt = message.receivedDateTime ?? .distantPast
            let subject = message.subject ?? ""
            let snippet = message.bodyPreview ?? ""
            let threadID = message.conversationId ?? ""
            let isRead = message.isRead ?? false

            if let email = existingByID[message.id] {
                var didChange = false
                if email.id != message.id {
                    email.id = message.id
                    didChange = true
                }
                if email.rawMessageID != message.id {
                    email.rawMessageID = message.id
                    didChange = true
                }
                if email.providerRawValue != providerRawValue {
                    email.providerRawValue = providerRawValue
                    didChange = true
                }
                if email.threadID != threadID {
                    email.threadID = threadID
                    didChange = true
                }
                if email.subject != subject {
                    email.subject = subject
                    didChange = true
                }
                if email.from != sender {
                    email.from = sender
                    didChange = true
                }
                if email.snippet != snippet {
                    email.snippet = snippet
                    didChange = true
                }
                if email.body != body {
                    email.body = body
                    didChange = true
                }
                if email.htmlBody != nil {
                    email.htmlBody = nil
                    didChange = true
                }
                if email.receivedAt != receivedAt {
                    email.receivedAt = receivedAt
                    didChange = true
                }
                if email.isRead != isRead {
                    email.isRead = isRead
                    didChange = true
                }
                if didChange {
                    upsertedMessageCount += 1
                }
            } else {
                let email = EmailMessage(
                    id: message.id,
                    threadID: threadID,
                    subject: subject,
                    from: sender,
                    snippet: snippet,
                    body: body,
                    htmlBody: nil,
                    receivedAt: receivedAt,
                    isRead: isRead,
                    provider: .outlook,
                    rawMessageID: message.id
                )
                emailContext.insert(email)
                upsertedMessageCount += 1
            }
        }

        let activeIDs = Set(snapshot.messages.map(\.id))
        let staleEmails = existing.filter {
            $0.receivedAt >= snapshot.lookbackCutoff && !activeIDs.contains($0.providerMessageID)
        }

        let staleRefs = Set(staleEmails.map(\.todoSourceRef))
        let todos = (try? todoContext.fetch(FetchDescriptor<Todo>())) ?? []
        var prunedTodoCount = 0

        for email in staleEmails {
            emailContext.delete(email)
        }

        for todo in todos where staleRefs.contains(todo.sourceRef) {
            NotificationService.shared.cancel(todo: todo)
            _ = CalendarService.shared.removeEmailCalendarArtifacts(for: todo)
            todoContext.delete(todo)
            prunedTodoCount += 1
        }

        if upsertedMessageCount > 0 || !staleEmails.isEmpty {
            try emailContext.save()
        }
        if prunedTodoCount > 0 {
            try todoContext.save()
        }

        return EmailCacheSyncResult(
            upsertedMessageCount: upsertedMessageCount,
            prunedMessageCount: staleEmails.count,
            prunedTodoCount: prunedTodoCount
        )
    }

    @MainActor
    func fetchAndStoreExtractedItems(context: ModelContext, allowFoundationModels: Bool = true) async throws -> EmailIngestionResult {
        let lookbackDays = recentMessageLookbackDays(fallback: 7)
        let cap = min(50, max(10, lookbackDays * 3))
        let messages = try await fetchRecentActiveMessages(lookbackDays: lookbackDays, top: cap)
        let store = EmailLearningStore.shared
        let handledRefs = store.analyzedMessageIDs().union(store.dismissedMessageIDs())

        let syntheticMessages = messages.map(makeSyntheticMessage(from:))
        let candidates = syntheticMessages.filter { !handledRefs.contains($0.id) }

        let existing = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        let existingRefs = Set(existing.map(\.sourceRef))
        let ingestionEngine = EmailIngestionEngine()

        var extractedTodos: [Todo] = []
        for message in candidates where !existingRefs.contains(message.id) {
            extractedTodos += (try? await ingestionEngine.extractTodos(from: message, allowFoundationModels: allowFoundationModels)) ?? []
        }
        let extractedEvents = (try? await ingestionEngine.extractCalendarEvents(from: candidates)) ?? []

        let filteredTodos = extractedTodos.filter {
            !store.isSuppressed($0.sourceSenderEmail) && !store.isDismissed($0.sourceRef)
        }
        let todoSourceRefs = Set(filteredTodos.filter { $0.triage == .todo }.map(\.sourceRef))
        let filteredEvents = extractedEvents.filter { todoSourceRefs.contains($0.sourceRef) }

        let result = EmailService.shared.applyExtractedItems(
            todos: filteredTodos,
            events: filteredEvents,
            to: context,
            existingRefs: existingRefs
        )

        store.recordAnalyzed(messageIDs: candidates.map(\.id))
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pieroot.todo.lastEmailFetchDate")
        return result
    }

    func fetchFullMessage(id rawMessageID: String) async throws -> GmailMessage {
        let token = try await accessToken()
        let message = try await fetchMessage(id: rawMessageID, token: token)
        return makeSyntheticMessage(from: message)
    }

    func markAsRead(messageID rawMessageID: String) async throws {
        let token = try await accessToken()
        let url = try graphURL(
            path: "/me/messages/\(rawMessageID)",
            queryItems: []
        )
        _ = try await performGraphRequest(
            url: url,
            token: token,
            method: "PATCH",
            preferTextBody: false,
            body: ["isRead": true]
        )
    }

    func trashMessage(messageID rawMessageID: String) async throws {
        let token = try await accessToken()
        let url = try graphURL(
            path: "/me/messages/\(rawMessageID)/move",
            queryItems: []
        )
        _ = try await performGraphRequest(
            url: url,
            token: token,
            method: "POST",
            preferTextBody: false,
            body: ["destinationId": "deleteditems"]
        )
    }
}

private extension OutlookMailService {
    var clientID: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "MicrosoftClientID") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasRedirectScheme: Bool {
        guard
            let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        else { return false }

        return urlTypes.contains { entry in
            let schemes = entry["CFBundleURLSchemes"] as? [String] ?? []
            return schemes.contains("msauth.\(Bundle.main.bundleIdentifier ?? "pieroot.sift-todo")")
        }
    }

    var redirectURI: String {
        "msauth.\(Bundle.main.bundleIdentifier ?? "pieroot.sift-todo")://auth"
    }

    func application() throws -> MSALPublicClientApplication {
        guard let clientID else { throw OutlookMailError.missingClientID }
        let authorityURL = URL(string: "https://login.microsoftonline.com/common")!
        let authority = try MSALAADAuthority(url: authorityURL)
        let config = MSALPublicClientApplicationConfig(
            clientId: clientID,
            redirectUri: redirectURI,
            authority: authority
        )
        config.knownAuthorities = [authority]
        return try MSALPublicClientApplication(configuration: config)
    }

    func currentAccount() async throws -> MSALAccount? {
        let app = try application()
        let parameters = MSALParameters()
        parameters.completionBlockQueue = DispatchQueue.main

        let account = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MSALAccount?, Error>) in
            app.getCurrentAccount(with: parameters) { account, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: account)
            }
        }

        if let account {
            return account
        }

        return try app.allAccounts().first
    }

    func accessToken() async throws -> String {
        #if DEBUG
        if let testAccessTokenProvider {
            return try await testAccessTokenProvider()
        }
        #endif

        guard let account = try await currentAccount() else {
            throw OutlookMailError.notAuthenticated
        }

        let app = try application()
        let parameters = MSALSilentTokenParameters(scopes: scopes, account: account)

        do {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MSALResult, Error>) in
                app.acquireTokenSilent(with: parameters) { result, error in
                    if let result {
                        continuation.resume(returning: result)
                        return
                    }
                    continuation.resume(throwing: error ?? OutlookMailError.invalidResponse)
                }
            }
            return result.accessToken
        } catch {
            if isInteractionRequired(error) {
                throw OutlookMailError.notAuthenticated
            }
            throw error
        }
    }

    func isInteractionRequired(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == MSALErrorDomain && nsError.code == MSALError.interactionRequired.rawValue
    }

    func authPresentationViewController() throws -> UIViewController {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { lhs, rhs in
                lhs.activationState == .foregroundActive && rhs.activationState != .foregroundActive
            }

        let windows = scenes.flatMap(\.windows)
        guard let root = windows.first(where: \.isKeyWindow)?.rootViewController ?? windows.first?.rootViewController else {
            throw OutlookMailError.invalidResponse
        }

        return topViewController(from: root)
    }

    func topViewController(from root: UIViewController) -> UIViewController {
        if let navigation = root as? UINavigationController, let visible = navigation.visibleViewController {
            return topViewController(from: visible)
        }
        if let tab = root as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(from: selected)
        }
        if let presented = root.presentedViewController {
            return topViewController(from: presented)
        }
        return root
    }

    func recentMessageLookbackDays(fallback defaultValue: Int) -> Int {
        let value = UserDefaults.standard.integer(forKey: "pieroot.todo.emailLookbackDays")
        return value > 0 ? min(max(value, 1), 30) : defaultValue
    }

    func fetchRecentMessageSyncSnapshot(lookbackDays: Int) async throws -> OutlookRecentMessageSyncSnapshot {
        let activeMessages = try await fetchRecentActiveMessages(lookbackDays: lookbackDays, top: 100, paginate: true)
        let cutoff = Date().addingTimeInterval(-Double(lookbackDays) * 24 * 3600)
        return OutlookRecentMessageSyncSnapshot(
            messages: activeMessages,
            lookbackCutoff: cutoff
        )
    }

    func fetchRecentActiveMessages(lookbackDays: Int, top: Int, paginate: Bool = false) async throws -> [OutlookGraphMessage] {
        let token = try await accessToken()
        let excludedFolderIDs = try await fetchExcludedFolderIDs(token: token)
        var nextURL: URL? = try recentMessagesURL(lookbackDays: lookbackDays, top: top)
        var messages: [OutlookGraphMessage] = []

        while let url = nextURL {
            let data = try await performGraphRequest(url: url, token: token, preferTextBody: true)
            let response = try graphDecoder.decode(OutlookGraphMessageListResponse.self, from: data)
            let activePageMessages = response.value.filter { message in
                guard let parentFolderId = message.parentFolderId else { return true }
                return !excludedFolderIDs.contains(parentFolderId)
            }
            messages.append(contentsOf: activePageMessages)
            nextURL = paginate ? response.nextLink.flatMap(URL.init(string:)) : nil
        }

        return messages.sorted { ($0.receivedDateTime ?? .distantPast) > ($1.receivedDateTime ?? .distantPast) }
    }

    func fetchExcludedFolderIDs(token: String) async throws -> Set<String> {
        let junk = try await fetchFolder(id: "junkemail", token: token)
        let deleted = try await fetchFolder(id: "deleteditems", token: token)
        return Set([junk.id, deleted.id])
    }

    func fetchFolder(id: String, token: String) async throws -> OutlookGraphFolder {
        let url = try graphURL(path: "/me/mailFolders/\(id)", queryItems: [])
        let data = try await performGraphRequest(url: url, token: token, preferTextBody: false)
        do {
            return try graphDecoder.decode(OutlookGraphFolder.self, from: data)
        } catch {
            throw OutlookMailError.invalidResponse
        }
    }

    func fetchMessage(id rawMessageID: String, token: String) async throws -> OutlookGraphMessage {
        let url = try graphURL(
            path: "/me/messages/\(rawMessageID)",
            queryItems: [
                URLQueryItem(name: "$select", value: "id,conversationId,internetMessageId,subject,from,bodyPreview,body,receivedDateTime,isRead,parentFolderId")
            ]
        )
        let data = try await performGraphRequest(url: url, token: token, preferTextBody: true)
        do {
            return try graphDecoder.decode(OutlookGraphMessage.self, from: data)
        } catch {
            throw OutlookMailError.invalidResponse
        }
    }

    func recentMessagesURL(lookbackDays: Int, top: Int) throws -> URL {
        let cutoff = Date().addingTimeInterval(-Double(lookbackDays) * 24 * 3600)
        return try graphURL(
            path: "/me/messages",
            queryItems: [
                URLQueryItem(name: "$filter", value: "receivedDateTime ge \(graphFilterFormatter.string(from: cutoff))"),
                URLQueryItem(name: "$orderby", value: "receivedDateTime desc"),
                URLQueryItem(name: "$top", value: String(top)),
                URLQueryItem(name: "$select", value: "id,conversationId,internetMessageId,subject,from,bodyPreview,body,receivedDateTime,isRead,parentFolderId")
            ]
        )
    }

    func graphURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0\(path)")
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw OutlookMailError.invalidResponse
        }
        return url
    }

    func performGraphRequest(
        url: URL,
        token: String,
        method: String = "GET",
        preferTextBody: Bool,
        body: [String: Any]? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var preferValues = ["IdType=\"ImmutableId\""]
        if preferTextBody {
            preferValues.append("outlook.body-content-type=\"text\"")
        }
        request.setValue(preferValues.joined(separator: ", "), forHTTPHeaderField: "Prefer")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OutlookMailError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OutlookMailError.apiFailed
        }
        return data
    }

    func normalizedBody(from message: OutlookGraphMessage) -> String {
        let content = message.body?.content ?? ""
        let normalized: String
        if let contentType = message.body?.contentType?.lowercased(), contentType == "html" {
            normalized = stripHTML(content)
        } else {
            normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !normalized.isEmpty {
            return normalized
        }
        return (message.bodyPreview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func senderDisplay(from container: OutlookGraphRecipientContainer?) -> String {
        guard let address = container?.emailAddress else { return "" }
        let name = (address.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (address.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch (name.isEmpty, email.isEmpty) {
        case (false, false):
            return "\(name) <\(email)>"
        case (false, true):
            return name
        case (true, false):
            return email
        case (true, true):
            return ""
        }
    }

    func makeSyntheticMessage(from message: OutlookGraphMessage) -> GmailMessage {
        GmailMessage(
            id: "outlook:\(message.id)",
            threadID: message.conversationId ?? "",
            messageID: message.internetMessageId ?? "",
            subject: message.subject ?? "",
            from: senderDisplay(from: message.from),
            snippet: message.bodyPreview ?? "",
            body: normalizedBody(from: message),
            htmlBody: nil,
            receivedAt: message.receivedDateTime ?? .distantPast,
            labelIds: [],
            isBulk: false
        )
    }

    func stripHTML(_ html: String) -> String {
        var text = html
        let blockPatterns = [
            "<style[^>]*>[\\s\\S]*?</style>",
            "<script[^>]*>[\\s\\S]*?</script>",
            "<!--[\\s\\S]*?-->"
        ]
        for pattern in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                text = regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(text.startIndex..., in: text),
                    withTemplate: ""
                )
            }
        }

        let blockTags = ["</p>", "</div>", "<br>", "<br/>", "<br />", "</li>", "</h1>", "</h2>", "</h3>", "</h4>", "</tr>"]
        for tag in blockTags {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }

        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
            ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        if let regex = try? NSRegularExpression(pattern: "\\n{3,}") {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "\n\n"
            )
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var graphFilterFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    var graphDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.fractionalDateFormatter.date(from: value) ?? Self.isoDateFormatter.date(from: value) {
                return date
            }
            throw OutlookMailError.invalidResponse
        }
        return decoder
    }

    static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

extension Notification.Name {
    static let outlookAuthChanged = Notification.Name("pieroot.todo.outlookAuthChanged")
}

enum OutlookMailError: LocalizedError, Equatable {
    case missingClientID
    case notAuthenticated
    case apiFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Microsoft Client ID가 Info.plist의 MicrosoftClientID 키에 설정되어 있지 않습니다."
        case .notAuthenticated:
            return "Outlook에 로그인되어 있지 않습니다."
        case .apiFailed:
            return "Microsoft Graph API 호출에 실패했습니다."
        case .invalidResponse:
            return "Outlook 응답을 해석하지 못했습니다."
        }
    }
}

private struct OutlookRecentMessageSyncSnapshot {
    let messages: [OutlookGraphMessage]
    let lookbackCutoff: Date
}

private struct OutlookGraphMessageListResponse: Decodable {
    let value: [OutlookGraphMessage]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

private struct OutlookGraphFolder: Decodable {
    let id: String
}

private struct OutlookGraphBody: Decodable {
    let contentType: String?
    let content: String?
}

private struct OutlookGraphRecipientContainer: Decodable {
    let emailAddress: OutlookGraphEmailAddress?
}

private struct OutlookGraphEmailAddress: Decodable {
    let name: String?
    let address: String?
}

private struct OutlookGraphMessage: Decodable {
    let id: String
    let conversationId: String?
    let internetMessageId: String?
    let subject: String?
    let bodyPreview: String?
    let body: OutlookGraphBody?
    let receivedDateTime: Date?
    let isRead: Bool?
    let parentFolderId: String?
    let from: OutlookGraphRecipientContainer?
}
